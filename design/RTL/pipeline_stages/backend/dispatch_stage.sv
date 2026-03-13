// ============================================================================
// dispatch_stage.sv - Instruction Dispatch to Reservation Stations
// ============================================================================
// Routes instructions to appropriate reservation stations based on decoded instruction type, and
// prepare alu_op and immediate values for execution. Also generates control signals for RS, ROB, and LSQ allocation.
// long critical path (Decode -> RAT -> PRF -> Dispatch -> RS)

`include "../riscv_header.sv"

module dispatch_stage #(
    parameter XLEN = 32,
    parameter INST_WIDTH = 32,
    parameter NUM_INT_REGS = 32,
    parameter NUM_PHYS_REGS = 64,
    parameter ALU_RS_SIZE = 8,
    parameter MEM_RS_SIZE = 8,
    parameter MUL_RS_SIZE = 4,
    parameter DIV_RS_SIZE = 4,
    parameter VEC_RS_SIZE = 8,
    parameter LSQ_TAG_WIDTH = 3
) (
    input clk,
    input rst_n,
    input stall,
    input flush,
    
    // From decode stage
    input [INST_WIDTH-1:0] instr_in,
    input [3:0] instr_type,
    input [XLEN-1:0] pc_in,
    input valid_in,

    // RAT Interface (Encapsulated)
    input [5:0] free_phys_reg,       // From Free List
    input [4:0] commit_arch_reg,     // From Commit/ROB
    input [5:0] commit_phys_reg,     // From Commit/ROB
    input commit_en,                 // From Commit/ROB
    
    output [5:0] phys_rs1, phys_rs2, // To PRF and RS
    output [5:0] phys_rd, phys_rd_old, // To RS/ROB and ROB/FreeList

    // Signals from physical register file
    input [XLEN-1:0] PReg_src1_value, PReg_src2_value, // Physical register values 
    input PReg_src1_valid_in, PReg_src2_valid_in,      // Physical register valid bits
    
    // Output instruction fields
    output [XLEN-1:0] src1_value, // operand 1 value (register)
    output [XLEN-1:0] src2_value, // operand 2 value (register or immediate)
    output [3:0] alu_op,
    output src1_valid, // Operand 1 is ready (immediate/PC or valid reg)
    output src2_valid, // Operand 2 is ready (immediate or valid reg)
    
    // RS allocation
    output [3:0] rs_type,  // Which RS to use
    output rs_alloc_valid, // Valid signal for RS allocation   
    // ROB allocation
    output rob_alloc_valid, // Valid signal for ROB allocation
    // LSQ allocation (for loads/stores)
    output lsq_alloc_valid, // Valid signal for LSQ allocation

    // LSQ Alloc Interface (New)
    input [LSQ_TAG_WIDTH-1:0] lsq_alloc_tag_in, // Tag from LSQ
    output [LSQ_TAG_WIDTH-1:0] dispatch_lsq_tag, // Tag to RS
    output lsq_alloc_req,
    output lsq_alloc_is_store,

    output valid_out
);

    // Extract fields from instruction
    logic [6:0] opcode;
    logic [4:0] rs1, rs2, rd; // Architectural register addresses
    logic [3:0] funct3;
    logic [6:0] funct7;
    
    assign opcode = instr_in[6:0];
    assign rd = instr_in[11:7];
    assign funct3 = instr_in[14:12];
    assign rs1 = instr_in[19:15];
    assign rs2 = instr_in[24:20];
    assign funct7 = instr_in[31:25];

    logic [4:0] rs1_arch_internal, rs2_arch_internal, dst_arch_internal;
    // Sign-extend immediate
    logic [XLEN-1:0] imm_extended;


    // Determine if RS2 is used (register dependency)
    // Used for: R-Type, Branch, Store (Vector is on different path)
    logic use_rs2;
    always @(*) begin
        case (instr_type)
            `IBASE_ALU, `IBASE_BRANCH, `IBASE_STORE, `M_EXT_MUL, `M_EXT_DIV:
                use_rs2 = 1'b1;
            default:
                use_rs2 = 1'b0;
        endcase
    end
    
    // Determine if RS1 is used
    logic use_rs1;
    always @(*) begin
        case (instr_type)
            `IBASE_LUI, `IBASE_AUIPC, `IBASE_JAL, `V_EXT_VEC, `V_EXT_LOAD, `V_EXT_STORE: 
                use_rs1 = 1'b0;
            default: 
                use_rs1 = 1'b1;
        endcase
    end
    
    // Preparing architectural addresses for RAT mapping
    assign rs1_arch_internal = (use_rs1) ? rs1 : 5'b0; // Zero out if unused
    assign rs2_arch_internal = (use_rs2) ? rs2 : 5'b0; // Zero out if unused to prevent false dependency in RAT
    
    // Preparing destination register for RAT renaming
    // Avoid unecessary register renaming; stores (S-type) and Branches (B-type) do not write to rd
    logic use_rd = (instr_type == `IBASE_STORE || instr_type == `IBASE_BRANCH || instr_type == `V_EXT_STORE || instr_type == `V_EXT_VEC || instr_type == `V_EXT_LOAD || instr_type == `IBASE_UNKNOWN);
    assign dst_arch_internal =  use_rd ? 5'b0 : rd;

    // Internal RAT Instantiation
    rat #(.NUM_INT_REGS(NUM_INT_REGS), .NUM_PHYS_REGS(NUM_PHYS_REGS))
    rat_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_arch(rs1_arch_internal), .src2_arch(rs2_arch_internal),
        .src1_phys(phys_rs1), .src2_phys(phys_rs2),
        .dst_arch(dst_arch_internal), .dst_phys(free_phys_reg),
        .dst_old_phys(phys_rd_old),
        .rename_en(valid_in && !stall && !flush && (dst_arch_internal != 5'b0)),
        .commit_arch(commit_arch_reg), .commit_phys(commit_phys_reg), .commit_en(commit_en)
    );
    assign phys_rd = free_phys_reg; // Pass through allocated tag

    // Preparing inputs for reservation station
    // Mux for src1: LUI uses 0, AUIPC uses PC, others use PReg value
    assign src1_value = (instr_type == `IBASE_LUI)   ? {XLEN{1'b0}} :
                        (instr_type == `IBASE_AUIPC || instr_type == `IBASE_JAL) ? pc_in :
                        PReg_src1_value;
    // Mux for src2: Register value OR Immediate
    assign src2_value = (use_rs2) ? PReg_src2_value : imm_extended;
    assign src1_valid = (use_rs1) ? PReg_src1_valid_in : 1'b1; // Valid if not using reg (imm/pc) or reg is valid
    assign src2_valid = (use_rs2) ? PReg_src2_valid_in : 1'b1;
    
    // Immediate generation based on instruction type
    always @(*) begin
        case (instr_type)
            `IBASE_STORE:  // S-Type
                imm_extended = {{20{instr_in[31]}}, instr_in[31:25], instr_in[11:7]};
            `IBASE_BRANCH: // B-Type
                imm_extended = {{19{instr_in[31]}}, instr_in[31], instr_in[7], instr_in[30:25], instr_in[11:8], 1'b0};
            `IBASE_LUI, `IBASE_AUIPC: // U-Type
                imm_extended = {instr_in[31:12], 12'b0};
            `IBASE_JAL:    // J-Type
                imm_extended = {{11{instr_in[31]}}, instr_in[31], instr_in[19:12], instr_in[20], instr_in[30:21], 1'b0};
            default:       // I-Type (ALU_IMM, LOAD, JALR)
                imm_extended = {{20{instr_in[31]}}, instr_in[31:20]};
        endcase
    end
    
    // ALU operation decoding - alu_op is used by functional units to determine operation type
    always @(*) begin
        if (instr_type == `V_EXT_VEC) begin
            // Vector Operation Decoding (based on funct6)
            // Note: We currently ONLY support Vector-Vector (.VV) OPVV operations. 
            // RISC-V use funct3 to distinguish between .VV, .VX, and .VI
            // .VV ops use funct3 = 3'b000 (OPIVV - Integer Vector-Vector) or 3'b010 (OPMVV - Mask/Miscellaneous Vector-Vector).
            // .VX (Scalar) and .VI (Immediate) are filtered out here to prevent mis-execution.
            if (funct3 == 3'b000 || funct3 == 3'b010) begin
                case (funct7[6:1]) // funct6 is top 6 bits of funct7
                    6'b000000: alu_op = `VEC_OP_ADD;
                    6'b000010: alu_op = `VEC_OP_SUB;
                    6'b100101: begin // This funct6 is shared by VMUL.VV and VSLL.VV
                        case(funct3)
                            3'b010: alu_op = `VEC_OP_MUL; // VMUL.VV (OPMVV)
                            3'b000: alu_op = `VEC_OP_SLL; // VSLL.VV (OPIVV)
                            default: alu_op = `UNKNOWN_VEC_OP;
                        endcase
                    end
                    6'b001001: alu_op = `VEC_OP_AND;
                    6'b001010: alu_op = `VEC_OP_OR;
                    6'b001011: alu_op = `VEC_OP_XOR;
                    6'b101000: alu_op = `VEC_OP_SRL;
                    default:   alu_op = `UNKNOWN_VEC_OP; // Default for unhandled funct6
                endcase
            end else begin
                alu_op = `UNKNOWN_VEC_OP;
            end
        end else if (instr_type == `IBASE_ALU || instr_type == `IBASE_ALU_IMM) begin
            // Scalar ALU Operation Decoding (R-Type and I-Type)
            case (funct3)
                `FUNCT3_ADD_SUB: alu_op = (funct7[5] && instr_type != `IBASE_ALU_IMM) ? `ALU_SUB : `ALU_ADD;
                `FUNCT3_SLL:     alu_op = `ALU_SLL;
                `FUNCT3_SLT:     alu_op = `ALU_SLT;
                `FUNCT3_SLTU:    alu_op = `ALU_SLTU;
                `FUNCT3_XOR:     alu_op = `ALU_XOR;
                `FUNCT3_SR:      alu_op = (funct7[5]) ? `ALU_SRA : `ALU_SRL;
                `FUNCT3_OR:      alu_op = `ALU_OR;
                `FUNCT3_AND:     alu_op = `ALU_AND;
                default:         alu_op = `ALU_ADD;
            endcase
        end else if (instr_type == `IBASE_BRANCH) begin
            // Branch Operation Decoding
            case (funct3)
                3'b000, 3'b001: alu_op = `ALU_SUB;  // BEQ, BNE
                3'b100, 3'b101: alu_op = `ALU_SLT;  // BLT, BGE
                3'b110, 3'b111: alu_op = `ALU_SLTU; // BLTU, BGEU
                default:        alu_op = `ALU_SUB;
            endcase
        end else if (instr_type == `M_EXT_MUL || instr_type == `M_EXT_DIV) begin
            // M-Extension Operation Decoding
            // funct3 maps directly to the operation subtype (MUL, MULH, DIV, REM, etc.)
            alu_op = {1'b0, funct3};
        end else begin
            // Default for Loads, Stores, Jumps, LUI, AUIPC (Address Calculation)
            // Also covers Vector Load/Store which need base address calculation.
            alu_op = `ALU_ADD;
        end
    end

    // Decode instruction type to determine RS type
    always @(*) begin
        case (instr_type)
            `IBASE_ALU:      rs_type = `RS_TYPE_ALU;
            `IBASE_ALU_IMM:  rs_type = `RS_TYPE_ALU;
            `IBASE_LOAD:     rs_type = `RS_TYPE_MEM;
            `IBASE_STORE:    rs_type = `RS_TYPE_MEM;
            `IBASE_LUI:      rs_type = `RS_TYPE_ALU;
            `IBASE_AUIPC:    rs_type = `RS_TYPE_ALU;
            `IBASE_JAL:      rs_type = `RS_TYPE_ALU;
            `IBASE_JALR:     rs_type = `RS_TYPE_ALU;
            `IBASE_BRANCH:   rs_type = `RS_TYPE_ALU; // Branches use ALU for comparison
            `M_EXT_MUL:      rs_type = `RS_TYPE_MUL;
            `M_EXT_DIV:      rs_type = `RS_TYPE_DIV;
            `V_EXT_VEC:      rs_type = `RS_TYPE_VEC;
            `V_EXT_LOAD:     rs_type = `RS_TYPE_MEM; // Vector Loads go to MEM RS
            `V_EXT_STORE:    rs_type = `RS_TYPE_MEM; // Vector Stores go to MEM RS
            default:         rs_type = `RS_TYPE_NONE;
        endcase
    end
    
    // Control signals
    assign rs_alloc_valid = valid_in && !stall && !flush;
    assign rob_alloc_valid = valid_in && !stall && !flush;
    
    logic is_load = (instr_type == `IBASE_LOAD);
    logic is_store = (instr_type == `IBASE_STORE);
    
    assign lsq_alloc_valid = (is_load || is_store) && valid_in && !stall && !flush;
    assign lsq_alloc_req = lsq_alloc_valid;
    assign lsq_alloc_is_store = is_store;
    assign dispatch_lsq_tag = lsq_alloc_tag_in;
    
    assign valid_out = valid_in && !stall && !flush;

endmodule
