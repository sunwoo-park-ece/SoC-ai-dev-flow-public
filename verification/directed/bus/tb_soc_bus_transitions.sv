`timescale 1ns/1ps
module tb_soc_bus_transitions;
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
    reg [31:0] drive_addr = 0;
    reg [1:0] drive_trans = 0;
    reg drive_write = 0;
    reg [2:0] drive_size = 3'b010;
    reg [31:0] drive_data = 0;
    reg [12:0] held_mem_addr;
    reg held_mem_write;
    reg [31:0] held_vram_addr, held_bridge_addr;
    reg held_vram_write, held_vram_read, held_bridge_write;
    always #5 clk = ~clk;
    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI), .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );
    task drive(input [31:0] addr, input [1:0] trans);
        begin @(negedge clk); drive_addr=addr; drive_trans=trans; #1; end
    endtask
    task edge_check(input [3:0] expected_phase, input ready, input [1:0] resp);
        begin
            @(posedge clk); #1;
            if ({dut.HSEL_MEM_d,dut.HSEL_VRAM_d,dut.HSEL_APB_d,dut.HSEL_ERROR_d} !== expected_phase ||
                dut.HREADY !== ready || dut.HRESP !== resp)
                $fatal(1,"phase=%b ready=%b resp=%b expected=%b/%b/%b addr=%h",
                       {dut.HSEL_MEM_d,dut.HSEL_VRAM_d,dut.HSEL_APB_d,dut.HSEL_ERROR_d},
                       dut.HREADY,dut.HRESP,expected_phase,ready,resp,drive_addr);
        end
    endtask
    task check_stalled_captures;
        begin
            if (dut.u_memory.addr_reg !== held_mem_addr ||
                dut.u_memory.write_en_reg !== held_mem_write ||
                dut.U_VRAM.addr_reg !== held_vram_addr ||
                dut.U_VRAM.write_reg !== held_vram_write ||
                dut.U_VRAM.read_reg !== held_vram_read ||
                dut.u_bridge.addr_reg !== held_bridge_addr ||
                dut.u_bridge.write_reg !== held_bridge_write)
                $fatal(1,"slave address/control overwritten while global HREADY=0");
        end
    endtask
    initial begin
        force dut.HADDR = drive_addr;
        force dut.HWRITE = drive_write;
        force dut.HTRANS = drive_trans;
        force dut.HSIZE = drive_size;
        force dut.HWDATA = drive_data;
        force dut.PRESETN_SYS = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); force dut.PRESETN_SYS = 1;

        // MEM -> APB, then APB -> MEM across forced APB wait states.
        drive(32'h10000000,2'b10); edge_check(4'b1000,1,0);
        drive(32'h40020004,2'b10); edge_check(4'b0010,0,0);
        held_mem_addr = dut.u_memory.addr_reg;
        held_mem_write = dut.u_memory.write_en_reg;
        held_vram_addr = dut.U_VRAM.addr_reg;
        held_vram_write = dut.U_VRAM.write_reg;
        held_vram_read = dut.U_VRAM.read_reg;
        held_bridge_addr = dut.u_bridge.addr_reg;
        held_bridge_write = dut.u_bridge.write_reg;
        force dut.APB_SLAVE_PREADY = 0;
        drive(32'h10000004,2'b10); drive_write=1;
        edge_check(4'b0010,0,0); check_stalled_captures();
        repeat (2) begin edge_check(4'b0010,0,0); check_stalled_captures(); end
        drive_write=0;
        release dut.APB_SLAVE_PREADY;
        #1;
        if (dut.HREADY !== 1) $fatal(1,"APB wait did not complete");
        edge_check(4'b1000,1,0);
        if (dut.u_memory.addr_reg !== 13'h0001 || dut.u_memory.write_en_reg !== 0)
            $fatal(1,"intended MEM address was not captured on HREADY=1");

        // MEM -> invalid. The younger MEM address during ERROR is cancelled.
        drive(32'h10008000,2'b10); edge_check(4'b0001,0,2'b01);
        drive(32'h10000008,2'b10); edge_check(4'b0001,1,2'b01);
        edge_check(4'b0000,1,0);
        if (dut.HSEL_MEM_d) $fatal(1,"invalid -> MEM committed during ERROR");

        // Reissue MEM, then APB -> invalid. APB response must not leak.
        drive(32'h10000008,2'b10); edge_check(4'b1000,1,0);
        drive(32'h40020004,2'b10); edge_check(4'b0010,0,0);
        drive(32'hdeadbeec,2'b10); edge_check(4'b0010,1,0);
        edge_check(4'b0001,0,2'b01);
        drive(32'h40020004,2'b10); edge_check(4'b0001,1,2'b01);
        edge_check(4'b0000,1,0);
        if (dut.u_bridge.state != dut.u_bridge.IDLE || dut.PSEL != 0)
            $fatal(1,"invalid -> APB committed during ERROR");

        // Reissue APB after cancellation; normal ACCESS succeeds.
        drive(32'h40020004,2'b10); edge_check(4'b0010,0,0);
        drive(0,0); edge_check(4'b0010,1,0);
        edge_check(4'b0000,1,0);

        // Cover the VGA slave in the same data-phase mux. Status reads are
        // canonical and do not depend on private framebuffer payload.
        drive(32'h10000000,2'b10); edge_check(4'b1000,1,0);
        drive(32'h20010000,2'b10); edge_check(4'b0100,1,0);
        drive(32'h40020004,2'b10); edge_check(4'b0010,0,0);
        force dut.APB_SLAVE_PREADY = 0;
        drive(32'h20010000,2'b10); edge_check(4'b0010,0,0);
        repeat (2) edge_check(4'b0010,0,0);
        release dut.APB_SLAVE_PREADY;
        #1;
        edge_check(4'b0100,1,0);
        drive(32'hdeadbeec,2'b10); edge_check(4'b0001,0,2'b01);
        drive(32'h20010000,2'b10); edge_check(4'b0001,1,2'b01);
        edge_check(4'b0000,1,0);
        if (dut.HSEL_VRAM_d) $fatal(1,"invalid -> VGA committed during ERROR");
        drive(32'h20010000,2'b10); edge_check(4'b0100,1,0);
        drive(0,0); edge_check(4'b0000,1,0);
        $display("SUMMARY: PASS MEM/APB/VGA/invalid cross-slave wait/error transitions");
        $finish;
    end
endmodule
