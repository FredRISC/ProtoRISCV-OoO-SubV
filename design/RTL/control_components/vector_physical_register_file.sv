// ============================================================================
// vector_physical_register_file.sv - Speculative Vector Data Storage
// ============================================================================
// Holds SPECULATIVE VECTORS during execution.
// 64 entries, each VLEN (128) bits wide.

`include "../riscv_header.sv"

module vector_physical_register_file (
    input clk,
    input rst_n,
    
    // Write port (from Vector CDB)
    input [5:0] write_addr,        // Physical register ID (0-63)
    input [VLEN-1:0] write_data,
    input write_en,
    
    // Read ports (read operands for VEU)
    input [5:0] read_addr1,
    input [5:0] read_addr2,
    output logic [VLEN-1:0] read_data1,
    output logic [VLEN-1:0] read_data2,
    input [5:0] read_addr3, // Dedicated port for memory stores
    output logic [VLEN-1:0] read_data3,
    output logic [NUM_PHYS_REGS-1:0] status_valid, // Valid Status signals (Used for Vector RS operand ready checking)

    // Commit interface (read to update Arch Vector Reg)
    input [5:0] commit_read_addr,
    output logic [VLEN-1:0] commit_read_data,
    
    // Allocation (clear valid bit)
    input [5:0] alloc_addr,
    input alloc_en
);

    // Storage: 64 physical registers, each 128 bits wide
    logic [VLEN-1:0] phys_regs [NUM_PHYS_REGS-1:0];
    logic [NUM_PHYS_REGS-1:0] valid_bits;
    
    // Combinational reads
    assign read_data1 = phys_regs[read_addr1];
    assign read_data2 = phys_regs[read_addr2];
    assign read_data3 = phys_regs[read_addr3];
    assign commit_read_data = phys_regs[commit_read_addr];
    
    // Status valid (All are strictly tracked. v0 is NOT permanently valid in contrast to x0)
    assign status_valid = valid_bits;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                phys_regs[i] <= {VLEN{1'b0}};
                valid_bits[i] <= 1'b0;
            end
        end else begin
            if (write_en) begin // Write on CDB broadcast
                phys_regs[write_addr] <= write_data;
                valid_bits[write_addr] <= 1'b1; // Marked as valid/ready
            end
            if (alloc_en) // Clear valid bit on allocation
                valid_bits[alloc_addr] <= 1'b0; // Unready/Waiting CDB Broadcast
        end
    end

endmodule