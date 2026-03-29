// ============================================================================
// vector_rat.sv (Vector Register Alias Table)
// ============================================================================
// Maps architectural vector registers (v0-v31) to PHYSICAL vector registers
// (vp0-vp63). Operates completely independently of the scalar RAT.

`include "../riscv_header.sv"

module vector_rat (
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

    // Speculative Vector RAT (used for dispatch/renaming)
    // Architectural Vector RAT (used for recovery on flush)
    logic [5:0] spec_rat [NUM_VEC_REGS-1:0];
    logic [5:0] arch_rat [NUM_VEC_REGS-1:0];
    
    assign src1_phys = spec_rat[src1_arch];
    assign src2_phys = spec_rat[src2_arch];
    assign dst_old_phys = spec_rat[dst_arch]; // Read old mapping before update
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_VEC_REGS; i++) begin
                spec_rat[i] <= i[5:0];
                arch_rat[i] <= i[5:0];
            end
        end else begin
            if (commit_en) // Register the commit state mapping to architectural vRAT (even on flush)
                arch_rat[commit_arch] <= commit_phys;
                
            if (flush) begin
                // Recovery: Restore from architectural vRAT, including the new commit
                for (int i = 0; i < NUM_VEC_REGS; i++) begin
                    if (commit_en && commit_arch == i) // When flush and commit are both true, roll back with the latest commit state
                        spec_rat[i] <= commit_phys;
                    else
                        spec_rat[i] <= arch_rat[i];
                end
            end else if (rename_en) begin // Regular renaming/mapping
                spec_rat[dst_arch] <= dst_phys;
            end
        end
    end

endmodule