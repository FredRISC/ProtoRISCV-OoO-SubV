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
    input [5:0] dispatch_phys_tag, // Phys tag of the instruction to be sent to CDB
    output logic [LSQ_TAG_WIDTH-1:0] alloc_tag, // queue entry's id sent to dispatch_stage for matching after addr calculation
    output lsq_full,
    
    // 2. Execution Interface (Out-of-Order Address Calculation)
    input [XLEN-1:0] exe_addr,			// Calculated address
    input [XLEN-1:0] exe_data,      // Store data
    input [LSQ_TAG_WIDTH-1:0] exe_lsq_tag, // Which entry to update? = earlier sent alloc_tag 
    input exe_load_valid,
    input exe_store_valid,
    
    // 3. CDB Interface
    output logic [XLEN-1:0] load_data, // Data to CDB 
    output logic [5:0] cdb_phys_tag_out, // Physical tag for CDB
    output logic load_data_valid, // CDB input is valid
    
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
    
    // 6. Disambiguation (Speculative Load)
    output logic flush_pipeline, // Asserted if store-load ordering violation detected
    
    // 7. Status (retained outputs for compatibility, logic internal)
    output load_blocked,
    output store_blocked
);

    // ========================================================================
    // Unified Queue Entry Structure
    // ========================================================================
    typedef struct packed {
        logic is_store;
        logic [XLEN-1:0] address;       
        logic [XLEN-1:0] data;          // Data to store, or data loaded
        logic [5:0] phys_tag; // Physical tag
        logic addr_valid;     // Is address calculated?
        logic data_valid;     // Is data ready? (Loaded from mem/fwd, or computed for store)
        logic valid;
        logic sent_to_mem; // Track if request sent to memory (MSHR behavior)
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
    // Memory Read Arbiter (MSHR Logic)
    // ========================================================================
    
    logic [LSQ_TAG_WIDTH-1:0] issue_load_idx;
    logic issue_load_valid;
    
    always @(*) begin
        issue_load_valid = 1'b0;
        issue_load_idx = 0;
        dmem_read_addr = 0;
        dmem_read_en = 1'b0;
        
        // Scan from Head (Oldest) to Tail
        for (int i = 0; i < LSQ_SIZE; i++) begin
            logic [LSQ_TAG_WIDTH-1:0] ptr = head + i[LSQ_TAG_WIDTH-1:0];
            if (ptr == tail) break; // Stop at valid entries
            
            if (lsq[ptr].valid && !lsq[ptr].is_store && lsq[ptr].addr_valid && 
                !lsq[ptr].data_valid && !lsq[ptr].sent_to_mem) begin
                issue_load_idx = ptr; // record the issued idx
                issue_load_valid = 1'b1; 
                dmem_read_addr = lsq[ptr].address; 
                dmem_read_en = 1'b1; 
                break; // Issue one load per cycle
            end
        end
    end

    // ========================================================================
    // Execution: Disambiguation & Forwarding Logic
    // ========================================================================
    logic [XLEN-1:0] forwarded_data;
    logic forwarding_valid;
    
    always @(*) begin
        flush_pipeline = 1'b0;
        forwarding_valid = 1'b0;
        forwarded_data = 0;
        
        if (exe_store_valid) begin
            // 1. DISAMBIGUATION (Store Executed)
            // Check all YOUNGER loads (from exe_lsq_tag + 1 to tail).
            for (int k = 1; k < LSQ_SIZE; k++) begin
                logic [LSQ_TAG_WIDTH-1:0] ptr = exe_lsq_tag + k[LSQ_TAG_WIDTH-1:0];
                if (ptr == tail) break; // Checked all younger
                
                // If it's a speculative load that already fetched data from this address
                if (lsq[ptr].valid && !lsq[ptr].is_store && lsq[ptr].addr_valid && lsq[ptr].data_valid) begin
                    if (lsq[ptr].address == exe_addr) begin
                        flush_pipeline = 1'b1;
                    end
                end
            end
        end else if (exe_load_valid) begin
            // 2. FORWARDING (Load Executed)
            // Scan backwards from load (exe_lsq_tag - 1) to head for the newest older store
            for (int k = 1; k < LSQ_SIZE; k++) begin
                logic [LSQ_TAG_WIDTH-1:0] ptr = exe_lsq_tag - k[LSQ_TAG_WIDTH-1:0];
                
                if (lsq[ptr].valid && lsq[ptr].is_store && lsq[ptr].addr_valid) begin
                    if (lsq[ptr].address == exe_addr) begin
                        // Found the youngest older store.
                        // Since RS waits for both operands to issue a store, its data is ready!
                        forwarded_data = lsq[ptr].data;
                        forwarding_valid = 1'b1;
                        break;
                    end
                end
                if (ptr == head) break; // Reached the oldest entry
            end
        end
    end
    
    // ========================================================================
    // State Updates (Allocation, Memory Return, Commit, Retirement)
    // ========================================================================
    
    logic [LSQ_TAG_WIDTH-1:0] mem_inflight_idx;
    logic mem_inflight_valid;
    
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
                lsq[tail].phys_tag <= dispatch_phys_tag;
                lsq[tail].addr_valid <= 1'b0;
                lsq[tail].data_valid <= 1'b0;
                lsq[tail].sent_to_mem <= 1'b0;
                lsq[tail].committed <= 1'b0;
                tail <= next_tail;
            end
            
            // 2. Execution (Address Calculation)
            if (exe_load_valid) begin
                lsq[exe_lsq_tag].address <= exe_addr;
                lsq[exe_lsq_tag].addr_valid <= 1'b1;
                
                if (forwarding_valid) begin
                    lsq[exe_lsq_tag].data <= forwarded_data;
                    lsq[exe_lsq_tag].data_valid <= 1'b1;
                end
            end
            if (exe_store_valid) begin
                lsq[exe_lsq_tag].address <= exe_addr;
                lsq[exe_lsq_tag].data <= exe_data;
                lsq[exe_lsq_tag].addr_valid <= 1'b1;
                lsq[exe_lsq_tag].data_valid <= 1'b1;
            end
            
            // Mark Sent to Memory
            if (issue_load_valid) begin
                lsq[issue_load_idx].sent_to_mem <= 1'b1;
                mem_inflight_idx <= issue_load_idx;
                mem_inflight_valid <= 1'b1;
            end
            
            // Memory Response
            if (dmem_read_valid && mem_inflight_valid) begin
                lsq[mem_inflight_idx].data <= dmem_read_data;
                lsq[mem_inflight_idx].data_valid <= 1'b1;
                mem_inflight_valid <= 1'b0; // Request done
            end
            
            // 3. Commit Pointer Advance (from ROB)
            if (commit_lsq && lsq[commit_ptr].valid) begin
                lsq[commit_ptr].committed <= 1'b1;
                commit_ptr <= commit_ptr + 1;
            end
            
            // 4. Memory Write & Queue Retirement (Popping Head)
            if (head != commit_ptr) begin // Head has been committed by ROB
                if (!lsq[head].is_store) begin
                    // Loads retire immediately after commit
                    lsq[head].valid <= 1'b0;
                    head <= head + 1;
                end else if (lsq[head].committed) begin
                    // Stores retire when sent to memory
                    // Assuming 1 cycle write acceptance for dmem_write_en
                    lsq[head].valid <= 1'b0;
                    head <= head + 1;
                end
            end
        end
    end
    
    // Drive Memory Write Port (Combinational based on Head)
    assign dmem_write_en = (head != commit_ptr) && lsq[head].is_store && lsq[head].committed;
    assign dmem_write_addr = lsq[head].address;
    assign dmem_write_data = lsq[head].data;

    // ========================================================================
    // Output Data Selection (Forwarding vs Memory to CDB)
    // ========================================================================
    always @(*) begin
        load_data = 0;
        load_data_valid = 1'b0;
        cdb_phys_tag_out = 0;
        
        // Priority 1: Instant forwarding for EXECUTING load
        if (exe_load_valid && forwarding_valid) begin
            load_data = forwarded_data;
            load_data_valid = 1'b1;
            cdb_phys_tag_out = lsq[exe_lsq_tag].phys_tag;
        end 
        // Priority 2: Memory Response (for Pending Load)
        else if (dmem_read_valid && mem_inflight_valid) begin
            load_data = lsq[mem_inflight_idx].data; // Data just captured
            load_data_valid = 1'b1;
            cdb_phys_tag_out = lsq[mem_inflight_idx].phys_tag;
        end
    end

endmodule
