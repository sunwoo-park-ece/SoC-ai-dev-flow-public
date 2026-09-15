// True bidirectional APB GPIO. All pins reset to high impedance.
module APB_GPIO #(
    parameter integer GPIO_WIDTH = 16
) (
    input wire PCLK, PRESETn,
    input wire [31:0] PADDR, PWDATA,
    input wire PWRITE, PSEL, PENABLE,
    output reg [31:0] PRDATA,
    output wire PREADY,
    inout wire [GPIO_WIDTH-1:0] GPIO_IO,
    output wire gpio_irq
);
    reg [GPIO_WIDTH-1:0] data_out, direction, irq_enable;
    reg [GPIO_WIDTH-1:0] irq_type, irq_polarity, irq_both_edge;
    reg [GPIO_WIDTH-1:0] sync_ff1, sync_ff2, input_prev, edge_pending;
    reg [GPIO_WIDTH-1:0] rearm_wait1, rearm_wait2;
    reg [2:0] warmup;
    wire [GPIO_WIDTH-1:0] input_mask = ~direction;
    wire [GPIO_WIDTH-1:0] changed = sync_ff2 ^ input_prev;
    wire [GPIO_WIDTH-1:0] rising = changed & sync_ff2;
    wire [GPIO_WIDTH-1:0] falling = changed & ~sync_ff2;
    wire [GPIO_WIDTH-1:0] edge_event = {GPIO_WIDTH{warmup[2]}} & input_mask &
        ~rearm_wait1 & ~rearm_wait2 & irq_type &
        ((irq_both_edge & changed) | (~irq_both_edge &
         ((irq_polarity & rising) | (~irq_polarity & falling))));
    wire [GPIO_WIDTH-1:0] level_active = ~(sync_ff2 ^ irq_polarity);
    wire [GPIO_WIDTH-1:0] pending_view = input_mask &
        ((edge_pending & irq_type) | (level_active & ~irq_type));
    wire access_write = PSEL && PENABLE && PWRITE;
    wire [GPIO_WIDTH-1:0] dir_next =
        (access_write && PADDR[15:0] == 16'h0008) ?
        PWDATA[GPIO_WIDTH-1:0] : direction;
    wire [GPIO_WIDTH-1:0] to_output = ~direction & dir_next;
    wire [GPIO_WIDTH-1:0] to_input = direction & ~dir_next;
    wire [GPIO_WIDTH-1:0] clear_edge =
        (access_write && PADDR[15:0] == 16'h001c) ?
        PWDATA[GPIO_WIDTH-1:0] : {GPIO_WIDTH{1'b0}};

    assign PREADY = 1'b1;
    assign gpio_irq = |(pending_view & irq_enable);
    genvar i;
    generate for (i=0; i<GPIO_WIDTH; i=i+1) begin : gpio_pin
        assign GPIO_IO[i] = direction[i] ? data_out[i] : 1'bz;
    end endgenerate

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            data_out <= 0;
            direction <= 0;
            irq_enable <= 0;
            irq_type <= 0;
            irq_polarity <= 0;
            irq_both_edge <= 0;
            sync_ff1 <= 0;
            sync_ff2 <= 0;
            input_prev <= 0;
            edge_pending <= 0;
            rearm_wait1 <= 0;
            rearm_wait2 <= 0;
            warmup <= 0;
        end else begin
            sync_ff1 <= GPIO_IO;
            sync_ff2 <= sync_ff1;
            input_prev <= sync_ff2;
            warmup <= {warmup[1:0], 1'b1};
            rearm_wait1 <= to_input;
            rearm_wait2 <= rearm_wait1;
            // Direction changes take priority over edge history and pending.
            edge_pending <= ((edge_pending & ~clear_edge) | edge_event) & ~to_output;
            if (to_input != 0) input_prev <= (input_prev & ~to_input) | (sync_ff2 & to_input);
            if (access_write) begin
                case (PADDR[15:0])
                    16'h0004: data_out <= PWDATA[GPIO_WIDTH-1:0];
                    16'h0008: direction <= dir_next;
                    16'h000c: irq_enable <= PWDATA[GPIO_WIDTH-1:0];
                    16'h0010: irq_type <= PWDATA[GPIO_WIDTH-1:0];
                    16'h0014: irq_polarity <= PWDATA[GPIO_WIDTH-1:0];
                    16'h0018: irq_both_edge <= PWDATA[GPIO_WIDTH-1:0];
                    default: ;
                endcase
            end
        end
    end

    always @(*) begin
        PRDATA = 32'b0;
        if (PSEL && PENABLE && !PWRITE) begin
            case (PADDR[15:0])
                16'h0000: PRDATA = {{(32-GPIO_WIDTH){1'b0}},sync_ff2};
                16'h0004: PRDATA = {{(32-GPIO_WIDTH){1'b0}},data_out};
                16'h0008: PRDATA = {{(32-GPIO_WIDTH){1'b0}},direction};
                16'h000c: PRDATA = {{(32-GPIO_WIDTH){1'b0}},irq_enable};
                16'h0010: PRDATA = {{(32-GPIO_WIDTH){1'b0}},irq_type};
                16'h0014: PRDATA = {{(32-GPIO_WIDTH){1'b0}},irq_polarity};
                16'h0018: PRDATA = {{(32-GPIO_WIDTH){1'b0}},irq_both_edge};
                16'h001c: PRDATA = {{(32-GPIO_WIDTH){1'b0}},pending_view};
                default: PRDATA = 32'b0;
            endcase
        end
    end
endmodule
