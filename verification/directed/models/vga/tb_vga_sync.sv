`timescale 1ns/1ps
module tb_vga_sync;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire hs, vs, video_on;
    wire [9:0] h, v;
    integer pixels;
    integer hs_low;
    integer vs_low;
    integer visible;

    always #5 clk = ~clk;
    VGA_SyncGen dut (
        .iRSTn(rst_n), .iPCLK(clk), .oHS(hs), .oVS(vs),
        .oHCNT(h), .oVCNT(v), .oVideoOn(video_on)
    );

    initial begin
        #12; rst_n = 1'b1;
        pixels = 0; hs_low = 0; vs_low = 0; visible = 0;
        repeat (800*525) begin
            @(posedge clk); #1;
            if (h > 799 || v > 524) $fatal(1, "counter range");
            if (video_on !== ((h < 640) && (v < 480))) $fatal(1, "video window");
            if (hs !== ~((h >= 656) && (h < 752))) $fatal(1, "HS window");
            if (vs !== ~((v >= 490) && (v < 492))) $fatal(1, "VS window");
            pixels = pixels + 1;
            if (!hs) hs_low = hs_low + 1;
            if (!vs) vs_low = vs_low + 1;
            if (video_on) visible = visible + 1;
        end
        if (h != 0 || v != 0) $fatal(1, "frame rollover");
        if (hs_low != 96*525) $fatal(1, "HS pulse total %0d", hs_low);
        if (vs_low != 2*800) $fatal(1, "VS pulse total %0d", vs_low);
        if (visible != 640*480) $fatal(1, "visible total %0d", visible);
        $display("SUMMARY: PASS VGA sync");
        $finish;
    end
endmodule
