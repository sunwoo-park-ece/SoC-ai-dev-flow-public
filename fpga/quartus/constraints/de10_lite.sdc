# Project-owned reconstruction of the board-clock timing intent.
# The DE10-Lite MAX10_CLK1_50 input is 50 MHz.
create_clock -name clk -period 20.000 [get_ports {clk}]

# Let TimeQuest derive the private IP PLL outputs from the compiled netlist.
# This describes their actual generated clocks without publishing IP payload.
derive_pll_clocks
derive_clock_uncertainty

# External input/output delays require board/peripheral timing data and are
# intentionally not invented here. This file is not timing sign-off complete.
