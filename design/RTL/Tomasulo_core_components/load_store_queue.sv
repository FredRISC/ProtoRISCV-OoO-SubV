// ============================================================================
// load_store_queue.sv - Load-Store Queue with Memory Hazard Detection
// ============================================================================
// Implements load/store queues with address hazard detection (WAR, RAW, WAW)
// and store-to-load forwarding.

`include "../riscv_header.sv"

module load_store_queue #(
    parameter LSQ_LQ_SIZE = 8,
    parameter LSQ_SQ_SIZE = 8,
    parameter XLEN = 32
) (
    input clk,
    input rst_n,
    input flush,
    
    // Load interface
    input [XLEN-1:0] load_addr,
    input [5:0] load_tag,
    input load_valid,
    output logic [XLEN-1:0] load_data,
    output logic [5:0] load_tag_out,
    output logic load_data_valid,
    output load_blocked,
    
    // Store interface
    input [XLEN-1:0] store_addr,
    input [XLEN-1:0] store_data,
    input store_valid,
    input commit_store, // From ROB/Commit: Retire the oldest store
    output store_blocked,
    
    // Dual Memory Interface
    // Read Port
    output logic [XLEN-1:0] dmem_read_addr,
    output logic dmem_read_en,
    input [XLEN-1:0] dmem_read_data,
    input dmem_read_valid,
    
    // Write Port
    output logic [XLEN-1:0] dmem_write_addr,
    output logic [XLEN-1:0] dmem_write_data,
    output logic dmem_write_en,
    
    // Disambiguation
    output logic flush_pipeline, // Asserted if store-load ordering violation detected
    
    // Status
    output lsq_lq_full,
    output lsq_sq_full
);

    // ========================================================================
    // Load Queue Entry & Store Queue Entry
    // ========================================================================
    typedef struct packed {
        logic [XLEN-1:0] address;
        logic [5:0] tag;
        logic valid;
        logic complete;
        logic sent_to_mem; // Track if request sent to memory (MSHR behavior)
        logic forwarded;
    } lq_entry_t;
    
    typedef struct packed {
        logic [XLEN-1:0] address;
        logic [XLEN-1:0] data;
        logic valid;
        logic complete;
        logic committed; // Ready to write to memory        
    } sq_entry_t;
    
    lq_entry_t load_queue [LSQ_LQ_SIZE-1:0]; // Circular buffer for load queue
    sq_entry_t store_queue [LSQ_SQ_SIZE-1:0]; // Circular buffer for store queue
    
    logic [$clog2(LSQ_LQ_SIZE)-1:0] lq_head, lq_tail; // Pointers for load queue
    logic [$clog2(LSQ_SQ_SIZE)-1:0] sq_head, sq_tail; // Pointers for store queue
    
    // ========================================================================
    // Allocation-Time Forwarding (All valid Store in SQ are older than the new Load)
    // ========================================================================   
    logic [XLEN-1:0] forwarded_data;
    logic forwarding_valid;
    
    always @(*) begin
        forwarding_valid = 1'b0;
        forwarded_data = 0;
        
        // Check if load address matches any pending store (store-to-load forwarding)
        // Iterate BACKWARDS from Tail to Head to find the YOUNGEST match first.
        // Note: This allocation logic assumes in-order allocation (Tail is youngest).
        for (int i = 0; i < LSQ_SQ_SIZE; i++) begin
            // Use automatic width for loop variable to avoid truncation warnings
            // Calculate circular pointer backwards: (tail - 1 - i) % SIZE
            logic [$clog2(LSQ_SQ_SIZE)-1:0] ptr = (sq_tail - 1 - i[$clog2(LSQ_SQ_SIZE)-1:0]);
            if (store_queue[ptr].valid && (store_queue[ptr].address == load_addr)) begin
                forwarded_data = store_queue[ptr].data;
                forwarding_valid = 1'b1;
                break; // Found the youngest match, stop searching
            end
        end
    end
    
    // ========================================================================
    // Memory Read Arbiter (MSHR Logic)
    // ========================================================================
    // Selects the OLDEST pending load that hasn't been sent to memory yet.
    // This allows FCFS handling of cache misses.
    
    logic [$clog2(LSQ_LQ_SIZE)-1:0] issue_load_idx;
    logic issue_load_valid;
    
    always @(*) begin
        issue_load_valid = 1'b0;
        issue_load_idx = 0;
        dmem_read_addr = 0;
        dmem_read_en = 1'b0;
        
        // Scan from Head (Oldest) to Tail
        for (int i = 0; i < LSQ_LQ_SIZE; i++) begin
            logic [$clog2(LSQ_LQ_SIZE)-1:0] ptr = lq_head + i[$clog2(LSQ_LQ_SIZE)-1:0];
            
            // If valid, not complete, not forwarded, and not yet sent to memory
            if (load_queue[ptr].valid && !load_queue[ptr].complete && 
                !load_queue[ptr].forwarded && !load_queue[ptr].sent_to_mem) begin
                
                issue_load_idx = ptr;
                issue_load_valid = 1'b1;
                dmem_read_addr = load_queue[ptr].address;
                dmem_read_en = 1'b1;
                break; // Found oldest
            end
        end
    end

    // ========================================================================
    // Memory Write Arbiter (Retirement Logic)
    // ========================================================================
    // Only writes to memory when the store at HEAD is committed.
    
    always @(*) begin
        dmem_write_en = 1'b0;
        dmem_write_addr = 0;
        dmem_write_data = 0;
        
        // Store at head is valid, executed (complete), and committed?
        // Note: commit_store signal retires the head. The actual memory write
        // happens on the entry at sq_head if valid.
        if (store_queue[sq_head].valid && store_queue[sq_head].committed) begin
            dmem_write_en = 1'b1;
            dmem_write_addr = store_queue[sq_head].address;
            dmem_write_data = store_queue[sq_head].data;
        end
    end

    // ========================================================================
    // WAR/Memory Disambiguation Check
    // ========================================================================
    
    always @(*) begin
        flush_pipeline = 1'b0;
        
        // Disambiguation placeholder:
        // Check if any YOUNGER load to same address has already executed/completed.
        // This requires accurate age tracking relative to the store.
    end
    
    // ========================================================================
    // Queue Management
    // ========================================================================
    
    // Track which load is currently being serviced by memory
    logic [$clog2(LSQ_LQ_SIZE)-1:0] mem_inflight_load_idx;
    logic mem_inflight_valid;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < LSQ_LQ_SIZE; i++) begin
                load_queue[i].valid <= 1'b0;
                load_queue[i].sent_to_mem <= 1'b0;
            end
            for (int i = 0; i < LSQ_SQ_SIZE; i++) begin
                store_queue[i].valid <= 1'b0;
                store_queue[i].committed <= 1'b0;
            end
            lq_head <= 0;
            lq_tail <= 0;
            sq_head <= 0;
            sq_tail <= 0;
            mem_inflight_valid <= 1'b0;
        end else begin
            
            // --- LOAD QUEUE ---
            
            // Allocate load queue entry
            if (load_valid && !lsq_lq_full) begin
                load_queue[lq_tail].address <= load_addr; // Set address
                load_queue[lq_tail].tag <= load_tag;      // Set tag
                load_queue[lq_tail].valid <= 1'b1; // Mark valid
                
                if (forwarding_valid) begin // If already forwarded, mark complete immediately
                    load_queue[lq_tail].complete <= 1'b1;
                    load_queue[lq_tail].forwarded <= 1'b1;
                    load_queue[lq_tail].sent_to_mem <= 1'b0;
                end else begin // Otherwise, wait for data to arrive in future cycles
                    load_queue[lq_tail].complete <= 1'b0;
                    load_queue[lq_tail].forwarded <= 1'b0;
                    load_queue[lq_tail].sent_to_mem <= 1'b0;
                end
                lq_tail <= lq_tail + 1;
            end 
            
            // Mark Sent to Memory
            if (issue_load_valid) begin
                load_queue[issue_load_idx].sent_to_mem <= 1'b1;
                mem_inflight_load_idx <= issue_load_idx;
                mem_inflight_valid <= 1'b1;
            end
            
            // Memory Response
            if (dmem_read_valid && mem_inflight_valid) begin
                load_queue[mem_inflight_load_idx].complete <= 1'b1;
                mem_inflight_valid <= 1'b0; // Request done
            end
            
            // Retirement (Remove completed loads at head)
            if (load_queue[lq_head].valid && load_queue[lq_head].complete) begin
                load_queue[lq_head].valid <= 1'b0;
                lq_head <= lq_head + 1;
            end
            
            // --- STORE QUEUE ---
            
            // Allocate store queue entry
            if (store_valid && !lsq_sq_full) begin
                store_queue[sq_tail].address <= store_addr;
                store_queue[sq_tail].data <= store_data;
                store_queue[sq_tail].valid <= 1'b1;
                store_queue[sq_tail].complete <= 1'b1; // Executed, waiting for commit
                store_queue[sq_tail].committed <= 1'b0;
                sq_tail <= sq_tail + 1;
            end
            
            // Commit Signal (from ROB)
            if (commit_store && store_queue[sq_head].valid) begin
                store_queue[sq_head].committed <= 1'b1;
            end
            
            // Write Completion (Retirement)
            // If we are writing this cycle, assume it completes and retire from SQ
            if (store_queue[sq_head].valid && store_queue[sq_head].committed) begin
                store_queue[sq_head].valid <= 1'b0;
                sq_head <= sq_head + 1;
            end
        end
    end
    
    // ========================================================================
    // Output Load Data Selection (Forwarding vs Memory)
    // =======================================================================
    always @(*) begin
        load_data = 0;
        load_data_valid = 1'b0;
        load_tag_out = 0;
        
        // Priority 1: Instant forwarding for NEW load
        if (load_valid && forwarding_valid) begin
            load_data = forwarded_data;
            load_data_valid = 1'b1;
            load_tag_out = load_tag;
        end 
        // Priority 2: Memory Response (for Pending Load)
        else if (dmem_read_valid && mem_inflight_valid) begin
            load_data = dmem_read_data;
            load_data_valid = 1'b1;
            load_tag_out = load_queue[mem_inflight_load_idx].tag;
        end
    end
    

    // ========================================================================
    // Status Signals
    // ========================================================================
    assign lsq_lq_full = (lq_tail + 1 == lq_head);
    assign lsq_sq_full = (sq_tail + 1 == sq_head);
    
    assign load_blocked = 1'b0; // No blocking for RAW, we forward or issue
    assign store_blocked = 1'b0;

endmodule
