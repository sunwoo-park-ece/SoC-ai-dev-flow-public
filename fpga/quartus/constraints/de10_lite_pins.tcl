# Project-owned DE10-Lite pin reconstruction for the used AMBA_SoC_TOP ports.
# Board pin facts: Terasic DE10-Lite User Manual, tables 3-2 through 3-13.
# https://www.terasic.com.tw/attachment/archive/1021/DE10-Lite_User_Manual.pdf
# UART/LoRa signal-to-GPIO allocation is project-specific wiring; validate before programming.
# No vendor IP/project assignments are copied into this file.

# JP1 GPIO_0..15; user-confirmed wiring has no physical conflict.
# Electrical loading and external timing remain open under STA-002.
set_location_assignment PIN_V10 -to {GPIO_IO[0]}
set_location_assignment PIN_W10 -to {GPIO_IO[1]}
set_location_assignment PIN_V9 -to {GPIO_IO[2]}
set_location_assignment PIN_W9 -to {GPIO_IO[3]}
set_location_assignment PIN_V8 -to {GPIO_IO[4]}
set_location_assignment PIN_W8 -to {GPIO_IO[5]}
set_location_assignment PIN_V7 -to {GPIO_IO[6]}
set_location_assignment PIN_W7 -to {GPIO_IO[7]}
set_location_assignment PIN_W6 -to {GPIO_IO[8]}
set_location_assignment PIN_V5 -to {GPIO_IO[9]}
set_location_assignment PIN_W5 -to {GPIO_IO[10]}
set_location_assignment PIN_AA15 -to {GPIO_IO[11]}
set_location_assignment PIN_AA14 -to {GPIO_IO[12]}
set_location_assignment PIN_W13 -to {GPIO_IO[13]}
set_location_assignment PIN_W12 -to {GPIO_IO[14]}
set_location_assignment PIN_AB13 -to {GPIO_IO[15]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[7]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[8]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[9]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[10]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[11]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[12]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[13]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[14]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {GPIO_IO[15]}

# clk
set_location_assignment PIN_P11 -to {clk}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {clk}

# KEY
set_location_assignment PIN_B8 -to {KEY[0]}
set_instance_assignment -name IO_STANDARD "3.3 V SCHMITT TRIGGER" -to {KEY[0]}
set_location_assignment PIN_A7 -to {KEY[1]}
set_instance_assignment -name IO_STANDARD "3.3 V SCHMITT TRIGGER" -to {KEY[1]}

# SW
set_location_assignment PIN_C10 -to {SW[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[0]}
set_location_assignment PIN_C11 -to {SW[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[1]}
set_location_assignment PIN_D12 -to {SW[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[2]}
set_location_assignment PIN_C12 -to {SW[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[3]}
set_location_assignment PIN_A12 -to {SW[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[4]}
set_location_assignment PIN_B12 -to {SW[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[5]}
set_location_assignment PIN_A13 -to {SW[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[6]}
set_location_assignment PIN_A14 -to {SW[7]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[7]}
set_location_assignment PIN_B14 -to {SW[8]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[8]}
set_location_assignment PIN_F15 -to {SW[9]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {SW[9]}

# LEDR
set_location_assignment PIN_A8 -to {LEDR[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[0]}
set_location_assignment PIN_A9 -to {LEDR[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[1]}
set_location_assignment PIN_A10 -to {LEDR[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[2]}
set_location_assignment PIN_B10 -to {LEDR[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[3]}
set_location_assignment PIN_D13 -to {LEDR[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[4]}
set_location_assignment PIN_C13 -to {LEDR[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[5]}
set_location_assignment PIN_E14 -to {LEDR[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[6]}
set_location_assignment PIN_D14 -to {LEDR[7]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[7]}
set_location_assignment PIN_A11 -to {LEDR[8]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[8]}
set_location_assignment PIN_B11 -to {LEDR[9]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {LEDR[9]}

# HEX0
set_location_assignment PIN_C14 -to {HEX0[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[0]}
set_location_assignment PIN_E15 -to {HEX0[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[1]}
set_location_assignment PIN_C15 -to {HEX0[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[2]}
set_location_assignment PIN_C16 -to {HEX0[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[3]}
set_location_assignment PIN_E16 -to {HEX0[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[4]}
set_location_assignment PIN_D17 -to {HEX0[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[5]}
set_location_assignment PIN_C17 -to {HEX0[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX0[6]}

# HEX1
set_location_assignment PIN_C18 -to {HEX1[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[0]}
set_location_assignment PIN_D18 -to {HEX1[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[1]}
set_location_assignment PIN_E18 -to {HEX1[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[2]}
set_location_assignment PIN_B16 -to {HEX1[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[3]}
set_location_assignment PIN_A17 -to {HEX1[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[4]}
set_location_assignment PIN_A18 -to {HEX1[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[5]}
set_location_assignment PIN_B17 -to {HEX1[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX1[6]}

# HEX2
set_location_assignment PIN_B20 -to {HEX2[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[0]}
set_location_assignment PIN_A20 -to {HEX2[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[1]}
set_location_assignment PIN_B19 -to {HEX2[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[2]}
set_location_assignment PIN_A21 -to {HEX2[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[3]}
set_location_assignment PIN_B21 -to {HEX2[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[4]}
set_location_assignment PIN_C22 -to {HEX2[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[5]}
set_location_assignment PIN_B22 -to {HEX2[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX2[6]}

# HEX3
set_location_assignment PIN_F21 -to {HEX3[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[0]}
set_location_assignment PIN_E22 -to {HEX3[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[1]}
set_location_assignment PIN_E21 -to {HEX3[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[2]}
set_location_assignment PIN_C19 -to {HEX3[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[3]}
set_location_assignment PIN_C20 -to {HEX3[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[4]}
set_location_assignment PIN_D19 -to {HEX3[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[5]}
set_location_assignment PIN_E17 -to {HEX3[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX3[6]}

# HEX4
set_location_assignment PIN_F18 -to {HEX4[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[0]}
set_location_assignment PIN_E20 -to {HEX4[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[1]}
set_location_assignment PIN_E19 -to {HEX4[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[2]}
set_location_assignment PIN_J18 -to {HEX4[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[3]}
set_location_assignment PIN_H19 -to {HEX4[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[4]}
set_location_assignment PIN_F19 -to {HEX4[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[5]}
set_location_assignment PIN_F20 -to {HEX4[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX4[6]}

# HEX5
set_location_assignment PIN_J20 -to {HEX5[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[0]}
set_location_assignment PIN_K20 -to {HEX5[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[1]}
set_location_assignment PIN_L18 -to {HEX5[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[2]}
set_location_assignment PIN_N18 -to {HEX5[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[3]}
set_location_assignment PIN_M20 -to {HEX5[4]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[4]}
set_location_assignment PIN_N19 -to {HEX5[5]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[5]}
set_location_assignment PIN_N20 -to {HEX5[6]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {HEX5[6]}

# VGA_R
set_location_assignment PIN_AA1 -to {VGA_R[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_R[0]}
set_location_assignment PIN_V1 -to {VGA_R[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_R[1]}
set_location_assignment PIN_Y2 -to {VGA_R[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_R[2]}
set_location_assignment PIN_Y1 -to {VGA_R[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_R[3]}

# VGA_G
set_location_assignment PIN_W1 -to {VGA_G[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_G[0]}
set_location_assignment PIN_T2 -to {VGA_G[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_G[1]}
set_location_assignment PIN_R2 -to {VGA_G[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_G[2]}
set_location_assignment PIN_R1 -to {VGA_G[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_G[3]}

# VGA_B
set_location_assignment PIN_P1 -to {VGA_B[0]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_B[0]}
set_location_assignment PIN_T1 -to {VGA_B[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_B[1]}
set_location_assignment PIN_P4 -to {VGA_B[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_B[2]}
set_location_assignment PIN_N2 -to {VGA_B[3]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_B[3]}

# VGA_HS
set_location_assignment PIN_N3 -to {VGA_HS}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_HS}

# VGA_VS
set_location_assignment PIN_N1 -to {VGA_VS}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {VGA_VS}

# G_SENSOR_CS_N
set_location_assignment PIN_AB16 -to {G_SENSOR_CS_N}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_CS_N}

# G_SENSOR_INT
set_location_assignment PIN_Y14 -to {G_SENSOR_INT[1]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_INT[1]}
set_location_assignment PIN_Y13 -to {G_SENSOR_INT[2]}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_INT[2]}

# G_SENSOR_SCLK
set_location_assignment PIN_AB15 -to {G_SENSOR_SCLK}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_SCLK}

# G_SENSOR_SDI
set_location_assignment PIN_V11 -to {G_SENSOR_SDI}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_SDI}

# G_SENSOR_SDO
set_location_assignment PIN_V12 -to {G_SENSOR_SDO}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {G_SENSOR_SDO}

# uart_tx
set_location_assignment PIN_AB2 -to {uart_tx}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {uart_tx}

# uart_rx
set_location_assignment PIN_AA2 -to {uart_rx}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {uart_rx}

# lora_tx
set_location_assignment PIN_Y4 -to {lora_tx}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {lora_tx}

# lora_rx
set_location_assignment PIN_Y5 -to {lora_rx}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {lora_rx}

# lora_aux
set_location_assignment PIN_Y6 -to {lora_aux}
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {lora_aux}
