`timescale 1ns/1ps
module tb_p04_boardio;
    reg clk=0, resetn=1, write=0, enable=0;
    reg [2:0] sel=0;
    reg [31:0] addr=0, wdata=0;
    reg [9:0] switches=10'h155;
    reg [15:0] ext_drive=0, ext_enable=0;
    tri [15:0] gpio_pins;
    wire [31:0] grdata, srdata, lrdata;
    wire gpready, spready, lpready, gpio_irq, sw_irq;
    wire [9:0] leds;
    integer i, j;
    always #5 clk=~clk;
    genvar pin;
    generate for (pin=0; pin<16; pin=pin+1) begin : ext
        assign gpio_pins[pin] = ext_enable[pin] ? ext_drive[pin] : 1'bz;
    end endgenerate
    APB_GPIO gpio(.PCLK(clk),.PRESETn(resetn),.PADDR(addr),.PWDATA(wdata),
        .PWRITE(write),.PSEL(sel[0]),.PENABLE(enable),.PRDATA(grdata),
        .PREADY(gpready),.GPIO_IO(gpio_pins),.gpio_irq(gpio_irq));
    APB_SW sw(.PCLK(clk),.PRESETn(resetn),.PADDR(addr),.PWDATA(wdata),
        .PWRITE(write),.PSEL(sel[1]),.PENABLE(enable),.SW(switches),
        .PRDATA(srdata),.PREADY(spready),.irq(sw_irq));
    APB_LED led(.PCLK(clk),.PRESETn(resetn),.PADDR(addr),.PWDATA(wdata),
        .PWRITE(write),.PSEL(sel[2]),.PENABLE(enable),.PRDATA(lrdata),
        .PREADY(lpready),.LEDR(leds));

    task apb_write(input [2:0] target, input [31:0] address, input [31:0] data);
        begin
            @(negedge clk); sel=target; addr=address; wdata=data; write=1; enable=1;
            @(posedge clk); #1;
            @(negedge clk); sel=0; write=0; enable=0;
        end
    endtask
    task apb_read(input [2:0] target, input [31:0] address, input [31:0] expected);
        begin
            @(negedge clk); sel=target; addr=address; write=0; enable=1; #1;
            if (((target[0] ? grdata : target[1] ? srdata : lrdata)) !== expected)
                $fatal(1,"read addr=%h got=%h expected=%h",address,
                    (target[0] ? grdata : target[1] ? srdata : lrdata),expected);
            sel=0; enable=0;
        end
    endtask
    initial begin
        #1; resetn=0; #1;
        if (gpio_pins !== 16'hzzzz || leds !== 10'b0 || gpio_irq || sw_irq)
            $fatal(1,"reset outputs/Hi-Z");
        repeat (2) @(negedge clk); resetn=1;
        repeat (5) @(negedge clk);
        if (sw_irq || sw.irq_pending !== 0) $fatal(1,"SW reset high produced ghost IRQ");
        apb_read(3'b010,32'h4008_0000,32'h155);
        // Transition just before a PCLK edge must not bypass the two stages.
        @(negedge clk); #4; switches[9]=1;
        #0.1; if (sw.sync_ff2[9] !== 0) $fatal(1,"SW raw near-edge feedthrough");
        @(posedge clk); #1;
        if (sw.sync_ff2[9] !== 0) $fatal(1,"SW one-stage bypass");
        @(posedge clk); #1;
        if (sw.sync_ff2[9] !== 1) $fatal(1,"SW second-stage sampling");
        @(negedge clk); switches[9]=0;
        repeat (4) @(negedge clk);
        if (sw.sync_ff2[9] !== 0 || sw.irq_pending[9] !== 1)
            $fatal(1,"SW away-edge change capture");
        apb_write(3'b010,32'h4008_0008,32'h200);
        switches=0;
        repeat (4) @(negedge clk);
        apb_write(3'b010,32'h4008_0008,32'h3ff);
        for (i=0; i<10; i=i+1) begin
            switches=(10'h1 << i);
            repeat (4) @(negedge clk);
            if (sw.sync_ff2 !== (10'h1 << i) || !sw.irq_pending[i])
                $fatal(1,"SW walking-one input/event bit %0d",i);
            apb_write(3'b010,32'h4008_0008,32'h3ff);
            switches=0;
            repeat (4) @(negedge clk);
            apb_write(3'b010,32'h4008_0008,32'h3ff);
        end
        switches=10'h155;
        repeat (4) @(negedge clk);
        apb_write(3'b010,32'h4008_0008,32'h3ff);
        apb_write(3'b100,32'h4009_0000,32'h3ff);
        if (leds !== 10'h3ff || gpio_pins !== 16'hzzzz)
            $fatal(1,"LED one-owner/full-width or GPIO reset Hi-Z");
        for (i=0; i<10; i=i+1) begin
            apb_write(3'b100,32'h4009_0000,32'h1 << i);
            if (leds !== (10'h1 << i)) $fatal(1,"LED walking-one bit %0d",i);
        end
        apb_write(3'b100,32'h4009_0000,32'h3ff);
        apb_read(3'b100,32'h4009_0000,32'h3ff);
        apb_write(3'b100,32'h4009_0004,0);
        if (leds !== 10'h3ff) $fatal(1,"LED noncanonical alias");
        apb_write(3'b001,32'h4001_0004,32'h0000_a505);
        if (gpio_pins !== 16'hzzzz) $fatal(1,"GPIO preload drove Hi-Z pin");
        apb_write(3'b001,32'h4001_0008,32'h0000_8001);
        if (gpio_pins[15] !== 1'b1 || gpio_pins[0] !== 1'b1 ||
            gpio_pins[14:1] !== 14'hzzzz) $fatal(1,"GPIO per-bit OE/drive");
        for (i=0; i<16; i=i+1) begin
            apb_write(3'b001,32'h4001_0004,32'h1 << i);
            apb_write(3'b001,32'h4001_0008,32'h1 << i);
            for (j=0; j<16; j=j+1)
                if ((j==i && gpio_pins[j] !== 1'b1) ||
                    (j!=i && gpio_pins[j] !== 1'bz))
                    $fatal(1,"GPIO walking-one pin %0d affected pin %0d",i,j);
        end
        apb_write(3'b001,32'h4001_0004,32'h0000_a505);
        apb_write(3'b001,32'h4001_0008,32'h0000_8001);
        apb_read(3'b001,32'h4001_0004,32'h0000_a505);
        apb_read(3'b001,32'h4001_0008,32'h0000_8001);
        ext_drive=16'h4002; ext_enable=16'h7ffe;
        repeat (4) @(negedge clk);
        apb_read(3'b001,32'h4001_0000,32'h0000_c003);
        apb_write(3'b001,32'h4001_0010,32'hffff); // Edge mode removes live low-level pending.
        apb_write(3'b001,32'h4001_0014,32'h2); // Rising.
        apb_write(3'b001,32'h4001_000c,32'h2);
        ext_drive[1]=0;
        repeat (4) @(negedge clk);
        ext_drive[1]=1;
        repeat (4) @(negedge clk);
        if (!gpio_irq) $fatal(1,"GPIO rising IRQ missing");
        apb_read(3'b001,32'h4001_001c,32'h2);
        apb_write(3'b001,32'h4001_001c,32'h2);
        if (gpio_irq) $fatal(1,"GPIO W1C failed");
        ext_enable[1]=0;
        apb_write(3'b001,32'h4001_0008,32'h8003);
        if (gpio_irq || gpio.edge_pending[1]) $fatal(1,"GPIO output-mode IRQ mask/clear");
        apb_write(3'b001,32'h4001_0004,32'h0000_a507);
        repeat (4) @(negedge clk);
        apb_write(3'b001,32'h4001_0008,32'h8001);
        ext_drive[1]=0;
        ext_enable[1]=1;
        repeat (5) @(negedge clk);
        if (gpio_irq) $fatal(1,"GPIO direction rearm ghost IRQ");
        ext_drive[1]=1;
        wait (gpio.edge_event[1] === 1'b1);
        @(negedge clk); sel=3'b001; addr=32'h4001_001c; wdata=2;
        write=1; enable=1;
        @(posedge clk); #1;
        if (gpio.edge_pending[1] !== 1'b1)
            $fatal(1,"GPIO simultaneous event/W1C lost event");
        @(negedge clk); sel=0; write=0; enable=0;
        apb_write(3'b001,32'h4001_001c,2);
        apb_write(3'b010,32'h4008_0004,32'h001);
        switches[0]=0;
        repeat (4) @(negedge clk);
        if (!sw_irq || sw.irq_pending[0] !== 1'b1)
            $fatal(1,"SW change event/IRQ missing");
        apb_read(3'b010,32'h4008_0000,32'h154);
        apb_write(3'b010,32'h4008_0008,32'h001);
        if (sw_irq) $fatal(1,"SW W1C failed");
        apb_write(3'b010,32'h4008_000c,32'h3ff);
        if (sw.irq_enable !== 10'h001) $fatal(1,"SW noncanonical alias");
        // Arrange W1C on the same sampling edge as a new synchronized event.
        switches[0]=1;
        wait (sw.change_event[0] === 1'b1);
        @(negedge clk); sel=3'b010; addr=32'h4008_0008; wdata=1;
        write=1; enable=1;
        @(posedge clk); #1;
        if (sw.irq_pending[0] !== 1'b1)
            $fatal(1,"SW simultaneous event/W1C lost event");
        @(negedge clk); sel=0; write=0; enable=0;
        apb_write(3'b010,32'h4008_0008,1);
        // GPIO level pending is live and cannot be suppressed by W1C.
        apb_write(3'b001,32'h4001_0010,0);
        apb_write(3'b001,32'h4001_0014,0);
        apb_write(3'b001,32'h4001_000c,2);
        ext_drive[1]=0;
        repeat (4) @(negedge clk);
        apb_write(3'b001,32'h4001_001c,2);
        if (!gpio_irq || !gpio.pending_view[1])
            $fatal(1,"GPIO live level improperly W1C-cleared");
        // Reassert reset with a static high input: no edge shall be manufactured.
        @(negedge clk); resetn=0; ext_enable=16'hffff; ext_drive=16'hffff;
        #1;
        if (gpio.direction !== 0 || gpio.edge_pending !== 0 ||
            sw.irq_pending !== 0 || leds !== 0)
            $fatal(1,"reset state after activity");
        @(negedge clk); resetn=1;
        repeat (5) @(negedge clk);
        if (gpio.edge_pending !== 0 || sw.irq_pending !== 0)
            $fatal(1,"static high input caused warmup ghost event");
        apb_write(3'b001,32'h4001_0010,32'hffff);
        if (gpio.edge_pending !== 0) $fatal(1,"GPIO static high ghost edge");
        if (!gpready || !spready || !lpready) $fatal(1,"APB ready");
        $display("SUMMARY: PASS P04 GPIO/SW/LED directed");
        $finish;
    end
endmodule
