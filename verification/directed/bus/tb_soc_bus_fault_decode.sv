`timescale 1ns/1ps
module tb_soc_bus_fault_decode;
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
    reg [31:0] drive_addr = 0, drive_data = 0;
    reg drive_write = 0;
    reg [1:0] drive_trans = 0;
    reg [2:0] drive_size = 3'b010;
    integer checks = 0;
    always #5 clk = ~clk;

    AMBA_SoC_TOP dut (
        .clk(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .G_SENSOR_CS_N(G_SENSOR_CS_N), .G_SENSOR_INT(G_SENSOR_INT),
        .G_SENSOR_SCLK(G_SENSOR_SCLK), .G_SENSOR_SDI(G_SENSOR_SDI), .G_SENSOR_SDO(G_SENSOR_SDO),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .lora_tx(lora_tx), .lora_rx(lora_rx), .lora_aux(lora_aux), .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    task set_bus(input [31:0] addr, input wr, input [1:0] trans, input [2:0] size);
        begin
            @(negedge clk);
            drive_addr=addr; drive_write=wr; drive_trans=trans; drive_size=size;
            #1;
        end
    endtask
    task check_idle;
        begin
            if (dut.HSEL_MEM || dut.HSEL_VRAM || dut.HSEL_APB || dut.HSEL_ERROR)
                $fatal(1, "IDLE/BUSY selected a slave at %h", drive_addr);
            @(posedge clk); #1;
            if (dut.HRESP !== 0 || dut.HREADY !== 1)
                $fatal(1, "IDLE/BUSY generated an error");
            checks=checks+1;
        end
    endtask
    task check_ok(input [2:0] expected_select);
        begin
            if ({dut.HSEL_MEM,dut.HSEL_VRAM,dut.HSEL_APB} !== expected_select)
                $fatal(1, "decode %h got %b expected %b", drive_addr,
                       {dut.HSEL_MEM,dut.HSEL_VRAM,dut.HSEL_APB}, expected_select);
            @(posedge clk); #1;
            if (dut.HRESP !== 0) $fatal(1, "valid address ERROR %h", drive_addr);
            if (expected_select != 3'b001 && dut.HREADY !== 1)
                $fatal(1, "zero-wait target stalled %h", drive_addr);
            if (expected_select == 3'b001) begin
                if (dut.HREADY !== 0 || dut.PENABLE !== 0)
                    $fatal(1, "APB SETUP missing");
                set_bus(0, 0, 0, 3'b010);
                @(posedge clk); #1;
                if (dut.HREADY !== 1 || dut.HRESP !== 0 || dut.PENABLE !== 1)
                    $fatal(1, "APB ACCESS missing");
            end
            checks=checks+1;
        end
    endtask
    task check_error(input [31:0] addr, input wr, input [2:0] size);
        begin
            set_bus(addr,wr,2'b10,size);
            if (dut.HSEL_ERROR !== 1 || dut.HSEL_MEM || dut.HSEL_VRAM || dut.HSEL_APB)
                $fatal(1, "invalid decode not default ERROR at %h", addr);
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 0)
                $fatal(1, "first default ERROR response %h", addr);
            set_bus(0,0,0,3'b010);
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 1)
                $fatal(1, "final default ERROR response %h", addr);
            @(posedge clk); #1;
            if (dut.HRESP !== 0 || dut.HREADY !== 1)
                $fatal(1, "default ERROR did not terminate %h", addr);
            checks=checks+1;
        end
    endtask
    task check_apb_error(input [31:0] addr, input [2:0] size, input wr);
        reg [15:0] gpio_out_before, gpio_dir_before;
        begin
            gpio_out_before = dut.u_gpio.data_out;
            gpio_dir_before = dut.u_gpio.direction;
            set_bus(addr,wr,2'b10,size);
            if (!dut.HSEL_APB) $fatal(1, "APB request did not enter bridge %h",addr);
            @(posedge clk); #1;
            if (dut.PSEL !== 0 || dut.PENABLE !== 0 || dut.HREADY !== 0)
                $fatal(1, "invalid APB SETUP selected real slave");
            set_bus(0,0,0,3'b010);
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 0 || dut.PSEL !== 0)
                $fatal(1, "invalid APB first ERROR");
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 1)
                $fatal(1, "invalid APB final ERROR");
            @(posedge clk); #1;
            checks=checks+1;
            if (dut.u_gpio.data_out !== gpio_out_before ||
                dut.u_gpio.direction !== gpio_dir_before)
                $fatal(1, "invalid APB store changed actual GPIO state at %h", addr);
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
        set_bus(32'hdeadbeef,0,2'b00,3'b010); check_idle();
        set_bus(32'h10000000,0,2'b00,3'b010); check_idle();
        set_bus(32'h10000000,0,2'b01,3'b010); check_idle();
        set_bus(32'hdeadbeef,0,2'b01,3'b010); check_idle();
        set_bus(32'h10000000,0,2'b10,3'b010); check_ok(3'b100);
        set_bus(32'h10007ffc,0,2'b10,3'b010); check_ok(3'b100);
        set_bus(32'h10007ffc,1,2'b11,3'b010); check_ok(3'b100);
        drive_data = 32'hdeadbeef;
        check_error(32'h0ffffffc,0,3'b010);
        check_error(32'h0ffffffc,1,3'b010);
        check_error(32'h10008000,0,3'b010);
        check_error(32'h10008000,1,3'b010);
        check_error(32'h1000fffc,1,3'b010);
        check_error(32'h1000fffc,0,3'b010);
        if (dut.u_memory.u_bram.words[0] !== 32'b0)
            $fatal(1, "invalid DMEM upper-alias store changed physical word zero");
        set_bus(32'h20000000,1,2'b10,3'b010); check_ok(3'b010);
        set_bus(32'h200095fc,1,2'b10,3'b010); check_ok(3'b010);
        set_bus(32'h20010000,0,2'b10,3'b010); check_ok(3'b010);
        set_bus(32'h20010004,1,2'b10,3'b010); check_ok(3'b010);
        check_error(32'h20000000,0,3'b010);
        check_error(32'h20000000,1,3'b000);
        check_error(32'h20000000,1,3'b001);
        check_error(32'h20000002,1,3'b010);
        check_error(32'h20009600,1,3'b010);
        check_error(32'h20010004,0,3'b010);
        check_error(32'h20020000,1,3'b010);
        set_bus(32'h40000000,0,2'b10,3'b010); check_ok(3'b001);
        set_bus(32'h400ffffc,0,2'b10,3'b010);
        if (!dut.HSEL_APB) $fatal(1, "APB upper canonical boundary not selected");
        // Reserved slot enters the bridge, then returns its internal ERROR.
        @(posedge clk); #1;
        set_bus(0,0,0,3'b010);
        @(posedge clk); #1;
        if (dut.HRESP !== 2'b01 || dut.HREADY !== 0)
            $fatal(1, "reserved APB first ERROR missing");
        @(posedge clk); #1;
        if (dut.HRESP !== 2'b01 || dut.HREADY !== 1)
            $fatal(1, "reserved APB final ERROR missing");
        @(posedge clk); #1;
        check_error(32'h40100000,0,3'b010);
        check_error(32'h41000000,1,3'b010);
        check_apb_error(32'h40000000,3'b111,0);
        check_apb_error(32'h40010020,3'b010,1); // Beyond the eight canonical GPIO registers.
        check_apb_error(32'h40010000,3'b000,1); // Unsupported APB subword write.
        check_apb_error(32'h400a0000,3'b010,1); // Reserved slot write.
        $display("SUMMARY: PASS SoC bus decode/error checks=%0d",checks);
        $finish;
    end
endmodule
