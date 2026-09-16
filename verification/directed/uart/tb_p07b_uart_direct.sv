`timescale 1ns/1ps

module tb_p07b_uart_direct;
    localparam integer BAUD = 217;
    localparam [31:0] DATA = 32'h0;
    localparam [31:0] STATUS = 32'h4;
    localparam [31:0] CONTROL = 32'h8;
    localparam [31:0] BAUD_REG = 32'hc;

    reg clk = 0;
    reg resetn = 0;
    reg [31:0] addr = 0;
    reg write = 0;
    reg sel0 = 0;
    reg sel1 = 0;
    reg enable = 0;
    reg [31:0] wdata = 0;
    reg rx0 = 1;
    reg rx1 = 1;
    reg aux = 0;
    wire [31:0] rdata0, rdata1;
    wire tx0, tx1, ready0, ready1;
    integer accept0 = 0;
    integer accept1 = 0;
    integer i;

    always #5 clk = ~clk;

    APB_UART_LORA uart0 (
        .PCLK(clk), .PRESETn(resetn), .PADDR(addr), .PWRITE(write),
        .PSEL(sel0), .PENABLE(enable), .PWDATA(wdata), .PRDATA(rdata0),
        .uart_tx(tx0), .uart_rx(rx0), .lora_aux(aux), .PREADY(ready0)
    );
    APB_UART uart1 (
        .PCLK(clk), .PRESETn(resetn), .PADDR(addr), .PWRITE(write),
        .PSEL(sel1), .PENABLE(enable), .PWDATA(wdata), .PRDATA(rdata1),
        .uart_tx(tx1), .uart_rx(rx1), .PREADY(ready1)
    );

    always @(posedge clk) begin
        if (resetn && uart0.tx_accept) accept0 <= accept0 + 1;
        if (resetn && uart1.tx_accept) accept1 <= accept1 + 1;
    end

    task automatic fail(input [8*120-1:0] message);
        begin $display("FAIL: %0s", message); $fatal(1); end
    endtask

    task automatic idle_bus;
        begin
            @(negedge clk); sel0=0; sel1=0; enable=0; write=0; addr=0; wdata=0;
        end
    endtask

    task automatic write0(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); addr=a; wdata=d; write=1; sel0=1; sel1=0; enable=1;
            while (!ready0) @(posedge clk);
            @(posedge clk); #1;
            idle_bus();
        end
    endtask

    task automatic write1(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); addr=a; wdata=d; write=1; sel0=0; sel1=1; enable=1;
            while (!ready1) @(posedge clk);
            @(posedge clk); #1;
            idle_bus();
        end
    endtask

    task automatic read0(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); addr=a; write=0; sel0=1; sel1=0; enable=1; #1; d=rdata0;
            @(posedge clk); #1; idle_bus();
        end
    endtask

    task automatic read1(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); addr=a; write=0; sel0=0; sel1=1; enable=1; #1; d=rdata1;
            @(posedge clk); #1; idle_bus();
        end
    endtask

    task automatic check_tx0(input [7:0] value);
        integer bitn;
        reg expected;
        begin
            write0(DATA, value);
            // write0 returns after acceptance; no deferred-start cycle is allowed.
            if (tx0 !== 1'b0 || rdata0[0] !== 1'b0) fail("UART0 TX did not start on acceptance");
            for (bitn=0; bitn<10; bitn=bitn+1) begin
                expected = (bitn==0) ? 1'b0 : ((bitn==9) ? 1'b1 : value[bitn-1]);
                if (tx0 !== expected) fail("UART0 serial bit/order mismatch");
                repeat (BAUD) @(posedge clk);
                #1;
            end
            if (tx0 !== 1'b1 || uart0.tx_busy !== 1'b0) fail("UART0 stop completion/ready timing");
        end
    endtask

    task automatic check_tx1_cycles(input [7:0] value, input integer cycles);
        integer bitn;
        reg expected;
        begin
            write1(DATA, value);
            if (tx1 !== 1'b0 || uart1.tx_busy !== 1'b1) fail("UART1 TX did not start on acceptance");
            for (bitn=0; bitn<10; bitn=bitn+1) begin
                expected = (bitn==0) ? 1'b0 : ((bitn==9) ? 1'b1 : value[bitn-1]);
                if (tx1 !== expected) fail("UART1 serial bit/order mismatch");
                repeat (cycles) @(posedge clk);
                #1;
            end
            if (tx1 !== 1'b1 || uart1.tx_busy !== 1'b0) fail("UART1 stop completion/ready timing");
        end
    endtask

    task automatic check_tx1(input [7:0] value);
        begin check_tx1_cycles(value,BAUD); end
    endtask

    task automatic send_rx0_cycles(input [7:0] value, input stop_value,
                                    input integer phase, input integer cycles);
        integer bitn;
        begin
            @(negedge clk); #(phase); rx0=0;
            repeat (cycles) @(posedge clk);
            for (bitn=0; bitn<8; bitn=bitn+1) begin
                rx0=value[bitn]; repeat (cycles) @(posedge clk);
            end
            rx0=stop_value;
            if (stop_value) begin
                repeat (cycles+4) @(posedge clk);
            end else begin
                wait (uart0.rx_framing_error);
                @(posedge clk); #1;
            end
            rx0=1;
            repeat (cycles) @(posedge clk);
        end
    endtask

    task automatic send_rx0(input [7:0] value, input stop_value, input integer phase);
        begin send_rx0_cycles(value,stop_value,phase,BAUD); end
    endtask

    task automatic send_rx1_cycles(input [7:0] value, input stop_value,
                                    input integer phase, input integer cycles);
        integer bitn;
        begin
            @(negedge clk); #(phase); rx1=0;
            repeat (cycles) @(posedge clk);
            for (bitn=0; bitn<8; bitn=bitn+1) begin
                rx1=value[bitn]; repeat (cycles) @(posedge clk);
            end
            rx1=stop_value;
            if (stop_value) begin
                repeat (cycles+4) @(posedge clk);
            end else begin
                wait (uart1.rx_framing_error);
                @(posedge clk); #1;
            end
            rx1=1;
            repeat (cycles) @(posedge clk);
        end
    endtask

    task automatic send_rx1(input [7:0] value, input stop_value, input integer phase);
        begin send_rx1_cycles(value,stop_value,phase,BAUD); end
    endtask

    task automatic expect_pop0(input [7:0] expected);
        reg [31:0] d;
        begin
            read0(DATA,d);
            if (d[7:0] !== expected) begin
                $display("UART0 got=%02x expected=%02x count=%0d", d[7:0], expected,
                         uart0.rx_fifo_count);
                fail("UART0 FIFO order/data");
            end
        end
    endtask

    task automatic expect_pop1(input [7:0] expected);
        reg [31:0] d;
        begin
            read1(DATA,d);
            if (d[7:0] !== expected) begin
                $display("UART1 got=%02x expected=%02x count=%0d", d[7:0], expected,
                         uart1.rx_fifo_count);
                fail("UART1 FIFO order/data");
            end
        end
    endtask

    reg [31:0] d;
    integer before_accept;
    initial begin
        repeat (4) @(posedge clk); #1 resetn=1;
        repeat (3) @(posedge clk); #1;
        if (tx0 !== 1 || tx1 !== 1 || !ready0 || !ready1) fail("reset idle/ready");
        read0(BAUD_REG,d); if (d!==434) fail("UART0 reset BAUD");
        read1(BAUD_REG,d); if (d!==434) fail("UART1 reset BAUD");

        // CONTROL is RAZ/WI; only full canonical offsets decode locally.
        write0(CONTROL,32'hffff_ffff); read0(CONTROL,d); if (d!==0) fail("UART0 CONTROL RAZ/WI");
        write1(CONTROL,32'hffff_ffff); read1(CONTROL,d); if (d!==0) fail("UART1 CONTROL RAZ/WI");
        write0(BAUD_REG,BAUD); write1(BAUD_REG,BAUD);
        write0(BAUD_REG,434); read0(BAUD_REG,d); if (d!==434) fail("UART0 valid BAUD 434");
        write0(BAUD_REG,300); read0(BAUD_REG,d); if (d!==300) fail("UART0 representative BAUD");
        write0(BAUD_REG,65535); read0(BAUD_REG,d); if (d!==65535) fail("UART0 valid BAUD maximum");
        write0(BAUD_REG,BAUD);
        write0(BAUD_REG,0); write0(BAUD_REG,1); write0(BAUD_REG,216);
        read0(BAUD_REG,d); if (d!==BAUD) fail("UART0 invalid BAUD changed state");
        write1(BAUD_REG,0); write1(BAUD_REG,1); write1(BAUD_REG,216);
        read1(BAUD_REG,d); if (d!==BAUD) fail("UART1 invalid BAUD changed state");
        // Local noncanonical offsets are not register mirrors.
        write0(32'h10,32'hffff); read0(32'h10,d); if (d!==0) fail("UART0 0x10 local alias");
        write0(32'h14,32'hffff); read0(32'h14,d); if (d!==0) fail("UART0 0x14 local alias");
        write1(32'h18,32'hffff); read1(32'h18,d); if (d!==0) fail("UART1 0x18 local alias");
        write1(32'h1c,32'hffff); read1(32'h1c,d); if (d!==0) fail("UART1 0x1c local alias");
        check_tx0(8'h00); check_tx0(8'hff); check_tx0(8'ha5);
        check_tx1(8'h00); check_tx1(8'hff); check_tx1(8'h5a);
        write1(BAUD_REG,434); check_tx1_cycles(8'h96,434); write1(BAUD_REG,BAUD);

        // Mid-frame BAUD writes update programmed state, not the active TX frame.
        write0(BAUD_REG,BAUD); write0(DATA,8'h3c);
        repeat (BAUD+20) @(posedge clk); write0(BAUD_REG,300);
        if (uart0.tx_active_baud_div !== BAUD) fail("UART0 TX active BAUD changed mid-frame");
        wait (!uart0.tx_busy); read0(BAUD_REG,d); if (d!==300) fail("UART0 programmed BAUD visibility");
        write0(BAUD_REG,BAUD);

        // RX active divisor is frozen for a frame; the following frame uses B.
        fork
            send_rx0_cycles(8'h69,1,2,BAUD);
            begin
                wait (uart0.rx_state==2); write0(BAUD_REG,300);
                if (uart0.rx_active_baud_div!==BAUD) fail("UART0 RX active BAUD changed mid-frame");
            end
        join
        expect_pop0(8'h69);
        send_rx0_cycles(8'h96,1,4,300); expect_pop0(8'h96);
        write0(BAUD_REG,BAUD);

        // Busy DATA access must remain held and be accepted exactly once when free.
        before_accept=accept1;
        write1(DATA,8'h12);
        repeat (20) @(posedge clk);
        @(negedge clk); addr=DATA; wdata=8'h34; write=1; sel1=1; enable=1;
        repeat (20) begin @(posedge clk); #1; if (ready1) fail("UART1 PREADY rose while busy"); end
        wait (ready1); @(posedge clk); #1; idle_bus();
        wait (!uart1.tx_busy);
        if (accept1-before_accept != 2) fail("UART1 busy transfer lost/duplicated");

        before_accept=accept0;
        write0(DATA,8'h56);
        repeat (20) @(posedge clk);
        @(negedge clk); addr=DATA; wdata=8'h78; write=1; sel0=1; sel1=0; enable=1;
        repeat (20) begin @(posedge clk); #1; if (ready0) fail("UART0 PREADY rose while busy"); end
        wait (ready0); @(posedge clk); #1; idle_bus();
        wait (!uart0.tx_busy);
        if (accept0-before_accept != 2) fail("UART0 busy transfer lost/duplicated");

        // Basic RX, selected phase offsets, back-to-back FIFO ordering.
        send_rx0(8'h00,1,1); send_rx0(8'hff,1,7); send_rx0(8'ha5,1,3);
        expect_pop0(8'h00); expect_pop0(8'hff); expect_pop0(8'ha5);
        send_rx1(8'h00,1,2); send_rx1(8'hff,1,8); send_rx1(8'h5a,1,4);
        expect_pop1(8'h00); expect_pop1(8'hff); expect_pop1(8'h5a);

        // Empty read is zero and has no state/error side effect after activity.
        read0(DATA,d); if (d!==0 || uart0.rx_fifo_count!==0) fail("UART0 empty DATA semantics");
        read1(DATA,d); if (d!==0 || uart1.rx_fifo_count!==0) fail("UART1 empty DATA semantics");

        // False start: return high before midpoint confirmation.
        @(negedge clk); rx0=0; repeat (20) @(posedge clk); rx0=1;
        repeat (BAUD) @(posedge clk);
        if (uart0.rx_fifo_count!==0 || uart0.rx_error) fail("false start handling");

        // UART0 framing error is not committed.  The sticky indication survives
        // STATUS bit2=0, a normal STATUS read, a later good push, and its pop.
        send_rx0(8'h66,0,0); if (!uart0.rx_error || uart0.rx_fifo_count!==0) fail("UART0 framing error set/no commit");
        wait (uart0.rx_state==0 && uart0.rx_sync_2==1); repeat (3) @(posedge clk);
        read0(STATUS,d); if (!d[2] || !uart0.rx_error) fail("UART0 STATUS read cleared sticky error");
        write0(STATUS,0); if (!uart0.rx_error) fail("UART0 STATUS bit2=0 cleared sticky error");
        send_rx0(8'h77,1,0); if (!uart0.rx_error) fail("UART0 successful RX cleared sticky error");
        expect_pop0(8'h77); if (!uart0.rx_error) fail("UART0 DATA pop cleared sticky error");
        write0(STATUS,4); if (uart0.rx_error) fail("UART0 RX_ERROR W1C");

        // UART1 receives the same explicit framing/sticky/W1C coverage.
        send_rx1(8'h86,0,0); if (!uart1.rx_error || uart1.rx_fifo_count!==0) fail("UART1 framing error set/no commit");
        wait (uart1.rx_state==0 && uart1.rx_sync_2==1); repeat (3) @(posedge clk);
        read1(STATUS,d); if (!d[2] || !uart1.rx_error) fail("UART1 STATUS read cleared sticky error");
        write1(STATUS,0); if (!uart1.rx_error) fail("UART1 STATUS bit2=0 cleared sticky error");
        send_rx1(8'h97,1,0); if (!uart1.rx_error) fail("UART1 successful RX cleared sticky error");
        expect_pop1(8'h97); if (!uart1.rx_error) fail("UART1 DATA pop cleared sticky error");
        write1(STATUS,4); if (uart1.rx_error) fail("UART1 RX_ERROR W1C");

        // UART0 fill/full/overflow: the seventeenth byte is dropped and the
        // original sixteen bytes remain in exact order.
        for (i=0;i<16;i=i+1) send_rx0(8'h40+i[7:0],1,i%5);
        if (uart0.rx_fifo_count!==16) fail("UART0 FIFO full count");
        send_rx0(8'hed,1,0);
        if (uart0.rx_fifo_count!==16 || !uart0.rx_error) fail("UART0 overflow/drop/error");
        write0(STATUS,0); if (!uart0.rx_error) fail("UART0 overflow error cleared by bit2=0");
        for (i=0;i<16;i=i+1) expect_pop0(8'h40+i[7:0]);
        if (uart0.rx_fifo_count!==0 || !uart0.rx_error) fail("UART0 overflow drain/sticky retention");
        read0(STATUS,d); if (!d[2] || !uart0.rx_error) fail("UART0 overflow STATUS read retention");
        write0(STATUS,4); if (uart0.rx_error) fail("UART0 overflow RX_ERROR W1C");

        // UART1 receives the same full/overflow/preservation coverage.
        for (i=0;i<16;i=i+1) send_rx1(8'h80+i[7:0],1,i%5);
        if (uart1.rx_fifo_count!==16) fail("UART1 FIFO full count");
        send_rx1(8'hee,1,0);
        if (uart1.rx_fifo_count!==16 || !uart1.rx_error) fail("UART1 overflow/drop/error");
        write1(STATUS,0); if (!uart1.rx_error) fail("UART1 overflow error cleared by bit2=0");
        for (i=0;i<16;i=i+1) expect_pop1(8'h80+i[7:0]);
        if (uart1.rx_fifo_count!==0 || !uart1.rx_error) fail("UART1 overflow drain/sticky retention");
        read1(STATUS,d); if (!d[2] || !uart1.rx_error) fail("UART1 overflow STATUS read retention");
        write1(STATUS,4); if (uart1.rx_error) fail("UART1 overflow RX_ERROR W1C");

        // Actual framing errors on both instances are followed by reset.  FIFO
        // count zero is the architectural validity indication after reset.
        send_rx0(8'ha6,0,0);
        wait (uart0.rx_state==0 && uart0.rx_sync_2==1); repeat (3) @(posedge clk);
        send_rx1(8'hb6,0,0);
        wait (uart1.rx_state==0 && uart1.rx_sync_2==1); repeat (3) @(posedge clk);
        if (!uart0.rx_error || !uart1.rx_error) fail("dual-UART pre-reset error setup");
        #1 resetn=0; #1;
        if (uart0.rx_error || uart1.rx_error ||
            uart0.rx_fifo_count!==0 || uart1.rx_fifo_count!==0)
            fail("dual-UART reset did not clear error/FIFO validity");
        repeat (2) @(posedge clk); #1 resetn=1; repeat (3) @(posedge clk);
        write0(BAUD_REG,BAUD); write1(BAUD_REG,BAUD);

        // Deterministic same-edge push/pop collision (nonempty).
        uart0.rx_fifo[0]=8'h11; uart0.rx_fifo_rd_ptr=0; uart0.rx_fifo_wr_ptr=1; uart0.rx_fifo_count=1;
        uart0.rx_shifter=8'h22; uart0.rx_state=3; uart0.rx_active_baud_div=BAUD;
        uart0.rx_baud_cnt=BAUD-1; rx0=1; uart0.rx_sync_1=1; uart0.rx_sync_2=1;
        addr=DATA; write=0; sel0=1; enable=1; #1;
        if (rdata0[7:0]!==8'h11) fail("push/pop returned wrong front");
        @(posedge clk); #1; idle_bus();
        if (uart0.rx_fifo_count!==1 || uart0.rx_fifo[uart0.rx_fifo_rd_ptr]!==8'h22)
            fail("nonempty push/pop collision");
        expect_pop0(8'h22);

        // Empty read + push returns zero and leaves the new byte queued.
        uart0.rx_fifo_count=0; uart0.rx_fifo_rd_ptr=0; uart0.rx_fifo_wr_ptr=0;
        uart0.rx_shifter=8'h33; uart0.rx_state=3; uart0.rx_baud_cnt=BAUD-1;
        addr=DATA; write=0; sel0=1; enable=1; #1;
        if (rdata0!==0) fail("empty-read/push did not return zero");
        @(posedge clk); #1; idle_bus();
        if (uart0.rx_fifo_count!==1) fail("empty-read consumed same-edge push");
        expect_pop0(8'h33);

        // Full + pop permits replacement push without overflow.
        uart0.rx_fifo_count=16; uart0.rx_fifo_rd_ptr=0; uart0.rx_fifo_wr_ptr=0;
        for (i=0;i<16;i=i+1) uart0.rx_fifo[i]=i[7:0];
        uart0.rx_shifter=8'h44; uart0.rx_state=3; uart0.rx_baud_cnt=BAUD-1; uart0.rx_error=0;
        addr=DATA; write=0; sel0=1; enable=1;
        @(posedge clk); #1; idle_bus();
        if (uart0.rx_fifo_count!==16 || uart0.rx_error) fail("full+pop replacement collision");
        for (i=1;i<16;i=i+1) expect_pop0(i[7:0]); expect_pop0(8'h44);

        // Controlled STOP-state setup aligns a real framing-error event and a
        // completed STATUS[2] W1C on the same PCLK edge.  This exercises the
        // production priority logic but is not an end-to-end serial frame.
        @(negedge clk);
        uart0.rx_error=0; uart0.rx_state=3; uart0.rx_active_baud_div=BAUD;
        uart0.rx_baud_cnt=BAUD-1; rx0=0; uart0.rx_sync_1=0; uart0.rx_sync_2=0;
        addr=STATUS; wdata=4; write=1; sel0=1; enable=1;
        @(posedge clk); #1; idle_bus(); rx0=1;
        if (!uart0.rx_error) fail("UART0 error/W1C collision was not set-dominant");
        write0(STATUS,4);
        wait (uart0.rx_state==0 && uart0.rx_sync_2==1); repeat (3) @(posedge clk);

        @(negedge clk);
        uart1.rx_error=0; uart1.rx_state=3; uart1.rx_active_baud_div=BAUD;
        uart1.rx_baud_cnt=BAUD-1; rx1=0; uart1.rx_sync_1=0; uart1.rx_sync_2=0;
        addr=STATUS; wdata=4; write=1; sel1=1; enable=1;
        @(posedge clk); #1; idle_bus(); rx1=1;
        if (!uart1.rx_error) fail("UART1 error/W1C collision was not set-dominant");
        write1(STATUS,4);
        wait (uart1.rx_state==0 && uart1.rx_sync_2==1); repeat (3) @(posedge clk);

        // Full-duplex exercise with different direction-active divisor epochs.
        write0(BAUD_REG,BAUD); write0(DATA,8'hc3);
        repeat (30) @(posedge clk); write0(BAUD_REG,300);
        if (uart0.programmed_baud_div!==300) fail("concurrent programmed BAUD setup");
        fork
            begin send_rx0_cycles(8'h3c,1,5,300); expect_pop0(8'h3c); end
            begin
                wait (uart0.rx_state==2);
                if (uart0.tx_active_baud_div!==BAUD || uart0.rx_active_baud_div!==300) begin
                    $display("active baud tx=%0d rx=%0d busy=%b state=%0d",
                             uart0.tx_active_baud_div,uart0.rx_active_baud_div,
                             uart0.tx_busy,uart0.rx_state);
                    fail("independent TX/RX active BAUD epochs");
                end
                write0(BAUD_REG,434);
                if (uart0.tx_active_baud_div!==BAUD || uart0.rx_active_baud_div!==300)
                    fail("concurrent mid-frame BAUD isolation");
                wait (!uart0.tx_busy);
            end
        join
        // Reset while TX DATA ACCESS is stalled aborts the active frame and
        // releases the held local APB access into the reset state.
        write0(BAUD_REG,BAUD); write0(DATA,8'h55);
        @(negedge clk); addr=DATA; wdata=8'haa; write=1; sel0=1; enable=1;
        repeat (20) @(posedge clk); if (ready0) fail("stalled write was not held");
        #1 resetn=0; #1;
        if (tx0!==1 || !ready0 || uart0.rx_fifo_count!==0 || uart0.rx_error)
            fail("stalled-access reset abort/safe idle");
        idle_bus(); rx0=1; repeat (3) @(posedge clk); #1 resetn=1; repeat (3) @(posedge clk);

        // Repeat reset with pending FIFO/error state remains deterministic.
        uart0.rx_fifo_count=1; uart0.rx_error=1; #1 resetn=0; #1;
        if (uart0.rx_fifo_count!==0 || uart0.rx_error || tx0!==1) fail("repeat reset state");
        repeat (2) @(posedge clk); #1 resetn=1; repeat (3) @(posedge clk);

        aux=1; repeat (3) @(posedge clk); #1;
        read0(STATUS,d); if (!d[3]) fail("LoRa AUX synchronized high-ready level");

        $display("SUMMARY: PASS P07B dual-UART direct APB/serial verification");
        $finish;
    end
endmodule
