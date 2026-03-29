// ============================================================================
// load_store_queue.sv - Load-Store Queue with Memory Hazard Detection
// ============================================================================
// Implements load/store queues with address hazard detection (WAR, RAW, WAW)
// and store-to-load forwarding.

`include "../riscv_header.sv"

module load_store_queue #(
    parameter LSQ_SIZE = 16,
    parameter XLEN = 32
) (
    input clk,
    input rst_n,
    input flush,

    // 1. Dispatch Allocation Interface (In-Order)
    input alloc_req,
    input alloc_is_store,
    input [2:0] alloc_size,
    input [5:0] dispatch_phys_tag, // Phys tag of the instruction to be sent to CDB
    output logic [LSQ_TAG_WIDTH-1:0] alloc_tag, // queue entry's id sent to dispatch_stage for matching after addr calculation
    output lsq_full,
    
    // 2. Execution Interface (Out-of-Order Address Calculation)
    input [XLEN-1:0] exe_addr,  // Calculated address
    input [XLEN-1:0] exe_data,  // Store data
    input [LSQ_TAG_WIDTH-1:0] exe_lsq_tag, // Which entry to update? = earlier sent alloc_tag 
    input exe_load_valid,
    input exe_store_valid,
    
    // 3. CDB Interface
    output logic [XLEN-1:0] lsq_data_out, // Data to CDB 
    output logic [5:0] cdb_phys_tag_out, // PReg tag for CDB and ROB wakeup
    output logic lsq_out_valid, // Valid signal for CDB and ROB wakeup (stores also use this to wake up ROB)
    
    // 4. Commit Interface
    input commit_lsq, // From ROB/Commit: Retire the oldest load/store
    
    // 5. Dual Memory Interface
    // Read Port
    output logic [XLEN-1:0] dmem_read_addr,
    output logic dmem_read_en,
    input [XLEN-1:0] dmem_read_data,
    input dmem_read_valid,
    
    // Write Port
    output logic [XLEN-1:0] dmem_write_addr,
    output logic [XLEN-1:0] dmem_write_data,
    output logic dmem_write_en,
    input dmem_write_ready, // Handshake: memory is ready to accept the store
    output logic [3:0] dmem_be,
    
    // 6. Disambiguation (Speculative Load)
    output logic flush_pipeline, // Asserted if store-load ordering violation detected
    output logic [5:0] lsq_violation_tag, // PReg tag of the violating load
    
    // 7. Status (retained outputs for compatibility, logic internal)
    output load_blocked,
    output store_blocked
);

    // ========================================================================
    // Unified Queue Entry Structure
    // ========================================================================
    typedef struct packed {
        logic is_store;
        logic [XLEN-1:0] address;   // Target address for load/store
        logic [XLEN-1:0] data;  // Data to store, or data loaded
        logic [5:0] phys_tag; // Physical tag
        logic [2:0] mem_size; // Size and sign-extension behavior
        logic addr_valid;     // Is address ready?
        logic data_valid;     // Is data ready?
        logic broadcasted;    // Has the tag been broadcast on CDB?
        logic valid;
        logic sent_to_mem; // Track if request sent to memory
        logic committed;   // Ready to retire/write to memory
    } lsq_entry_t;
    
    lsq_entry_t lsq [LSQ_SIZE-1:0]; 
    
    logic [LSQ_TAG_WIDTH-1:0] head, tail, commit_ptr;
    logic [LSQ_TAG_WIDTH-1:0] next_tail;
    
    assign next_tail = tail + 1;
    
    // Output Allocation Tags (to Dispatch)
    assign alloc_tag = tail;
    assign lsq_full = (next_tail == head) && lsq[tail].valid;
    assign load_blocked = 1'b0; 
    assign store_blocked = 1'b0;
    
    // ========================================================================
    // Data Formatting Function (Sign/Zero Extension based on offset)
    // ========================================================================
    function logic [XLEN-1:0] format_data(input [XLEN-1:0] raw_data, input [2:0] size, input [1:0] offset);
        logic [7:0] b;
        logic [15:0] h;
        begin
            case (offset)
                2'b00: b = raw_data[7:0];
                2'b01: b = raw_data[15:8];
                2'b10: b = raw_data[23:16];
                2'b11: b = raw_data[31:24];
            endcase
            h = offset[1] ? raw_data[31:16] : raw_data[15:0];
            case (size)
                3'b000: format_data = {{24{b[7]}}, b}; // LB
                3'b100: format_data = {24'b0, b};      // LBU
                3'b001: format_data = {{16{h[15]}}, h};// LH
                3'b101: format_data = {16'b0, h};      // LHU
                default: format_data = raw_data;       // LW (3'b010)
            endcase
        end
    endfunction
    
    // ========================================================================
    // Load Request Selector (Scan from Head for Ready Loads) 
    // ========================================================================
    logic issue_load_ready;
    logic [LSQ_TAG_WIDTH-1:0] issue_load_idx;
    logic issue_load_valid;
    logic [LSQ_TAG_WIDTH-1:0] mem_inflight_idx;
    logic mem_inflight_valid;
                
    always @(*) begin
        issue_load_valid = 1'b0;
        issue_load_idx = 0;
        dmem_read_addr = 0;
        dmem_read_en = 1'b0;
        
        // Scan from Head (Oldest) to Tail
        for (int i = 0; i < LSQ_SIZE; i++) begin
            logic [LSQ_TAG_WIDTH-1:0] ptr = head + i[LSQ_TAG_WIDTH-1:0];

            // A load is ready to issue (no memory load response pending and address/data ready)
            assign issue_load_ready = lsq[ptr].valid && !lsq[ptr].is_store && lsq[ptr].addr_valid && 
                !lsq[ptr].data_valid && !lsq[ptr].sent_to_mem && !mem_inflight_valid;
            if (issue_load_ready) begin // prepare to issue it in the next cycle
                issue_load_idx = ptr; // record the ptr for tracking
                issue_load_valid = 1'b1; // mark that we have a load to issue in the next cycle
                break;
            end
            else begin
                issue_load_valid = 1'b0;
            end

            if (ptr == tail) break;
        end
    end

    // ========================================================================
    // Disambiguation & Forwarding Logic 
    // (Word accesses (LW/SW) must have addresses ending in 00 (byte offset 0). Halfwords must end in 0)
    // ========================================================================
    logic [XLEN-1:0] forwarded_data;
    logic forwarding_valid;
    
    always @(*) begin
        flush_pipeline = 1'b0;
        lsq_violation_tag = 6'b0;
        forwarding_valid = 1'b0;
        forwarded_data = 0;
        
        if (exe_store_valid) begin // Check at the moment we receive the calculated st address from execute stage
            // 1. DISAMBIGUATION
            for (int k = 1; k < LSQ_SIZE; k++) begin
                logic [LSQ_TAG_WIDTH-1:0] ptr = exe_lsq_tag + k[LSQ_TAG_WIDTH-1:0]; //check younger load entries
                
                // check younger loads that has already calculated its address
                if (lsq[ptr].valid && !lsq[ptr].is_store && lsq[ptr].addr_valid) begin
                    if (lsq[ptr].address[XLEN-1:2] == exe_addr[XLEN-1:2]) begin
                        flush_pipeline = 1'b1;
                        lsq_violation_tag = lsq[ptr].phys_tag; // mark the younger load as violation
                    end
                end
                if (ptr == tail) break; // Checked all younger entries
            end
        end 
        else if (exe_load_valid) begin // Check at the moment we receive the calculated ld address from execute stage
            // 2. FORWARDING 
            for (int k = 1; k < LSQ_SIZE; k++) begin
                logic [LSQ_TAG_WIDTH-1:0] ptr = exe_lsq_tag - k[LSQ_TAG_WIDTH-1:0]; //check older entries
                
                // If it's an older store with valid address, check for Word-Aligned Overlap
                if (lsq[ptr].valid && lsq[ptr].is_store && lsq[ptr].addr_valid) begin
                    if (lsq[ptr].address[XLEN-1:2] == exe_addr[XLEN-1:2]) begin
                        if (lsq[ptr].mem_size == 3'b010) begin // Assuming strict memory alignment, otherwise complex to forward and will create a long critcal path
                            forwarded_data = lsq[ptr].data; 
                            forwarding_valid = 1'b1;
                        end 
                        else begin
                            // Potenial Overlap:  Simplified logic to flush the load
                            // and let it retry after the store permanently writes to memory.
                            flush_pipeline = 1'b1;
                            lsq_violation_tag = lsq[exe_lsq_tag].phys_tag;
                        end
                        break;
                    end
                end
                if (ptr == head) break; // Checked all older entries
            end
        end
    end
    
    // ========================================================================
    // State Updates (Allocation, Memory Return, Commit, Retirement)
    // ========================================================================
    logic [LSQ_TAG_WIDTH-1:0] broadcast_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < LSQ_SIZE; i++) begin
                lsq[i].valid <= 1'b0;
            end
            head <= 0;
            tail <= 0;
            commit_ptr <= 0;
            mem_inflight_valid <= 1'b0;
        end else begin
            // 1. Allocation (Dispatch)
            if (alloc_req && !lsq_full) begin
                lsq[tail].valid <= 1'b1;
                lsq[tail].is_store <= alloc_is_store;
                lsq[tail].mem_size <= alloc_size; // Record data width at dispatch!
                lsq[tail].phys_tag <= dispatch_phys_tag;
                lsq[tail].addr_valid <= 1'b0;
                lsq[tail].data_valid <= 1'b0;
                lsq[tail].broadcasted <= 1'b0;
                lsq[tail].sent_to_mem <= 1'b0;
                lsq[tail].committed <= 1'b0;
                tail <= next_tail;
            end
            
            // 2. Obtaining target address from execute_stage
            if (exe_load_valid) begin // Load address calculation has finished
                lsq[exe_lsq_tag].address <= exe_addr; // Calculated load address
                lsq[exe_lsq_tag].addr_valid <= 1'b1; // Mark the address as valid
                
                if (forwarding_valid) begin
                    lsq[exe_lsq_tag].data <= format_data(forwarded_data, lsq[exe_lsq_tag].mem_size , exe_addr[1:0]);
                    lsq[exe_lsq_tag].data_valid <= 1'b1;
                end
                // else: wait for memory read request issue/response
                // Other fields remain unchanged
            end
            if (exe_store_valid) begin // Store address calculation has finished
                lsq[exe_lsq_tag].address <= exe_addr; // Calculated store address
                lsq[exe_lsq_tag].data <= exe_data; // Data to be stored to Memory
                lsq[exe_lsq_tag].addr_valid <= 1'b1; // Mark the address as valid
                lsq[exe_lsq_tag].data_valid <= 1'b1; // Mark the data as valid. 
                // The store can wake up in ROB now, but remains in LSQ until retired/committed by ROB and issued to memory
            end
            
            // 3. Issuing load memory request (setting mem_inflight_valid and tracking inflight request)
            if (issue_load_valid) begin
                dmem_read_addr <= lsq[issue_load_idx].address; // Drive the output read memory address for "a" cycle
                dmem_read_en <= 1'b1;  // Drive the output read enable for "a" cycle
                lsq[issue_load_idx].sent_to_mem <= 1'b1;
                mem_inflight_idx <= issue_load_idx;
                mem_inflight_valid <= 1'b1;
            end
            else begin
                issue_load_idx <= issue_load_idx; // Hold the index steady when not issuing
                dmem_read_en <= 1'b0; // De-assert read enable when not issuing a load
            end
            
            // 4. Receiving Load Memory Response
            if (dmem_read_valid && mem_inflight_valid) begin 
                lsq[mem_inflight_idx].data <= format_data(dmem_read_data, lsq[mem_inflight_idx].mem_size, lsq[mem_inflight_idx].address[1:0]);
                lsq[mem_inflight_idx].data_valid <= 1'b1;
                mem_inflight_valid <= 1'b0; // Request done
            end
            
            // 5. Commit Pointer Advance 
            if (commit_lsq && lsq[commit_ptr].valid) begin
                lsq[commit_ptr].committed <= 1'b1;
                commit_ptr <= commit_ptr + 1; // ptr < commit_ptr means committed
            end
            
            // 6. Memory Write & Queue Retirement (Popping Head)
            if (head != commit_ptr) begin // Head has been marked as committed
                if (!lsq[head].is_store) begin // Load at head can retire as soon as committed (boradcast had happened so it can commit)
                    lsq[head].valid <= 1'b0; // Free the entry
                    head <= head + 1; // Advance head pointer
                end 
                else if (lsq[head].committed && dmem_write_ready) begin // Store at head retires when memory accepts it
                    lsq[head].valid <= 1'b0;
                    head <= head + 1;
                end
            end
            
            // 7. CDB Broadcast Acknowledgment
            // Mark the entry as broadcasted so the decoupled scanner moves to the next one.
            if (lsq_out_valid) begin
                lsq[broadcast_idx].broadcasted <= 1'b1;
            end
        end
    end
    
    // ========================================================================
    // Store Operation: Drive Memory Write Port
    // ========================================================================
    assign dmem_write_en = lsq[head].is_store && lsq[head].committed; // don't need to check addr/data valid here
    assign dmem_write_addr = {lsq[head].address[XLEN-1:2], 2'b00}; // Word-aligned memory bus
    
    logic [1:0] byte_offset;
    assign byte_offset = lsq[head].address[1:0];
    
    // Generate Byte Enables and formatting store data
    always @(*) begin
        dmem_be = 4'b0000;
        dmem_write_data = 32'h0;
        if(lsq[head].mem_size == 3'b000) begin // SB (Store Byte)
            dmem_be = 4'b0001 << byte_offset; 
            dmem_write_data = {4{lsq[head].data[7:0]}}; // Replicate byte, dmem_be masks it
        end 
        else if(lsq[head].mem_size == 3'b001) begin // SH (Store Halfword)
            dmem_be = byte_offset[1] ? 4'b1100 : 4'b0011; // RISC-V specifies halfwords must be 2-byte aligned. byte_offset[0] is ignored.
            dmem_write_data = {2{lsq[head].data[15:0]}};
        end 
        else begin // SW (Store Word)
            dmem_be = 4'b1111;
            dmem_write_data = lsq[head].data;
        end
    end

    // ========================================================================
    // CDB Interface: Decoupled Broadcast Scanner
    // ========================================================================
    
    always @(*) begin
        lsq_data_out = 0;
        lsq_out_valid = 1'b0;
        cdb_phys_tag_out = 0;
        broadcast_idx = 0;
        
        // Scan from Head to Tail for oldest un-broadcasted ready entry
        for (int i = 0; i < LSQ_SIZE; i++) begin
            logic [LSQ_TAG_WIDTH-1:0] ptr = head + i[LSQ_TAG_WIDTH-1:0];
            
            // Broadcast when load has valid data or store has valid address
            if (lsq[ptr].valid && !lsq[ptr].broadcasted) begin
                if ((!lsq[ptr].is_store && lsq[ptr].data_valid) || 
                    (lsq[ptr].is_store && lsq[ptr].addr_valid)) begin
                    
                    lsq_out_valid = 1'b1;
                    cdb_phys_tag_out = lsq[ptr].phys_tag;
                    lsq_data_out = lsq[ptr].data; // Already cleanly formatted!
                    broadcast_idx = ptr;
                    break;
                end
            end
            if (ptr == tail) break;
        end
    end

endmodule
