// ============================================================================
// reservation_station.sv - Generic Reservation Station
// ============================================================================
// Implements a single reservation station for the Tomasulo algorithm.
// Holds instructions waiting for operands and executes when ready.

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
    input [XLEN-1:0] src1_value,
    input [RS_TAG_WIDTH-1:0] src1_tag, // tag from RAT
    input src1_valid,
    input [XLEN-1:0] src2_value,
    input [RS_TAG_WIDTH-1:0] src2_tag,
    input src2_valid,
    input [3:0] alu_op,
    input dispatch_valid,
    input [RS_TAG_WIDTH-1:0] dest_tag_in, // Tag assigned to the instruction; used for CDB broadcast
    
    // CDB broadcast interface
    input [XLEN-1:0] cdb_result,
    input [RS_TAG_WIDTH-1:0] cdb_tag,
    input cdb_valid,
    
    // Execute interface
    output [XLEN-1:0] operand1,
    output [XLEN-1:0] operand2,
    output [3:0] execute_op,
    output execute_valid,
    
    // Status
    output rs_full,
    output [RS_TAG_WIDTH-1:0] assigned_tag
);

    // ========================================================================
    // Reservation Station Entry Structure
    // ========================================================================
    
    typedef struct packed {
        logic [XLEN-1:0] src1_val;
        logic [XLEN-1:0] src2_val;
        logic [RS_TAG_WIDTH-1:0] src1_tag_val;
        logic [RS_TAG_WIDTH-1:0] src2_tag_val;
        logic src1_ready;
        logic src2_ready;
        logic [RS_TAG_WIDTH-1:0] dest_tag;
        logic [3:0] alu_op_val;
        logic busy;
    } rs_entry_t;
    
    rs_entry_t [RS_SIZE-1:0] rs_entries;
    logic [RS_SIZE-1:0] entry_ready;
    
    // Free list management
    logic [$clog2(RS_SIZE)-1:0] alloc_idx;
    logic allocatable;
    logic [$clog2(RS_SIZE)-1:0] issue_idx;
    
    // CDB Buffer to avoid race conditions and missing broadcasts
    reg [XLEN-1:0] cdb_res_buf;
    reg [RS_TAG_WIDTH-1:0] cdb_tag_buf;
    reg cdb_val_buf;

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
        if (!rst_n) begin
            for (int i = 0; i < RS_SIZE; i++) begin
                rs_entries[i].busy <= 1'b0;
                rs_entries[i].src1_val <= {XLEN{1'b0}};
                rs_entries[i].src2_val <= {XLEN{1'b0}};
                rs_entries[i].src1_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].src2_tag_val <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].src1_ready <= 1'b0;
                rs_entries[i].src2_ready <= 1'b0;
                rs_entries[i].dest_tag <= {RS_TAG_WIDTH{1'b0}};
                rs_entries[i].alu_op_val <= 4'b0;
            end
            cdb_res_buf <= {XLEN{1'b0}};
            cdb_tag_buf <= {RS_TAG_WIDTH{1'b0}};
            cdb_val_buf <= 1'b0;
        end else if (flush) begin
            for (int i = 0; i < RS_SIZE; i++) begin
                rs_entries[i].busy <= 1'b0;
            end
            cdb_val_buf <= 1'b0;
        end else begin
            // 1. Buffer CDB result (capture transient signal) 
            cdb_res_buf <= cdb_result; // Cycle N
            cdb_tag_buf <= cdb_tag; // Cycle N
            cdb_val_buf <= cdb_valid; // Cycle N

            // 2. Update waiting entries using BUFFERED CDB result; 
            if (cdb_val_buf) begin // Cycle N+1
                for (int i = 0; i < RS_SIZE; i++) begin
                    if (rs_entries[i].busy) begin
                        if (!rs_entries[i].src1_ready && rs_entries[i].src1_tag_val == cdb_tag_buf) begin
                            rs_entries[i].src1_val <= cdb_res_buf;
                            rs_entries[i].src1_ready <= 1'b1;
                        end
                        if (!rs_entries[i].src2_ready && rs_entries[i].src2_tag_val == cdb_tag_buf) begin
                            rs_entries[i].src2_val <= cdb_res_buf;
                            rs_entries[i].src2_ready <= 1'b1;
                        end
                    end
                end
            end

            // 3. Dispatch - Allocate new entry
            if (dispatch_valid && !rs_full) begin // Cycle N
                // Set constant fields
                rs_entries[alloc_idx].alu_op_val <= alu_op;
                rs_entries[alloc_idx].dest_tag <= dest_tag_in;
                rs_entries[alloc_idx].busy <= 1'b1;

                // Handle Src1
                if (src1_valid) begin
                    rs_entries[alloc_idx].src1_val <= src1_value;
                    rs_entries[alloc_idx].src1_ready <= 1'b1;
                end else begin
                    rs_entries[alloc_idx].src1_tag_val <= src1_tag;
                    rs_entries[alloc_idx].src1_ready <= 1'b0;
                end

                // Handle Src2
                if (src2_valid) begin
                    rs_entries[alloc_idx].src2_val <= src2_value;
                    rs_entries[alloc_idx].src2_ready <= 1'b1;
                end else begin
                    rs_entries[alloc_idx].src2_tag_val <= src2_tag;
                    rs_entries[alloc_idx].src2_ready <= 1'b0;
                end
            end

            // 4. Execution - Free issued entry
            if (execute_valid) begin
                rs_entries[issue_idx].busy <= 1'b0;
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
                           rs_entries[i].src2_ready;
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
    
    assign execute_valid = (entry_ready != 0);
    assign operand1 = rs_entries[issue_idx].src1_val;
    assign operand2 = rs_entries[issue_idx].src2_val;
    assign execute_op = rs_entries[issue_idx].alu_op_val;
    
    // ========================================================================
    // Status Signals
    // ========================================================================
    
    assign assigned_tag = rs_entries[issue_idx].dest_tag;

endmodule
