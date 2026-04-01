// ============================================================================
// vector_execution_unit.sv - Vector ALU with 4 Parallel Lanes
// ============================================================================
// RVV v1.0 subset: element-wise operations
// VLEN=128, 4 lanes of 32-bit elements
// Chaining will be enabled later (Pipelining)


`include "../riscv_header.sv"

module vector_execution_unit #(
    parameter VLEN = 128,
    parameter ELEN = 32,
    parameter NUM_VEC_LANES = 4
) (
    input clk,
    input rst_n,
    
    // Vector configuration (from VSETVLI)
    input [31:0] vl,  // Current vector length
    input [31:0] vtype,
    
    // Operand interface
    input [VLEN-1:0] vec_src1,
    input [VLEN-1:0] vec_src2,
    input [3:0] vec_op,
    input vec_valid,
    
    // Result interface
    output reg [VLEN-1:0] vec_result,
    output reg vec_result_valid,
    
    // Handshaking with Execute Stage
    input cdb_granted,      // VEU result was broadcast on CDB
    output logic vec_fu_ready // VEU is ready for a new instruction
);

    // Lane interface: 4 parallel 32-bit lanes
    logic [ELEN-1:0] lane_src1 [NUM_VEC_LANES-1:0];
    logic [ELEN-1:0] lane_src2 [NUM_VEC_LANES-1:0];
    logic [ELEN-1:0] lane_result [NUM_VEC_LANES-1:0];
    
    // Distribute operands across lanes        
    always @(*) begin
        for (i = 0; i < NUM_VEC_LANES; i++) begin
            lane_src1[i] = vec_src1[i*ELEN +: ELEN];
            lane_src2[i] = vec_src2[i*ELEN +: ELEN];
        end
    end

    
    // ========================================================================
    // Lane Execution Units (element-wise operations)
    // ========================================================================
    logic lane_valid [NUM_VEC_LANES-1:0];
    generate
        for (i = 0; i < NUM_VEC_LANES; i++) begin : gen_lanes
            vector_lane #(
                .ELEN(ELEN)
            ) lane (
                .clk(clk),
                .rst_n(rst_n),
                .operand1(lane_src1[i]),
                .operand2(lane_src2[i]),
                .vec_op(vec_op),
                .valid_in(vec_valid),
                .result(lane_result[i]),
                .valid_out(lane_valid[i])
            );
        end
    endgenerate
    
    // ========================================================================
    // Combine lane results
    // ========================================================================
    
    // Combinational logic to assemble the full result from lanes
    logic [DLEN-1:0] lane_results_comb;
    always @(*) begin
        for (int j = 0; j < NUM_VEC_LANES; j++) begin
            lane_results_comb[j*ELEN +: ELEN] = lane_result[j];
        end
    end

    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vec_result_valid <= 1'b0;
        end 
        else if (lane_valid[0]) begin // SIMPLIFIED FOR NOW
            vec_result <= lane_results_comb;
            vec_result_valid <= 1'b1;
        end else begin
            vec_result_valid <= 1'b0;
        end
    end

endmodule
