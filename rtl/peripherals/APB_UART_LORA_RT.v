// APB LoRa UART slave with 8N1 TX/RX, 16-byte RX FIFO, and AUX status.
module APB_UART_LORA (
    input  wire        PCLK,
    input  wire        PRESETn,
    input  wire [31:0] PADDR,
    input  wire        PWRITE,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        uart_tx,
    input  wire        uart_rx,
    input  wire        lora_aux,
    output wire        PREADY
);
    localparam [15:0] UART_DATA    = 16'h0000;
    localparam [15:0] UART_STATUS  = 16'h0004;
    localparam [15:0] UART_CONTROL = 16'h0008;
    localparam [15:0] UART_BAUD    = 16'h000c;

    localparam [15:0] BAUD_RESET = 16'd434;
    localparam [15:0] BAUD_MIN   = 16'd217;

    localparam [1:0] S_IDLE  = 2'b00;
    localparam [1:0] S_START = 2'b01;
    localparam [1:0] S_DATA  = 2'b10;
    localparam [1:0] S_STOP  = 2'b11;

    reg [15:0] programmed_baud_div;
    reg [15:0] tx_active_baud_div;
    reg [15:0] rx_active_baud_div;

    reg [9:0]  tx_shift_reg;
    reg [3:0]  tx_bit_count;
    reg [15:0] tx_baud_cnt;
    reg        tx_busy;

    reg [7:0]  rx_shifter;
    reg [15:0] rx_baud_cnt;
    reg [3:0]  rx_bit_index;
    reg [1:0]  rx_state;
    reg        rx_error;

    reg [7:0] rx_fifo [0:15];
    reg [3:0] rx_fifo_wr_ptr;
    reg [3:0] rx_fifo_rd_ptr;
    reg [4:0] rx_fifo_count;

    reg rx_sync_1;
    reg rx_sync_2;
    reg aux_sync_1;
    reg aux_sync_2;

    wire apb_access = PSEL && PENABLE;
    wire data_write_access = apb_access && PWRITE &&
                             (PADDR[15:0] == UART_DATA);
    wire status_w1c = apb_access && PWRITE &&
                      (PADDR[15:0] == UART_STATUS) && PWDATA[2];
    wire baud_write = apb_access && PWRITE &&
                      (PADDR[15:0] == UART_BAUD);
    wire baud_write_valid = baud_write && (PWDATA[15:0] >= BAUD_MIN);

    assign PREADY = data_write_access ? !tx_busy : 1'b1;
    wire tx_accept = data_write_access && PREADY;

    wire rx_in = rx_sync_2;
    wire eff_aux = aux_sync_2;
    wire rx_ready = (rx_fifo_count != 5'd0);
    wire rx_fifo_full = (rx_fifo_count == 5'd16);
    wire [7:0] rx_fifo_front = rx_fifo[rx_fifo_rd_ptr];
    wire data_read_complete = apb_access && !PWRITE && PREADY &&
                              (PADDR[15:0] == UART_DATA);
    wire rx_pop = data_read_complete && rx_ready;
    wire rx_fifo_can_push = !rx_fifo_full || rx_pop;
    wire rx_stop_sample = (rx_state == S_STOP) &&
                          (rx_baud_cnt == (rx_active_baud_div - 1'b1));
    wire rx_push = rx_stop_sample && rx_in && rx_fifo_can_push;
    wire rx_overflow = rx_stop_sample && rx_in && !rx_fifo_can_push;
    wire rx_framing_error = rx_stop_sample && !rx_in;

    assign uart_tx = tx_busy ? tx_shift_reg[0] : 1'b1;

    // Preserve the P05B CDC/reset contract: RX resets high/high.
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_sync_1 <= 1'b1;
            rx_sync_2 <= 1'b1;
        end else begin
            rx_sync_1 <= uart_rx;
            rx_sync_2 <= rx_sync_1;
        end
    end

    // Preserve the P05B CDC/reset contract: AUX resets low/low and exposes a
    // synchronized high-ready level in STATUS[3].
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            aux_sync_1 <= 1'b0;
            aux_sync_2 <= 1'b0;
        end else begin
            aux_sync_1 <= lora_aux;
            aux_sync_2 <= aux_sync_1;
        end
    end

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            programmed_baud_div <= BAUD_RESET;
        end else if (baud_write_valid) begin
            programmed_baud_div <= PWDATA[15:0];
        end
    end

    always @(*) begin
        PRDATA = 32'h00000000;
        if (apb_access && !PWRITE) begin
            case (PADDR[15:0])
                UART_DATA:
                    PRDATA = rx_ready ? {24'h0, rx_fifo_front} : 32'h0;
                UART_STATUS:
                    PRDATA = {28'h0, eff_aux, rx_error, rx_ready, !tx_busy};
                UART_CONTROL:
                    PRDATA = 32'h0;
                UART_BAUD:
                    PRDATA = {16'h0, programmed_baud_div};
                default:
                    PRDATA = 32'h0;
            endcase
        end
    end

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_active_baud_div <= BAUD_RESET;
            tx_busy            <= 1'b0;
            tx_shift_reg       <= 10'h3ff;
            tx_bit_count       <= 4'd0;
            tx_baud_cnt        <= 16'd0;
        end else if (tx_accept) begin
            tx_active_baud_div <= programmed_baud_div;
            tx_busy            <= 1'b1;
            tx_shift_reg       <= {1'b1, PWDATA[7:0], 1'b0};
            tx_bit_count       <= 4'd10;
            tx_baud_cnt        <= programmed_baud_div - 1'b1;
        end else if (tx_busy) begin
            if (tx_baud_cnt == 16'd0) begin
                if (tx_bit_count == 4'd1) begin
                    tx_busy      <= 1'b0;
                    tx_shift_reg <= 10'h3ff;
                    tx_bit_count <= 4'd0;
                    tx_baud_cnt  <= 16'd0;
                end else begin
                    tx_shift_reg <= {1'b1, tx_shift_reg[9:1]};
                    tx_bit_count <= tx_bit_count - 1'b1;
                    tx_baud_cnt  <= tx_active_baud_div - 1'b1;
                end
            end else begin
                tx_baud_cnt <= tx_baud_cnt - 1'b1;
            end
        end
    end

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_active_baud_div <= BAUD_RESET;
            rx_state           <= S_IDLE;
            rx_baud_cnt        <= 16'd0;
            rx_bit_index       <= 4'd0;
            rx_shifter         <= 8'h00;
            rx_error           <= 1'b0;
            rx_fifo_wr_ptr     <= 4'd0;
            rx_fifo_rd_ptr     <= 4'd0;
            rx_fifo_count      <= 5'd0;
        end else begin
            if (rx_pop)
                rx_fifo_rd_ptr <= rx_fifo_rd_ptr + 1'b1;
            if (rx_push) begin
                rx_fifo[rx_fifo_wr_ptr] <= rx_shifter;
                rx_fifo_wr_ptr <= rx_fifo_wr_ptr + 1'b1;
            end
            case ({rx_push, rx_pop})
                2'b10: rx_fifo_count <= rx_fifo_count + 1'b1;
                2'b01: rx_fifo_count <= rx_fifo_count - 1'b1;
                default: rx_fifo_count <= rx_fifo_count;
            endcase

            if (rx_overflow || rx_framing_error)
                rx_error <= 1'b1;
            else if (status_w1c)
                rx_error <= 1'b0;

            case (rx_state)
                S_IDLE: begin
                    rx_baud_cnt  <= 16'd0;
                    rx_bit_index <= 4'd0;
                    if (!rx_in) begin
                        rx_active_baud_div <= programmed_baud_div;
                        rx_state <= S_START;
                    end
                end
                S_START: begin
                    if (rx_baud_cnt < (rx_active_baud_div / 2)) begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end else if (!rx_in) begin
                        rx_state    <= S_DATA;
                        rx_baud_cnt <= 16'd0;
                    end else begin
                        rx_state <= S_IDLE;
                    end
                end
                S_DATA: begin
                    if (rx_baud_cnt == (rx_active_baud_div - 1'b1)) begin
                        rx_baud_cnt <= 16'd0;
                        rx_shifter[rx_bit_index[2:0]] <= rx_in;
                        if (rx_bit_index == 4'd7) begin
                            rx_bit_index <= 4'd0;
                            rx_state <= S_STOP;
                        end else begin
                            rx_bit_index <= rx_bit_index + 1'b1;
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
                S_STOP: begin
                    if (rx_baud_cnt == (rx_active_baud_div - 1'b1)) begin
                        rx_state <= S_IDLE;
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
                default: rx_state <= S_IDLE;
            endcase
        end
    end
endmodule
