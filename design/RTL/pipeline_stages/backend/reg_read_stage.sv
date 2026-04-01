// ============================================================================
// reg_read_stage.sv - Payload / Register Read Stage
// ============================================================================
// Receives issued tags from the Reservation Stations, fetches data from the 
// Physical Register Files, handles CDB forwarding (bypass), multiplexes constants
// (PC/Immediates), and flops the payload to the Execute Stage.

`include "../../riscv_header.sv"

module reg_read_stage #(
    parameter XLEN = 32,
    parameter VLEN = 128,
    parameter RS_TAG_WIDTH = 6,
    parameter LSQ_TAG_WIDTH = 4
) (
    input clk,
    input rst_n,
    input flush,

    // --------------------------------------------------------------------
    // Interfaces from Issue Stage (Tags & Constants)
    // --------------------------------------------------------------------
    input alu_issue_valid,
    input [RS_TAG_WIDTH-1:0] alu_issue_src1_tag, alu_issue_src2_tag, alu_issue_dest_tag,
    input [XLEN-1:0] alu_issue_imm, alu_issue_pc,
    input [3:0] alu_issue_op,
    input alu_use_rs1, alu_use_rs2, alu_use_pc, // Multiplexing control

    input mem_issue_valid,
    input [RS_TAG_WIDTH-1:0] mem_issue_src1_tag, mem_issue_src2_tag, mem_issue_dest_tag,
    input [RS_TAG_WIDTH-1:0] mem_issue_vl_tag,
    input [XLEN-1:0] mem_issue_imm,
    input [3:0] mem_issue_op,
    input [LSQ_TAG_WIDTH-1:0] mem_issue_lsq_tag,
    input mem_use_rs1, mem_use_rs2,
    input mem_use_vl,

    input mul_issue_valid,
    input [RS_TAG_WIDTH-1:0] mul_issue_src1_tag, mul_issue_src2_tag, mul_issue_dest_tag,
    input [3:0] mul_issue_op,

    input div_issue_valid,
    input [RS_TAG_WIDTH-1:0] div_issue_src1_tag, div_issue_src2_tag, div_issue_dest_tag,
    input [3:0] div_issue_op,

    input vec_issue_valid,
    input [RS_TAG_WIDTH-1:0] vec_issue_src1_tag, vec_issue_src2_tag, vec_issue_dest_tag,
    input [RS_TAG_WIDTH-1:0] vec_issue_vl_tag,
    input [3:0] vec_issue_op,
    input vec_use_vl,
    input [XLEN-1:0] vec_issue_vtype,

    // --------------------------------------------------------------------
    // Interfaces to/from PRFs (Data Fetching)
    // --------------------------------------------------------------------
    output logic [RS_TAG_WIDTH-1:0] prf_read_addrs [0:9],
    input  logic [XLEN-1:0] prf_read_datas [0:9],
    
    output logic [RS_TAG_WIDTH-1:0] vprf_read_addr1, vprf_read_addr2,
    output logic [RS_TAG_WIDTH-1:0] vprf_read_addr3,
    input  logic [VLEN-1:0] vprf_read_data1, vprf_read_data2,
    input  logic [VLEN-1:0] vprf_read_data3,

    // --------------------------------------------------------------------
    // CDB Bypass Inputs (From Execute Stage)
    // --------------------------------------------------------------------
    input cdb0_valid,
    input [RS_TAG_WIDTH-1:0] cdb0_tag,
    input [XLEN-1:0] cdb0_result,

    input cdb1_valid,
    input [RS_TAG_WIDTH-1:0] cdb1_tag,
    input [XLEN-1:0] cdb1_result,
    
    input vec_cdb0_valid,
    input [RS_TAG_WIDTH-1:0] vec_cdb0_tag,
    input [VLEN-1:0] vec_cdb0_result,
    
    input vec_cdb1_valid,
    input [RS_TAG_WIDTH-1:0] vec_cdb1_tag,
    input [VLEN-1:0] vec_cdb1_result,

    // --------------------------------------------------------------------
    // Interfaces to Execute Stage (Actual Data Payloads)
    // --------------------------------------------------------------------
    output logic alu_valid_exec, mem_valid_exec, mul_valid_exec, div_valid_exec, vec_valid_exec,
    output logic [XLEN-1:0] alu_op1_exec, alu_op2_exec,
    output logic [XLEN-1:0] mem_op1_exec, 
    output logic [DLEN-1:0] mem_op2_exec,
    output logic [XLEN-1:0] mem_imm_exec,
    output logic [31:0] mem_vl_exec,
    output logic [XLEN-1:0] mul_op1_exec, mul_op2_exec,
    output logic [XLEN-1:0] div_op1_exec, div_op2_exec,
    output logic [VLEN-1:0] vec_op1_exec, vec_op2_exec,
    output logic [31:0] vec_vl_exec,
    output logic [31:0] vec_vtype_exec,
    
    output logic [RS_TAG_WIDTH-1:0] alu_tag_exec, mem_tag_exec, mul_tag_exec, div_tag_exec, vec_tag_exec,
    output logic [3:0] alu_op_exec, mem_op_exec, vec_op_exec,
    output logic [LSQ_TAG_WIDTH-1:0] mem_lsq_tag_exec
);

    // ========================================================================
    // 1. Map Read Addresses to the PRF Ports
    // ========================================================================
    assign prf_read_addrs[0] = alu_issue_src1_tag;
    assign prf_read_addrs[1] = alu_issue_src2_tag;
    assign prf_read_addrs[2] = mem_issue_src1_tag;
    assign prf_read_addrs[3] = mem_issue_src2_tag;
    assign prf_read_addrs[4] = mul_issue_src1_tag;
    assign prf_read_addrs[5] = mul_issue_src2_tag;
    assign prf_read_addrs[6] = div_issue_src1_tag;
    assign prf_read_addrs[7] = div_issue_src2_tag;
    assign prf_read_addrs[8] = mem_issue_vl_tag;
    assign prf_read_addrs[9] = vec_issue_vl_tag;
    
    assign vprf_read_addr1 = vec_issue_src1_tag;
    assign vprf_read_addr2 = vec_issue_src2_tag;
    assign vprf_read_addr3 = mem_issue_src2_tag; // 3rd port dedicated to vector store operand

    // ========================================================================
    // 2. Combinational Bypass & Multiplexing Logic
    // ========================================================================
    logic [XLEN-1:0] alu_src1_bypassed, alu_src2_bypassed;
    logic [XLEN-1:0] mem_src1_bypassed, mem_src2_bypassed;
    logic [XLEN-1:0] mul_src1_bypassed, mul_src2_bypassed;
    logic [XLEN-1:0] div_src1_bypassed, div_src2_bypassed;
    logic [XLEN-1:0] mem_vl_bypassed;
    logic [XLEN-1:0] vec_vl_bypassed;
    logic [VLEN-1:0] vec_src1_bypassed, vec_src2_bypassed;
    logic [VLEN-1:0] mem_vec_src2_bypassed;

    // ALU Payload
    always @(*) begin
        // Operand 1 (Register vs PC vs 0)
        if (!alu_use_rs1) alu_src1_bypassed = alu_use_pc ? alu_issue_pc : {XLEN{1'b0}};
        else if (cdb0_valid && cdb0_tag == alu_issue_src1_tag) alu_src1_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == alu_issue_src1_tag) alu_src1_bypassed = cdb1_result;
        else alu_src1_bypassed = prf_read_datas[0];

        // Operand 2 (Register vs Immediate)
        if (!alu_use_rs2) alu_src2_bypassed = alu_issue_imm;
        else if (cdb0_valid && cdb0_tag == alu_issue_src2_tag) alu_src2_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == alu_issue_src2_tag) alu_src2_bypassed = cdb1_result;
        else alu_src2_bypassed = prf_read_datas[1];
    end

    // MEM Payload
    always @(*) begin
        if (!mem_use_rs1) mem_src1_bypassed = {XLEN{1'b0}}; // All MEM operations use rs1; this won't happen.
        else if (cdb0_valid && cdb0_tag == mem_issue_src1_tag) mem_src1_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == mem_issue_src1_tag) mem_src1_bypassed = cdb1_result;
        else mem_src1_bypassed = prf_read_datas[2];
        
        // Scalar Store Data Bypass
        if (!mem_use_rs2) mem_src2_bypassed = {XLEN{1'b0}}; // Loads don't use rs2 
        else if (cdb0_valid && cdb0_tag == mem_issue_src2_tag) mem_src2_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == mem_issue_src2_tag) mem_src2_bypassed = cdb1_result;
        else mem_src2_bypassed = prf_read_datas[3];
        
        //Vector Store Data and VL Bypass (Only for Vector Stores)
        if (mem_use_vl) begin  
            // VL Bypass
            mem_vl_bypassed = prf_read_datas[8]; // VL already ready from RS
            // Vector Store Data Bypass (from vec_cdb or vector PRF)
            if (vec_cdb0_valid && vec_cdb0_tag == mem_issue_src2_tag) mem_vec_src2_bypassed = vec_cdb0_result;
            else if (vec_cdb1_valid && vec_cdb1_tag == mem_issue_src2_tag) mem_vec_src2_bypassed = vec_cdb1_result;
            else mem_vec_src2_bypassed = vprf_read_data3;
        end else begin
            mem_vl_bypassed = 32'b0;
            mem_vec_src2_bypassed = {VLEN{1'b0}};
        end
    end

    // MUL Payload (Always uses registers)
    always @(*) begin
        if (cdb0_valid && cdb0_tag == mul_issue_src1_tag) mul_src1_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == mul_issue_src1_tag) mul_src1_bypassed = cdb1_result;
        else mul_src1_bypassed = prf_read_datas[4];

        if (cdb0_valid && cdb0_tag == mul_issue_src2_tag) mul_src2_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == mul_issue_src2_tag) mul_src2_bypassed = cdb1_result;
        else mul_src2_bypassed = prf_read_datas[5];
    end

    // DIV Payload (Always uses registers)
    always @(*) begin
        if (cdb0_valid && cdb0_tag == div_issue_src1_tag) div_src1_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == div_issue_src1_tag) div_src1_bypassed = cdb1_result;
        else div_src1_bypassed = prf_read_datas[6];

        if (cdb0_valid && cdb0_tag == div_issue_src2_tag) div_src2_bypassed = cdb0_result;
        else if (cdb1_valid && cdb1_tag == div_issue_src2_tag) div_src2_bypassed = cdb1_result;
        else div_src2_bypassed = prf_read_datas[7];
    end

    // VEC Payload (Bypasses via dedicated Vector CDB)
    always @(*) begin
        if (vec_cdb0_valid && vec_cdb0_tag == vec_issue_src1_tag) vec_src1_bypassed = vec_cdb0_result;
        else if (vec_cdb1_valid && vec_cdb1_tag == vec_issue_src1_tag) vec_src1_bypassed = vec_cdb1_result;
        else vec_src1_bypassed = vprf_read_data1;

        if (vec_cdb0_valid && vec_cdb0_tag == vec_issue_src2_tag) vec_src2_bypassed = vec_cdb0_result;
        else if (vec_cdb1_valid && vec_cdb1_tag == vec_issue_src2_tag) vec_src2_bypassed = vec_cdb1_result;
        else vec_src2_bypassed = vprf_read_data2;
        
        if (!vec_use_vl) vec_vl_bypassed = 32'b0;
        else vec_vl_bypassed = prf_read_datas[9]; // VL already ready from RS
    end

    // ========================================================================
    // 3. Pipeline Register (Flop to Execute Stage)
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            alu_valid_exec <= 1'b0;
            mem_valid_exec <= 1'b0;
            mul_valid_exec <= 1'b0;
            div_valid_exec <= 1'b0;
            vec_valid_exec <= 1'b0;
        end else begin
            // ALU Flop
            alu_valid_exec <= alu_issue_valid;
            if (alu_issue_valid) begin
                alu_op1_exec <= alu_src1_bypassed;
                alu_op2_exec <= alu_src2_bypassed;
                alu_tag_exec <= alu_issue_dest_tag;
                alu_op_exec  <= alu_issue_op;
            end
            
            // MEM Flop
            mem_valid_exec <= mem_issue_valid;
            if (mem_issue_valid) begin
                mem_op1_exec <= mem_src1_bypassed;
                if (mem_use_vl) mem_op2_exec <= mem_vec_src2_bypassed; // 128-bit VPRF data
                else mem_op2_exec <= { {(DLEN-XLEN){1'b0}}, mem_src2_bypassed }; // 32-bit zero-extended data
                mem_imm_exec <= mem_issue_imm;
                mem_tag_exec <= mem_issue_dest_tag;
                mem_op_exec  <= mem_issue_op;
                mem_lsq_tag_exec <= mem_issue_lsq_tag;
                mem_vl_exec <= mem_vl_bypassed;
            end
            
            // MUL Flop
            mul_valid_exec <= mul_issue_valid;
            if (mul_issue_valid) begin
                mul_op1_exec <= mul_src1_bypassed;
                mul_op2_exec <= mul_src2_bypassed;
                mul_tag_exec <= mul_issue_dest_tag;
            end
            
            // DIV Flop
            div_valid_exec <= div_issue_valid;
            if (div_issue_valid) begin
                div_op1_exec <= div_src1_bypassed;
                div_op2_exec <= div_src2_bypassed;
                div_tag_exec <= div_issue_dest_tag;
            end
            
            // VEC Flop
            vec_valid_exec <= vec_issue_valid;
            if (vec_issue_valid) begin
                vec_op1_exec <= vec_src1_bypassed;
                vec_op2_exec <= vec_src2_bypassed;
                vec_tag_exec <= vec_issue_dest_tag;
                vec_op_exec  <= vec_issue_op;
                vec_vl_exec  <= vec_vl_bypassed;
                vec_vtype_exec <= vec_issue_vtype;
            end
        end
    end

endmodule