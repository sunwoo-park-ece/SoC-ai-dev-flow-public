// Fixed-function ADXL345 controller. All state is owned by the 50 MHz PCLK.
// SCLK is an output register, not an internal clock.
module spi_ee_config #(
    parameter integer POLL_BITS = 14
) (
    input  wire        iRSTN,
    input  wire        iPCLK,
    input  wire        iG_INT2,
    output reg  [15:0] out_acc_x,
    output reg  [15:0] out_acc_y,
    output reg  [15:0] out_acc_z,
    output reg         gsensor_ready,
    output reg         SPI_SDI,
    input  wire        SPI_SDO,
    output reg         oSPI_CSN,
    output reg         oSPI_CLK
);
    localparam [7:0] READ_XYZ_COMMAND = 8'hF2;
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SHIFT = 2'd1;
    localparam [1:0] ST_HOLD = 2'd2;

    reg [1:0] state;
    reg [3:0] init_index;
    reg [POLL_BITS:0] poll_count;
    reg [4:0] poll_div_count;
    reg [3:0] half_count;
    reg read_transfer;
    reg [5:0] bits_left;
    reg [55:0] tx_frame;
    reg [47:0] rx_shift;
    reg int_meta;
    reg int_sync;
    wire [47:0] completed_rx = {rx_shift[46:0], SPI_SDO};
    reg [15:0] init_word;

    always @(*) begin
        case (init_index)
            4'd0:  init_word = 16'h2420;
            4'd1:  init_word = 16'h2503;
            4'd2:  init_word = 16'h2601;
            4'd3:  init_word = 16'h277F;
            4'd4:  init_word = 16'h2809;
            4'd5:  init_word = 16'h2946;
            4'd6:  init_word = 16'h2C09;
            4'd7:  init_word = 16'h2E00;
            4'd8:  init_word = 16'h2F00;
            4'd9:  init_word = 16'h3100;
            default: init_word = 16'h2D08;
        endcase
    end

    always @(posedge iPCLK or negedge iRSTN) begin
        if (!iRSTN) begin
            state <= ST_IDLE;
            init_index <= 4'd0;
            poll_count <= {(POLL_BITS+1){1'b0}};
            poll_div_count <= 5'd0;
            half_count <= 4'd0;
            read_transfer <= 1'b0;
            bits_left <= 6'd0;
            tx_frame <= 56'd0;
            rx_shift <= 48'd0;
            int_meta <= 1'b0;
            int_sync <= 1'b0;
            oSPI_CSN <= 1'b1;
            oSPI_CLK <= 1'b1;
            SPI_SDI <= 1'b0;
            out_acc_x <= 16'd0;
            out_acc_y <= 16'd0;
            out_acc_z <= 16'd0;
            gsensor_ready <= 1'b0;
        end else begin
            int_meta <= iG_INT2;
            int_sync <= int_meta;
            gsensor_ready <= 1'b0;
            case (state)
                ST_IDLE: begin
                    // No APB wait is introduced. The SPI engine runs independently.
                    if (init_index < 4'd11) begin
                        tx_frame <= {40'd0, init_word};
                        bits_left <= 6'd16;
                        read_transfer <= 1'b0;
                        SPI_SDI <= init_word[15];
                        oSPI_CSN <= 1'b0;
                        oSPI_CLK <= 1'b1;
                        half_count <= 4'd0;
                        state <= ST_SHIFT;
                    end else if (int_sync || poll_count[POLL_BITS]) begin
                        tx_frame <= {READ_XYZ_COMMAND, 48'd0};
                        rx_shift <= 48'd0;
                        bits_left <= 6'd56;
                        read_transfer <= 1'b1;
                        SPI_SDI <= READ_XYZ_COMMAND[7];
                        oSPI_CSN <= 1'b0;
                        oSPI_CLK <= 1'b1;
                        half_count <= 4'd0;
                        poll_count <= {(POLL_BITS+1){1'b0}};
                        poll_div_count <= 5'd0;
                        state <= ST_SHIFT;
                    end else if (poll_div_count == 5'd24) begin
                        poll_div_count <= 5'd0;
                        poll_count <= poll_count + {{POLL_BITS{1'b0}}, 1'b1};
                    end else begin
                        poll_div_count <= poll_div_count + 5'd1;
                    end
                end
                ST_SHIFT: begin
                    // Mode 3: idle high, MOSI changes on falling SCLK,
                    // MISO is sampled on rising SCLK. High/low halves last
                    // 12/13 PCLK edges, giving exactly 25 PCLKs per SCLK cycle.
                    if (half_count == (oSPI_CLK ? 4'd11 : 4'd12)) begin
                        half_count <= 4'd0;
                        if (oSPI_CLK) begin
                            oSPI_CLK <= 1'b0;
                            SPI_SDI <= tx_frame[bits_left - 1'b1];
                        end else begin
                            oSPI_CLK <= 1'b1;
                            if (read_transfer && (bits_left <= 6'd48))
                                rx_shift <= completed_rx;
                            if (bits_left == 6'd1) begin
                                bits_left <= 6'd0;
                                state <= ST_HOLD;
                                if (read_transfer) begin
                                    // One PCLK edge publishes all three axes.
                                    out_acc_x <= {completed_rx[39:32], completed_rx[47:40]};
                                    out_acc_y <= {completed_rx[23:16], completed_rx[31:24]};
                                    out_acc_z <= {completed_rx[7:0], completed_rx[15:8]};
                                    gsensor_ready <= 1'b1;
                                    poll_count <= {(POLL_BITS+1){1'b0}};
                                    poll_div_count <= 5'd0;
                                end else begin
                                    init_index <= init_index + 4'd1;
                                end
                            end else begin
                                bits_left <= bits_left - 6'd1;
                            end
                        end
                    end else begin
                        half_count <= half_count + 4'd1;
                    end
                end
                ST_HOLD: begin
                    // Hold CS low while SCLK is high after the last sample.
                    if (half_count == 4'd11) begin
                        half_count <= 4'd0;
                        oSPI_CSN <= 1'b1;
                        SPI_SDI <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        half_count <= half_count + 4'd1;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                    oSPI_CSN <= 1'b1;
                    oSPI_CLK <= 1'b1;
                end
            endcase
        end
    end
endmodule
