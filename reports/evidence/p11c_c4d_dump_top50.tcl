# TimeQuest Tcl script to extract top 50 setup paths for P11 C4-D timing root-cause analysis
project_open AMBA_SoC_TOP
create_timing_netlist
read_sdc
update_timing_netlist

# 1. Top 50 setup paths (path-only summary: Slack, From, To, Data Delay)
report_timing -to_clock [get_clocks {clk}] -setup -npaths 50 -detail path_only -file top50_setup_summary.txt

# 2. Top 20 setup paths (full detail: IC vs CELL breakdown, fanout, loop delays)
report_timing -to_clock [get_clocks {clk}] -setup -npaths 20 -detail full_path -file top20_setup_full.txt

delete_timing_netlist
project_close
