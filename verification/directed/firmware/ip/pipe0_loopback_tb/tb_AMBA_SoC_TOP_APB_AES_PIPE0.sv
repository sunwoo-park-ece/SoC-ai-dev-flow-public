`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Vendor IP 대체용 간단 메모리 모델 (ModelSim 시뮬 전용)
// -----------------------------------------------------------------------------
module IMEM #(
    // Override at compile/elaboration time with a repository-relative or
    // caller-provided path. Empty means use the initialized NOP contents.
    parameter string INIT_MIF = ""
) (
    input  wire        aclr,
    input  wire [9:0]  address,
    input  wire        clken,
    input  wire        clock,
    output reg  [31:0] q
);
    reg [31:0] mem [0:1023];
    reg [31:0] mif_data;
    integer mif_addr;
    integer fd;
    integer rc;
    string line;
    integer idx;

    initial begin
        for (idx = 0; idx < 1024; idx = idx + 1) begin
            mem[idx] = 32'h0000_0013; // NOP
        end

        if (INIT_MIF == "") begin
            $display("META,IMEM_DEFAULT_IMAGE,nop_filled=1");
        end else begin
            fd = $fopen(INIT_MIF, "r");
            if (fd == 0) begin
                $display("WARN,IMEM_MIF_OPEN_FAIL,path=%0s", INIT_MIF);
            end else begin
                while (!$feof(fd)) begin
                    line = "";
                    rc = $fgets(line, fd);
                    if ($sscanf(line, "%d : %h;", mif_addr, mif_data) == 2) begin
                        if ((mif_addr >= 0) && (mif_addr < 1024)) begin
                            mem[mif_addr] = mif_data;
                        end
                    end
                end
                $fclose(fd);
                $display("META,IMEM_LOAD_OK,path=%0s", INIT_MIF);
            end
        end
    end

    always @(posedge clock or posedge aclr) begin
        if (aclr) begin
            q <= 32'h0000_0013;
        end else if (clken) begin
            q <= mem[address];
        end
    end
endmodule


module memory #(
    // Override at compile/elaboration time with a repository-relative or
    // caller-provided path. Empty means use the initialized zero contents.
    parameter string INIT_MIF = ""
) (
    input  wire [3:0]  byteena_a,
    input  wire        clock,
    input  wire [31:0] data,
    input  wire [12:0] rdaddress,
    input  wire        rden,
    input  wire [12:0] wraddress,
    input  wire        wren,
    output reg  [31:0] q
);
    reg [31:0] mem [0:8191];
    reg [31:0] cur;
    reg [31:0] mif_data;
    integer mif_addr;
    integer fd;
    integer rc;
    string line;
    integer idx;

    initial begin
        for (idx = 0; idx < 8192; idx = idx + 1) begin
            mem[idx] = 32'h0;
        end

        if (INIT_MIF == "") begin
            $display("META,DMEM_DEFAULT_IMAGE,zero_filled=1");
        end else begin
            fd = $fopen(INIT_MIF, "r");
            if (fd == 0) begin
                $display("WARN,DMEM_MIF_OPEN_FAIL,path=%0s", INIT_MIF);
            end else begin
                while (!$feof(fd)) begin
                    line = "";
                    rc = $fgets(line, fd);
                    if ($sscanf(line, "%d : %h;", mif_addr, mif_data) == 2) begin
                        if ((mif_addr >= 0) && (mif_addr < 8192)) begin
                            mem[mif_addr] = mif_data;
                        end
                    end
                end
                $fclose(fd);
                $display("META,DMEM_LOAD_OK,path=%0s", INIT_MIF);
            end
        end
    end

    always @(posedge clock) begin
        if (wren) begin
            cur = mem[wraddress];
            if (byteena_a[0]) cur[7:0]   = data[7:0];
            if (byteena_a[1]) cur[15:8]  = data[15:8];
            if (byteena_a[2]) cur[23:16] = data[23:16];
            if (byteena_a[3]) cur[31:24] = data[31:24];
            mem[wraddress] <= cur;
        end
        if (rden) begin
            q <= mem[rdaddress];
        end
    end
endmodule

// -----------------------------------------------------------------------------
// TOP TB
// -----------------------------------------------------------------------------
module tb_AMBA_SoC_TOP_APB_AES_PIPE0;
    reg         clk;
    reg  [1:0]  KEY;
    reg  [9:0]  SW;
    reg         uart_rx;
    wire [9:0]  LEDR;
    wire        uart_tx;
    wire [31:0] debug_pc;
    wire [31:0] debug_X4;

    integer cycles;
    reg     done;
    reg     pass;
    reg [31:0] sig;

    AMBA_SoC_TOP_APB_AES_PIPE0 dut (
        .clk      (clk),
        .KEY      (KEY),
        .SW       (SW),
        .LEDR     (LEDR),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .debug_pc (debug_pc),
        .debug_X4 (debug_X4)
    );

    // 50MHz
    initial begin
        clk = 1'b0;
        forever #10 clk = ~clk;
    end

    task automatic dump_log_words;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                $display("LOG,%0d,0x%08x", i, dut.u_memory.u_bram.mem[i]);
            end
        end
    endtask

    initial begin
        KEY     = 2'b11;
        SW      = 10'h000;
        uart_rx = 1'b1;
        done    = 1'b0;
        pass    = 1'b0;

        // reset assert (active-low)
        KEY[0] = 1'b0;
        repeat (20) @(posedge clk);
        KEY[0] = 1'b1;

        $display("META,TB_START,time=%0t", $time);

        monitor_loop: for (cycles = 0; cycles < 200000; cycles = cycles + 1) begin
            @(posedge clk);
            sig = dut.u_memory.u_bram.mem[0];

            if (sig == 32'hA5E50001) begin
                done = 1'b1;
                pass = 1'b1;
                $display("EVT,PASS_SIGNATURE,time=%0t,cycles=%0d", $time, cycles);
                dump_log_words();
                if (LEDR[0] !== 1'b1) begin
                    $display("ASSERT,LED_PASS_MISMATCH,LEDR=0x%03x", LEDR);
                    pass = 1'b0;
                end
                disable monitor_loop;
            end

            if (sig == 32'hDEAD0001) begin
                done = 1'b1;
                pass = 1'b0;
                $display("EVT,FAIL_SIGNATURE,time=%0t,cycles=%0d", $time, cycles);
                dump_log_words();
                disable monitor_loop;
            end
        end

        if (!done) begin
            $display("ASSERT,TIMEOUT,time=%0t,debug_pc=0x%08x,debug_X4=0x%08x", $time, debug_pc, debug_X4);
            pass = 1'b0;
        end

        if (pass) begin
            $display("SUMMARY,status=PASS");
        end else begin
            $display("SUMMARY,status=FAIL");
        end

        #100;
        $finish;
    end
endmodule
