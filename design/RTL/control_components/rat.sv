// ============================================================================
// rat.sv (Register Alias Table)
// ============================================================================
// Maps architectural registers to PHYSICAL registers
// Key difference from rename_table:
//   - Maps to physical register IDs, not ROB IDs
//   - Tracks which phys reg holds which arch reg's value

`include "riscv_header.sv"

module rat (
    input clk,
    input rst_n,
    input flush,
    
    // Read (lookup which physical regs hold these arch regs)
    input [4:0] src1_arch,
    input [4:0] src2_arch,
    output logic [5:0] src1_phys,      // Physical reg ID
    output logic [5:0] src2_phys,      // Physical reg ID
    
    // Write (allocate new physical reg for destination)
    input [4:0] dst_arch,
    input [5:0] dst_phys,              // New physical reg ID (FROM FREE LIST)
    output logic [5:0] dst_old_phys,   // Old physical reg ID (to be saved in ROB for freeing)
    
    // Rename enable
    input rename_en,
    
    // On commit (update to reflect last committed writer)
    input [4:0] commit_arch,
    input [5:0] commit_phys,
    input commit_en
);

    // Two tables: 
    // 1. Speculative RAT (used for dispatch/renaming)
    // 2. Architectural RAT (used for recovery on flush)
    logic [5:0] spec_rat [NUM_INT_REGS-1:0];
    logic [5:0] arch_rat [NUM_INT_REGS-1:0];
    
    // Read: combinational lookup
    assign src1_phys = spec_rat[src1_arch];
    assign src2_phys = spec_rat[src2_arch];
    assign dst_old_phys = spec_rat[dst_arch]; // Read old mapping before update
    
    // Sequential updates
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize: arch reg i maps to phys reg i (0-31)
            for (int i = 0; i < NUM_INT_REGS; i++) begin
                spec_rat[i] <= i[5:0];
                arch_rat[i] <= i[5:0];
            end
        end else if (flush) begin
            // Recovery: Restore speculative RAT from architectural RAT
            for (int i = 0; i < NUM_INT_REGS; i++) begin
                spec_rat[i] <= arch_rat[i];
            end
        end else begin
            // 1. Rename (Dispatch) - Update Speculative RAT
            if (rename_en && dst_arch != 5'b0) begin
                spec_rat[dst_arch] <= dst_phys;
            end
            
            // 2. Commit (Retire) - Update Architectural RAT
            if (commit_en && commit_arch != 5'b0) begin
                arch_rat[commit_arch] <= commit_phys;
            end
        end
    end

endmodule