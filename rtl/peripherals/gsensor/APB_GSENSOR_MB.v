// P09B fixed-function ADXL345 APB snapshot wrapper. All state uses PCLK/PRESETn.
module APB_GSENSOR_MB (
    input  wire        PCLK,
    input  wire        PRESETn,
    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERR,
    output wire        GSENSOR_CS_N,
    input  wire [2:1]  GSENSOR_INT,
    output wire        GSENSOR_SCLK,
    output wire        GSENSOR_SDI,
    input  wire        GSENSOR_SDO,
    output wire [15:0] debug_acc_x,
    output wire [15:0] debug_acc_y
);
    localparam [31:0] HOLD_XY_ADDR   = 32'h4003_0000;
    localparam [31:0] HOLD_Z_ADDR    = 32'h4003_0004;
    localparam [31:0] STATUS_ADDR    = 32'h4003_0008;
    localparam [31:0] HOLD_SEQ_ADDR  = 32'h4003_000c;
    localparam [31:0] SNAP_CTRL_ADDR = 32'h4003_0010;

    wire [15:0] out_acc_x, out_acc_y, out_acc_z;
    wire        gsensor_ready;
    reg  [15:0] live_x, live_y, live_z;
    reg  [31:0] live_seq;
    reg         live_valid;
    reg  [15:0] hold_x, hold_y, hold_z;
    reg  [31:0] hold_seq;
    reg         hold_valid;
    reg  [31:0] setup_wdata;

    assign PREADY = 1'b1;
    // Preserve the legacy direct acquisition debug signals, not HOLD readback.
    assign debug_acc_x = out_acc_x;
    assign debug_acc_y = out_acc_y;

    spi_ee_config u_spi_ee_config (
        .iRSTN(PRESETn),
        .iPCLK(PCLK),
        .iG_INT2(GSENSOR_INT[1]), // Board PIN_Y14 is physical INT1.
        .out_acc_x(out_acc_x),
        .out_acc_y(out_acc_y),
        .out_acc_z(out_acc_z),
        .gsensor_ready(gsensor_ready),
        .SPI_SDI(GSENSOR_SDI),
        .SPI_SDO(GSENSOR_SDO),
        .oSPI_CSN(GSENSOR_CS_N),
        .oSPI_CLK(GSENSOR_SCLK)
    );

    wire read_addr = (PADDR == HOLD_XY_ADDR) || (PADDR == HOLD_Z_ADDR) ||
                     (PADDR == STATUS_ADDR) || (PADDR == HOLD_SEQ_ADDR);
    wire access = PRESETn && PSEL && PENABLE;
    // APB write data is stable from SETUP through ACCESS. Registering the
    // SETUP value also keeps PSLVERR off the AHB HREADY/HWDATA feedback path.
    wire legal_ctrl = (setup_wdata == 32'h1) || (setup_wdata == 32'h2);
    wire legal_access = PWRITE ? ((PADDR == SNAP_CTRL_ADDR) && legal_ctrl) : read_addr;
    assign PSLVERR = access && !legal_access;

    wire capture = access && PWRITE && !PSLVERR &&
                   (PADDR == SNAP_CTRL_ADDR) && (setup_wdata == 32'h1);
    wire release_hold = access && PWRITE && !PSLVERR &&
                        (PADDR == SNAP_CTRL_ADDR) && (setup_wdata == 32'h2);
    wire capture_success = capture && live_valid && !hold_valid;

    // APB samples this combinational value at the completing ACCESS edge.
    // Nonblocking bank updates on that edge are not forwarded into the read.
    always @(*) begin
        PRDATA = 32'h0;
        if (access && !PWRITE && !PSLVERR) begin
            case (PADDR)
                HOLD_XY_ADDR:  PRDATA = hold_valid ? {hold_x, hold_y} : 32'h0;
                HOLD_Z_ADDR:   PRDATA = hold_valid ? {16'h0, hold_z} : 32'h0;
                STATUS_ADDR:   PRDATA = {30'h0, hold_valid, live_valid};
                HOLD_SEQ_ADDR: PRDATA = hold_valid ? hold_seq : 32'h0;
                default:       PRDATA = 32'h0;
            endcase
        end
    end

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            setup_wdata <= 32'h0;
            live_x <= 16'h0;
            live_y <= 16'h0;
            live_z <= 16'h0;
            live_seq <= 32'h0;
            live_valid <= 1'b0;
            hold_x <= 16'h0;
            hold_y <= 16'h0;
            hold_z <= 16'h0;
            hold_seq <= 32'h0;
            hold_valid <= 1'b0;
        end else begin
            if (PSEL && !PENABLE && PWRITE)
                setup_wdata <= PWDATA;
            // E1: the controller registered XYZ and ready together at E0.
            // Event publication wins over successful CAPTURE's pending clear.
            if (gsensor_ready) begin
                live_x <= out_acc_x;
                live_y <= out_acc_y;
                live_z <= out_acc_z;
                live_seq <= live_seq + 32'd1;
                live_valid <= 1'b1;
            end else if (capture_success) begin
                live_valid <= 1'b0;
            end

            if (release_hold) begin
                hold_x <= 16'h0;
                hold_y <= 16'h0;
                hold_z <= 16'h0;
                hold_seq <= 32'h0;
                hold_valid <= 1'b0;
            end else if (capture_success) begin
                // Copy only the pre-edge LIVE generation, even with E1 now.
                hold_x <= live_x;
                hold_y <= live_y;
                hold_z <= live_z;
                hold_seq <= live_seq;
                hold_valid <= 1'b1;
            end
        end
    end
endmodule
