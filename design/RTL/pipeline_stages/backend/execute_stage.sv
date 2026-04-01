// ============================================================================
// execute_stage.sv - REFACTORED: Encapsulates ALL Functional Units
// ============================================================================
// Improvements:
// - All FUs encapsulated (ALU, MUL, DIV, LSU, VEU)
// - Cleaner interface with top module
// - Easy to add/remove FUs without changing top module
// - CDB arbitration inside (not in top module)
// - Flexible number of FUs per type (parameterized)

`include "riscv_header.sv"

module execute_stage #(
    parameter XLEN = 32,
    parameter VLEN = 128,
    parameter DLEN = `DLEN,
    parameter NUM_ALU_FUS = 1,        // Number of ALU instances
    parameter NUM_MUL_FUS = 1,        // Number of multiplier instances
    parameter NUM_DIV_FUS = 1,        // Number of divider instances
    parameter MUL_LATENCY = 4,
    parameter DIV_LATENCY = 6,
    parameter LSQ_TAG_WIDTH = 3
) (
    input clk,
    input rst_n,
    input flush,
    
    // From reservation stations (ALU, MEM, MUL, DIV, VEC)
    input [XLEN-1:0] alu_op1, alu_op2, // Operand 1 (Register or PC or 0), Operand 2 (Register or Imm)
    input [3:0] alu_operation,
    input alu_valid,
    input [5:0] alu_tag,
    
    input [XLEN-1:0] mem_op1, // Base Address
    input [DLEN-1:0] mem_op2, // Store Data (Scalar or Vector)
    input [XLEN-1:0] mem_imm,
    input [3:0] mem_operation,
    input mem_valid,
    input [31:0] mem_vl,
    input [5:0] mem_tag,
    input [LSQ_TAG_WIDTH-1:0] mem_lsq_tag, // LSQ Entry Tag
    
    input [XLEN-1:0] mul_op1, mul_op2,
    input mul_valid,
    input [5:0] mul_tag,
    
    input [XLEN-1:0] div_op1, div_op2,
    input div_valid,
    input [5:0] div_tag,
    
    input [VLEN-1:0] vec_op1, vec_op2,
    input [3:0] vec_operation,
    input vec_valid,
    input [5:0] vec_tag,
    input [31:0] vec_vl,
    input [31:0] vec_vtype,
    
    // LSQ Tunneling (Dispatch <-> LSQ)
    input lsq_alloc_req,
    input lsq_alloc_is_store,
    input lsq_alloc_is_vector,
    input [31:0] lsq_alloc_vtype,
    input [2:0] lsq_alloc_size,
    input [5:0] alloc_phys_tag,
    output [LSQ_TAG_WIDTH-1:0] alloc_tag,
    output lsq_full,
    
    // Memory interface (from LSU)
    // Read Port
    output [XLEN-1:0] dmem_read_addr,
    output dmem_read_en,
    input [XLEN-1:0] dmem_read_data,
    input dmem_read_valid,
    
    // Write Port
    output [XLEN-1:0] dmem_write_addr,
    output [XLEN-1:0] dmem_write_data,
    output dmem_write_en,
    input dmem_write_ready,
    output [3:0] dmem_be,
    
    // Commit Signal for Store
    input commit_lsq,
    
    // Pipeline Flush Request from LSQ (Memory Disambiguation Violation)
    output lsq_flush,
    output [5:0] lsq_violation_tag,
    
    // CDB 0 Broadcast Interface (Scheduled - ALU/MUL/VEC)
    output logic [XLEN-1:0] cdb0_result,
    output logic [5:0] cdb0_tag,
    output logic cdb0_valid,
    
    // CDB 1 Broadcast Interface (Unscheduled - LSQ/DIV)
    output logic [XLEN-1:0] cdb1_result,
    output logic [5:0] cdb1_tag,
    output logic cdb1_valid,

    // Vector CDB 0 (Scheduled - VEU)
    output logic [DLEN-1:0] vec_cdb0_result,
    output logic [5:0] vec_cdb0_tag,
    output logic vec_cdb0_valid,
    
    // Vector CDB 1 (Unscheduled - LSQ)
    output logic [DLEN-1:0] vec_cdb1_result,
    output logic [5:0] vec_cdb1_tag,
    output logic vec_cdb1_valid
);

    // ========================================================================
    // Internal Signals: FU Outputs (Multiple per type)
    // ========================================================================
    
    // ALU FU outputs (can have multiple ALUs)
    logic [XLEN-1:0] alu_results [NUM_ALU_FUS-1:0];
    logic [5:0] alu_tags [NUM_ALU_FUS-1:0];
    logic alu_valids [NUM_ALU_FUS-1:0];
    
    // MUL FU outputs (can have multiple multipliers)
    logic [XLEN-1:0] mul_results [NUM_MUL_FUS-1:0];
    logic [5:0] mul_tags [NUM_MUL_FUS-1:0];
    logic mul_valids [NUM_MUL_FUS-1:0];
    
    // DIV FU outputs (can have multiple dividers)
    logic [XLEN-1:0] div_results [NUM_DIV_FUS-1:0];
    logic [5:0] div_tags [NUM_DIV_FUS-1:0];
    logic div_valids [NUM_DIV_FUS-1:0];
    
    // LSU output
    logic [XLEN-1:0] lsu_scalar_result;
    logic lsu_valid;
    logic [DLEN-1:0] lsu_vector_result;
    logic [5:0]      lsu_vector_tag;
    logic            lsu_vector_valid;
    
    // VEU output
    logic [DLEN-1:0] veu_result;
    logic [5:0] vec_result_tag;
    logic vec_result_valid;

    // ========================================================================
    // Generate Multiple ALU Instances (Flexible)
    // ========================================================================
    
    genvar i;
    generate
        for (i = 0; i < NUM_ALU_FUS; i = i + 1) begin : gen_alus
            alu #(.XLEN(XLEN), .VLEN(VLEN)) alu_inst (
                .clk(clk),
                .rst_n(rst_n),
                .operand1(alu_op1),
                .operand2(alu_op2),
                .alu_op(alu_operation),
                .valid_in(alu_valid),
                .result(alu_results[i]),
                .valid_out(alu_valids[i])
            );
            
            always @(posedge clk) begin
                if (alu_valids[i])
                    alu_tags[i] <= alu_tag;
            end
        end
    endgenerate

    // ========================================================================
    // Generate Multiple Multiplier Instances (Flexible)
    // ========================================================================
    
    generate
        for (i = 0; i < NUM_MUL_FUS; i = i + 1) begin : gen_muls
            multiplier #(
                .XLEN(XLEN),
                .MUL_LATENCY(MUL_LATENCY)
            ) mul_inst (
                .clk(clk),
                .rst_n(rst_n),
                .multiplicand(mul_op1),
                .multiplier(mul_op2),
                .valid_in(mul_valid),
                .mul_type(2'b00),
                .product_low(mul_results[i]),
                .product_high(),
                .valid_out(mul_valids[i])
            );
            
            always @(posedge clk) begin
                if (mul_valids[i])
                    mul_tags[i] <= mul_tag;
            end
        end
    endgenerate

    // ========================================================================
    // Generate Multiple Divider Instances (Flexible)
    // ========================================================================
    
    generate
        for (i = 0; i < NUM_DIV_FUS; i = i + 1) begin : gen_divs
            divider #(
                .XLEN(XLEN),
                .DIV_LATENCY(DIV_LATENCY)
            ) div_inst (
                .clk(clk),
                .rst_n(rst_n),
                .dividend(div_op1),
                .divisor(div_op2),
                .valid_in(div_valid),
                .div_type(2'b00),
                .quotient(div_results[i]),
                .remainder(),
                .valid_out(div_valids[i])
            );
            
            always @(posedge clk) begin
                if (div_valids[i])
                    div_tags[i] <= div_tag;
            end
        end
    endgenerate

    // ========================================================================
    // Load-Store Unit (Single)
    // ========================================================================
    
    // AGU (Address Generation Unit)
    logic [XLEN-1:0] agu_addr;
    assign agu_addr = mem_op1 + mem_imm;

    // Decode Load/Store (Assuming bit 0 differentiates if ALU_ADD is ambiguous, 
    // or relying on valid bits from Dispatch if implemented. 
    // Here we use a placeholder check; in real design Dispatch should send distinct ops)
    logic exe_is_store, exe_is_load;
    assign exe_is_store = (mem_operation == 4'b0001); // Defined in Dispatch
    assign exe_is_load  = (mem_operation == 4'b0000);
    
    logic [5:0] lsu_tag_extended;

    load_store_queue #(.LSQ_SIZE(16), .XLEN(XLEN), .DLEN(DLEN)) lsq_inst (
        .clk(clk),
        .rst_n(rst_n),
        .flush(flush), 
        
        // Dispatch Allocation Interface (handled in Top/Dispatch, wired separately)
        .alloc_req(lsq_alloc_req), 
        .alloc_is_store(lsq_alloc_is_store),
        .alloc_is_vector(lsq_alloc_is_vector),
        .alloc_vtype(lsq_alloc_vtype),
        .alloc_size(lsq_alloc_size),
        .dispatch_phys_tag(alloc_phys_tag),
        .alloc_tag(alloc_tag),
        .lsq_full(lsq_full),

        // Execute Interface
        .exe_addr(agu_addr),
        .exe_data(mem_op2[XLEN-1:0]), // TRUNCATED temporarily until VLSU is implemented
        .exe_lsq_tag(mem_lsq_tag),
        .exe_vl(mem_vl),
        .exe_load_valid(mem_valid && exe_is_load),
        .exe_store_valid(mem_valid && exe_is_store),
        
        // Result Interface
        // Scalar Port
        .cdb_phys_tag_out(lsu_tag_extended), 
        .lsq_data_out(lsu_scalar_result),
        .lsq_out_valid(lsu_valid),
        // Vector Port
        .vec_cdb_phys_tag_out(lsu_vector_tag),
        .vec_lsq_data_out(lsu_vector_result),
        .vec_lsq_out_valid(lsu_vector_valid),
        
        .commit_lsq(commit_lsq), // Retire load/store
        
        // Memory interface
        .dmem_read_addr(dmem_read_addr),
        .dmem_read_en(dmem_read_en),
        .dmem_read_data(dmem_read_data),
        .dmem_read_valid(dmem_read_valid),
        
        .dmem_write_addr(dmem_write_addr),
        .dmem_write_data(dmem_write_data),
        .dmem_write_en(dmem_write_en),
        .dmem_write_ready(dmem_write_ready),
        .dmem_be(dmem_be), // Let LSQ control byte enables
        
        .flush_pipeline(lsq_flush), // Connected to trigger pipeline flush
        .lsq_violation_tag(lsq_violation_tag),
        
        // Status
        .load_blocked(),
        .store_blocked()
    );
    
    // ========================================================================
    // Vector Execution Unit (Single)
    // ========================================================================
    
    vector_execution_unit #(
        .VLEN(`VLEN),
        .ELEN(`ELEN),
        .NUM_VEC_LANES(`NUM_VEC_LANES)
    ) veu_inst (
        .clk(clk),
        .rst_n(rst_n),
        .vl(vec_vl),
        .vtype(vec_vtype),
        .vec_src1(vec_op1),
        .vec_src2(vec_op2),
        .vec_op(vec_operation),
        .vec_valid(vec_valid),
        .vec_result(veu_result),
        .vec_result_valid(vec_result_valid),
        .vreg_rd_addr(5'b0),
        .vreg_rd_data(),
        .vreg_wr_addr(5'b0),
        .vreg_wr_data(0),
        .vreg_wr_en(1'b0)
    );
    
    always @(posedge clk) begin
        if (vec_result_valid)
            vec_result_tag <= vec_tag;
    end

    // ========================================================================
    // Result Selection From Each FU Type (Priority Encoding)
    // ========================================================================
   
    logic [XLEN-1:0] alu_result_selected;
    logic [5:0] alu_tag_selected;
    logic alu_result_valid;
    
    // ALU result selection
    always @(*) begin
        alu_result_valid = 1'b0;
        alu_result_selected = 0;
        alu_tag_selected = 0;
        
        for (int j = 0; j < NUM_ALU_FUS; j = j + 1) begin
            if (alu_valids[j]) begin
                alu_result_valid = 1'b1;
                alu_result_selected = alu_results[j];
                alu_tag_selected = alu_tags[j];
                break;
            end
        end
    end
    
    // MUL result selection
    logic [XLEN-1:0] mul_result_selected;
    logic [5:0] mul_tag_selected;
    logic mul_result_valid;
    
    always @(*) begin
        mul_result_valid = 1'b0;
        mul_result_selected = 0;
        mul_tag_selected = 0;
        for (int j = 0; j < NUM_MUL_FUS; j = j + 1) begin
            if (mul_valids[j]) begin
                mul_result_valid = 1'b1;
                mul_result_selected = mul_results[j];
                mul_tag_selected = mul_tags[j];
                break;
            end
        end
    end

    // DIV result selection
    logic [XLEN-1:0] div_result_selected;
    logic [5:0] div_tag_selected;
    logic div_result_valid;
    
    always @(*) begin
        div_result_valid = 1'b0;
        div_result_selected = 0;
        div_tag_selected = 0;
        for (int j = 0; j < NUM_DIV_FUS; j = j + 1) begin
            if (div_valids[j]) begin
                div_result_valid = 1'b1;
                div_result_selected = div_results[j];
                div_tag_selected = div_tags[j];
                break;
            end
        end
    end

    // ========================================================================
    // CDB 0: Scheduled Bus (ALU, MUL)
    // The issue_scheduler guarantees these will NEVER collide!
    // ========================================================================
    always @(*) begin
        cdb0_valid = 1'b0;
        cdb0_result = 0;
        cdb0_tag = 0;
        
        if (alu_result_valid) begin
            cdb0_valid = 1'b1;
            cdb0_result = alu_result_selected;
            cdb0_tag = alu_tag_selected;
        end else if (mul_result_valid) begin
            cdb0_valid = 1'b1;
            cdb0_result = mul_result_selected;
            cdb0_tag = mul_tag_selected;
        end
    end

    // ========================================================================
    // CDB 1: Unscheduled Bus (LSQ, DIV, VEU)
    // These operate outside the scheduler. LSQ gets priority.
    // (Known edge case: DIV drops data if LSQ hits on the same exact cycle).
    // ========================================================================
    always @(*) begin
        cdb1_valid = 1'b0;
        cdb1_result = 0;
        cdb1_tag = 0;
        
        if (lsu_valid) begin
            cdb1_valid = 1'b1;
            cdb1_result = lsu_scalar_result;
            cdb1_tag = lsu_tag_extended; 
        end else if (div_result_valid) begin
            cdb1_valid = 1'b1;
            cdb1_result = div_result_selected;
            cdb1_tag = div_tag_selected;
        end
    end

    // ========================================================================
    // Dedicated Vector CDBs
    // ========================================================================
    always @(*) begin
        vec_cdb0_valid = vec_result_valid;
        vec_cdb0_result = veu_result;
        vec_cdb0_tag = vec_result_tag;
        
        vec_cdb1_valid = lsu_vector_valid;
        vec_cdb1_result = lsu_vector_result;
        vec_cdb1_tag = lsu_vector_tag;
    end

endmodule
