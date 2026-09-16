`timescale 1ns/1ps

module tb_p05b_uart_rx_regression;
    localparam integer BAUD_CYCLES = 217;

    reg pclk = 1'b0;
    reg preset_n = 1'b0;
    reg [31:0] paddr = 32'h0;
    reg pwrite = 1'b0;
    reg psel = 1'b0;
    reg penable = 1'b0;
    reg [31:0] pwdata = 32'h0;
    reg uart0_rx = 1'b1;
    reg uart1_rx = 1'b1;
    wire [31:0] uart0_prdata;
    wire [31:0] uart1_prdata;
    wire uart0_tx;
    wire uart1_tx;
    wire uart0_pready;
    wire uart1_pready;

    always #10 pclk = ~pclk;

    APB_UART_LORA u_uart0 (
        .PCLK(pclk), .PRESETn(preset_n), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(uart0_prdata),
        .uart_tx(uart0_tx), .uart_rx(uart0_rx), .lora_aux(1'b0),
        .PREADY(uart0_pready)
    );

    APB_UART u_uart1 (
        .PCLK(pclk), .PRESETn(preset_n), .PADDR(paddr), .PWRITE(pwrite),
        .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata), .PRDATA(uart1_prdata),
        .uart_tx(uart1_tx), .uart_rx(uart1_rx), .PREADY(uart1_pready)
    );

    task automatic check_condition;
        input condition;
        input [8*96-1:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                $fatal(1);
            end
        end
    endtask

    task automatic apb_write_baud;
        begin
            paddr = 32'h0000_000c;
            pwdata = BAUD_CYCLES;
            pwrite = 1'b1;
            psel = 1'b1;
            penable = 1'b1;
            @(posedge pclk); #1;
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
        end
    endtask

    task automatic drive_uart0_byte;
        input [7:0] value;
        input integer phase_delay;
        integer bit_index;
        begin
            @(negedge pclk); #(phase_delay);
            uart0_rx = 1'b0;
            repeat (BAUD_CYCLES) @(posedge pclk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart0_rx = value[bit_index];
                repeat (BAUD_CYCLES) @(posedge pclk);
            end
            uart0_rx = 1'b1;
            repeat (BAUD_CYCLES + 4) @(posedge pclk);
        end
    endtask

    task automatic drive_uart1_byte;
        input [7:0] value;
        input integer phase_delay;
        integer bit_index;
        begin
            @(negedge pclk); #(phase_delay);
            uart1_rx = 1'b0;
            repeat (BAUD_CYCLES) @(posedge pclk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart1_rx = value[bit_index];
                repeat (BAUD_CYCLES) @(posedge pclk);
            end
            uart1_rx = 1'b1;
            repeat (BAUD_CYCLES + 4) @(posedge pclk);
        end
    endtask

    task automatic check_and_pop_uart0;
        input [7:0] expected_byte;
        begin
            paddr = 32'h4; psel = 1'b1; penable = 1'b1; #1;
            check_condition(uart0_prdata[2:1] == 2'b01, "UART0 RX status/error regression");
            paddr = 32'h0; #1;
            check_condition(uart0_prdata[7:0] == expected_byte, "UART0 RX byte mismatch");
            @(posedge pclk); #1;
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    task automatic check_and_pop_uart1;
        input [7:0] expected_byte;
        begin
            paddr = 32'h4; psel = 1'b1; penable = 1'b1; #1;
            check_condition(uart1_prdata[2:1] == 2'b01, "UART1 RX status/error regression");
            paddr = 32'h0; #1;
            check_condition(uart1_prdata[7:0] == expected_byte, "UART1 RX byte mismatch");
            @(posedge pclk); #1;
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge pclk);
        #3 preset_n = 1'b1;
        repeat (3) @(posedge pclk);
        apb_write_baud();

        // Two phase offsets per production instance retain the existing 2FF RX
        // path and exercise complete start/data/stop/FIFO behavior.
        drive_uart0_byte(8'ha5, 1);
        check_and_pop_uart0(8'ha5);
        drive_uart0_byte(8'h3c, 9);
        check_and_pop_uart0(8'h3c);

        drive_uart1_byte(8'h5a, 2);
        check_and_pop_uart1(8'h5a);
        drive_uart1_byte(8'hc3, 8);
        check_and_pop_uart1(8'hc3);

        // Reset during a partial frame must return both paths to idle/no-data.
        @(negedge pclk); #4 uart0_rx = 1'b0;
        repeat (BAUD_CYCLES * 2) @(posedge pclk);
        #3 preset_n = 1'b0; #1;
        uart0_rx = 1'b1;
        check_condition(u_uart0.rx_fifo_count == 0 && u_uart1.rx_fifo_count == 0,
                        "UART RX FIFO did not clear during activity reset");
        check_condition(uart0_tx === 1'b1 && uart1_tx === 1'b1,
                        "UART TX idle level changed during reset");

        $display("SUMMARY: PASS P05B UART0/UART1 RX regression");
        $finish;
    end
endmodule
