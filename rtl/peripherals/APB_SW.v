module APB_SW (
    input wire PCLK, PRESETn,
    input wire [31:0] PADDR, PWDATA,
    input wire PWRITE, PSEL, PENABLE,
    input wire [9:0] SW,
    output reg [31:0] PRDATA,
    output wire PREADY, irq
);
    reg [9:0] sync_ff1, sync_ff2, sw_prev, irq_enable, irq_pending;
    reg [2:0] warmup;
    wire [9:0] change_event = (sync_ff2 ^ sw_prev) & {10{warmup[2]}};
    wire [9:0] clear_mask = (PSEL && PENABLE && PWRITE &&
        PADDR[15:0] == 16'h0008) ? PWDATA[9:0] : 10'b0;
    assign PREADY = 1'b1;
    assign irq = |(irq_pending & irq_enable);
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            sync_ff1 <= 0;
            sync_ff2 <= 0;
            sw_prev <= 0;
            warmup <= 0;
            irq_enable <= 0;
            irq_pending <= 0;
        end else begin
            sync_ff1 <= SW;
            sync_ff2 <= sync_ff1;
            sw_prev <= sync_ff2;
            warmup <= {warmup[1:0], 1'b1};
            irq_pending <= (irq_pending & ~clear_mask) | change_event;
            if (PSEL && PENABLE && PWRITE && PADDR[15:0] == 16'h0004)
                irq_enable <= PWDATA[9:0];
        end
    end
    always @(*) begin
        PRDATA = 32'b0;
        if (PSEL && PENABLE && !PWRITE) begin
            case (PADDR[15:0])
                16'h0000: PRDATA = {22'b0,sync_ff2};
                16'h0004: PRDATA = {22'b0,irq_enable};
                16'h0008: PRDATA = {22'b0,irq_pending};
                default: PRDATA = 32'b0;
            endcase
        end
    end
endmodule
