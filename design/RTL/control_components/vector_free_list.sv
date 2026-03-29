// ============================================================================
// vector_free_list.sv 
// ============================================================================
// Tracks FREE physical vector registers.

`include "../riscv_header.sv"

module vector_free_list (
    input clk,
    input rst_n,
    input flush,
    
    // Allocate a free physical register
    input alloc_req,
    output logic [5:0] alloc_phys,     // allocate Physical reg ID to use
    output logic alloc_valid,          // Is one available?
    
    // Commit updates
    input [5:0] commit_phys,
    input [5:0] free_phys,
    input commit_en
);

    logic [NUM_PHYS_REGS-1:0] spec_free_bits;
    logic [NUM_PHYS_REGS-1:0] arch_free_bits;
    
    always @(*) begin
        alloc_phys = 6'h0;
        alloc_valid = 1'b0;
        // Search ALL registers. v0 is not hardwired to zero!
        for (int i = 0; i < NUM_PHYS_REGS; i++) begin
            if (spec_free_bits[i]) begin
                alloc_phys = i[5:0];
                alloc_valid = 1'b1;
                break;
            end
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spec_free_bits <= 64'hFFFFFFFF_00000000;
            arch_free_bits <= 64'hFFFFFFFF_00000000;
        end else begin
            if (commit_en) begin // Update the architectural free list to the latest commit state (even on commit)
                arch_free_bits[commit_phys] <= 1'b0;
                arch_free_bits[free_phys] <= 1'b1;
            end
            
            if (flush) begin
                for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                    if (commit_en && i == commit_phys) // When flush and commit are both true, roll back to the latest commit state
                        spec_free_bits[i] <= 1'b0;
                    else if (commit_en && i == free_phys)
                        spec_free_bits[i] <= 1'b1;
                    else
                        spec_free_bits[i] <= arch_free_bits[i];
                end
            end else begin
                if (alloc_req && alloc_valid) begin 
                    spec_free_bits[alloc_phys] <= 1'b0; 
                end
                if (commit_en) begin 
                    spec_free_bits[free_phys] <= 1'b1;
                end
            end
        end
    end

endmodule