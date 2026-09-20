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
    integer sensor_frames = 0, sensor_reads = 0, sensor_bit;
    reg [47:0] sensor_bytes;
    reg [15:0] init_word [0:11];
    reg [55:0] sensor_tx, expected_tx;
    always #5 clk = ~clk;

    // External-pin ADXL345 peer: the expected bytes are fixed independent
    // stimulus, not sampled from controller outputs or snapshot bank state.
    initial begin : sensor_peer
        init_word[0]=16'h2420; init_word[1]=16'h2503;
        init_word[2]=16'h2601; init_word[3]=16'h277f;
        init_word[4]=16'h2809; init_word[5]=16'h2946;
        init_word[6]=16'h2c09; init_word[7]=16'h2f00;
        init_word[8]=16'h2e80; init_word[9]=16'h3100;
        init_word[10]=16'h2007; init_word[11]=16'h2d08;
        forever begin
            @(negedge G_SENSOR_CS_N);
            sensor_tx = 0;
            if (sensor_frames < 12) begin
                expected_tx = {40'h0, init_word[sensor_frames]};
                for (sensor_bit=0; sensor_bit<16; sensor_bit=sensor_bit+1) begin
                    @(negedge G_SENSOR_SCLK); #1;
                    if (G_SENSOR_SDI !== expected_tx[15-sensor_bit])
                        $fatal(1,"SoC sensor init MOSI frame=%0d bit=%0d",sensor_frames,sensor_bit);
                    G_SENSOR_SDO=0;
                    @(posedge G_SENSOR_SCLK); #1;
                    sensor_tx={sensor_tx[54:0],G_SENSOR_SDI};
                end
            end else begin
                expected_tx={8'hf2,48'h0};
                sensor_bytes=(sensor_reads==0) ? 48'h3412_7856_bc9a : 48'hbc9a_f0de_3412;
                sensor_reads=sensor_reads+1;
                for (sensor_bit=0; sensor_bit<56; sensor_bit=sensor_bit+1) begin
                    @(negedge G_SENSOR_SCLK); #1;
                    if (G_SENSOR_SDI !== expected_tx[55-sensor_bit])
                        $fatal(1,"SoC sensor read MOSI bit=%0d",sensor_bit);
                    if (sensor_bit>=8) G_SENSOR_SDO=sensor_bytes[55-sensor_bit];
                    else G_SENSOR_SDO=0;
                    @(posedge G_SENSOR_SCLK); #1;
                    sensor_tx={sensor_tx[54:0],G_SENSOR_SDI};
                end
            end
            if (sensor_tx !== expected_tx) $fatal(1,"SoC sensor SPI frame mismatch");
            @(posedge G_SENSOR_CS_N);
            sensor_frames=sensor_frames+1;
        end
    end

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
    task check_gsensor_local_error(input [31:0] addr, input wr, input [31:0] data);
        begin
            drive_data = data;
            set_bus(addr,wr,2'b10,3'b010);
            if (!dut.HSEL_APB) $fatal(1,"G-sensor request missed APB %h",addr);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 0 || dut.HREADY !== 0)
                $fatal(1,"G-sensor local-error SETUP %h",addr);
            set_bus(0,0,0,3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 1 ||
                dut.GSENSOR_SLVERR !== 1 || dut.HRESP !== 2'b01 || dut.HREADY !== 0)
                $fatal(1,"G-sensor local-error first AHB ERROR %h",addr);
            @(posedge clk); #1;
            if (dut.HRESP !== 2'b01 || dut.HREADY !== 1 || dut.PSEL !== 0)
                $fatal(1,"G-sensor local-error final AHB ERROR %h",addr);
            @(posedge clk); #1;
            if (dut.HRESP !== 0 || dut.HREADY !== 1)
                $fatal(1,"G-sensor malformed request caused side effect %h",addr);
            check_populated_banks();
            checks=checks+1;
        end
    endtask
    task check_populated_banks;
        begin
            if (dut.u_gsensor.live_x !== 16'h9abc ||
                dut.u_gsensor.live_y !== 16'hdef0 ||
                dut.u_gsensor.live_z !== 16'h1234 ||
                dut.u_gsensor.live_seq !== 32'd2 ||
                dut.u_gsensor.live_valid !== 1'b1 ||
                dut.u_gsensor.hold_x !== 16'h1234 ||
                dut.u_gsensor.hold_y !== 16'h5678 ||
                dut.u_gsensor.hold_z !== 16'h9abc ||
                dut.u_gsensor.hold_seq !== 32'd1 ||
                dut.u_gsensor.hold_valid !== 1'b1)
                $fatal(1,"populated G-sensor LIVE/HOLD state changed unexpectedly");
            checks=checks+1;
        end
    endtask
    task gsensor_capture_first;
        begin
            drive_data=32'h1;
            set_bus(32'h40030010,1,2'b10,3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 0)
                $fatal(1,"G-sensor CAPTURE SETUP missing");
            set_bus(0,0,0,3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 1 ||
                dut.HRESP !== 0 || dut.HREADY !== 1)
                $fatal(1,"G-sensor CAPTURE ACCESS response");
            @(posedge clk); #1;
            if (dut.u_gsensor.hold_x !== 16'h1234 ||
                dut.u_gsensor.hold_y !== 16'h5678 ||
                dut.u_gsensor.hold_z !== 16'h9abc ||
                dut.u_gsensor.hold_seq !== 32'd1 ||
                dut.u_gsensor.hold_valid !== 1 ||
                dut.u_gsensor.live_valid !== 0)
                $fatal(1,"legal CAPTURE did not copy first scripted generation");
            checks=checks+1;
        end
    endtask
    task gsensor_write_ok(input [31:0] command);
        begin
            drive_data=command;
            set_bus(32'h40030010,1,2'b10,3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 0)
                $fatal(1,"G-sensor legal command SETUP missing");
            set_bus(0,0,0,3'b010);
            @(posedge clk); #1;
            if (dut.PSEL !== 16'h0008 || dut.PENABLE !== 1 ||
                dut.HRESP !== 0 || dut.HREADY !== 1)
                $fatal(1,"G-sensor legal command ACCESS failed");
            @(posedge clk); #1;
            checks=checks+1;
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
        reg vga_owned;
        begin
            set_bus(addr,wr,2'b10,size);
            vga_owned = (addr >= 32'h2000_0000) && (addr <= 32'h2001_ffff);
            if (vga_owned) begin
                if (!dut.HSEL_VRAM || dut.HSEL_ERROR || dut.HSEL_MEM || dut.HSEL_APB)
                    $fatal(1, "invalid VGA request not owned by VGA at %h", addr);
            end else if (dut.HSEL_ERROR !== 1 || dut.HSEL_MEM || dut.HSEL_VRAM || dut.HSEL_APB) begin
                $fatal(1, "invalid decode not default ERROR at %h", addr);
            end
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
            if (addr[31:16] == 16'h4003) check_populated_banks();
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
        wait (sensor_frames == 12);
        @(negedge clk); G_SENSOR_INT[1]=1;
        wait (sensor_frames == 13);
        gsensor_capture_first();
        @(negedge clk); G_SENSOR_INT[1]=0;
        repeat (4) @(posedge clk);
        @(negedge clk); G_SENSOR_INT[1]=1;
        wait (sensor_frames == 14);
        check_populated_banks(); // HOLD occupied and newer LIVE pending.
        check_apb_error(32'h40030014,3'b010,1); // G-sensor unlisted offset.
        check_apb_error(32'h40030100,3'b010,0); // Full-offset mirror blocked.
        check_apb_error(32'h40030010,3'b001,1); // Unsupported G-sensor halfword.
        check_apb_error(32'h40030002,3'b010,0); // Misaligned alias.
        check_gsensor_local_error(32'h40030000,1,32'h1); // RO write.
        check_gsensor_local_error(32'h40030010,0,32'h0); // WO read.
        check_gsensor_local_error(32'h40030010,1,32'h0);
        check_gsensor_local_error(32'h40030010,1,32'h3);
        check_gsensor_local_error(32'h40030010,1,32'h8000_0001);
        gsensor_write_ok(32'h1); // Occupied CAPTURE is legal no-op.
        check_populated_banks();
        gsensor_write_ok(32'h2); // RELEASE clears HOLD, not LIVE.
        if (dut.u_gsensor.hold_x !== 0 || dut.u_gsensor.hold_y !== 0 ||
            dut.u_gsensor.hold_z !== 0 || dut.u_gsensor.hold_seq !== 0 ||
            dut.u_gsensor.hold_valid !== 0 || dut.u_gsensor.live_valid !== 1 ||
            dut.u_gsensor.live_seq !== 2)
            $fatal(1,"legal RELEASE failed or consumed LIVE");
        gsensor_write_ok(32'h2); // Empty RELEASE stays OKAY/no-op.
        if (dut.u_gsensor.hold_valid !== 0 || dut.u_gsensor.live_valid !== 1)
            $fatal(1,"empty RELEASE changed bank validity");
        gsensor_write_ok(32'h1); // Recapture second generation.
        if (dut.u_gsensor.hold_x !== 16'h9abc ||
            dut.u_gsensor.hold_y !== 16'hdef0 ||
            dut.u_gsensor.hold_z !== 16'h1234 ||
            dut.u_gsensor.hold_seq !== 2 ||
            dut.u_gsensor.hold_valid !== 1 || dut.u_gsensor.live_valid !== 0)
            $fatal(1,"legal recapture did not copy second generation");
        $display("SUMMARY: PASS SoC bus decode/error checks=%0d",checks);
        $finish;
    end
endmodule
