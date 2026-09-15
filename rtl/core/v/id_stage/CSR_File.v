`include "../../vh/csr.vh"

module CSRFile #(
    parameter XLEN = 32
)(
    input clk,                    // clock signal
    input clk_enable,
    input reset,                  // reset signal
    input normal_req_valid,
    input [11:0] normal_req_addr,
    input trap_req_valid,
    input [11:0] trap_req_addr,
    input mret_req_valid,
    input [11:0] mret_req_addr,
    input rsp_consume,
    input normal_wr_valid,
    input [11:0] normal_wr_addr,
    input [XLEN-1:0] normal_wr_data,
    input trap_wr_valid,
    input [11:0] trap_wr_addr,
    input [XLEN-1:0] trap_wr_data,
    input commit_valid,

    output reg [XLEN-1:0] csr_read_out,
    output reg csr_rsp_valid,
    output reg [1:0] csr_rsp_owner
    );

    wire [XLEN-1:0] mvendorid = 32'h0000_0000;
    wire [XLEN-1:0] marchid   = 32'h0000_0000;
    wire [XLEN-1:0] mimpid    = 32'h0001_0000;
    wire [XLEN-1:0] mhartid   = 32'h0000_0000;
    wire [XLEN-1:0] mstatus   = 32'h00001800;    // MPP[12:11] = 11
    wire [XLEN-1:0] misa      = 32'h40000100;    // MXL = 32; misa[31:30] = 01. RV32"I"; misa[8] = 1.

    reg [XLEN-1:0] mtvec;
    reg [XLEN-1:0] mepc;
    reg [XLEN-1:0] mcause;

    reg [63:0] mcycle;
    reg [63:0] minstret;

    localparam [1:0] OWNER_NONE = 2'b00;
    localparam [1:0] OWNER_NORMAL = 2'b01;
    localparam [1:0] OWNER_TRAP = 2'b10;
    localparam [1:0] OWNER_MRET = 2'b11;
    wire [11:0] selected_addr = trap_req_valid ? trap_req_addr :
                                mret_req_valid ? mret_req_addr : normal_req_addr;
    reg [XLEN-1:0] csr_read_data;

    localparam [XLEN-1:0] DEFAULT_mtvec  = 32'h00006D60;
    localparam [XLEN-1:0] DEFAULT_mepc   = {XLEN{1'b0}};
    localparam [XLEN-1:0] DEFAULT_mcause = {XLEN{1'b0}};
    localparam [63:0] DEFAULT_mcycle = 64'b0;
    localparam [63:0] DEFAULT_minstret = 64'b0;

    // Read Operation.
    always @(*) begin
      case (selected_addr)
        12'hB00: csr_read_data = mcycle[XLEN-1:0];
        12'hB02: csr_read_data = minstret[XLEN-1:0];
        12'hB80: csr_read_data = mcycle[63:32];
        12'hB82: csr_read_data = minstret[63:32];
        12'hF11: csr_read_data = mvendorid;
        12'hF12: csr_read_data = marchid;
        12'hF13: csr_read_data = mimpid;
        12'hF14: csr_read_data = mhartid;
        12'h300: csr_read_data = mstatus;
        12'h301: csr_read_data = misa;
        12'h305: csr_read_data = mtvec;
        12'h341: csr_read_data = mepc;
        12'h342: csr_read_data = mcause;
        default: csr_read_data = {XLEN{1'b0}};
      endcase

    end

    // Reset Operation
    always @(posedge clk or posedge reset) begin
      if (reset) begin
        mtvec   <= DEFAULT_mtvec;
        mepc    <= DEFAULT_mepc;
        mcause  <= DEFAULT_mcause;
        mcycle <= DEFAULT_mcycle;
        minstret <= DEFAULT_minstret;
        csr_read_out <= {XLEN{1'b0}};
        csr_rsp_valid <= 1'b0;
        csr_rsp_owner <= OWNER_NONE;
      end else if (clk_enable) begin
        mcycle <= mcycle + 1;
        if (commit_valid) begin
          minstret <= minstret + 1;
        end

        if (rsp_consume) begin
          csr_rsp_valid <= 1'b0;
          csr_rsp_owner <= OWNER_NONE;
        end else if (!csr_rsp_valid &&
                     (trap_req_valid || mret_req_valid || normal_req_valid)) begin
          csr_read_out <= csr_read_data;
          csr_rsp_valid <= 1'b1;
          csr_rsp_owner <= trap_req_valid ? OWNER_TRAP :
                           mret_req_valid ? OWNER_MRET : OWNER_NORMAL;
        end

        // A trap-owned write is never combined with a normal CSR write.
        if (trap_wr_valid) begin
          case (trap_wr_addr)
            12'h305: mtvec <= trap_wr_data;
            // Fixed IALIGN32: the architectural mepc register itself is
            // canonical, including when the trap-service writer owns it.
            12'h341: mepc <= {trap_wr_data[XLEN-1:2], 2'b00};
            12'h342: mcause <= trap_wr_data;
            default: ;
          endcase
        end else if (normal_wr_valid) begin
          case (normal_wr_addr)
            12'h305: mtvec <= normal_wr_data;
            12'h341: mepc <= {normal_wr_data[XLEN-1:2], 2'b00};
            12'h342: mcause <= normal_wr_data;
            default: ; // Counter CSRs remain write-ignore in this milestone.
          endcase
        end
      end
    end


endmodule
