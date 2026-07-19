# fb_top.sdc -- timing constraints

create_clock -name clk50 -period 20.000 [get_ports clk50]

derive_pll_clocks
derive_clock_uncertainty

# 50MHz USB domain and 6.4MHz pixel domain only meet inside the dual-clock
# M9K RAM and the palette; treat them as asynchronous.
set_clock_groups -asynchronous \
    -group [get_clocks clk50] \
    -group [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}]

# FT245 async FIFO: RXF# goes through a 2FF synchronizer; data is sampled
# 80ns after RD# falls, far outside any single-cycle timing concern.
set_false_path -from [get_ports {ft_rxf_n ft_data[*]}]
set_false_path -to   [get_ports {ft_rd_n ft_wr_n}]

# Analog video via resistor DAC -- no receiver setup/hold to meet.
set_false_path -to [get_ports {vid_r[*] vid_g[*] vid_b[*] vid_hs_n vid_vs_n vid_cs_n}]
