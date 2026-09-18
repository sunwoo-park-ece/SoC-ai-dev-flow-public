`timescale 1ns/1ps

module tb_p08b_vga;
    reg clock_50 = 0;
    reg hclk = 0;
    reg hresetn = 0;
    reg [31:0] haddr = 0;
    reg hwrite = 0;
    reg [1:0] htrans = 0;
    reg [2:0] hsize = 3'b010;
    reg [31:0] hwdata = 0;
    reg hsel = 0;
    wire [31:0] hrdata;
    wire hready;
    wire [1:0] hresp;
    wire [3:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs;

    integer total_we;
    integer bank0_we;
    integer bank1_we;

    always #5 clock_50 = ~clock_50;
    always #5 hclk = ~hclk;

    AHB_VRAM_DUAL_BUFFER dut (
        .CLOCK_50(clock_50), .HCLK(hclk), .HRESETn(hresetn),
        .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans), .HSIZE(hsize),
        .HWDATA(hwdata), .HSEL(hsel), .HREADY_IN(hready),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b),
        .VGA_HS(vga_hs), .VGA_VS(vga_vs)
    );

    always @(posedge hclk) begin
        if (dut.vram0_we) begin total_we <= total_we + 1; bank0_we <= bank0_we + 1; end
        if (dut.vram1_we) begin total_we <= total_we + 1; bank1_we <= bank1_we + 1; end
        if (dut.vram0_we && dut.vram1_we) $fatal(1, "both VRAM banks written");
        if ((dut.vram0_we && dut.front_bank_p == 0) ||
            (dut.vram1_we && dut.front_bank_p == 1))
            $fatal(1, "displayed front bank modified");
    end

    task automatic ahb_idle;
        begin
            @(negedge hclk);
            hsel = 0; htrans = 0; hwrite = 0; haddr = 0;
            hsize = 3'b010;
        end
    endtask

    task automatic ahb_write_ok(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = 3'b010;
            haddr = addr; hwdata = data;
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b00) $fatal(1, "expected OKAY addr=%h", addr);
            ahb_idle();
            @(posedge hclk); #1;
        end
    endtask

    task automatic ahb_read_ok(input [31:0] addr, output [31:0] data);
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 0; hsize = 3'b010; haddr = addr;
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b00) $fatal(1, "expected read OKAY");
            data = hrdata;
            ahb_idle();
        end
    endtask

    task automatic ahb_write_error(input [31:0] addr, input [2:0] size,
                                   input [31:0] data);
        integer before_we;
        begin
            before_we = total_we;
            @(negedge hclk);
            hsel = 1; htrans = 2'b10; hwrite = 1; hsize = size;
            haddr = addr; hwdata = data;
            @(posedge hclk); #1;
            if (hready || hresp != 2'b01) $fatal(1, "missing ERROR wait cycle");
            if (total_we != before_we) $fatal(1, "write during ERROR wait");
            @(posedge hclk); #1;
            if (!hready || hresp != 2'b01) $fatal(1, "missing ERROR final cycle");
            if (total_we != before_we) $fatal(1, "write during ERROR final");
            ahb_idle();
        end
    endtask

    task automatic wait_ready;
        integer n;
        begin
            n = 0;
            while (!dut.domain_ready && n < 200) begin @(posedge hclk); n = n + 1; end
            if (!dut.domain_ready) $fatal(1, "DOMAIN_READY timeout");
        end
    endtask

    task automatic force_frame_wrap;
        begin
            wait (dut.pending_swap_p == 1'b1);
            force dut.h_cnt = 10'd799;
            force dut.v_cnt = 10'd524;
            @(posedge dut.pclk_25); #1;
            release dut.h_cnt;
            release dut.v_cnt;
        end
    endtask

    task automatic wait_done;
        integer n;
        begin
            n = 0;
            while (!dut.operation_done_sticky && n < 20000) begin
                @(posedge hclk); n = n + 1;
            end
            if (!dut.operation_done_sticky) $fatal(1, "operation timeout");
            if (dut.operation_busy) $fatal(1, "DONE while BUSY");
        end
    endtask

    reg [31:0] status;
    integer before_count;
    integer clear_begin;

    initial begin
        total_we = 0; bank0_we = 0; bank1_we = 0;
        repeat (4) @(posedge hclk);
        hresetn = 1;
        wait_ready();
        $display("P08B_PROGRESS ready t=%0t", $time);

        // First-frame-black invariant.
        force dut.video_on = 1'b1;
        force dut.vram0_q = 1'b1;
        #1;
        if ({vga_r,vga_g,vga_b} != 12'h000) $fatal(1, "display not black before publication");
        release dut.video_on;
        release dut.vram0_q;

        // Canonical write commits exactly once to initial back bank (VRAM1).
        before_count = total_we;
        ahb_write_ok(32'h2000_0000, 32'h55aa_1234);
        if (total_we != before_count + 1 || bank1_we != 1) $fatal(1, "canonical write count/bank");
        $display("P08B_PROGRESS canonical-write t=%0t", $time);

        // Subword, gap and read-direction equivalents are rejected locally.
        ahb_write_error(32'h2000_0004, 3'b000, 32'hdead_beef);
        $display("P08B_PROGRESS subword-error t=%0t", $time);
        ahb_write_error(32'h2000_9600, 3'b010, 32'hdead_beef);
        $display("P08B_PROGRESS gap-error t=%0t", $time);

        // Clear-only: exact 9600 writes, all to stable back bank.
        ahb_write_ok(32'h2001_0000, 32'h0000_000a);
        $display("P08B_PROGRESS status-clear t=%0t", $time);
        clear_begin = total_we;
        ahb_write_ok(32'h2001_0004, 32'h0000_0002);
        $display("P08B_PROGRESS clear-command busy=%b t=%0t", dut.operation_busy, $time);
        wait (dut.operation_busy);
        ahb_write_error(32'h2000_0008, 3'b010, 32'hffff_ffff);
        wait_done();
        $display("P08B_PROGRESS clear-only t=%0t", $time);
        if (total_we - clear_begin != 9600) $fatal(1, "clear count=%0d", total_we-clear_begin);
        if (dut.u_cleaner.clr_addr != 14'd9599) $fatal(1, "clear last address");

        // Swap-only commits once at frame wrap and arms display.
        ahb_write_ok(32'h2001_0000, 32'h0000_0002);
        ahb_write_ok(32'h2001_0004, 32'h0000_0001);
        fork
            force_frame_wrap();
            wait_done();
        join
        $display("P08B_PROGRESS swap-only t=%0t", $time);
        if (dut.front_bank_h != 1 || dut.front_bank_p != 1)
            $fatal(1, "swap ownership mismatch");
        if (!dut.display_armed_p) $fatal(1, "display not armed after swap");

        // Combined operation swaps first, then clears old-front/new-back.
        ahb_write_ok(32'h2001_0000, 32'h0000_0002);
        clear_begin = total_we;
        ahb_write_ok(32'h2001_0004, 32'h0000_0003);
        fork
            force_frame_wrap();
            wait_done();
        join
        $display("P08B_PROGRESS combined t=%0t", $time);
        if (total_we - clear_begin != 9600) $fatal(1, "combined clear count");
        if (dut.front_bank_h != 0 || dut.front_bank_p != 0)
            $fatal(1, "combined ownership mismatch");

        // W1C set dominance.
        force dut.vsync_event = 1'b1;
        ahb_write_ok(32'h2001_0000, 32'h0000_0001);
        release dut.vsync_event;
        if (!dut.vsync_sticky) $fatal(1, "event did not dominate W1C");

        // PLL loss aborts an active clear, gates writes, and recovers fixed ownership.
        ahb_write_ok(32'h2001_0000, 32'h0000_000b);
        ahb_write_ok(32'h2001_0004, 32'h0000_0002);
        wait (dut.clear_busy);
        repeat (5) @(posedge hclk);
        dut.U_PLL.inject_lock_loss();
        #1;
        before_count = total_we;
        repeat (12) @(posedge hclk);
        if (total_we != before_count) $fatal(1, "write continued after PLL loss");
        if (!dut.operation_abort_sticky || dut.operation_busy)
            $fatal(1, "abort status incorrect");
        wait_ready();
        $display("P08B_PROGRESS recovery t=%0t", $time);
        if (dut.front_bank_h != 0 || dut.front_bank_p != 0)
            $fatal(1, "recovery ownership not rebased");
        if (dut.display_armed_p) $fatal(1, "display remained armed after recovery");

        ahb_read_ok(32'h2001_0000, status);
        if (!status[4] || !status[3]) $fatal(1, "final status=%h", status);

        $display("SUMMARY: PASS P08B VGA focused RTL");
        $finish;
    end
endmodule
