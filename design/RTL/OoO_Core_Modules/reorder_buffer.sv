// ============================================================================
// reorder_buffer.sv - Reorder Buffer Implementation
// ============================================================================
// Maintains in-order instruction tracking for precise exceptions and commits

`include "../riscv_header.sv"

module reorder_buffer #(
    parameter ROB_SIZE = 16,
    parameter XLEN = 32
) (
    input clk,
    input rst_n,
    input flush,
    
    // Allocation interface (from dispatch stage)
    input [XLEN-1:0] alloc_pc,       // Store PC for replay/exceptions
    input [3:0] alloc_instr_type,    // For commit stage to know how to update architectural state
    input [4:0] alloc_dest_reg,      // Architectural destination register (for commit_stage)
    input [5:0] alloc_phys_reg,      // Allocated physical destination register (for CDB, commit_stage)
    input [5:0] alloc_old_phys_reg,  // Old physical register to Free_List
    input [31:0] alloc_vtype,        // Vector type state

    input alloc_valid,
    output rob_full,
    
    // Result interface 0 (from CDB 0)
    input [5:0] result0_tag,  
    input result0_valid, 
    
    // Result interface 1 (from CDB 1)
    input [5:0] result1_tag,  
    input result1_valid, 
    
    // Vector Result interface 0 (from VEU)
    input [5:0] vec_result0_tag,
    input vec_result0_valid,
    
    // Vector Result interface 1 (from LSQ)
    input [5:0] vec_result1_tag,
    input vec_result1_valid,
    
    // Disambiguation Violation (from LSQ)
    input lsq_violation_req,
    input [5:0] lsq_violation_tag,
        
    // Commit interface
    output commit_valid, // To commit_stage and LSQ for store/load data availability
    output [3:0] commit_instr_type,
    output [4:0] commit_dest_reg,
    output [5:0] commit_dest_phys,   // Physical register to update Arch RAT
    output [5:0] commit_old_phys,     // Old physical register to return to Free List    
    output [31:0] commit_vtype,      // To update vCSR
    
    // Flush outputs (to Main Controller)
    output rob_flush_req,            // Trigger pipeline flush
    output [XLEN-1:0] rob_flush_pc   // PC to restart from
);

    typedef struct packed {
        logic [XLEN-1:0] pc;
        logic [3:0] instr_type; // For commit stage to know how to update architectural state
        logic [4:0] dest_reg; // For update architectural register file in commit_stage
        logic [5:0] phys_reg; // For matching CDB result to ROB entry and for updating RAT on commit
        logic [5:0] old_phys_reg; // For freeing old phys reg on commit
        logic [31:0] vtype;       // For updating architectural vtype
        logic memory_violation; // Set if LSQ detects out-of-order memory conflict
        logic result_ready; // signals instruction is ready to commit (stores/branches are ready immediately)
        logic valid; // signals this entry is allocated and valid
    } rob_entry_t;
    
    rob_entry_t [ROB_SIZE-1:0] rob_entries;
    logic [$clog2(ROB_SIZE)-1:0] head_ptr, tail_ptr;
    logic [$clog2(ROB_SIZE)-1:0] next_tail;
    
    // ========================================================================
    // Entry Allocation (allocated when dispatch_stage assert alloc_valid)
    // Entry Allocation
    // ========================================================================
    
    assign rob_full = (next_tail == head_ptr) && rob_entries[tail_ptr].valid;
    assign next_tail = tail_ptr + 1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < ROB_SIZE; i++) begin
                rob_entries[i].valid <= 1'b0;
                rob_entries[i].instr_type <= 4'b0;
                rob_entries[i].dest_reg <= 5'b0;
                rob_entries[i].phys_reg <= 6'b0;
                rob_entries[i].old_phys_reg <= 6'b0;
                rob_entries[i].vtype <= 32'b0;
                rob_entries[i].memory_violation <= 1'b0;
                rob_entries[i].result_ready <= 1'b0;
            end
            head_ptr <= 0;
            tail_ptr <= 0;
        end else begin
            
            // 1. Allocation (Allocate at tail)
            if (alloc_valid && !rob_full) begin
                rob_entries[tail_ptr].pc <= alloc_pc;
                rob_entries[tail_ptr].instr_type <= alloc_instr_type;
                rob_entries[tail_ptr].dest_reg <= alloc_dest_reg;
                rob_entries[tail_ptr].phys_reg <= alloc_phys_reg;
                rob_entries[tail_ptr].old_phys_reg <= alloc_old_phys_reg;
                rob_entries[tail_ptr].vtype <= alloc_vtype;
                rob_entries[tail_ptr].result_ready <= 1'b0;
                rob_entries[tail_ptr].memory_violation <= 1'b0;
                rob_entries[tail_ptr].valid <= 1'b1;
                tail_ptr <= next_tail;
            end        
            
            // 2. Receiving Tags (sweeping all ROB entries to update ready bits)
            for (int i = 0; i < ROB_SIZE; i++) begin
                if (rob_entries[i].valid && !rob_entries[i].result_ready) begin
                    // Check domain based on instruction type
                    if (rob_entries[i].instr_type == `V_EXT_VEC || rob_entries[i].instr_type == `V_EXT_LOAD) begin
                        if (vec_result0_valid && (rob_entries[i].phys_reg == vec_result0_tag)) begin
                            rob_entries[i].result_ready <= 1'b1;
                        end else if (vec_result1_valid && (rob_entries[i].phys_reg == vec_result1_tag)) begin
                            rob_entries[i].result_ready <= 1'b1;
                        end
                    end else begin
                        if (result0_valid && (rob_entries[i].phys_reg == result0_tag)) begin
                            rob_entries[i].result_ready <= 1'b1;
                        end else if (result1_valid && (rob_entries[i].phys_reg == result1_tag)) begin
                            rob_entries[i].result_ready <= 1'b1;
                        end
                    end
                end
            end
            
            // 3. Memory Violation Flagging
            if (lsq_violation_req) begin
                for (int i = 0; i < ROB_SIZE; i++) begin
                    if (rob_entries[i].valid && (rob_entries[i].phys_reg == lsq_violation_tag)) begin
                        rob_entries[i].memory_violation <= 1'b1;
                    end
                end
            end

            // 4. Commit Stage (Free head entry)
            if (commit_valid) begin
                rob_entries[head_ptr].valid <= 1'b0;
                head_ptr <= head_ptr + 1;
            end
        end
    end
    
    // ========================================================================
    // Commit Logic (to commit_stage and LSQ)
    // ========================================================================

    logic head_is_violator;
    assign head_is_violator = rob_entries[head_ptr].valid && rob_entries[head_ptr].memory_violation;
    
    assign rob_flush_req = head_is_violator;
    assign rob_flush_pc = rob_entries[head_ptr].pc;
    
    // Only check ROB's head pointer, as it is the oldest instruction
    assign commit_valid = rob_entries[head_ptr].valid && rob_entries[head_ptr].result_ready && !head_is_violator;
    assign commit_instr_type = rob_entries[head_ptr].instr_type;
    assign commit_dest_reg = rob_entries[head_ptr].dest_reg;
    assign commit_dest_phys = rob_entries[head_ptr].phys_reg;

    assign commit_old_phys = rob_entries[head_ptr].old_phys_reg; // already prepared in dispatch_stage for the dummy cases 
    assign commit_vtype = rob_entries[head_ptr].vtype;

endmodule
