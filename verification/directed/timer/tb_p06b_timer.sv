`timescale 1ns/1ps

module tb_p06b_timer;
    localparam logic [31:0] CTRL    = 32'h4002_0000;
    localparam logic [31:0] COUNT   = 32'h4002_0004;
    localparam logic [31:0] COMPARE = 32'h4002_0008;
    localparam logic [31:0] STATUS  = 32'h4002_000c;

    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg [31:0] paddr = 32'd0;
    reg psel = 1'b0;
    reg penable = 1'b0;
    reg pwrite = 1'b0;
    reg [31:0] pwdata = 32'd0;
    wire [31:0] prdata;
    wire pready;

    reg [31:0] haddr = 32'd0;
    reg [31:0] hwdata = 32'd0;
    reg hwrite = 1'b0;
    reg hsel = 1'b0;
    reg [1:0] htrans = 2'b00;
    reg [2:0] hsize = 3'b010;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire [31:0] bridge_paddr;
    wire bridge_pwrite;
    wire [15:0] bridge_psel;
    wire bridge_penable;
    wire [31:0] bridge_pwdata;
    wire [31:0] bridge_prdata;
    wire bridge_pready;
    wire bridge_pclk;
    wire bridge_presetn;

    integer case_count = 0;

    always #5 clk = ~clk;

    APB_TIMER dut (
        .PCLK(clk),
        .PRESETn(resetn),
        .PADDR(paddr),
        .PSEL(psel),
        .PENABLE(penable),
        .PWRITE(pwrite),
        .PWDATA(pwdata),
        .PRDATA(prdata),
        .PREADY(pready)
    );

    AHB_APB_bridge bridge (
        .HCLK(clk),
        .HRESETn(resetn),
        .HADDR(haddr),
        .HWRITE(hwrite),
        .HTRANS(htrans),
        .HSIZE(hsize),
        .HWDATA(hwdata),
        .HSEL(hsel),
        .HREADY_IN(hready),
        .HRDATA(hrdata),
        .HREADY(hready),
        .HRESP(hresp),
        .PCLK(bridge_pclk),
        .PRESETn(bridge_presetn),
        .PADDR(bridge_paddr),
        .PWRITE(bridge_pwrite),
        .PSEL(bridge_psel),
        .PENABLE(bridge_penable),
        .PWDATA(bridge_pwdata),
        .PRDATA(bridge_prdata),
        .PREADY(bridge_pready),
        .PSLVERR(1'b0)
    );

    APB_TIMER arch_timer (
        .PCLK(bridge_pclk),
        .PRESETn(bridge_presetn),
        .PADDR(bridge_paddr),
        .PSEL(bridge_psel[2]),
        .PENABLE(bridge_penable),
        .PWRITE(bridge_pwrite),
        .PWDATA(bridge_pwdata),
        .PRDATA(bridge_prdata),
        .PREADY(bridge_pready)
    );

    task automatic apb_write(input logic [31:0] address, input logic [31:0] data);
        begin
            @(negedge clk);
            paddr = address;
            pwdata = data;
            psel = 1'b1;
            penable = 1'b1;
            pwrite = 1'b1;
            @(posedge clk);
            #1;
            if (!pready) $fatal(1, "Timer PREADY deasserted");
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = 32'd0;
            pwdata = 32'd0;
        end
    endtask

    task automatic expect_read(input logic [31:0] address, input logic [31:0] expected);
        begin
            @(negedge clk);
            paddr = address;
            psel = 1'b1;
            penable = 1'b1;
            pwrite = 1'b0;
            #1;
            if (prdata !== expected)
                $fatal(1, "read %h got=%h expected=%h", address, prdata, expected);
            psel = 1'b0;
            penable = 1'b0;
            paddr = 32'd0;
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_state(
        input logic [31:0] expected_count,
        input logic [31:0] expected_programmed,
        input logic [31:0] expected_active,
        input logic expected_running,
        input logic expected_ready
    );
        begin
            if (dut.counter !== expected_count ||
                dut.programmed_compare !== expected_programmed ||
                dut.active_compare !== expected_active ||
                dut.running !== expected_running || dut.ready !== expected_ready)
                $fatal(1,
                    "state count=%h/%h programmed=%h/%h active=%h/%h running=%b/%b ready=%b/%b",
                    dut.counter, expected_count, dut.programmed_compare, expected_programmed,
                    dut.active_compare, expected_active, dut.running, expected_running,
                    dut.ready, expected_ready);
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            resetn = 1'b0;
            #1;
            expect_state(32'd0, 32'd0, 32'd0, 1'b0, 1'b0);
            if (prdata !== 32'd0 || !pready) $fatal(1, "reset outputs");
            repeat (2) @(posedge clk);
            @(negedge clk);
            resetn = 1'b1;
        end
    endtask

    task automatic expect_exact_n(input logic [31:0] n);
        integer i;
        begin
            apb_write(COMPARE, n);
            apb_write(CTRL, 32'h1);
            if (n == 0) begin
                expect_state(0, n, n, 1'b0, 1'b1);
            end else begin
                expect_state(0, n, n, 1'b1, 1'b0);
                for (i = 1; i <= n; i = i + 1) begin
                    tick();
                    if (i < n)
                        expect_state(i, n, n, 1'b1, 1'b0);
                    else
                        expect_state(n, n, n, 1'b0, 1'b1);
                end
            end
            case_count = case_count + 1;
        end
    endtask

    task automatic ahb_expect_error(
        input logic [31:0] address,
        input logic [2:0] size
    );
        begin
            @(negedge clk);
            haddr = address;
            hwdata = 32'hdead_beef;
            hwrite = 1'b1;
            hsize = size;
            hsel = 1'b1;
            htrans = 2'b10;
            @(posedge clk);
            #1;
            if (bridge_psel !== 16'd0 || hready !== 1'b0 || bridge_penable !== 1'b0)
                $fatal(1, "invalid Timer request selected a slave in SETUP");
            @(negedge clk);
            hsel = 1'b0;
            htrans = 2'b00;
            @(posedge clk);
            #1;
            if (bridge_psel !== 16'd0 || bridge_penable !== 1'b1 ||
                hresp !== 2'b01 || hready !== 1'b0)
                $fatal(1, "invalid Timer request missing first ERROR cycle");
            @(posedge clk);
            #1;
            if (bridge_psel !== 16'd0 || hresp !== 2'b01 || hready !== 1'b1)
                $fatal(1, "invalid Timer request missing final ERROR cycle");
            @(posedge clk);
            #1;
            if (hresp !== 2'b00 || hready !== 1'b1)
                $fatal(1, "invalid Timer ERROR did not terminate");
            if (arch_timer.counter !== 0 || arch_timer.programmed_compare !== 0 ||
                arch_timer.active_compare !== 0 || arch_timer.running || arch_timer.ready)
                $fatal(1, "invalid Timer access changed architectural state");
            case_count = case_count + 1;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1;
        if (!pready || bridge_pready !== 1'b1) $fatal(1, "PREADY reset constant");
        resetn = 1'b1;

        // Reset/register contract, COUNT RO, reserved read-zero and local alias removal.
        expect_read(CTRL, 32'd0);
        expect_read(COUNT, 32'd0);
        expect_read(COMPARE, 32'd0);
        expect_read(STATUS, 32'd0);
        apb_write(COUNT, 32'hffff_ffff);
        expect_state(0, 0, 0, 0, 0);
        apb_write(COMPARE, 32'h1234_5678);
        expect_read(COMPARE, 32'h1234_5678);
        apb_write(32'h4002_0018, 32'hdead_beef);
        expect_read(COMPARE, 32'h1234_5678);
        expect_read(32'h4002_0018, 32'd0);
        apb_write(CTRL, 32'hffff_fffc);
        expect_read(CTRL, 32'd0);
        case_count = case_count + 1;

        apply_reset();
        expect_exact_n(0);
        apb_write(STATUS, 32'hffff_ffff);
        expect_state(0, 0, 0, 0, 0);
        expect_exact_n(1);
        apb_write(STATUS, 1);
        expect_exact_n(2);
        apb_write(STATUS, 1);
        expect_exact_n(7);

        // W1C clears only READY and does not restart or clear terminal COUNT.
        apb_write(STATUS, 1);
        expect_state(7, 7, 7, 0, 0);
        tick();
        expect_state(7, 7, 7, 0, 0);
        case_count = case_count + 1;

        // START while READY and repeated START both create a fresh interval.
        apb_write(CTRL, 1);
        expect_state(0, 7, 7, 1, 0);
        tick();
        tick();
        apb_write(CTRL, 1);
        expect_state(0, 7, 7, 1, 0);
        case_count = case_count + 1;

        // STOP wins on an increment edge and preserves COUNT/READY.
        tick();
        expect_state(1, 7, 7, 1, 0);
        apb_write(CTRL, 0);
        expect_state(1, 7, 7, 0, 0);
        tick();
        expect_state(1, 7, 7, 0, 0);

        // START after STOP/nonzero COUNT is fresh.
        apb_write(CTRL, 1);
        expect_state(0, 7, 7, 1, 0);

        // STOP also wins on a would-be terminal edge.
        apb_write(COMPARE, 2);
        apb_write(CTRL, 1);
        tick();
        expect_state(1, 2, 2, 1, 0);
        apb_write(CTRL, 0);
        expect_state(1, 2, 2, 0, 0);
        case_count = case_count + 1;

        // RELOAD clears state, preserves programmed COMPARE, and suppresses counting.
        apb_write(CTRL, 1);
        tick();
        apb_write(CTRL, 2);
        expect_state(0, 2, 2, 0, 0);
        apb_write(CTRL, 3);
        expect_state(0, 2, 2, 1, 0);
        case_count = case_count + 1;

        // Programmed COMPARE changes during a run without changing active COMPARE.
        apply_reset();
        apb_write(COMPARE, 4);
        apb_write(CTRL, 1);
        apb_write(COMPARE, 2);
        expect_state(1, 2, 4, 1, 0);
        tick();
        tick();
        tick();
        expect_state(4, 2, 4, 0, 1);
        apb_write(STATUS, 1);
        apb_write(CTRL, 1);
        tick();
        tick();
        expect_state(2, 2, 2, 0, 1);
        case_count = case_count + 1;

        // Terminal completion is set-dominant over same-edge STATUS W1C.
        apb_write(STATUS, 1);
        apb_write(CTRL, 1);
        tick();
        @(negedge clk);
        paddr = STATUS;
        pwdata = 1;
        psel = 1;
        penable = 1;
        pwrite = 1;
        @(posedge clk);
        #1;
        expect_state(2, 2, 2, 0, 1);
        @(negedge clk);
        psel = 0;
        penable = 0;
        pwrite = 0;
        case_count = case_count + 1;

        // Maximum compare is checked with controlled near-terminal state.
        apb_write(STATUS, 1);
        apb_write(COMPARE, 32'hffff_ffff);
        apb_write(CTRL, 1);
        expect_read(COMPARE, 32'hffff_ffff);
        @(negedge clk);
        dut.counter = 32'hffff_fffd;
        tick();
        expect_state(32'hffff_fffe, 32'hffff_ffff, 32'hffff_ffff, 1, 0);
        tick();
        expect_state(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff, 0, 1);
        tick();
        expect_state(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff, 0, 1);
        case_count = case_count + 1;

        // Reset wins while running, near terminal, and while READY is set.
        apply_reset();
        apb_write(COMPARE, 3);
        apb_write(CTRL, 1);
        tick();
        apply_reset();
        apb_write(COMPARE, 1);
        apb_write(CTRL, 1);
        apply_reset();
        apb_write(COMPARE, 0);
        apb_write(CTRL, 1);
        expect_state(0, 0, 0, 0, 1);
        apply_reset();
        case_count = case_count + 1;

        // Architectural AHB/APB path rejects Timer aliases, misalignment, and size.
        ahb_expect_error(32'h4002_0010, 3'b010);
        ahb_expect_error(32'h4002_0002, 3'b010);
        ahb_expect_error(32'h4002_0008, 3'b001);

        if (case_count < 16) $fatal(1, "insufficient Timer cases: %0d", case_count);
        $display("SUMMARY: PASS P06B Timer directed cases=%0d", case_count);
        $finish;
    end
endmodule
