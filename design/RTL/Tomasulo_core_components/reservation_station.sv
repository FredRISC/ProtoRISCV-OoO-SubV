// ============================================================================
// reservation_station.sv - Generic Reservation Station
// ============================================================================
// Implements a single reservation station for the Tomasulo algorithm.
// Holds instructions waiting for operands and executes when ready.
// Critical Path: Priority encoder selecting ready entry -> issue_scheduler grant -> execute_valid assertion

`include "../riscv_header.sv"

module reservation_station #(
    parameter RS_SIZE = 8,
    parameter XLEN = 32,
    parameter RS_TAG_WIDTH = 6
) (
    input clk,
    input rst_n,
    input flush,
    
    // Dispatch interface
    input [RS_TAG_WIDTH-1:0] src1_tag, // tag from RAT
    input src1_valid,
    input [RS_TAG_WIDTH-1:0] src2_tag,
    input src2_valid,
    input use_rs1_in,
    input use_rs2_in,
    input use_pc_in,
    input [RS_TAG_WIDTH-1:0] vl_tag_in,
    input vl_valid_in,
    input use_vl_in,
    input [XLEN-1:0] imm_data, // Constant payload
    input [XLEN-1:0] vtype_data, // For vector instructions
    input [XLEN-1:0] pc_data,  // Constant payload
    input [3:0] alu_op,
    input dispatch_valid,
    input [RS_TAG_WIDTH-1:0] dest_tag_in, // Tag assigned to the instruction; used for CDB broadcast
    input [LSQ_TAG_WIDTH-1:0] lsq_tag_in, // Tag for LSQ entry (if load/store)
    
    // CDB 0 Broadcast Interface (Tags Only!)
    input [RS_TAG_WIDTH-1:0] cdb0_tag,
    input cdb0_valid,
    
    // CDB 1 Broadcast Interface (Tags Only!)
    input [RS_TAG_WIDTH-1:0] cdb1_tag,
    input cdb1_valid,
    
    // Predictive Issue Scheduling Interface
    output logic issue_req,
    input logic issue_grant,
    
    // RegRead interface (Outputs tags & constants, NOT data)
    output [RS_TAG_WIDTH-1:0] issue_src1_tag,
    output [RS_TAG_WIDTH-1:0] issue_src2_tag,
    output logic issue_use_rs1,
    output logic issue_use_rs2,
    output logic issue_use_pc,
    output logic issue_use_vl,
    output [RS_TAG_WIDTH-1:0] issue_vl_tag,
    output [XLEN-1:0] issue_imm,
    output [XLEN-1:0] issue_vtype,
    output [XLEN-1:0] issue_pc,
    output [3:0] execute_op,
    output [LSQ_TAG_WIDTH-1:0] execute_lsq_tag,
    output execute_valid,
    
    // Status
    output rs_full,
    output [RS_TAG_WIDTH-1:0] assigned_tag
);

    // ========================================================================
    // Reservation Station Entry Structure
    // ========================================================================
    
    typedef struct packed {
        logic [RS_TAG_WIDTH-1:0] src1_tag_val;
        logic [RS_TAG_WIDTH-1:0] src2_tag_val;
        logic src1_ready;
        logic src2_ready;
        logic [RS_TAG_WIDTH-1:0] vl_tag_val;
        logic vl_ready;
        logic use_vl;
        logic [RS_TAG_WIDTH-1:0] dest_tag;
        logic [3:0] alu_op_val;
        logic [LSQ_TAG_WIDTH-1:0] lsq_tag;
        logic [XLEN-1:0] imm_data;
        logic [XLEN-1:0] vtype_data;
        logic [XLEN-1:0] pc_data;
        logic use_rs1;
        logic use_rs2;
        logic use_pc;
        logic busy;
    } rs_entry_t;
    
    rs_entry_t [RS_SIZE-1:0] rs_entries;
    logic [RS_SIZE-1:0] entry_ready;
    
    // Free list management
    logic [$clog2(RS_SIZE)-1:0] alloc_idx;
    logic allocatable;
    logic [$clog2(RS_SIZE)-1:0] issue_idx;
    
    // CDB Tag Buffers
    reg [RS_TAG_WIDTH-1:0] cdb0_tag_buf;
    reg cdb0_val_buf;
    
    reg [RS_TAG_WIDTH-1:0] cdb1_tag_buf;
    reg cdb1_val_buf;

    // ========================================================================
    // Entry Allocation
    // ========================================================================
    
    // Priority encoder to find first free entry
    always @(*) begin
        alloc_idx = 0;
        allocatable = 1'b0;
        for (int i = 0; i < RS_SIZE; i++) begin
            if (!rs_entries[i].busy) begin
                alloc_idx = i[$clog2(RS_SIZE)-1:0];
                allocatable = 1'b1;
                break;
            end
        end
    end
    
    assign rs_full = !allocatable;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            for (int i = 0; i < RS_SIZE; i++) begin
                rs_entries[i].busy <= 1'b0;
                rs_entries[i].src1_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].src2_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].src1_ready <= 1'b0;
                rs_entries[i].src2_ready <= 1'b0;
                rs_entries[i].dest_tag <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].alu_op_val <= 4'b0;
                rs_entries[i].lsq_tag <= {LSQ_TAG_WIDTH{1'b0}};
                rs_entries[i].imm_data <= {XLEN{1'b0}};
                rs_entries[i].vtype_data <= {XLEN{1'b0}};
                rs_entries[i].pc_data <= {XLEN{1'b0}};
                rs_entries[i].use_rs1 <= 1'b0;
                rs_entries[i].use_rs2 <= 1'b0;
                rs_entries[i].use_pc <= 1'b0;
                rs_entries[i].use_vl <= 1'b0;
                rs_entries[i].vl_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].vl_ready <= 1'b0;
            end
            cdb0_tag_buf <= {RS_TAG_WIDTH{1'b0}};
            cdb0_val_buf <= 1'b0;
            cdb1_tag_buf <= {RS_TAG_WIDTH{1'b0}};
            cdb1_val_buf <= 1'b0;
        end 
        else begin
            // 1. Buffer CDB tag (capture transient signal) 
            cdb0_tag_buf <= cdb0_tag;
            cdb0_val_buf <= cdb0_valid;
            cdb1_tag_buf <= cdb1_tag;
            cdb1_val_buf <= cdb1_valid;

            // 2. Dispatch - Allocate new entry
            if (dispatch_valid && !rs_full) begin // Cycle N
                // Set constant fields
                rs_entries[alloc_idx].alu_op_val <= alu_op;
                rs_entries[alloc_idx].dest_tag <= dest_tag_in;
                rs_entries[alloc_idx].busy <= 1'b1;
                rs_entries[alloc_idx].lsq_tag <= lsq_tag_in;
                rs_entries[alloc_idx].imm_data <= imm_data;
                rs_entries[alloc_idx].vtype_data <= vtype_data;
                rs_entries[alloc_idx].pc_data <= pc_data;
                rs_entries[alloc_idx].use_rs1 <= use_rs1_in;
                rs_entries[alloc_idx].use_rs2 <= use_rs2_in;
                rs_entries[alloc_idx].use_pc <= use_pc_in;

                // Handle Src1
                rs_entries[alloc_idx].src1_tag_val <= src1_tag;
                rs_entries[alloc_idx].src1_ready <= src1_valid | !use_rs1_in;

                // Handle Src2
                rs_entries[alloc_idx].src2_tag_val <= src2_tag;
                rs_entries[alloc_idx].src2_ready <= src2_valid | !use_rs2_in;
                
                // Handle VL
                rs_entries[alloc_idx].vl_tag_val <= vl_tag_in;
                rs_entries[alloc_idx].vl_ready <= vl_valid_in | !use_vl_in;
                rs_entries[alloc_idx].use_vl <= use_vl_in;
            end

            // 3. Update waiting entries using buffered CDB tags
            for (int i = 0; i < RS_SIZE; i++) begin // Cycle N+1
                if (rs_entries[i].busy) begin
                    // Check CDB 0
                    if (cdb0_val_buf && !rs_entries[i].src1_ready && rs_entries[i].src1_tag_val == cdb0_tag_buf) begin
                        rs_entries[i].src1_ready <= 1'b1;
                    end
                    if (cdb0_val_buf && !rs_entries[i].src2_ready && rs_entries[i].src2_tag_val == cdb0_tag_buf) begin
                        rs_entries[i].src2_ready <= 1'b1;
                    end
                    if (cdb0_val_buf && !rs_entries[i].vl_ready && rs_entries[i].vl_tag_val == cdb0_tag_buf) begin
                        rs_entries[i].vl_ready <= 1'b1;
                    end
                    
                    // Check CDB 1
                    if (cdb1_val_buf && !rs_entries[i].src1_ready && rs_entries[i].src1_tag_val == cdb1_tag_buf) begin
                        rs_entries[i].src1_ready <= 1'b1;
                    end
                    if (cdb1_val_buf && !rs_entries[i].src2_ready && rs_entries[i].src2_tag_val == cdb1_tag_buf) begin
                        rs_entries[i].src2_ready <= 1'b1;
                    end
                end
            end

            // 4. Issued - Free issued entry on next cycle
            if (execute_valid) begin
                rs_entries[issue_idx].busy <= 1'b0;
                rs_entries[issue_idx].src1_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[issue_idx].src2_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[issue_idx].src1_ready <= 1'b0;
                rs_entries[issue_idx].src2_ready <= 1'b0;
                rs_entries[issue_idx].dest_tag <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[issue_idx].alu_op_val <= 4'b0;
                rs_entries[issue_idx].lsq_tag <= {LSQ_TAG_WIDTH{1'b0}};
                rs_entries[issue_idx].imm_data <= {XLEN{1'b0}};
                rs_entries[issue_idx].vtype_data <= {XLEN{1'b0}};
                rs_entries[issue_idx].pc_data <= {XLEN{1'b0}};
                rs_entries[issue_idx].use_rs1 <= 1'b0;
                rs_entries[issue_idx].use_rs2 <= 1'b0;
                rs_entries[issue_idx].use_pc <= 1'b0;
                rs_entries[issue_idx].use_vl <= 1'b0;
                rs_entries[issue_idx].vl_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[issue_idx].vl_ready <= 1'b0;
            end
        end
    end
    
    // ========================================================================
    // Ready Detection and Issue Selection
    // ========================================================================
    
    always @(*) begin
        for (int i = 0; i < RS_SIZE; i++) begin
            entry_ready[i] = rs_entries[i].busy && 
                           rs_entries[i].src1_ready && 
                           rs_entries[i].src2_ready &&
                           rs_entries[i].vl_ready; // vl is always ready for scalar instructions.
        end
    end
    
    // Priority encoder: select first ready entry
    always @(*) begin
        issue_idx = 0;
        for (int i = 0; i < RS_SIZE; i++) begin
            if (entry_ready[i]) begin
                issue_idx = i[$clog2(RS_SIZE)-1:0];
                break;
            end
        end
    end
    
    // ========================================================================
    // Execution Port
    // ========================================================================
    
    assign issue_req = (entry_ready != 0);
    assign execute_valid = issue_req && issue_grant;
    
    assign issue_src1_tag = rs_entries[issue_idx].src1_tag_val;
    assign issue_src2_tag = rs_entries[issue_idx].src2_tag_val;
    assign issue_use_rs1 = rs_entries[issue_idx].use_rs1;
    assign issue_use_rs2 = rs_entries[issue_idx].use_rs2;
    assign issue_use_pc  = rs_entries[issue_idx].use_pc;
    assign issue_use_vl  = rs_entries[issue_idx].use_vl;
    assign issue_vl_tag  = rs_entries[issue_idx].vl_tag_val;
    assign issue_imm = rs_entries[issue_idx].imm_data;
    assign issue_vtype = rs_entries[issue_idx].vtype_data;
    assign issue_pc = rs_entries[issue_idx].pc_data;
    assign execute_op = rs_entries[issue_idx].alu_op_val;
    assign execute_lsq_tag = rs_entries[issue_idx].lsq_tag;
    
    // ========================================================================
    // Destination tag for CDB broadcast
    // ========================================================================
    
    assign assigned_tag = rs_entries[issue_idx].dest_tag;

endmodule
