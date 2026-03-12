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
    
    // Allocate a free physical register
    input alloc_req,
    output logic [5:0] alloc_phys,     // allocate Physical reg ID to use
    output logic alloc_valid,          // Is one available?
    
    // Free a physical register (on commit)
    input [5:0] free_phys,
    input free_en
);

    logic [NUM_PHYS_REGS-1:0] free_bits;  // 1 = free, 0 = allocated
    
    // Allocate: find first free bit
    always @(*) begin
        alloc_phys = 6'h0;
        alloc_valid = 1'b0;
        for (int i = 32; i < NUM_PHYS_REGS; i++) begin  // Skip arch regs 0-31
            if (free_bits[i]) begin
                alloc_phys = i[5:0];
                alloc_valid = 1'b1;
                break;
            end
        end
    end
    
    // Sequential: allocate and free
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // All phys regs 32-63 are free initially
            free_bits <= 64'hFFFFFFFF_00000000;
        end else begin
            if (alloc_req && alloc_valid)
                free_bits[alloc_phys] <= 1'b0;  // Mark as allocated
            if (free_en)
                free_bits[free_phys] <= 1'b1;   // Mark as free
        end
    end

endmodule