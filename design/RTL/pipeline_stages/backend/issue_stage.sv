// ============================================================================
// issue_stage.sv - Encapsulates all Reservation Stations & Scheduler
// ============================================================================
// Holds instructions until their operands are ready on the CDB.
// Issues tags (not data) to the RegRead stage.

`include "../../riscv_header.sv"

module issue_stage #(
    parameter XLEN = 32,
    parameter RS_TAG_WIDTH = 6,
    parameter LSQ_TAG_WIDTH = 4,
    parameter ALU_RS_SIZE = 8,
    parameter MEM_RS_SIZE = 8,
    parameter MUL_RS_SIZE = 4,
    parameter DIV_RS_SIZE = 4,
    parameter VEC_RS_SIZE = 8,
    parameter MUL_LATENCY = 4,
    parameter DIV_LATENCY = 6
) (
    input clk,
    input rst_n,
    input flush,
    
    // --------------------------------------------------------------------
    // Dispatch Interface
    // --------------------------------------------------------------------
    input dispatch_valid,
    input [3:0] dispatch_rs_type,
    input [RS_TAG_WIDTH-1:0] dispatch_src1_tag,
    input dispatch_src1_valid,
    input [RS_TAG_WIDTH-1:0] dispatch_src2_tag,
    input dispatch_src2_valid,
    input dispatch_use_rs1,
    input dispatch_use_rs2,
    input dispatch_use_pc,
    input dispatch_use_vl,
    input [RS_TAG_WIDTH-1:0] dispatch_vl_tag,
    input dispatch_vl_valid,
    input [XLEN-1:0] dispatch_imm,
    input [XLEN-1:0] dispatch_vtype,
    input [XLEN-1:0] dispatch_pc,
    input [3:0] dispatch_alu_op,
    input dispatch_src1_is_vec,
    input dispatch_src2_is_vec,
    input [RS_TAG_WIDTH-1:0] dispatch_dest_tag,
    input [LSQ_TAG_WIDTH-1:0] dispatch_lsq_tag,
    
    // --------------------------------------------------------------------
    // CDB Broadcast Interfaces (Tags Only)
    // --------------------------------------------------------------------
    input [RS_TAG_WIDTH-1:0] cdb0_tag,
    input cdb0_valid,
    input [RS_TAG_WIDTH-1:0] cdb1_tag,
    input cdb1_valid,
    input [RS_TAG_WIDTH-1:0] vec_cdb0_tag,
    input vec_cdb0_valid,
    input [RS_TAG_WIDTH-1:0] vec_cdb1_tag,
    input vec_cdb1_valid,
    
    // --------------------------------------------------------------------
    // FU Ready Handshaking (Classic Tomasulo)
    // --------------------------------------------------------------------
    input mem_fu_ready,
    input div_fu_ready,
    input vec_fu_ready,

    // --------------------------------------------------------------------
    // Status to Dispatch/Hazard Unit
    // --------------------------------------------------------------------
    output alu_rs_full,
    output mem_rs_full,
    output mul_rs_full,
    output div_rs_full,
    output vec_rs_full,
    
    // --------------------------------------------------------------------
    // Issue Interfaces (to RegRead Stage)
    // --------------------------------------------------------------------
    // ALU
    output alu_issue_valid,
    output [RS_TAG_WIDTH-1:0] alu_issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] alu_issue_src2_tag,
    output alu_issue_use_rs1,
    output alu_issue_use_rs2,
    output alu_issue_use_pc,
    output [RS_TAG_WIDTH-1:0] alu_issue_dest_tag,
    output [XLEN-1:0] alu_issue_imm,
    output [XLEN-1:0] alu_issue_pc,
    output [3:0] alu_issue_op,
    
    // MEM
    output mem_issue_valid,
    output [RS_TAG_WIDTH-1:0] mem_issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] mem_issue_src2_tag,
    output mem_issue_use_rs1,
    output mem_issue_use_rs2,
    output mem_issue_use_vl,
    output [RS_TAG_WIDTH-1:0] mem_issue_dest_tag,
    output [XLEN-1:0] mem_issue_imm,
    output [RS_TAG_WIDTH-1:0] mem_issue_vl_tag,
    output [3:0] mem_issue_op,
    output [LSQ_TAG_WIDTH-1:0] mem_issue_lsq_tag,
    
    // MUL
    output mul_issue_valid,
    output [RS_TAG_WIDTH-1:0] mul_issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] mul_issue_src2_tag,
    output [RS_TAG_WIDTH-1:0] mul_issue_dest_tag,
    output [3:0] mul_issue_op,
    
    // DIV
    output div_issue_valid,
    output [RS_TAG_WIDTH-1:0] div_issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] div_issue_src2_tag,
    output [RS_TAG_WIDTH-1:0] div_issue_dest_tag,
    output [3:0] div_issue_op,
    
    // VEC
    output vec_issue_valid,
    output [RS_TAG_WIDTH-1:0] vec_issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] vec_issue_src2_tag,
    output [RS_TAG_WIDTH-1:0] vec_issue_dest_tag,
    output vec_issue_use_vl,
    output [3:0] vec_issue_op
    output [RS_TAG_WIDTH-1:0] vec_issue_vl_tag,
    output [XLEN-1:0] vec_issue_vtype
);

    // Scheduler wires
    logic req_alu, req_mul;
    logic grant_alu, grant_mul;

    // ========================================================================
    // Reservation Stations
    // ========================================================================

    reservation_station #(.RS_SIZE(ALU_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(RS_TAG_WIDTH)) alu_rs_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_tag(dispatch_src1_tag), .src1_valid(dispatch_src1_valid),
        .src2_tag(dispatch_src2_tag), .src2_valid(dispatch_src2_valid),
        .use_rs1_in(dispatch_use_rs1), .use_rs2_in(dispatch_use_rs2), .use_pc_in(dispatch_use_pc),
        .vl_tag_in(dispatch_vl_tag), .vl_valid_in(dispatch_vl_valid), .use_vl_in(dispatch_use_vl),
        .src1_is_vec_in(1'b0), .src2_is_vec_in(1'b0), // ALU uses scalar
        .imm_data(dispatch_imm), .vtype_data(dispatch_vtype), .pc_data(dispatch_pc), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_valid && (dispatch_rs_type == `RS_TYPE_ALU)),
        .dest_tag_in(dispatch_dest_tag), .lsq_tag_in({LSQ_TAG_WIDTH{1'b0}}),
        .cdb0_tag(cdb0_tag), .cdb0_valid(cdb0_valid), .cdb1_tag(cdb1_tag), .cdb1_valid(cdb1_valid),
        .vec_cdb0_tag(vec_cdb0_tag), .vec_cdb0_valid(vec_cdb0_valid), .vec_cdb1_tag(vec_cdb1_tag), .vec_cdb1_valid(vec_cdb1_valid),
        .issue_req(req_alu), .issue_grant(grant_alu),
        .issue_src1_tag(alu_issue_src1_tag), .issue_src2_tag(alu_issue_src2_tag),
        .issue_use_rs1(alu_issue_use_rs1), .issue_use_rs2(alu_issue_use_rs2), .issue_use_pc(alu_issue_use_pc),
        .issue_imm(alu_issue_imm), .issue_pc(alu_issue_pc), .execute_op(alu_issue_op), 
        .execute_valid(alu_issue_valid), .rs_full(alu_rs_full), .assigned_tag(alu_issue_dest_tag)
    );

    reservation_station #(.RS_SIZE(MEM_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(RS_TAG_WIDTH)) mem_rs_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_tag(dispatch_src1_tag), .src1_valid(dispatch_src1_valid),
        .src2_tag(dispatch_src2_tag), .src2_valid(dispatch_src2_valid),
        .use_rs1_in(dispatch_use_rs1), .use_rs2_in(dispatch_use_rs2), .use_pc_in(1'b0),
        .vl_tag_in(dispatch_vl_tag), .vl_valid_in(dispatch_vl_valid), .use_vl_in(dispatch_use_vl),
        .src1_is_vec_in(1'b0), .src2_is_vec_in(dispatch_src2_is_vec), // MEM might use vector for store data
        .imm_data(dispatch_imm), .vtype_data(dispatch_vtype), .pc_data(dispatch_pc), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_valid && (dispatch_rs_type == `RS_TYPE_MEM)),
        .dest_tag_in(dispatch_dest_tag), .lsq_tag_in(dispatch_lsq_tag),
        .cdb0_tag(cdb0_tag), .cdb0_valid(cdb0_valid), .cdb1_tag(cdb1_tag), .cdb1_valid(cdb1_valid),
        .vec_cdb0_tag(vec_cdb0_tag), .vec_cdb0_valid(vec_cdb0_valid), .vec_cdb1_tag(vec_cdb1_tag), .vec_cdb1_valid(vec_cdb1_valid),
        .issue_req(), .issue_grant(mem_fu_ready), // Unscheduled bus
        .issue_src1_tag(mem_issue_src1_tag), .issue_src2_tag(mem_issue_src2_tag),
        .issue_use_rs1(mem_issue_use_rs1), .issue_use_rs2(mem_issue_use_rs2), .issue_use_pc(), .issue_use_vl(mem_issue_use_vl),
        .issue_imm(mem_issue_imm), .issue_vl_tag(mem_issue_vl_tag), .execute_op(mem_issue_op), .execute_lsq_tag(mem_issue_lsq_tag),
        .execute_valid(mem_issue_valid), .rs_full(mem_rs_full), .assigned_tag(mem_issue_dest_tag)
    );

    reservation_station #(.RS_SIZE(MUL_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(RS_TAG_WIDTH)) mul_rs_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_tag(dispatch_src1_tag), .src1_valid(dispatch_src1_valid),
        .src2_tag(dispatch_src2_tag), .src2_valid(dispatch_src2_valid),
        .use_rs1_in(1'b1), .use_rs2_in(1'b1), .use_pc_in(1'b0), // MUL always uses registers
        .vl_tag_in(dispatch_vl_tag), .vl_valid_in(dispatch_vl_valid), .use_vl_in(dispatch_use_vl),
        .src1_is_vec_in(1'b0), .src2_is_vec_in(1'b0),
        .imm_data(dispatch_imm), .vtype_data(dispatch_vtype), .pc_data(dispatch_pc), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_valid && (dispatch_rs_type == `RS_TYPE_MUL)),
        .dest_tag_in(dispatch_dest_tag), .lsq_tag_in({LSQ_TAG_WIDTH{1'b0}}),
        .cdb0_tag(cdb0_tag), .cdb0_valid(cdb0_valid), .cdb1_tag(cdb1_tag), .cdb1_valid(cdb1_valid),
        .vec_cdb0_tag(vec_cdb0_tag), .vec_cdb0_valid(vec_cdb0_valid), .vec_cdb1_tag(vec_cdb1_tag), .vec_cdb1_valid(vec_cdb1_valid),
        .issue_req(req_mul), .issue_grant(grant_mul),
        .issue_src1_tag(mul_issue_src1_tag), .issue_src2_tag(mul_issue_src2_tag),
        .execute_op(mul_issue_op), .execute_valid(mul_issue_valid), .rs_full(mul_rs_full), .assigned_tag(mul_issue_dest_tag)
    );

    reservation_station #(.RS_SIZE(DIV_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(RS_TAG_WIDTH)) div_rs_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_tag(dispatch_src1_tag), .src1_valid(dispatch_src1_valid),
        .src2_tag(dispatch_src2_tag), .src2_valid(dispatch_src2_valid),
        .use_rs1_in(1'b1), .use_rs2_in(1'b1), .use_pc_in(1'b0), // DIV always uses registers
        .vl_tag_in(dispatch_vl_tag), .vl_valid_in(dispatch_vl_valid), .use_vl_in(dispatch_use_vl),
        .src1_is_vec_in(1'b0), .src2_is_vec_in(1'b0),
        .imm_data(dispatch_imm), .vtype_data(dispatch_vtype), .pc_data(dispatch_pc), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_valid && (dispatch_rs_type == `RS_TYPE_DIV)),
        .dest_tag_in(dispatch_dest_tag), .lsq_tag_in({LSQ_TAG_WIDTH{1'b0}}),
        .cdb0_tag(cdb0_tag), .cdb0_valid(cdb0_valid), .cdb1_tag(cdb1_tag), .cdb1_valid(cdb1_valid),
        .vec_cdb0_tag(vec_cdb0_tag), .vec_cdb0_valid(vec_cdb0_valid), .vec_cdb1_tag(vec_cdb1_tag), .vec_cdb1_valid(vec_cdb1_valid),
        .issue_req(), .issue_grant(div_fu_ready), // Unscheduled bus
        .issue_src1_tag(div_issue_src1_tag), .issue_src2_tag(div_issue_src2_tag),
        .execute_op(div_issue_op), .execute_valid(div_issue_valid), .rs_full(div_rs_full), .assigned_tag(div_issue_dest_tag)
    );

    reservation_station #(.RS_SIZE(VEC_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(RS_TAG_WIDTH)) vec_rs_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .src1_tag(dispatch_src1_tag), .src1_valid(dispatch_src1_valid),
        .src2_tag(dispatch_src2_tag), .src2_valid(dispatch_src2_valid),
        .use_rs1_in(1'b1), .use_rs2_in(1'b1), .use_pc_in(1'b0),
        .vl_tag_in(dispatch_vl_tag), .vl_valid_in(dispatch_vl_valid), .use_vl_in(dispatch_use_vl),
        .src1_is_vec_in(dispatch_src1_is_vec), .src2_is_vec_in(dispatch_src2_is_vec), // VEC uses vector operands
        .imm_data(dispatch_imm), .vtype_data(dispatch_vtype), .pc_data(dispatch_pc), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_valid && (dispatch_rs_type == `RS_TYPE_VEC)),
        .dest_tag_in(dispatch_dest_tag), .lsq_tag_in({LSQ_TAG_WIDTH{1'b0}}),
        .cdb0_tag(cdb0_tag), .cdb0_valid(cdb0_valid), .cdb1_tag(cdb1_tag), .cdb1_valid(cdb1_valid),
        .vec_cdb0_tag(vec_cdb0_tag), .vec_cdb0_valid(vec_cdb0_valid), .vec_cdb1_tag(vec_cdb1_tag), .vec_cdb1_valid(vec_cdb1_valid),
        .issue_req(), .issue_grant(vec_fu_ready), // Unscheduled bus
        .issue_src1_tag(vec_issue_src1_tag), .issue_src2_tag(vec_issue_src2_tag), .issue_use_vl(vec_issue_use_vl),
        .issue_vl_tag(vec_issue_vl_tag), .issue_vtype(vec_issue_vtype),
        .execute_op(vec_issue_op), .execute_valid(vec_issue_valid), .rs_full(vec_rs_full), .assigned_tag(vec_issue_dest_tag)
    );

    // ========================================================================
    // Predictive Issue Scheduler (For Scheduled CDB FUs)
    // ========================================================================
    issue_scheduler #(
        .MAX_LATENCY(8), .ALU_LATENCY(1), .MUL_LATENCY(MUL_LATENCY), .DIV_LATENCY(DIV_LATENCY)
    ) issue_scheduler_inst (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .req_alu(req_alu), .req_mul(req_mul), .req_div(1'b0),
        .grant_alu(grant_alu), .grant_mul(grant_mul), .grant_div()
    );

endmodule