// ============================================================================
// decode_stage.sv - Instruction Decode Stage
// ============================================================================
// Decodes instruction opcode, extracts fields, and routes to appropriate unit

`include "../riscv_header.sv"

module decode_stage #(
    parameter XLEN = 32,
    parameter INST_WIDTH = 32,
    parameter NUM_INT_REGS = 32
) (
    input clk,
    input rst_n,
    input flush,
    input stall,
    input [INST_WIDTH-1:0] instr_in,
    input [XLEN-1:0] pc_in,
    input valid_in,
    
    output reg [3:0] instr_type_out,
    output reg [XLEN-1:0] pc_out,
    output reg [INST_WIDTH-1:0] instr_out,
    output reg valid_out
);

    logic [6:0] opcode;
    assign opcode = instr_in[6:0];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            instr_type_out <= `ITYPE_UNKNOWN;
        end else if (flush) begin
            valid_out <= 1'b0;
        end else if (!stall && valid_in) begin
            pc_out <= pc_in;
            instr_out <= instr_in;
            valid_out <= 1'b1;
            
            // Decode instruction type from opcode
            case (opcode)
                7'b0110011: instr_type_out <= `ITYPE_ALU;
                7'b0010011: instr_type_out <= `ITYPE_ALU_IMM;
                7'b0000011: instr_type_out <= `ITYPE_LOAD;
                7'b0100011: instr_type_out <= `ITYPE_STORE;
                7'b1100011: instr_type_out <= `ITYPE_BRANCH;
                7'b1101111: instr_type_out <= `ITYPE_JAL;
                7'b1100111: instr_type_out <= `ITYPE_JALR;
                7'b1010111: instr_type_out <= `ITYPE_VEC;
                default:    instr_type_out <= `ITYPE_UNKNOWN;
            endcase
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
