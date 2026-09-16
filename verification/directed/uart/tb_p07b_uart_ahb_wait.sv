`timescale 1ns/1ps

module tb_p07b_uart_ahb_wait;
    localparam [31:0] UART1_DATA = 32'h4006_0000;
    localparam [31:0] UART1_BAUD = 32'h4006_000c;
    localparam [31:0] LED_DATA   = 32'h4009_0000;

    reg clk=0, resetn=0;
    reg [31:0] haddr=0, hwdata=0;
    reg hwrite=0, hsel=0;
    reg [1:0] htrans=0;
    reg [2:0] hsize=3'b010;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire pclk, presetn;
    wire [31:0] paddr, pwdata;
    wire pwrite, penable;
    wire [15:0] psel;
    wire [31:0] uart_rdata, led_rdata;
    wire uart_ready, led_ready;
    wire [31:0] prdata = psel[6] ? uart_rdata : psel[9] ? led_rdata : 32'h0;
    wire pready = psel[6] ? uart_ready : psel[9] ? led_ready : 1'b1;
    wire uart_tx;
    wire [9:0] leds;
    integer accepts=0;
    integer held_cycles=0;

    always #5 clk=~clk;

    AHB_APB_bridge bridge (
        .HCLK(clk),.HRESETn(resetn),.HADDR(haddr),.HWRITE(hwrite),
        .HTRANS(htrans),.HSIZE(hsize),.HWDATA(hwdata),.HSEL(hsel),
        .HREADY_IN(hready),.HRDATA(hrdata),.HREADY(hready),.HRESP(hresp),
        .PCLK(pclk),.PRESETn(presetn),.PADDR(paddr),.PWRITE(pwrite),
        .PENABLE(penable),.PSEL(psel),.PWDATA(pwdata),.PRDATA(prdata),
        .PREADY(pready),.PSLVERR(1'b0)
    );
    APB_UART uart1 (
        .PCLK(pclk),.PRESETn(presetn),.PADDR(paddr),.PWRITE(pwrite),
        .PSEL(psel[6]),.PENABLE(penable),.PWDATA(pwdata),.PRDATA(uart_rdata),
        .uart_tx(uart_tx),.uart_rx(1'b1),.PREADY(uart_ready)
    );
    APB_LED led (
        .PCLK(pclk),.PRESETn(presetn),.PADDR(paddr),.PWRITE(pwrite),
        .PSEL(psel[9]),.PENABLE(penable),.PWDATA(pwdata),.PRDATA(led_rdata),
        .PREADY(led_ready),.LEDR(leds)
    );

    always @(posedge clk) if (resetn && uart1.tx_accept) accepts <= accepts+1;

    task automatic ahb_write(input [31:0] address, input [31:0] data);
        begin
            @(negedge clk); haddr=address; hwdata=data; hwrite=1; hsel=1; htrans=2'b10;
            @(posedge clk); #1;
            @(negedge clk); hsel=0; htrans=0;
            while (!hready) @(posedge clk);
            @(posedge clk); #1;
            if (hresp!==0) $fatal(1,"AHB write response error");
        end
    endtask

    task automatic ahb_expect_error(input [31:0] address, input [2:0] size);
        integer accepts_before;
        begin
            accepts_before=accepts;
            @(negedge clk); haddr=address; hwdata=32'hdead_beef; hwrite=1;
            hsize=size; hsel=1; htrans=2'b10;
            @(posedge clk); #1;
            if (psel!==0 || hready!==0 || penable!==0)
                $fatal(1,"invalid UART request selected APB slave");
            @(negedge clk); hsel=0; htrans=0;
            @(posedge clk); #1;
            if (psel!==0 || penable!==1 || hresp!==2'b01 || hready!==0)
                $fatal(1,"invalid UART first ERROR response");
            @(posedge clk); #1;
            if (psel!==0 || hresp!==2'b01 || hready!==1)
                $fatal(1,"invalid UART final ERROR response");
            @(posedge clk); #1;
            if (hresp!==0 || !hready || accepts!==accepts_before)
                $fatal(1,"invalid UART request side effect/termination");
            hsize=3'b010;
        end
    endtask

    initial begin
        repeat(4) @(posedge clk); #1 resetn=1; repeat(3) @(posedge clk);
        ahb_write(UART1_BAUD,217);
        ahb_write(UART1_DATA,8'h12);
        if (accepts!==1 || !uart1.tx_busy) $fatal(1,"first UART AHB write not accepted");

        // The second request reaches ACCESS while TX is busy. PREADY and
        // HREADY must remain low until the stop bit completes.
        fork
            begin
                ahb_write(UART1_DATA,8'h34);
            end
            begin
                wait (penable && psel[6]); #1;
                while (!uart_ready) begin
                    if (hready!==0 || paddr!==UART1_DATA || pwdata[7:0]!==8'h34)
                        $fatal(1,"bridge did not hold UART ACCESS/data during wait");
                    held_cycles=held_cycles+1;
                    @(posedge clk); #1;
                end
            end
        join
        if (held_cycles<100 || accepts!==2) $fatal(1,"UART wait/accept count %0d/%0d",held_cycles,accepts);

        // A different decoded APB slave must remain usable after the wait.
        ahb_write(LED_DATA,32'h0000_0155);
        if (leds!==10'h155 || hresp!==0 || !hready)
            $fatal(1,"post-UART-wait LED transaction failed");

        // Architectural decode rejects noncanonical, misaligned, and
        // non-word UART accesses before asserting a real UART PSEL.
        ahb_expect_error(32'h4006_0010,3'b010);
        ahb_expect_error(32'h4006_0002,3'b010);
        ahb_expect_error(32'h4006_0000,3'b000);

        wait (!uart1.tx_busy);
        if (accepts!==2) $fatal(1,"held ACCESS duplicated UART transfer");
        $display("SUMMARY: PASS P07B actual AHB/APB UART wait-state integration held=%0d",held_cycles);
        $finish;
    end
endmodule
