// ============================================================================
// issue_scheduler.sv - Predictive Issue Logic (Writeback Scheduling)
// ============================================================================
// Prevents CDB collisions by tracking the future availability of the CDB.
// Grants issue requests only if the CDB will be free when the FU finishes.

`include "../riscv_header.sv"

module issue_scheduler #(
    parameter MAX_LATENCY = 8,
    parameter ALU_LATENCY = 1,
    parameter MUL_LATENCY = 4,
    parameter DIV_LATENCY = 4
) (
    input clk,
    input rst_n,
    input flush,
    
    // Requests from Reservation Stations (ready to issue)
    input req_alu,
    input req_mul,
    input req_div,
    
    // Grants back to Reservation Stations (allowed to issue)
    output logic grant_alu,
    output logic grant_mul,
    output logic grant_div
);

    // The Calendar: Tracks reserved cycles on CDB0 (Scheduled Bus)
    // calendar[1] == 1 means the bus is reserved 1 cycle from now.
    logic [MAX_LATENCY:1] calendar;
    logic [MAX_LATENCY:1] calendar_nxt;
    
    always @(*) begin
        // Default: no grants
        grant_alu = 1'b0;
        grant_mul = 1'b0;
        grant_div = 1'b0;
        
        calendar_nxt = calendar;
        
        // Arbitration priority: ALU > MUL > DIV
        if (req_alu && !calendar_nxt[ALU_LATENCY]) begin
            grant_alu = 1'b1;
            calendar_nxt[ALU_LATENCY] = 1'b1; // Reserve the future cycle
        end
        if (req_mul && !calendar_nxt[MUL_LATENCY]) begin
            grant_mul = 1'b1;
            calendar_nxt[MUL_LATENCY] = 1'b1; // Reserve the future cycle
        end
        if (req_div && !calendar_nxt[DIV_LATENCY]) begin
            grant_div = 1'b1;
            calendar_nxt[DIV_LATENCY] = 1'b1; // Reserve the future cycle
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) calendar <= '0;
        else calendar <= {1'b0, calendar_nxt[MAX_LATENCY:2]}; // Shift time forward
    end

endmodule