`timescale 1ns/1ps
module tb_soc_cpu_fault_e2e;
    reg clk = 0;
    reg [1:0] KEY = 2'b10;
    reg [9:0] SW = 0;
    reg [2:1] G_SENSOR_INT = 0;
    reg G_SENSOR_SDO = 0, lora_rx = 1, lora_aux = 0, uart_rx = 1;
    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire G_SENSOR_CS_N, G_SENSOR_SCLK, G_SENSOR_SDI;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire VGA_HS, VGA_VS, lora_tx, uart_tx;
    integer cycle;
    always #5 clk = ~clk;
    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI), .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );
    task program_case(input [31:0] address_lui, input is_store, input misalign);
        begin
            dut.u_CPU.if_id_register.u_IMEM.words[0] = address_lui;
            dut.u_CPU.if_id_register.u_IMEM.words[1] =
                is_store ? 32'h05500113 : 32'h00700113;
            dut.u_CPU.if_id_register.u_IMEM.words[2] =
                is_store ? (misalign ? 32'h0020a0a3 : 32'h0020a023) :
                           (misalign ? 32'h0010a103 : 32'h0000a103);
            dut.u_CPU.if_id_register.u_IMEM.words[3] = 32'h00100193;
        end
    endtask
    task run_case(input [31:0] cause);
        begin : wait_trap
            for (cycle=0; cycle<150; cycle=cycle+1) begin
                @(posedge clk); #1;
                if (dut.u_CPU.csr_file.mcause == cause) begin
                    if (dut.u_CPU.csr_file.mepc !== 32'd8)
                        $fatal(1, "cause=%0d mepc=%h expected=8",cause,dut.u_CPU.csr_file.mepc);
                    if (dut.u_CPU.register_file.registers[2] !== ((cause==5 || cause==4) ? 32'd7 : 32'h55))
                        $fatal(1, "failed access changed x2 cause=%0d",cause);
                    repeat (15) @(posedge clk);
                    #1;
                    if (dut.u_CPU.register_file.registers[3] !== 0)
                        $fatal(1, "younger instruction survived cause=%0d",cause);
                    $display("e2e cause=%0d mepc=%h cycles=%0d",cause,dut.u_CPU.csr_file.mepc,cycle);
                    disable wait_trap;
                end
            end
            $fatal(1,"SoC CPU fault timeout cause=%0d pc=%h mempc=%h hresp=%b ready=%b",
                   cause,dut.u_CPU.pc,dut.u_CPU.MEM_pc,dut.HRESP,dut.HREADY);
        end
    endtask
    initial begin
        force dut.PRESETN_SYS = 0;
        #1; program_case(32'h500000b7,0,0);
        repeat (4) @(posedge clk);
        @(negedge clk); force dut.PRESETN_SYS = 1;
        run_case(5);

        @(negedge clk); force dut.PRESETN_SYS = 0;
        program_case(32'h500000b7,1,0);
        repeat (4) @(posedge clk);
        @(negedge clk); force dut.PRESETN_SYS = 1;
        run_case(7);

        @(negedge clk); force dut.PRESETN_SYS = 0;
        program_case(32'h100000b7,0,1);
        repeat (4) @(posedge clk);
        @(negedge clk); force dut.PRESETN_SYS = 1;
        run_case(4);
        @(negedge clk); force dut.PRESETN_SYS = 0;
        program_case(32'h100000b7,1,1);
        repeat (4) @(posedge clk);
        @(negedge clk); force dut.PRESETN_SYS = 1;
        run_case(6);
        if (dut.u_memory.u_bram.words[0] !== 32'b0)
            $fatal(1,"misaligned store changed DMEM word zero");
        $display("SUMMARY: PASS SoC CPU fault e2e");
        $finish;
    end
endmodule
