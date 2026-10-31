// Open simulation boundary: external PLL-status/clock stimulus, no vendor IP.
module vga_pll(input wire inclk0, output wire c0, output wire locked);
 assign c0 = tb.pixel_clock;
 assign locked = tb.lock;
endmodule
