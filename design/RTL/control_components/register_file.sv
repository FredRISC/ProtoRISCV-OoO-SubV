// ============================================================================
// register_file.sv - Architectural Register File
// ============================================================================
// Holds ARCHITECTURAL REGISTER STATE only
// Does NOT hold speculative data (that's in physical registers)

`include "riscv_header.sv"

module register_file (
    input clk,
    input rst_n,
    
    // Write port (only on commit from physical registers)
    input [4:0] write_addr,
    input [XLEN-1:0] write_data,
    input write_en,
    
    // Debug interface
    output [NUM_INT_REGS-1:0][XLEN-1:0] debug_reg_file
);

    logic [XLEN-1:0] registers [NUM_INT_REGS-1:0];
    
    // Sequential writes (only on commit)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_INT_REGS; i++)
                registers[i] <= 32'h0;
        end else if (write_en && write_addr != 5'b0) begin
            registers[write_addr] <= write_data;
        end
    end
    
    // Debug
    assign debug_reg_file = registers;

endmodule