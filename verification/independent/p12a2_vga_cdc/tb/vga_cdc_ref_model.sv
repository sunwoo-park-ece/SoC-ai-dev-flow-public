`timescale 1ns/1ps
// Contract-derived external timing observer. No DUT counter/reset-release or
// request/ACK synchronizer is copied. The first HS after each reset establishes
// x656,line0; all later coordinates advance independently and pins are checked.
module vga_cdc_ref_model (
    input wire pclk_25, hresetn, pll_locked, vga_hs, vga_vs,
    output reg [9:0] pixel_x, pixel_y,
    output reg timing_valid
);
    reg previous_hs=1;
    reg timing_fault;
    initial begin
        pixel_x=0; pixel_y=0; timing_valid=0;
        timing_fault=$test$plusargs("TIMING_OBSERVATION_FAULT");
    end
    always @(negedge hresetn or negedge pll_locked) begin
        pixel_x=0; pixel_y=0; timing_valid=0; previous_hs=1;
    end
    always @(posedge pclk_25) begin : external_timing
        reg observed_hs;
        // Sample pins after their combinational propagation from pixel edges.
        // Scoreboard samples pre-edge coordinates; this block publishes post-edge.
        #0.002;
        if (hresetn && pll_locked) begin
            if (!timing_valid) begin
                if (previous_hs && !vga_hs) begin
                    pixel_x=656; pixel_y=0; timing_valid=1;
                    $display("[TIMING_ANCHOR] first external HS x=656 y=0 time=%0t",$time);
                end
            end else begin
                if (pixel_x==799) begin
                    pixel_x=0; pixel_y=(pixel_y==524)?0:pixel_y+1;
                end else pixel_x=pixel_x+1;
                observed_hs=vga_hs;
                if (timing_fault && pixel_x==700) begin
                    observed_hs=~vga_hs;
                    $display("[FAULT_ACTIVATION] TIMING_OBSERVATION_FAULT x=700 actual_hs=%b adapted_hs=%b",vga_hs,observed_hs);
                end
                if (observed_hs !== !((pixel_x>=656) && (pixel_x<752)) ||
                    vga_vs !== !((pixel_y>=490) && (pixel_y<492))) begin
                    $display("[ASSERT_FAIL] id=FAIL_EXTERNAL_TIMING x=%0d y=%0d hs=%b vs=%b",pixel_x,pixel_y,observed_hs,vga_vs);
                    $fatal(1,"External timing contract mismatch");
                end
                if (pixel_x==0 && pixel_y==492)
                    $display("[TIMING_ANCHOR_CHECKED] VS deassertion x=0 y=492 time=%0t",$time);
            end
            previous_hs=vga_hs;
        end
    end
endmodule
