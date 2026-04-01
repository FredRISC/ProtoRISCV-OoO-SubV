// ============================================================================
// vector_lane.sv - Single Vector Lane (32-bit Element Operations)
// ============================================================================
// Executes element-wise operations for one 32-bit element

`include "../riscv_header.sv"

module vector_lane #(
    parameter ELEN = 32
) (
    input clk,
    input rst_n,
    
    input [ELEN-1:0] operand1,
    input [ELEN-1:0] operand2,
    input [3:0] vec_op,
    input valid_in,
    
    output reg [ELEN-1:0] result,
    output reg valid_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 0;
            valid_out <= 1'b0;
        end else if (valid_in) begin
            valid_out <= 1'b1;
            case (vec_op)
                `VEC_OP_ADD:  result <= operand1 + operand2;
                `VEC_OP_SUB:  result <= operand1 - operand2;
                `VEC_OP_MUL:  result <= operand1 * operand2;
                `VEC_OP_AND:  result <= operand1 & operand2;
                `VEC_OP_OR:   result <= operand1 | operand2;
                `VEC_OP_XOR:  result <= operand1 ^ operand2;
                `VEC_OP_SLL:  result <= operand1 << operand2[4:0];
                `VEC_OP_SRL:  result <= operand1 >> operand2[4:0];
                `VEC_OP_SRA:  result <= $signed(operand1) >>> operand2[4:0];
                default:      result <= 32'h0;
            endcase
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
