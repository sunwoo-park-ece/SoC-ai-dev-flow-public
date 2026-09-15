`timescale 1ns/1ps
module tb_gsensor_single_pclk;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg [2:1] sensor_int = 2'b00;
    reg sensor_sdo = 1'b0;
    reg [31:0] paddr = 32'd0;
    reg pwrite = 1'b0, psel = 1'b0, penable = 1'b0;
    wire [31:0] prdata;
    wire pready, cs_n, sclk, mosi;
    wire [15:0] debug_x, debug_y;
    reg [15:0] expected_init [0:10];
    integer transaction;
    integer ready_count = 0;
    integer observed_fall_edges = 0;
    integer observed_rise_edges = 0;
    time last_pclk_edge = 0;
    time last_tick_edge = 0;
    time last_sclk_change = 0;

    always #10 clk = ~clk;

    APB_GSENSOR_MB #(.RESET_DELAY_BITS(3), .POLL_BITS(8)) dut (
        .PCLK(clk), .PRESETn(reset_n), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(32'd0), .PRDATA(prdata),
        .PREADY(pready), .GSENSOR_CS_N(cs_n), .GSENSOR_INT(sensor_int),
        .GSENSOR_SCLK(sclk), .GSENSOR_SDI(mosi), .GSENSOR_SDO(sensor_sdo),
        .debug_acc_x(debug_x), .debug_acc_y(debug_y)
    );

    always @(posedge clk) begin
        last_pclk_edge = $time;
        if (dut.u_spi_ee_config.state == 2'd1 &&
            dut.u_spi_ee_config.half_count == (sclk ? 4'd11 : 4'd12))
            last_tick_edge = $time;
        #2;
        if (dut.u_spi_ee_config.gsensor_ready)
            ready_count = ready_count + 1;
    end

    always @(sclk) begin
        if (reset_n && !dut.dly_rst && $time > 0) begin
            if (cs_n === 1'b1)
                $fatal(1, "SCLK changed while CS was inactive");
            if ($time != last_pclk_edge || $time != last_tick_edge)
                $fatal(1, "SCLK changed outside PCLK/tick edge at %0t", $time);
            if ($time == last_sclk_change)
                $fatal(1, "double SCLK toggle on one PCLK edge");
            last_sclk_change = $time;
        end
    end
    always @(cs_n) begin
        if (reset_n && !dut.dly_rst && $time > 0 &&
            $time != last_pclk_edge)
            $fatal(1, "CS changed outside PCLK edge");
    end
    always @(negedge cs_n) begin
        observed_fall_edges = 0;
        observed_rise_edges = 0;
    end
    always @(negedge sclk)
        if (cs_n === 1'b0)
            observed_fall_edges = observed_fall_edges + 1;
    always @(posedge sclk)
        if (cs_n === 1'b0)
            observed_rise_edges = observed_rise_edges + 1;

    task automatic check_apb(input [31:0] address, input [31:0] expected);
        begin
            @(negedge clk);
            paddr = address;
            psel = 1'b1;
            penable = 1'b1;
            pwrite = 1'b0;
            #1;
            if (pready !== 1'b1 || prdata !== expected)
                $fatal(1, "APB read %h got=%h expected=%h", address, prdata, expected);
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            #1;
            if (prdata !== 32'd0)
                $fatal(1, "APB idle read data not zero");
        end
    endtask

    task automatic capture_transaction(
        input integer bits,
        input [55:0] expected_tx,
        input [55:0] response_frame,
        input bit check_previous
    );
        integer n;
        time previous_edge;
        reg [55:0] observed_tx;
        reg [47:0] observed_rx;
        begin
            @(negedge cs_n);
            if (sclk !== 1'b1)
                $fatal(1, "Mode-3 SCLK not high at CS assertion");
            observed_tx = 56'd0;
            observed_rx = 48'd0;
            previous_edge = $time;
            for (n = 0; n < bits; n = n + 1) begin
                @(negedge sclk);
                if (($time - previous_edge) != 240)
                    $fatal(1, "high SCLK half-period was %0t ns", $time - previous_edge);
                previous_edge = $time;
                #1;
                if (cs_n !== 1'b0 || mosi !== expected_tx[bits-1-n])
                    $fatal(1, "transaction MOSI bit %0d got=%b expected=%b",
                           n, mosi, expected_tx[bits-1-n]);
                if (bits == 56 && n >= 8) begin
                    // Poison early sampling, then present the intended bit
                    // only just before the rising sample edge.
                    sensor_sdo = ~response_frame[55-n];
                    #250;
                    sensor_sdo = response_frame[55-n];
                end else
                    sensor_sdo = 1'b0;
                @(posedge sclk);
                if (($time - previous_edge) != 260)
                    $fatal(1, "low SCLK half-period was %0t ns", $time - previous_edge);
                previous_edge = $time;
                #1;
                if (mosi !== expected_tx[bits-1-n] || cs_n !== 1'b0)
                    $fatal(1, "MOSI or CS changed on sample edge %0d", n);
                observed_tx = {observed_tx[54:0], mosi};
                if (bits == 56 && n >= 8) begin
                    observed_rx = {observed_rx[46:0], sensor_sdo};
                    // Poison a late sample as well. This digital edge test
                    // does not establish the physical ADXL345 setup margin.
                    sensor_sdo = ~response_frame[55-n];
                end
                if (n == bits-1 && bits == 56 &&
                    dut.u_spi_ee_config.gsensor_ready !== 1'b1)
                    $fatal(1, "read completion did not pulse ready");
                if (n == 20 && check_previous) begin
                    check_apb(32'h0, 32'h1234_5678);
                    check_apb(32'h4, 32'h0000_9abc);
                end
            end
            if (sclk !== 1'b1 || cs_n !== 1'b0)
                $fatal(1, "last sample did not retain CS");
            @(posedge cs_n);
            if (($time - previous_edge) != 240 || sclk !== 1'b1)
                $fatal(1, "CS hold or idle SCLK invalid");
            #1;
            if (observed_fall_edges != bits || observed_rise_edges != bits)
                $fatal(1, "SPI edge count fall=%0d rise=%0d expected=%0d",
                       observed_fall_edges, observed_rise_edges, bits);
            if (observed_tx !== expected_tx)
                $fatal(1, "SPI TX stream got=%014h expected=%014h",
                       observed_tx, expected_tx);
            if (bits == 56 && observed_rx !== response_frame[47:0])
                $fatal(1, "SPI RX stimulus got=%012h expected=%012h",
                       observed_rx, response_frame[47:0]);
            if (bits == 56)
                $display("TRACE SPI001 read bits=56 tx=%014h rx=%012h fall/rise=%0d/%0d",
                         observed_tx, observed_rx, observed_fall_edges,
                         observed_rise_edges);
            else
                $display("TRACE SPI001 write bits=16 tx=%04h fall/rise=%0d/%0d",
                         observed_tx[15:0], observed_fall_edges,
                         observed_rise_edges);
        end
    endtask

    initial begin
        expected_init[0]=16'h2420; expected_init[1]=16'h2503;
        expected_init[2]=16'h2601; expected_init[3]=16'h277f;
        expected_init[4]=16'h2809; expected_init[5]=16'h2946;
        expected_init[6]=16'h2c09; expected_init[7]=16'h2e00;
        expected_init[8]=16'h2f00; expected_init[9]=16'h3100;
        expected_init[10]=16'h2d08;

        @(posedge clk); #1;
        if (cs_n !== 1'b1 || sclk !== 1'b1 || mosi !== 1'b0 ||
            dut.u_spi_ee_config.state !== 2'd0 ||
            dut.u_spi_ee_config.int_meta !== 1'b0 ||
            dut.u_spi_ee_config.int_sync !== 1'b0 ||
            debug_x !== 16'd0 || debug_y !== 16'd0)
            $fatal(1, "unsafe reset state");
        @(negedge clk);
        reset_n = 1'b1;
        repeat (7) @(posedge clk);
        #1;
        if (dut.dly_rst !== 1'b1)
            $fatal(1, "local reset released early");
        @(posedge clk);
        #1;
        if (dut.dly_rst !== 1'b0)
            $fatal(1, "local reset did not release");

        for (transaction = 0; transaction < 11; transaction = transaction + 1)
            capture_transaction(16, {40'd0, expected_init[transaction]}, 56'd0, 1'b0);
        if (dut.u_spi_ee_config.init_index != 4'd11)
            $fatal(1, "init did not complete exactly 11 writes");

        // Raw INT is asynchronous. The second synchronizer FF remains low
        // on the first PCLK edge and becomes high on the second.
        @(negedge clk); #2;
        sensor_int[1] = 1'b1;
        @(posedge clk); #1;
        if (dut.u_spi_ee_config.int_meta !== 1'b1 ||
            dut.u_spi_ee_config.int_sync !== 1'b0 || cs_n !== 1'b1)
            $fatal(1, "raw INT bypassed first synchronizer stage");
        @(posedge clk); #1;
        if (dut.u_spi_ee_config.int_sync !== 1'b1 || cs_n !== 1'b1)
            $fatal(1, "INT second stage latency wrong");
        fork
            begin
                @(negedge cs_n);
                sensor_int[1] = 1'b0;
            end
            capture_transaction(56, {8'hf2, 48'd0},
                                {8'h00, 48'h3412_7856_bc9a}, 1'b0);
        join
        if (ready_count != 1 || debug_x !== 16'h1234 || debug_y !== 16'h5678)
            $fatal(1, "first XYZ publication or ready count wrong");
        check_apb(32'h0, 32'h1234_5678);
        check_apb(32'h4, 32'h0000_9abc);
        check_apb(32'h8, 32'h0000_0000);
        psel = 1'b1; penable = 1'b1; pwrite = 1'b1; paddr = 32'h0;
        #1;
        if (pready !== 1'b1 || prdata !== 32'd0)
            $fatal(1, "APB write behavior changed");
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0;

        // A second trigger must retain the previous completed APB value
        // until the next 56-bit sample has fully arrived.
        @(negedge clk); #2;
        sensor_int[1] = 1'b1;
        fork
            begin
                @(negedge cs_n);
                sensor_int[1] = 1'b0;
            end
            capture_transaction(56, {8'hf2, 48'd0},
                                {8'h00, 48'h7856_3412_efcd}, 1'b1);
        join
        if (ready_count != 2)
            $fatal(1, "second sample ready count wrong");
        check_apb(32'h0, 32'h5678_1234);
        check_apb(32'h4, 32'h0000_cdef);

        // With INT low, the 2 MHz-equivalent poll tick must cause a
        // subsequent complete transfer without CPU/APB intervention.
        capture_transaction(56, {8'hf2, 48'd0},
                            {8'h00, 48'h3412_7856_bc9a}, 1'b0);
        if (ready_count != 3)
            $fatal(1, "periodic fallback did not produce third sample");
        check_apb(32'h0, 32'h1234_5678);
        check_apb(32'h4, 32'h0000_9abc);

        // Abort a fourth read in flight, not merely an idle controller.
        @(negedge clk); #2;
        sensor_int[1] = 1'b1;
        @(negedge cs_n);
        sensor_int[1] = 1'b0;
        repeat (3) @(posedge sclk);
        @(negedge clk);
        reset_n = 1'b0;
        #1;
        if (cs_n !== 1'b1 || sclk !== 1'b1 || mosi !== 1'b0 ||
            dut.u_spi_ee_config.state !== 2'd0 ||
            dut.u_spi_ee_config.gsensor_ready !== 1'b0 ||
            dut.u_spi_ee_config.int_meta !== 1'b0 ||
            dut.u_spi_ee_config.int_sync !== 1'b0 ||
            debug_x !== 16'd0 || debug_y !== 16'd0)
            $fatal(1, "mid-run reset left stale SPI/sensor state");
        repeat (3) @(posedge clk);
        #1;
        if (cs_n !== 1'b1 || sclk !== 1'b1 || ready_count != 3)
            $fatal(1, "aborted transfer leaked while reset held");
        $display("TRACE SPI001 in-flight reset abort: CS/SCLK idle, no ready");
        @(negedge clk);
        reset_n = 1'b1;
        capture_transaction(16, {40'd0, 16'h2420}, 56'd0, 1'b0);
        if (dut.u_spi_ee_config.init_index != 4'd1)
            $fatal(1, "reset did not restart initialization at first word");
        $display("TRACE SPI001 reset restart: first init word 2420");
        $display("SUMMARY: PASS GSensor single-PCLK Mode-3/APB/INT/poll");
        $finish;
    end

    initial begin
        #600000;
        $fatal(1, "GSensor single-PCLK directed test timeout");
    end
endmodule
