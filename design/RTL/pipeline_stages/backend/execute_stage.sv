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
    parameter NUM_ALU_FUS = 1,        // Number of ALU instances
    parameter NUM_MUL_FUS = 1,        // Number of multiplier instances
    parameter NUM_DIV_FUS = 1,        // Number of divider instances
    parameter MUL_LATENCY = 4,
    parameter DIV_LATENCY = 6
) (
    input clk,
    input rst_n,
    
    // From reservation stations (ALU, MEM, MUL, DIV, VEC)
    input [XLEN-1:0] alu_op1, alu_op2,
    input [3:0] alu_operation,
    input alu_valid,
    input [3:0] alu_tag,
    
    input [XLEN-1:0] mem_op1, mem_op2,
    input [3:0] mem_operation,
    input mem_valid,
    input [3:0] mem_tag,
    
    input [XLEN-1:0] mul_op1, mul_op2,
    input mul_valid,
    input [3:0] mul_tag,
    
    input [XLEN-1:0] div_op1, div_op2,
    input div_valid,
    input [3:0] div_tag,
    
    input [VLEN-1:0] vec_op1, vec_op2,
    input [3:0] vec_operation,
    input vec_valid,
    input [3:0] vec_tag,
    
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
    output [3:0] dmem_be,
    
    // Commit Signal for Store
    input commit_store,
    
    // Common Data Bus Output (ONE result per cycle via CDB arbitration)
    output [XLEN-1:0] cdb_result,
    output [7:0] cdb_tag,
    output cdb_valid
);

    // ========================================================================
    // Internal Signals: FU Outputs (Multiple per type)
    // ========================================================================
    
    // ALU FU outputs (can have multiple ALUs)
    logic [XLEN-1:0] alu_results [NUM_ALU_FUS-1:0];
    logic [3:0] alu_tags [NUM_ALU_FUS-1:0];
    logic alu_valids [NUM_ALU_FUS-1:0];
    
    // MUL FU outputs (can have multiple multipliers)
    logic [XLEN-1:0] mul_results [NUM_MUL_FUS-1:0];
    logic [3:0] mul_tags [NUM_MUL_FUS-1:0];
    logic mul_valids [NUM_MUL_FUS-1:0];
    
    // DIV FU outputs (can have multiple dividers)
    logic [XLEN-1:0] div_results [NUM_DIV_FUS-1:0];
    logic [3:0] div_tags [NUM_DIV_FUS-1:0];
    logic div_valids [NUM_DIV_FUS-1:0];
    
    // LSU output
    logic [XLEN-1:0] lsu_result;
    logic [3:0] lsu_tag;
    logic lsu_valid;
    
    // VEU output
    logic [XLEN-1:0] vec_result;
    logic [3:0] vec_result_tag;
    logic vec_result_valid;

    // ========================================================================
    // Generate Multiple ALU Instances (Flexible)
    // ========================================================================
    
    genvar i;
    generate
        for (i = 0; i < NUM_ALU_FUS; i = i + 1) begin : gen_alus
            alu #(.XLEN(XLEN)) alu_inst (
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
    assign agu_addr = mem_op1 + mem_op2;

    // Decode Load/Store (Assuming bit 0 differentiates if ALU_ADD is ambiguous, 
    // or relying on valid bits from Dispatch if implemented. 
    // Here we use a placeholder check; in real design Dispatch should send distinct ops)
    logic is_store, is_load;
    assign is_store = (mem_operation == 4'b0001); // Example placeholder encoding
    assign is_load  = (mem_operation == 4'b0000); // Example placeholder encoding
    
    // Mask store address to prevent spurious WAR hazards in LSQ
    logic [XLEN-1:0] lsq_store_addr;
    assign lsq_store_addr = (mem_valid && is_store) ? agu_addr : {XLEN{1'b0}};

    load_store_queue #(.LSQ_LQ_SIZE(8), .LSQ_SQ_SIZE(8), .XLEN(XLEN)) lsq_inst (
        .clk(clk),
        .rst_n(rst_n),
        .flush(1'b0), // Flush not connected in this context, needs top-level signal
        
        // Load interface
        .load_addr(agu_addr),
        .load_tag(mem_tag),
        .load_valid(mem_valid && is_load),
        .load_data(lsu_result),
        .load_tag_out(lsu_tag),
        .load_data_valid(lsu_valid),
        .load_blocked(), // Connected to hazard detection via top
        
        // Store interface
        .store_addr(lsq_store_addr), // Zeroed if not storing
        .store_data(mem_op2),        // Store data usually in op2 or needs separate path? 
                                     // Assuming RS put store data in op2 for STORE ops
        .store_valid(mem_valid && is_store),
        .commit_store(commit_store), // Retire store
        .store_blocked(),            // Connected to hazard detection via top
        
        // Memory interface
        .dmem_read_addr(dmem_read_addr),
        .dmem_read_en(dmem_read_en),
        .dmem_read_data(dmem_read_data),
        .dmem_read_valid(dmem_read_valid),
        
        .dmem_write_addr(dmem_write_addr),
        .dmem_write_data(dmem_write_data),
        .dmem_write_en(dmem_write_en),
        
        .flush_pipeline(), // Not connected yet
        
        // Status
        .lsq_lq_full(),
        .lsq_sq_full()
    );
    
    assign dmem_be = 4'b1111; // Default to full word for now

    // ========================================================================
    // Vector Execution Unit (Single)
    // ========================================================================
    
    vector_execution_unit #(
        .VLEN(VLEN),
        .VLMAX(16),
        .ELEN(32),
        .NUM_VEC_LANES(4)
    ) veu_inst (
        .clk(clk),
        .rst_n(rst_n),
        .vl(32'd16),
        .vtype(32'h0),
        .vec_src1({{(VLEN-XLEN){1'b0}}, vec_op1}),
        .vec_src2({{(VLEN-XLEN){1'b0}}, vec_op2}),
        .vec_op(vec_operation),
        .vec_valid(vec_valid),
        .vec_result(vec_result),
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
    // CDB ARBITRATION (Priority Encoder Inside Execute Stage)
    // ========================================================================
    // Priority: ALU > LSU > MUL > DIV > VEU
    
    logic [XLEN-1:0] alu_result_selected;
    logic [3:0] alu_tag_selected;
    logic alu_result_valid;
    
    // Select from any ALU that has valid result
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
    
    // CDB Arbitration with priority
    always @(*) begin
        cdb_valid = 1'b0;
        cdb_result = 0;
        cdb_tag = 0;
        
        // Priority 1: ALU
        if (alu_result_valid) begin
            cdb_valid = 1'b1;
            cdb_result = alu_result_selected;
            cdb_tag = {4'b0, alu_tag_selected};
        end
        // Priority 2: LSU
        else if (lsu_valid) begin
            cdb_valid = 1'b1;
            cdb_result = lsu_result;
            cdb_tag = {4'b0, lsu_tag};
        end
        // Priority 3: MUL
        else begin
            for (int j = 0; j < NUM_MUL_FUS; j = j + 1) begin
                if (mul_valids[j]) begin
                    cdb_valid = 1'b1;
                    cdb_result = mul_results[j];
                    cdb_tag = {4'b0, mul_tags[j]};
                    break;
                end
            end
        end
        
        // Priority 4: DIV
        if (!cdb_valid) begin
            for (int j = 0; j < NUM_DIV_FUS; j = j + 1) begin
                if (div_valids[j]) begin
                    cdb_valid = 1'b1;
                    cdb_result = div_results[j];
                    cdb_tag = {4'b0, div_tags[j]};
                    break;
                end
            end
        end
        
        // Priority 5: VEU
        if (!cdb_valid && vec_result_valid) begin
            cdb_valid = 1'b1;
            cdb_result = vec_result[XLEN-1:0];
            cdb_tag = {4'b0, vec_result_tag};
        end
    end

endmodule

// ============================================================================
// BENEFITS OF THIS ENCAPSULATION
// ============================================================================
//
// 1. MODULARITY:
//    - To add 2nd ALU: Just change NUM_ALU_FUS = 2
//    - No changes to top module
//    - CDB arbitration automatically handles multiple sources
//
// 2. READABILITY:
//    - Top module sees only one interface: execute_stage
//    - No mess of individual FU signals in top
//    - Data flow clear: RS → execute_stage → CDB
//
// 3. SCALABILITY:
//    - NUM_ALU_FUS, NUM_MUL_FUS, NUM_DIV_FUS parameterized
//    - Add FUs by just changing parameters
//    - Generate blocks handle all instances automatically
//
// 4. MAINTAINABILITY:
//    - All FU logic in one place
//    - CDB arbitration centralized
//    - Easy to debug execution pipeline
//
// ============================================================================
