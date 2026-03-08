// ============================================================================
// riscv_core_top.sv
// ============================================================================
// ARCHITECTURE: 6-stage OoO processor with RAT + PRF + ARF renaming scheme
// Key Notes: 
// - ROB is for in-oreder commit only, not data storage
// - Speculative data stored in physical_register_file

`include "riscv_header.sv"

module riscv_core_top (
    input clk,
    input rst_n,
    
    output [XLEN-1:0] imem_addr,
    input [INST_WIDTH-1:0] imem_data,
    input imem_valid,
    
    output [XLEN-1:0] dmem_addr,
    output [XLEN-1:0] dmem_write_data,
    input [XLEN-1:0] dmem_read_data,
    output dmem_we,
    output [3:0] dmem_be,
    input dmem_valid,
    
    input ext_irq,
    output exception_valid,
    output [EXCEPTION_CODE_WIDTH-1:0] exception_code,
    output [NUM_INT_REGS-1:0][XLEN-1:0] debug_reg_file
);

    // ========================================================================
    // INTERNAL SIGNALS
    // ========================================================================
    
    // Pipeline stage signals
    logic [XLEN-1:0] fetch_pc, decode_pc;
    logic [INST_WIDTH-1:0] fetch_instr, decode_instr;
    logic [3:0] decode_instr_type;
    logic fetch_valid, decode_valid, dispatch_valid;
    logic [3:0] dispatch_rs_type;
    logic dispatch_rs_alloc, dispatch_rob_alloc, dispatch_lsq_alloc;
    
    // Dispatch outputs
    logic [XLEN-1:0] dispatch_src1, dispatch_src2, dispatch_imm;
    logic [4:0] dispatch_dest_reg;
    logic [3:0] dispatch_alu_op;
    
    // Register addressing
    logic [4:0] rs1_addr, rs2_addr;
    logic [XLEN-1:0] rs1_value, rs2_value;
    
    // RAT signals (Register Alias Table)
    logic [5:0] rat_src1_phys, rat_src2_phys, rat_dst_phys;
    
    // Physical register file signals
    logic [XLEN-1:0] phys_reg_data1, phys_reg_data2;
    logic phys_reg_valid1, phys_reg_valid2;
    
    // RS signals (5 types)
    logic alu_rs_full, mem_rs_full, mul_rs_full, div_rs_full, vec_rs_full;
    logic [XLEN-1:0] alu_op1, alu_op2, mem_op1, mem_op2, mul_op1, mul_op2, div_op1, div_op2;
    logic [VLEN-1:0] vec_op1, vec_op2;
    logic [3:0] alu_operation, mem_operation, vec_operation;
    logic alu_valid, mem_valid, mul_valid, div_valid, vec_valid;
    logic [5:0] alu_tag, mem_tag, mul_tag, div_tag, vec_tag;  // Physical reg tags!
    
    // CDB (Common Data Bus)
    logic [XLEN-1:0] cdb_result;
    logic [5:0] cdb_tag;  // Physical register tag
    logic cdb_valid;
    
    // Free list signals
    logic [5:0] free_phys_reg;
    logic free_list_valid;
    
    // ROB signals (TRACKING ONLY, not data)
    logic rob_full, rob_commit_valid;
    logic [4:0] rob_commit_dest_arch_reg;
    logic [5:0] rob_commit_dest_phys_reg;  // Physical reg holding the result
    logic [3:0] rob_commit_instr_type;
    
    // Commit signals
    logic [4:0] reg_write_addr;
    logic [XLEN-1:0] reg_write_data;
    logic reg_write_en;
    
    // Control signals
    logic flush_pipeline, branch_mispredict;
    logic stall_fetch, stall_decode, stall_dispatch;
    logic [XLEN-1:0] branch_target;
    logic lsq_lq_full, lsq_sq_full;

    // ========================================================================
    // STAGE 1: FETCH
    // ========================================================================
    
    fetch_stage #(.XLEN(XLEN), .INST_WIDTH(INST_WIDTH))
    fetch_inst (.clk(clk), .rst_n(rst_n), .stall(stall_fetch), .flush(flush_pipeline),
        .branch_target(branch_target), .pc_out(fetch_pc), .instr_out(fetch_instr),
        .valid_out(fetch_valid), .imem_addr(imem_addr), .imem_data(imem_data), .imem_valid(imem_valid));

    // ========================================================================
    // STAGE 2: DECODE
    // ========================================================================
    
    decode_stage #(.XLEN(XLEN), .INST_WIDTH(INST_WIDTH), .NUM_INT_REGS(NUM_INT_REGS))
    decode_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline), .stall(stall_decode),
        .instr_in(fetch_instr), .pc_in(fetch_pc), .valid_in(fetch_valid),
        .instr_type_out(decode_instr_type), .pc_out(decode_pc),
        .instr_out(decode_instr), .valid_out(decode_valid));

    // ========================================================================
    // REGISTER FILES (Arch Registers Only)
    // ========================================================================
    
    register_file #(.NUM_INT_REGS(NUM_INT_REGS), .XLEN(XLEN))
    regfile_inst (.clk(clk), .rst_n(rst_n),
        .read_addr1(rs1_addr), .read_addr2(rs2_addr),
        .read_data1(rs1_value), .read_data2(rs2_value),
        .write_addr(reg_write_addr), .write_data(reg_write_data),
        .write_en(reg_write_en), .debug_reg_file(debug_reg_file));
    
    vector_register_file #(.NUM_VEC_REGS(NUM_VEC_REGS), .VLEN(VLEN))
    vec_regfile_inst (.clk(clk), .rst_n(rst_n),
        .read_addr1(5'b0), .read_addr2(5'b0),
        .read_data1(), .read_data2(),
        .write_addr(5'b0), .write_data(0), .write_en(1'b0));

    // ========================================================================
    // REGISTER ALIAS TABLE (Maps arch regs to physical regs)
    // ========================================================================
    
    rat #(.NUM_INT_REGS(NUM_INT_REGS), .NUM_PHYS_REGS(NUM_PHYS_REGS))
    rat_inst (.clk(clk), .rst_n(rst_n),
        .src1_arch(rs1_addr), .src2_arch(rs2_addr),
        .src1_phys(rat_src1_phys), .src2_phys(rat_src2_phys),
        .dst_arch(dispatch_dest_reg), .dst_phys(rat_dst_phys),
        .rename_en(dispatch_valid),
        .commit_arch(rob_commit_dest_arch_reg), .commit_phys(rob_commit_dest_phys_reg),
        .commit_en(rob_commit_valid));

    // Connect Free List allocation to RAT destination
    assign rat_dst_phys = free_phys_reg;

    // ========================================================================
    // PHYSICAL REGISTER FILE (Speculative data storage)
    // ========================================================================
    
    physical_register_file #(.NUM_PHYS_REGS(NUM_PHYS_REGS), .XLEN(XLEN))
    phys_regfile_inst (.clk(clk), .rst_n(rst_n),
        .write_addr(cdb_tag), .write_data(cdb_result), .write_en(cdb_valid),
        .read_addr1(rat_src1_phys), .read_addr2(rat_src2_phys),
        .read_data1(phys_reg_data1), .read_data2(phys_reg_data2),
        .status_wr_addr(cdb_tag), .status_wr_en(cdb_valid),
        .status_valid());

    // ========================================================================
    // FREE LIST (Returns freed physical registers)
    // ========================================================================
    
    free_list #(.NUM_PHYS_REGS(NUM_PHYS_REGS), .TAG_WIDTH(6))
    free_list_inst (.clk(clk), .rst_n(rst_n),
        .alloc_req(dispatch_valid), .alloc_phys(free_phys_reg),
        .alloc_valid(free_list_valid),
        .free_phys(rob_commit_dest_phys_reg), .free_en(rob_commit_valid));

    // ========================================================================
    // STAGE 3: DISPATCH
    // ========================================================================
    
    dispatch_stage #(.XLEN(XLEN), .INST_WIDTH(INST_WIDTH), .NUM_INT_REGS(NUM_INT_REGS))
    dispatch_inst (.clk(clk), .rst_n(rst_n), .stall(stall_dispatch), .flush(flush_pipeline),
        .instr_in(decode_instr), .instr_type(decode_instr_type), .pc_in(decode_pc), .valid_in(decode_valid),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rs1_value(rs1_value), .rs2_value(rs2_value),
        .src1_value(dispatch_src1), .src2_value(dispatch_src2),
        .immediate(dispatch_imm), .dest_reg(dispatch_dest_reg),
        .alu_op(dispatch_alu_op), .valid_out(dispatch_valid),
        .rs_type(dispatch_rs_type), .rs_alloc_valid(dispatch_rs_alloc),
        .rob_alloc_valid(dispatch_rob_alloc), .lsq_alloc_valid(dispatch_lsq_alloc)
    );

    // ========================================================================
    // RESERVATION STATIONS (All 5 types - routed to execute_stage)
    // ========================================================================
    
    // ALU RS
    reservation_station #(.RS_SIZE(ALU_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(6))
    alu_rs_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .src1_value(dispatch_src1), .src1_tag(rat_src1_phys), .src1_valid(1'b1),
        .src2_value(dispatch_src2), .src2_tag(rat_src2_phys), .src2_valid(1'b1),
        .immediate(dispatch_imm), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_rs_alloc && (dispatch_rs_type == `RS_TYPE_ALU)),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid),
        .operand1(alu_op1), .operand2(alu_op2), .execute_op(alu_operation),
        .execute_valid(alu_valid), .rs_full(alu_rs_full), .assigned_tag(alu_tag));
    
    // MEM RS
    reservation_station #(.RS_SIZE(MEM_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(6))
    mem_rs_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .src1_value(dispatch_src1), .src1_tag(rat_src1_phys), .src1_valid(1'b1),
        .src2_value(dispatch_src2), .src2_tag(rat_src2_phys), .src2_valid(1'b1),
        .immediate(dispatch_imm), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_rs_alloc && (dispatch_rs_type == `RS_TYPE_MEM)),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid),
        .operand1(mem_op1), .operand2(mem_op2), .execute_op(mem_operation),
        .execute_valid(mem_valid), .rs_full(mem_rs_full), .assigned_tag(mem_tag));
    
    // MUL RS
    reservation_station #(.RS_SIZE(MUL_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(6))
    mul_rs_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .src1_value(dispatch_src1), .src1_tag(rat_src1_phys), .src1_valid(1'b1),
        .src2_value(dispatch_src2), .src2_tag(rat_src2_phys), .src2_valid(1'b1),
        .immediate(dispatch_imm), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_rs_alloc && (dispatch_rs_type == `RS_TYPE_MUL)),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid),
        .operand1(mul_op1), .operand2(mul_op2), .execute_op(),
        .execute_valid(mul_valid), .rs_full(mul_rs_full), .assigned_tag(mul_tag));
    
    // DIV RS
    reservation_station #(.RS_SIZE(DIV_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(6))
    div_rs_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .src1_value(dispatch_src1), .src1_tag(rat_src1_phys), .src1_valid(1'b1),
        .src2_value(dispatch_src2), .src2_tag(rat_src2_phys), .src2_valid(1'b1),
        .immediate(dispatch_imm), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_rs_alloc && (dispatch_rs_type == `RS_TYPE_DIV)),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid),
        .operand1(div_op1), .operand2(div_op2), .execute_op(),
        .execute_valid(div_valid), .rs_full(div_rs_full), .assigned_tag(div_tag));
    
    // VEC RS
    reservation_station #(.RS_SIZE(VEC_RS_SIZE), .XLEN(XLEN), .RS_TAG_WIDTH(6))
    vec_rs_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .src1_value(dispatch_src1), .src1_tag(rat_src1_phys), .src1_valid(1'b1),
        .src2_value(dispatch_src2), .src2_tag(rat_src2_phys), .src2_valid(1'b1),
        .immediate(dispatch_imm), .alu_op(dispatch_alu_op),
        .dispatch_valid(dispatch_rs_alloc && (dispatch_rs_type == `RS_TYPE_VEC)),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid),
        .operand1(vec_op1[XLEN-1:0]), .operand2(vec_op2[XLEN-1:0]), .execute_op(vec_operation),
        .execute_valid(vec_valid), .rs_full(vec_rs_full), .assigned_tag(vec_tag));

    // ========================================================================
    // REORDER BUFFER (Tracking only, NOT data storage!)
    // ========================================================================
    
    reorder_buffer #(.ROB_SIZE(ROB_SIZE), .XLEN(XLEN))
    rob_inst (.clk(clk), .rst_n(rst_n), .flush(flush_pipeline),
        .alloc_instr_type(decode_instr_type), .alloc_dest_reg(dispatch_dest_reg),
        .alloc_phys_reg(rat_dst_phys),  // NEW: Track physical reg destination
        .alloc_valid(dispatch_rob_alloc), .alloc_tag(), .rob_full(rob_full),
        .result_data(cdb_result), .result_tag(cdb_tag), .result_valid(cdb_valid),
        .commit_valid(rob_commit_valid), .commit_instr_type(rob_commit_instr_type),
        .commit_dest_arch(rob_commit_dest_arch_reg),
        .commit_dest_phys(rob_commit_dest_phys_reg),  // NEW: Get phys reg
        .reg_write_en());

    // ========================================================================
    // STAGE 4: EXECUTE (Encapsulated FUs)
    // ========================================================================
    
    execute_stage #(.XLEN(XLEN), .VLEN(VLEN), .NUM_ALU_FUS(1), .NUM_MUL_FUS(1), .NUM_DIV_FUS(1),
        .MUL_LATENCY(MUL_LATENCY), .DIV_LATENCY(DIV_LATENCY))
    execute_inst (.clk(clk), .rst_n(rst_n),
        .alu_op1(alu_op1), .alu_op2(alu_op2), .alu_operation(alu_operation),
        .alu_valid(alu_valid), .alu_tag(alu_tag),
        .mem_op1(mem_op1), .mem_op2(mem_op2), .mem_operation(mem_operation),
        .mem_valid(mem_valid), .mem_tag(mem_tag),
        .mul_op1(mul_op1), .mul_op2(mul_op2), .mul_valid(mul_valid), .mul_tag(mul_tag),
        .div_op1(div_op1), .div_op2(div_op2), .div_valid(div_valid), .div_tag(div_tag),
        .vec_op1(vec_op1), .vec_op2(vec_op2), .vec_operation(vec_operation),
        .vec_valid(vec_valid), .vec_tag(vec_tag),
        .dmem_addr(dmem_addr), .dmem_write_data(dmem_write_data), .dmem_we(dmem_we),
        .dmem_be(dmem_be), .dmem_read_data(dmem_read_data), .dmem_valid(dmem_valid),
        .cdb_result(cdb_result), .cdb_tag(cdb_tag), .cdb_valid(cdb_valid));

    // ========================================================================
    // STAGE 5: WRITEBACK (Inside execute_stage)
    // ========================================================================
    // Results broadcast on CDB with PHYSICAL register tags

    // ========================================================================
    // STAGE 6: COMMIT
    // ========================================================================
    
    commit_stage #(.XLEN(XLEN), .NUM_INT_REGS(NUM_INT_REGS))
    commit_inst (.clk(clk), .rst_n(rst_n),
        .rob_result({{(XLEN){1'b0}}}),  // Result comes from physical_regfile, not ROB!
        .rob_dest_reg(rob_commit_dest_arch_reg),
        .rob_valid(rob_commit_valid), .rob_instr_type(rob_commit_instr_type),
        .reg_write_addr(reg_write_addr), .reg_write_data(reg_write_data),
        .reg_write_en(reg_write_en), .debug_reg_file());

    // ========================================================================
    // SUPPORT MODULES
    // ========================================================================
    
    hazard_detection hazard_inst (.clk(clk), .rst_n(rst_n),
        .rs_full(alu_rs_full || mem_rs_full || mul_rs_full || div_rs_full || vec_rs_full),
        .rob_full(rob_full), .lsq_full(lsq_lq_full || lsq_sq_full),
        .load_blocked(1'b0), .store_blocked(1'b0),
        .stall_fetch(stall_fetch), .stall_decode(stall_decode), .stall_dispatch(stall_dispatch));
    
    main_controller controller_inst (.clk(clk), .rst_n(rst_n),
        .rs_full(alu_rs_full || mem_rs_full || mul_rs_full || div_rs_full || vec_rs_full),
        .rob_full(rob_full), .lsq_full(lsq_lq_full || lsq_sq_full),
        .branch_mispredict(branch_mispredict),
        .stall_fetch(stall_fetch), .stall_decode(stall_decode), .stall_dispatch(stall_dispatch),
        .flush_pipeline(flush_pipeline), .pipeline_mode());
    
    branch_predictor branch_pred_inst (.clk(clk), .rst_n(rst_n), .pc(fetch_pc),
        .predicted_target(branch_target), .actual_target(32'h0),
        .is_branch(decode_instr_type == `IBASE_BRANCH), .branch_taken(1'b0),
        .branch_mispredict(branch_mispredict));
    
    exception_handler exc_handler (.clk(clk), .rst_n(rst_n), .ext_irq(ext_irq),
        .illegal_instr(1'b0), .instr_misalign(1'b0), .load_misalign(1'b0), .store_misalign(1'b0),
        .flush_pipeline(), .exception_code(exception_code), .exception_valid(exception_valid));
    
    // LSQ stubs
    assign lsq_lq_full = 1'b0;
    assign lsq_sq_full = 1'b0;
    
    // Vector operand extension (since RS is 32-bit but VEU is 128-bit)
    assign vec_op1[VLEN-1:XLEN] = '0;
    assign vec_op2[VLEN-1:XLEN] = '0;

endmodule
