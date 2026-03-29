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

    // From fetch stage
    input [INST_WIDTH-1:0] instr_in,
    input [XLEN-1:0] pc_in,
    input valid_in,
    
    // Output fields
    output reg [3:0] instr_type_out,    // Key output of this stage: instruction type for routing to appropriate reservation station
    output reg [XLEN-1:0] pc_out,   // Pass through PC for potential use in branch target calculation or debugging
    output reg [INST_WIDTH-1:0] instr_out, // Pass through instruction for debugging
    output reg valid_out    // Indicate that the output of this stage is valid
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    
    assign opcode = instr_in[6:0];
    assign funct3 = instr_in[14:12];
    assign funct7 = instr_in[31:25];
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            instr_type_out <= `IBASE_UNKNOWN; // Default to unknown instruction type
        end else if (flush) begin
            valid_out <= 1'b0;
        end else if (!stall && valid_in) begin
            pc_out <= pc_in; // Pass through PC for potential use in branch target calculation or debugging
            instr_out <= instr_in;  // Pass through instruction for debugging
            valid_out <= 1'b1;  // Indicate that the output of this stage is valid
            
            // Decode instruction type from opcode
            case (opcode)
                7'b0110011: begin  // DO HERE
                    if (funct7 == `FUNCT7_M_EXT) begin
                        // M-Extension: Distinguish MUL vs DIV based on funct3[2]
                        if (funct3[2]) 
                            instr_type_out <= `M_EXT_DIV;
                        else
                            instr_type_out <= `M_EXT_MUL;
                    end else begin
                        instr_type_out <= `IBASE_ALU;
                    end
                end

                7'b0010011: instr_type_out <= `IBASE_ALU_IMM; //OPIVI
                7'b0000011: instr_type_out <= `IBASE_LOAD;  //LOAD
                7'b0100011: instr_type_out <= `IBASE_STORE; //STORE
                7'b1100011: instr_type_out <= `IBASE_BRANCH; //BRANCH
                7'b1101111: instr_type_out <= `IBASE_JAL; //JAL
                7'b1100111: instr_type_out <= `IBASE_JALR; //JALR
                7'b0110111: instr_type_out <= `IBASE_LUI;  //LUI
                7'b0010111: instr_type_out <= `IBASE_AUIPC;  //AUIPC
                7'b1010111: begin // OP-V
                    if (funct3 == 3'b111) // VSETVLI
                        instr_type_out <= `V_EXT_CONFIG;
                    else
                        instr_type_out <= `V_EXT_VEC;
                end
                7'b0000111: instr_type_out <= `V_EXT_LOAD; //LOAD-FP
                7'b0100111: instr_type_out <= `V_EXT_STORE; //STORE-FP
                default:    instr_type_out <= `IBASE_UNKNOWN;
            endcase
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
