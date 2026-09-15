`timescale 1ns/1ps
`include "../../vh/trap.vh"

// Transport/ownership service only. Architectural retirement and final MRET
// semantics belong to 3B2B/3B3 respectively.
module WBServiceController (
    input wire clk,
    input wire clk_enable,
    input wire reset,
    input wire WB_valid,
    input wire WB_exc_valid,
    input wire [3:0] WB_exc_cause,
    input wire [31:0] WB_pc,
    input wire WB_is_mret,
    input wire csr_rsp_valid,
    input wire [1:0] csr_rsp_owner,
    input wire [31:0] csr_rsp_data,
    output wire service_hold,
    output wire trap_wr_valid,
    output wire [11:0] trap_wr_addr,
    output wire [31:0] trap_wr_data,
    output wire trap_req_valid,
    output wire [11:0] trap_req_addr,
    output wire mret_req_valid,
    output wire [11:0] mret_req_addr,
    output wire csr_rsp_consume,
    output wire redirect_fire,
    output wire mret_redirect_fire,
    output wire [31:0] redirect_target,
    output wire wb_clear
);
    localparam [3:0] S_IDLE = 4'd0,
                     S_MEPC = 4'd1,
                     S_MCAUSE = 4'd2,
                     S_REQ_MTVEC = 4'd3,
                     S_WAIT_MTVEC = 4'd4,
                     S_TRAP_REDIRECT = 4'd5,
                     S_REQ_MEPC = 4'd6,
                     S_WAIT_MEPC = 4'd7,
                     S_MRET_REDIRECT = 4'd8;
    localparam [1:0] OWNER_TRAP = 2'b10;
    localparam [1:0] OWNER_MRET = 2'b11;

    reg [3:0] state;
    reg [31:0] saved_target;
    reg [31:0] saved_pc;
    reg [3:0] saved_cause;

    function [31:0] architectural_cause;
        input [3:0] project_cause;
        begin
            case (project_cause)
                `TRAP_MISALIGNED_INSTRUCTION: architectural_cause = 32'd0;
                `TRAP_EBREAK: architectural_cause = 32'd3;
                `TRAP_MISALIGNED_LOAD: architectural_cause = 32'd4;
                `TRAP_LOAD_ACCESS_FAULT: architectural_cause = 32'd5;
                `TRAP_MISALIGNED_STORE: architectural_cause = 32'd6;
                `TRAP_STORE_ACCESS_FAULT: architectural_cause = 32'd7;
                `TRAP_ECALL: architectural_cause = 32'd11;
                default: architectural_cause = 32'd2;
            endcase
        end
    endfunction

    assign service_hold = (state != S_IDLE) ||
                          (WB_valid && (WB_exc_valid || WB_is_mret));
    assign trap_wr_valid = clk_enable && (state == S_MEPC || state == S_MCAUSE);
    assign trap_wr_addr = (state == S_MEPC) ? 12'h341 : 12'h342;
    assign trap_wr_data = (state == S_MEPC) ? saved_pc :
                          architectural_cause(saved_cause);
    assign trap_req_valid = clk_enable && (state == S_REQ_MTVEC);
    assign trap_req_addr = 12'h305;
    assign mret_req_valid = clk_enable && (state == S_REQ_MEPC);
    assign mret_req_addr = 12'h341;
    assign csr_rsp_consume = clk_enable &&
        ((state == S_WAIT_MTVEC && csr_rsp_valid &&
          csr_rsp_owner == OWNER_TRAP) ||
         (state == S_WAIT_MEPC && csr_rsp_valid &&
          csr_rsp_owner == OWNER_MRET));
    assign redirect_fire = clk_enable &&
        (state == S_TRAP_REDIRECT || state == S_MRET_REDIRECT);
    assign mret_redirect_fire = clk_enable && (state == S_MRET_REDIRECT);
    assign redirect_target = saved_target;
    assign wb_clear = redirect_fire;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE;
            saved_target <= 32'b0;
            saved_pc <= 32'b0;
            saved_cause <= `TRAP_NONE;
        end else if (clk_enable) begin
            case (state)
                S_IDLE: begin
                    if (WB_valid && WB_exc_valid) begin
                        saved_pc <= WB_pc;
                        saved_cause <= WB_exc_cause;
                        state <= S_MEPC;
                    end else if (WB_valid && WB_is_mret) begin
                        state <= S_REQ_MEPC;
                    end
                end
                S_MEPC: state <= S_MCAUSE;
                S_MCAUSE: state <= S_REQ_MTVEC;
                S_REQ_MTVEC: state <= S_WAIT_MTVEC;
                S_WAIT_MTVEC: begin
                    if (csr_rsp_valid && csr_rsp_owner == OWNER_TRAP) begin
                        saved_target <= csr_rsp_data;
                        state <= S_TRAP_REDIRECT;
                    end
                end
                S_TRAP_REDIRECT: state <= S_IDLE;
                S_REQ_MEPC: state <= S_WAIT_MEPC;
                S_WAIT_MEPC: begin
                    if (csr_rsp_valid && csr_rsp_owner == OWNER_MRET) begin
                        saved_target <= csr_rsp_data;
                        state <= S_MRET_REDIRECT;
                    end
                end
                S_MRET_REDIRECT: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
