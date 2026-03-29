// ============================================================================
// free_list.sv 
// ============================================================================
// Tracks FREE physical registers (not allocated)
// When phys reg is freed (on commit), return to free_list
// When new alloc needed, get from free_list

`include "riscv_header.sv"

module free_list (
    input clk,
    input rst_n,
    input flush,
    
    // Allocate a free physical register
    input alloc_req,
    output logic [5:0] alloc_phys,     // allocate Physical reg ID to use
    output logic alloc_valid,          // Is one available?
    
    // Commit updates
    input [5:0] commit_phys,    // New permanent physical register
    input [5:0] free_phys,      // Old physical register to release
    input commit_en
);

    logic [NUM_PHYS_REGS-1:0] spec_free_bits; // Speculative state
    logic [NUM_PHYS_REGS-1:0] arch_free_bits; // Architectural state
    
    // Allocate: find first free bit
    always @(*) begin
        alloc_phys = 6'h0;
        alloc_valid = 1'b0;
        // Search all registers (p0 is naturally protected by initialization)
        for (int i = 0; i < NUM_PHYS_REGS; i++) begin
            if (spec_free_bits[i]) begin
                alloc_phys = i[5:0]; // Allocate this physical register
                alloc_valid = 1'b1; // Found a free physical register
                break;
            end
        end
    end
    
    // Sequential: allocate and free
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // All phys regs 32-63 are free initially (0-31 are initially mapped to arch regs in RAT)
            spec_free_bits <= 64'hFFFFFFFF_00000000;
            arch_free_bits <= 64'hFFFFFFFF_00000000;
        end else begin
            // Update the architectural free list to the latest commit state (even on commit)
            if (commit_en) begin
                arch_free_bits[commit_phys] <= 1'b0; 
                arch_free_bits[free_phys] <= 1'b1;  
            end
            
            // Roll Back on flush
            if (flush) begin
                for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                    if (commit_en && i == commit_phys) spec_free_bits[i] <= 1'b0; // When flush and commit are both true, roll back to the latest commit state
                    else if (commit_en && i == free_phys) spec_free_bits[i] <= 1'b1;
                    else spec_free_bits[i] <= arch_free_bits[i];
                end
            end else begin
                if (alloc_req && alloc_valid)
                    spec_free_bits[alloc_phys] <= 1'b0;
                if (commit_en)
                    spec_free_bits[free_phys] <= 1'b1;
            end
        end
    end

endmodule