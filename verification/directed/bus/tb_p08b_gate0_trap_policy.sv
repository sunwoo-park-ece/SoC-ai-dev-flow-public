`timescale 1ns/1ps

// P08B Gate 0: distinguish precise CPU store-fault delivery from the current
// firmware image's lack of a valid handler at the reset mtvec target.
module tb_p08b_gate0_trap_policy;
    reg clk = 1'b0;
    reg reset = 1'b1;
    wire [31:0] HADDR, HWDATA, HRDATA;
    wire HWRITE, bus_stall_req;
    wire [1:0] HTRANS, HRESP;
    wire [2:0] HSIZE, HBURST;
    wire [3:0] write_mask, mask_out;
    wire ex_read, ex_write, bram_hazard;
    wire [31:0] ex_addr, store_data, read_data, retire_instruction;
    wire [2:0] ex_funct3;
    wire HREADY;

    reg [1:0] response_state = 2'd0;
    integer cycles;
    integer fault_final_count = 0;
    integer redirect_count = 0;
    reg saw_store_fault_redirect = 1'b0;
    reg saw_handler_illegal_redirect = 1'b0;

    always #5 clk = ~clk;

    assign HRDATA = 32'b0;
    assign HREADY = (response_state != 2'd1);
    assign HRESP = (response_state == 2'd0) ? 2'b00 : 2'b01;

    // Project-conformant two-cycle ERROR for the one failing store:
    // phase 1 ERROR/!READY, phase 2 ERROR/READY.
    always @(posedge clk or posedge reset) begin
        if (reset)
            response_state <= 2'd0;
        else begin
            case (response_state)
                2'd0: if (HTRANS[1] && HWRITE) response_state <= 2'd1;
                2'd1: response_state <= 2'd2;
                2'd2: response_state <= 2'd0;
                default: response_state <= 2'd0;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!reset && dut.bus_fault_final)
            fault_final_count = fault_final_count + 1;

        if (!reset && dut.trap_redirect_fire) begin
            redirect_count = redirect_count + 1;
            if (!saw_store_fault_redirect) begin
                if (dut.csr_file.mcause !== 32'd7 ||
                    dut.csr_file.mepc !== 32'd8 ||
                    dut.trap_target !== 32'h0000_6d60)
                    $fatal(1,
                        "store-fault redirect mismatch cause=%0d mepc=%h target=%h",
                        dut.csr_file.mcause, dut.csr_file.mepc, dut.trap_target);
                saw_store_fault_redirect = 1'b1;
            end else if (!saw_handler_illegal_redirect) begin
                if (dut.csr_file.mcause !== 32'd2 ||
                    dut.csr_file.mepc !== 32'h0000_6d60 ||
                    dut.trap_target !== 32'h0000_6d60)
                    $fatal(1,
                        "handler-fault redirect mismatch cause=%0d mepc=%h target=%h",
                        dut.csr_file.mcause, dut.csr_file.mepc, dut.trap_target);
                saw_handler_illegal_redirect = 1'b1;
            end
        end
    end

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(1'b1), .reset(reset),
        .retire_instruction(retire_instruction),
        .debug_X1(), .debug_X2(), .debug_X3(), .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(ex_read), .EX_memory_write_AHB(ex_write),
        .EX_alu_result_AHB(ex_addr), .EX_funct3_AHB(ex_funct3),
        .data_memory_read_data_AHB(store_data),
        .HRDATA_FROM_AHB(read_data), .HRESP_FROM_AHB(HRESP),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(bus_stall_req),
        .CUSTOM_WRITE_MASK(write_mask), .oBRAM_HAZARD(bram_hazard)
    );

    AHB_Master_Interface master (
        .EX_memory_read(ex_read), .EX_memory_write(ex_write),
        .EX_alu_result(ex_addr), .EX_funct3(ex_funct3),
        .MEM_read_data2(store_data), .HRDATA_to_CPU(read_data),
        .bus_stall_req(bus_stall_req), .HADDR(HADDR), .HWRITE(HWRITE),
        .HTRANS(HTRANS), .HSIZE(HSIZE), .HBURST(HBURST),
        .HWDATA(HWDATA), .HRDATA(HRDATA), .HREADY(HREADY),
        .CUSTOM_WRITE_MASK_IN(write_mask), .CUSTOM_WRITE_MASK_OUT(mask_out)
    );

    initial begin
        // Failing SW at PC 8. The reset mtvec 0x6d60 reaches physical IMEM
        // word address 0xB58 (2904) because the active IMEM port is 12 bits.
        // Current final_main/display_smoke MIFs contain 0x00000000 there and
        // firmware/start.S installs no alternate mtvec or handler.
        dut.if_id_register.u_IMEM.words[0] = 32'h5000_00b7; // lui x1,0x50000
        dut.if_id_register.u_IMEM.words[1] = 32'h0550_0113; // addi x2,x0,0x55
        dut.if_id_register.u_IMEM.words[2] = 32'h0020_a023; // sw x2,0(x1)
        dut.if_id_register.u_IMEM.words[3] = 32'h0010_0193; // younger, must flush
        dut.if_id_register.u_IMEM.words[12'hb58] = 32'h0000_0000;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        begin : wait_for_two_redirects
            for (cycles = 0; cycles < 240; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (saw_handler_illegal_redirect)
                    disable wait_for_two_redirects;
            end
            $fatal(1, "Gate-0 trap-policy observation timed out redirects=%0d",
                   redirect_count);
        end

        if (fault_final_count != 1)
            $fatal(1, "failing store final ERROR count=%0d expected=1",
                   fault_final_count);
        if (dut.register_file.registers[3] !== 32'd0)
            $fatal(1, "younger instruction committed across store fault");

        $display("GATE0: precise store fault PASS; current firmware trap policy UNSAFE");
        $display("GATE0: mtvec=00006d60 aliases IMEM[0xb58]=00000000 and retraps");
        $display("SUMMARY: PASS P08B Gate-0 incompatibility detection");
        $finish;
    end
endmodule
