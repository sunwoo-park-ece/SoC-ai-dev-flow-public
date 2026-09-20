// Fixed-function ADXL345 controller. PCLK owns every register; SCLK is output only.
module spi_ee_config (
    input  wire        iRSTN,
    input  wire        iPCLK,
    input  wire        iG_INT2, // Historical port name; wrapper connects physical INT1.
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
    localparam [1:0] ST_IDLE = 2'd0, ST_SHIFT = 2'd1, ST_HOLD = 2'd2;
    localparam [1:0] REQ_NONE = 2'd0, REQ_FALLBACK = 2'd1, REQ_IRQ = 2'd2;
    // elapsed=0 at arm/restart. Edge 1,500,000 sees pre-edge 1,499,999.
    localparam [20:0] WATCHDOG_LAST = 21'd1_499_999;

    reg [1:0] state;
    reg [3:0] init_index;
    reg [3:0] half_count;
    reg read_transfer;
    reg [5:0] bits_left;
    reg [55:0] tx_frame;
    reg [47:0] rx_shift;
    reg int_meta, int_sync, irq_seen_high;
    reg scheduler_armed;
    reg [20:0] elapsed;
    reg [1:0] pending_req;
    reg [15:0] init_word;
    wire [47:0] completed_rx = {rx_shift[46:0], SPI_SDO};

    // Twelve exact project-owned register writes. POWER_CTL is last.
    always @(*) begin
        case (init_index)
            4'd0:  init_word = 16'h2420;
            4'd1:  init_word = 16'h2503;
            4'd2:  init_word = 16'h2601;
            4'd3:  init_word = 16'h277F;
            4'd4:  init_word = 16'h2809;
            4'd5:  init_word = 16'h2946;
            4'd6:  init_word = 16'h2C09;
            4'd7:  init_word = 16'h2F00; // INT_MAP: DATA_READY -> INT1
            4'd8:  init_word = 16'h2E80; // INT_ENABLE: DATA_READY
            4'd9:  init_word = 16'h3100;
            4'd10: init_word = 16'h2007;
            4'd11: init_word = 16'h2D08;
            default: init_word = 16'h0000;
        endcase
    end

    // A HIGH after arm/rearm is one event. Only synchronized LOW rearms it.
    wire irq_event = scheduler_armed && int_sync && !irq_seen_high;
    wire timeout_event = scheduler_armed && (elapsed == WATCHDOG_LAST);
    wire [1:0] selected_req = irq_event ? REQ_IRQ :
                              (pending_req == REQ_IRQ) ? REQ_IRQ :
                              (pending_req == REQ_FALLBACK) ? REQ_FALLBACK :
                              timeout_event ? REQ_FALLBACK : REQ_NONE;
    wire launch = (state == ST_IDLE) && (init_index == 4'd12) &&
                  scheduler_armed && (selected_req != REQ_NONE);
    wire restart_elapsed = irq_event ||
                           (launch && (selected_req == REQ_FALLBACK)) ||
                           (launch && (selected_req == REQ_IRQ) && timeout_event);

    always @(posedge iPCLK or negedge iRSTN) begin
        if (!iRSTN) begin
            state <= ST_IDLE;
            init_index <= 4'd0;
            half_count <= 4'd0;
            read_transfer <= 1'b0;
            bits_left <= 6'd0;
            tx_frame <= 56'd0;
            rx_shift <= 48'd0;
            int_meta <= 1'b0;
            int_sync <= 1'b0;
            irq_seen_high <= 1'b0;
            scheduler_armed <= 1'b0;
            elapsed <= 21'd0;
            pending_req <= REQ_NONE;
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

            if (scheduler_armed) begin
                if (!int_sync)
                    irq_seen_high <= 1'b0;
                else if (irq_event)
                    irq_seen_high <= 1'b1;

                // One coalesced slot: IRQ upgrades FALLBACK, and a deadline
                // cannot create another request while IRQ is pending.
                pending_req <= launch ? REQ_NONE : selected_req;
                if (restart_elapsed)
                    elapsed <= 21'd0;
                else if (elapsed < WATCHDOG_LAST)
                    elapsed <= elapsed + 21'd1;
            end

            case (state)
                ST_IDLE: begin
                    if (init_index < 4'd12) begin
                        tx_frame <= {40'd0, init_word};
                        bits_left <= 6'd16;
                        read_transfer <= 1'b0;
                        SPI_SDI <= init_word[15];
                        oSPI_CSN <= 1'b0;
                        oSPI_CLK <= 1'b1;
                        half_count <= 4'd0;
                        state <= ST_SHIFT;
                    end else if (launch) begin
                        tx_frame <= {READ_XYZ_COMMAND, 48'd0};
                        rx_shift <= 48'd0;
                        bits_left <= 6'd56;
                        read_transfer <= 1'b1;
                        SPI_SDI <= READ_XYZ_COMMAND[7];
                        oSPI_CSN <= 1'b0;
                        oSPI_CLK <= 1'b1;
                        half_count <= 4'd0;
                        state <= ST_SHIFT;
                    end
                end
                ST_SHIFT: begin
                    // Mode 3: registered 12/13-PCLK high/low half-periods.
                    // Launch MOSI on falling SCLK; sample MISO on rising.
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
                                    // E0: publish complete digital bytes together.
                                    out_acc_x <= {completed_rx[39:32], completed_rx[47:40]};
                                    out_acc_y <= {completed_rx[23:16], completed_rx[31:24]};
                                    out_acc_z <= {completed_rx[7:0], completed_rx[15:8]};
                                    gsensor_ready <= 1'b1;
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
                    // Keep CS low after the last sample while SCLK is high.
                    if (half_count == 4'd11) begin
                        half_count <= 4'd0;
                        oSPI_CSN <= 1'b1;
                        SPI_SDI <= 1'b0;
                        state <= ST_IDLE;
                        // The twelfth write is fully over only on this edge.
                        if ((init_index == 4'd12) && !scheduler_armed) begin
                            scheduler_armed <= 1'b1;
                            elapsed <= 21'd0;
                        end
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
