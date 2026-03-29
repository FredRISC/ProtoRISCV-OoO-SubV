// ============================================================================
// vector_csr.sv - Vector Control and Status Registers
// ============================================================================
// Tracks vl (Vector Length) and vtype (Vector Type)
// Features speculative updating for dispatch dependencies and rollback on flush.

`include "../riscv_header.sv"

module vector_csr (
    input clk,
    input rst_n,
    input flush,
    
    // Dispatch interface (Speculative reads)
    output logic [31:0] spec_vtype,
    output logic [5:0] spec_vl_tag,
    
    // VSETVLI execution updates (Updates speculative state of vl and vtype early)
    // Called when vsetvli is decoded/dispatched
    input vtype_update_en,
    input [31:0] new_vtype,
    input [5:0] vsetvli_phys_tag,
    
    // Commit interface (Updates architectural state of vl and vtype)
    // Called when vsetvli reaches ROB head
    input commit_req,
    input [31:0] commit_vtype,
    input [5:0] commit_vl_tag
);

    // Architectural State
    logic [5:0] arch_vl_tag;
    logic [31:0] arch_vtype;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arch_vl_tag <= 6'h0;
            arch_vtype <= 32'h0;
            spec_vl_tag <= 6'h0;
            spec_vtype <= 32'h0;
        end else begin
            // on flush, roll back to architectural state
            if(flush) begin
                if(commit_req) begin
                    spec_vl_tag <= commit_vl_tag;
                    spec_vtype <= commit_vtype;
                end
                else begin
                    spec_vl_tag <= arch_vl_tag;
                    spec_vtype <= arch_vtype;
                end
            end else if (vtype_update_en) begin
                spec_vl_tag <= vsetvli_phys_tag;
                spec_vtype <= new_vtype;
            end

            if (commit_req) begin
                arch_vl_tag <= commit_vl_tag;
                arch_vtype <= commit_vtype;
            end
        end
    end
endmodule