// ============================================================================
// dispatch_stage.sv - Instruction Dispatch to Reservation Stations
// ============================================================================
// Routes instructions to appropriate reservation stations based on decoded instruction type, and
// prepare alu_op and immediate values for execution. Also generates control signals for RS, ROB, and LSQ allocation.
// Datapath (Decode -> Dispatch (RAT) -> PRF -> Dispatch (Encapsulation) -> RS)

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
    input predicted_branch_in,
    input [XLEN-1:0] predicted_target_in,
    input valid_in,

    // Essentially the dispatch_stage initialization signal
    output valid_out, // Sent to enable free_list & PRF; asserted when decode_stage output is valid
    
    // Free List Interface
    input [5:0] free_phys_reg, // free_list -> RAT for registering new mapping
    input [5:0] free_vphys_reg, // vector_free_list -> vRAT

    // Physical Register File Interface (Dispatch's RAT -> PRF & RS Interface)
    output [5:0] phys_rs1, phys_rs2, // Look up mapping by RAT (= spec_rat[src1_arch])

    
    // ROB Interface (Dispatch -> ROB Interface)
    output rob_alloc_valid, // Request for ROB allocation 
    output [5:0] phys_rd, // To RS/ROB for CDB tag matching (= free_phys_reg)
    output [4:0] dest_reg, // MUXed Architectural destination register; sent to ROB for commit_stage
    output phys_rd_old, // Old RAT mapping of the rd register to be freed; sent to ROB on allocation

    // Physical Register File Interface (Operands Ready?)
    // input PReg_src1_valid_in, PReg_src2_valid_in,      // Physical register valid bits
    
    // Reservation Station Interface
    output rs_alloc_valid, // Requst for RS allocation
    output [3:0] rs_type,  // Which RS to use (ALU, MEM, MUL, DIV, VEC)
    output logic [4:0] alu_op, // Encoded Control signals for ALU
    output [XLEN-1:0] imm_out,
    output [XLEN-1:0] pc_out,
    output use_rs1_out,
    output use_rs2_out,
    output use_pc_out,
    output use_vl_out,
    output dispatch_src1_is_vec,
    output dispatch_src2_is_vec,
    output dispatch_predicted_branch, // tunnel to issue_stage
    output [XLEN-1:0] dispatch_predicted_target, // tunnel to issue_stage
    
    // Vector CSR Interface
    input [31:0] spec_vtype, // Only read from CSR
    output logic [31:0] vtype_out, // Passed down to issue stage
    output logic vtype_update_en, // The update en to vtype CSR module
    output logic [31:0] new_vtype,


    // LSQ Alloc Interface 
    input [LSQ_TAG_WIDTH-1:0] lsq_alloc_tag_in, // Tag from LSQ
    output [LSQ_TAG_WIDTH-1:0] dispatch_lsq_tag, // Tag to RS
    output lsq_alloc_req, // Request for LSQ allocation
    output lsq_alloc_is_store, // Load or Store?
    output lsq_alloc_is_vector, // Is vector load/store?
    output [31:0] lsq_alloc_vtype, // Vtype for LSQ
    output [2:0] lsq_alloc_size, // funct3 to define byte/half/word

    // Commit Interface (ROB -> RAT Interface)
    input [4:0] commit_arch_reg,  // To update RAT's or vRAT's architectural state
    input [5:0] commit_phys_reg,     
    input commit_rat, // to enable the update of RAT architectural state                
    input commit_vrat // to enable the update of vRAT architectural state

);

    // Extract fields from instruction
    logic [6:0] opcode;
    logic [4:0] rs1, rs2, rd; // Architectural register addresses
    logic [3:0] funct3;
    logic [6:0] funct7;
    logic [10:0] zimm;
    
    assign opcode = instr_in[6:0];
    assign rd = instr_in[11:7];
    assign funct3 = instr_in[14:12];
    assign rs1 = instr_in[19:15];
    assign rs2 = instr_in[24:20];
    assign funct7 = instr_in[31:25];
    assign zimm = instr_in[30:20];
    

    logic [4:0] rs1_arch_internal, rs2_arch_internal, dst_arch_internal;
    // Sign-extend immediate
    logic [XLEN-1:0] imm_extended;


    logic is_vec_arith = (instr_type == `V_EXT_VEC);
    logic is_vec_load = (instr_type == `V_EXT_LOAD);
    logic is_vec_store = (instr_type == `V_EXT_STORE);
    logic is_vec_config = (instr_type == `V_EXT_CONFIG);

    logic is_OPIVI = (funct3 == 3'b011);
    logic is_OPIVV = (funct3 == 3'b000); 

    // Extract current Vector Configuration locally
    logic [2:0] current_sew;
    logic [2:0] current_lmul;
    always @(*) begin
        if (instr_type == `V_EXT_CONFIG) begin
            current_sew = zimm[5:3];
            current_lmul = zimm[2:0];
        end else begin
            current_sew = spec_vtype[5:3]; // Safely read from speculative CSR!
            current_lmul = spec_vtype[2:0];
        end
    end

    // Determine if RS1 is used
    logic use_rs1;
    always @(*) begin
        case (instr_type)
            `IBASE_LUI, `IBASE_AUIPC, `IBASE_JAL: 
                use_rs1 = 1'b0; 
            `V_EXT_CONFIG: // Now only support vsetvli; ignore vsetivli and vsetvl
                use_rs1 = 1'b1;
            `V_EXT_VEC: // V_EXT_LOAD/STORE use scalar rs1 for base address!
                if (is_OPIVV) begin
                    use_rs1 = 1'b1;
                end
                else if(is_OPIVI) begin
                    use_rs1 = 1'b0;
                end
            default: 
                use_rs1 = 1'b1;
        endcase
    end

    // Determine if RS2 is used (register dependency)
    // Used for: R-Type, Branch, Store
    logic use_rs2;
    always @(*) begin
        case (instr_type)
            `IBASE_ALU, `IBASE_BRANCH, `IBASE_STORE, `M_EXT_MUL, `M_EXT_DIV, `V_EXT_VEC:
                use_rs2 = 1'b1;
            `V_EXT_LOAD:
                use_rs2 = (instr_in[27:26] == 2'b10); // mop == 10 means strided load (needs rs2)
            default:
                use_rs2 = 1'b0;
        endcase
    end

    // Preparing architectural addresses for RAT/vRAT mapping
    assign rs1_arch_internal = use_rs1 ? rs1 : 5'b0; 
    assign rs2_arch_internal = use_rs2 ? rs2 : 5'b0; 
    
    // Preparing destination register for RAT renaming
    // Use dummy dest register for renaming of dest-less instructions
    logic Use_Dummy_rd = (instr_type == `IBASE_STORE || instr_type == `IBASE_BRANCH || instr_type == `V_EXT_STORE || instr_type == `IBASE_UNKNOWN);
    assign dst_arch_internal = Use_Dummy_rd ? 5'b0 : rd;

    logic [5:0] scalar_phys_rs1, scalar_phys_rs2, scalar_phys_rd_old;
    logic [5:0] vec_phys_rs1, vec_phys_rs2, vec_phys_rd_old;

    logic Scalar_Rename_en = !Use_Dummy_rd && (!is_vec_arith && !is_vec_load && !is_vec_store); // V.CONFIG like vsetvli is executed through scalar datapath
    rat #(.NUM_INT_REGS(NUM_INT_REGS), .NUM_PHYS_REGS(NUM_PHYS_REGS))
    scalar_rat_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_arch(rs1_arch_internal), .src2_arch(rs2_arch_internal),
        .src1_phys(scalar_phys_rs1), .src2_phys(scalar_phys_rs2),
        .dst_arch(dst_arch_internal), .dst_phys(free_phys_reg),
        .dst_old_phys(scalar_phys_rd_old),
        .rename_en(valid_in && !stall && !flush && Scalar_Rename_en), 
        .commit_arch(commit_arch_reg), .commit_phys(commit_phys_reg), .commit_en(commit_rat)
    );
    
    logic Vector_Rename_en = (is_vec_arith || is_vec_load); // DO NOT RENAME V.STORE and V.CONFIG
    vector_rat vector_rat_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_arch(rs1_arch_internal), .src2_arch(is_vec_store ? rd : rs2_arch_internal), // V.STORE encodes vs3 (store data) in the rd field;
        .src1_phys(vec_phys_rs1), .src2_phys(vec_phys_rs2), // We use vec_phys_rs2 for V.STORE
        .dst_arch(rd), .dst_phys(free_vphys_reg),
        .dst_old_phys(vec_phys_rd_old),
        .rename_en(valid_in && !stall && !flush &&  Vector_Rename_en), 
        .commit_arch(commit_arch_reg), .commit_phys(commit_phys_reg), .commit_en(commit_vrat)
    );

    // Multiplex outputs based on execution domain
    assign phys_rs1 = is_vec_arith ? vec_phys_rs1 : scalar_phys_rs1; // vsetvli, V.LOAD, V.STORE use scalar_phys_rs1
    assign phys_rs2 = (is_vec_arith || is_vec_store) ? vec_phys_rs2 : scalar_phys_rs2; // V.STORE uses vec_phys_rs2 as store data (vs3) 
    assign phys_rd =  (is_vec_arith || is_vec_load || is_vec_store) ? free_vphys_reg : free_phys_reg; 
    
    // Selecting the old physical register to free on commit
    always @(*) begin
        if((is_vec_arith || is_vec_load)) begin
            phys_rd_old = vec_phys_rd_old;
        end
        else if(is_vec_store) begin
            phys_rd_old = free_vphys_reg; // free the dummy physical register
        end
        else begin
            if(Use_Dummy_rd) begin
                phys_rd_old = free_phys_reg; // free the dummy physical register
            end
            else begin
                phys_rd_old = scalar_phys_rd_old; 
            end
        end
    end


    // Output architectural destination register to ROB
    assign dest_reg = dst_arch_internal; // Dummied as x0 for dest-less scalar instruction.

    // Tunnel Vector Configuration through unused RS payload fields!
    assign imm_out = imm_extended; 
    assign pc_out =  pc_in;
    assign vtype_out = spec_vtype;

    assign use_rs1_out = use_rs1; // to reg_read_stage
    assign use_rs2_out = use_rs2;
    assign use_pc_out = (instr_type == `IBASE_AUIPC || instr_type == `IBASE_JAL || instr_type == `IBASE_JALR || instr_type == `IBASE_BRANCH);
    assign use_vl_out = (instr_type == `V_EXT_VEC || instr_type == `V_EXT_LOAD || instr_type == `V_EXT_STORE);
    
    assign dispatch_predicted_branch = predicted_branch_in;
    assign dispatch_predicted_target = predicted_target_in;

    // Pass domain tags to RS for correct CDB snooping
    assign dispatch_src1_is_vec = is_vec_arith;
    assign dispatch_src2_is_vec = (is_vec_arith || is_vec_store);
    
    // VSETVLI Speculative Execution trigger
    assign vtype_update_en = (instr_type == `V_EXT_CONFIG) && valid_in && !stall && !flush;
    assign new_vtype = {21'b0, zimm}; // Extract zimm[10:0]
    
    // Immediate generation based on instruction type
    always @(*) begin
        case (instr_type)
            `IBASE_ALU_IMM:
                imm_extended = {{20{instr_in[31]}}, instr_in[31:20]}; // Sign-extend for regular immediates
            `V_EXT_LOAD, `V_EXT_STORE:
                imm_extended = 32'b0; // RVV memory ops don't use immediate offsets
            `V_EXT_CONFIG:
                imm_extended = {21'b0, zimm}; // Pass vtypei (zimm) to ALU on op2 for VLMAX calculation
            `V_EXT_VEC: begin
                if (is_OPIVI) 
                    imm_extended = {{27{instr_in[19]}}, instr_in[19:15]}; // Sign-extend 5-bit rs1 field for OPIVI
                else 
                    imm_extended = 32'b0;
            end
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
            // OPIVV uses funct3 = 3'b000 - Integer Vector-Vector; 
            // OPIVI uses funct3 = 3'b011 - Integer Vector-Immediate
            // OPIVX uses funct3 = 3'b100 - Integer Vector-Scalar
            // OPCFG (e.g. vsetli) uses funct3 = 3'b111
            // OPMVV uses funct = 3'b010 - (Miscellaneous) Mask/Permutation Vector-Vector
            // OPIVX and OPMVV will be implemented in the future

            case (funct7[6:1]) // funct6 is top 6 bits of funct7
                6'b000000: alu_op = `VEC_OP_ADD;
                6'b000010: alu_op = `VEC_OP_SUB;
                6'b100101: begin // This funct6 is shared by VMUL.VV and VSLL.VV
                    // For this funct6, we must disambiguate using funct3
                    if (funct3 == 3'b000) alu_op = `VEC_OP_SLL;      // vsll.vv
                    else if (funct3 == 3'b010) alu_op = `VEC_OP_MUL; // vmul.vv
                    else alu_op = `UNKNOWN_VEC_OP;
                end
                6'b001001: alu_op = `VEC_OP_AND;
                6'b001010: alu_op = `VEC_OP_OR;
                6'b001011: alu_op = `VEC_OP_XOR;
                6'b101000: alu_op = `VEC_OP_SRL;
                6'b101001: alu_op = `VEC_OP_SRA; // vsra.vv
                default:   alu_op = `UNKNOWN_VEC_OP; // Default for unhandled funct6
            endcase
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
                3'b000: alu_op = `ALU_BEQ;
                3'b001: alu_op = `ALU_BNE;
                3'b100: alu_op = `ALU_BLT;
                3'b101: alu_op = `ALU_BGE;
                3'b110: alu_op = `ALU_BLTU;
                3'b111: alu_op = `ALU_BGEU;
                default: alu_op = `UNKNOWN_ALU_OP;
            endcase
        end else if (instr_type == `IBASE_JAL) begin
            alu_op = `ALU_JAL;
        end else if (instr_type == `IBASE_JALR) begin
            alu_op = `ALU_JALR;
        end else if (instr_type == `M_EXT_MUL || instr_type == `M_EXT_DIV) begin
            // M-Extension Operation Decoding
            // funct3 maps directly to the operation subtype (MUL, MULH, DIV, REM, etc.)
            alu_op = {2'b00, funct3};
        end else if (instr_type == `V_EXT_CONFIG) begin
            // VSETVLI requires special ALU handling to compute min(AVL, VLMAX)
            alu_op = `ALU_VSETVL;
        end else if (instr_type == `IBASE_STORE || instr_type == `V_EXT_STORE) begin
            alu_op = 5'b00001; // See reg_read_stage.sv for how this routes store data
        end else if (instr_type == `IBASE_LOAD || instr_type == `V_EXT_LOAD) begin
            // execute_stage expects 00000 for unit-stride loads, 00010 for strided loads
            if (instr_type == `V_EXT_LOAD && instr_in[27:26] == 2'b10) begin
                alu_op = 5'b00010;
            end else begin
                alu_op = 5'b00000;
            end
        end else begin
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
            `V_EXT_CONFIG:   rs_type = `RS_TYPE_ALU; // VSETVLI goes to ALU (writes VL to scalar rd)
            default:         rs_type = `RS_TYPE_NONE;
        endcase
    end


    // Control signals for RS, ROB, and LSQ allocation
    assign rs_alloc_valid = valid_in && !stall && !flush;
    assign rob_alloc_valid = valid_in && !stall && !flush;
    
    logic is_load = (instr_type == `IBASE_LOAD || instr_type == `V_EXT_LOAD);
    logic is_store = (instr_type == `IBASE_STORE || instr_type == `V_EXT_STORE);
    
    assign lsq_alloc_req = (is_load || is_store) && valid_in && !stall && !flush;
    assign lsq_alloc_is_store = is_store;
    assign lsq_alloc_size = funct3; // Record size at allocation!
    assign lsq_alloc_is_vector = (is_vec_load || is_vec_store);
    assign lsq_alloc_vtype = spec_vtype; // Known at dispatch
    assign dispatch_lsq_tag = lsq_alloc_tag_in;
    
    // All signals should be prepared in one cycle 
    assign valid_out = valid_in && !stall && !flush;

endmodule
