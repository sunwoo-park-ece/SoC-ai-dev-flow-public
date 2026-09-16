`timescale 1ns/1ps
module tb_cpu_access_fault;
    reg clk = 0, reset = 1;
    wire [31:0] HADDR, HWDATA, HRDATA;
    wire HWRITE, bus_stall_req;
    wire [1:0] HTRANS, HRESP;
    wire [2:0] HSIZE, HBURST;
    wire [3:0] write_mask, mask_out;
    wire ex_read, ex_write, bram_hazard;
    wire [31:0] ex_addr, store_data, read_data, retire_instruction;
    wire [2:0] ex_funct3;
    wire HREADY;
    reg [1:0] response_state = 0;
    integer cycles, faults_seen;
    always #5 clk = ~clk;
    always @(posedge clk)
        if (!reset && dut.WB_valid && dut.WB_pc == 32'd8 &&
            (!dut.WB_exc_valid || dut.WB_register_write_enable ||
             dut.WB_csr_write_enable || dut.wb_owner_release))
            $fatal(1, "failed memory token reached WB without fault ownership");
    assign HRDATA = 32'b0;
    assign HREADY = (response_state != 2'd1);
    assign HRESP = (response_state == 0) ? 2'b00 : 2'b01;

    always @(posedge clk or posedge reset) begin
        if (reset) response_state <= 0;
        else case (response_state)
            0: if (HTRANS[1]) response_state <= 1;
            1: response_state <= 2;
            2: response_state <= 0;
            default: response_state <= 0;
        endcase
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

    task init_load_program;
        begin
            dut.if_id_register.u_IMEM.words[0] = 32'h500000b7; // lui x1,0x50000
            dut.if_id_register.u_IMEM.words[1] = 32'h00700113; // addi x2,x0,7
            dut.if_id_register.u_IMEM.words[2] = 32'h0000a103; // lw x2,0(x1)
            dut.if_id_register.u_IMEM.words[3] = 32'h00100193; // addi x3,x0,1, younger
        end
    endtask
    task init_store_program;
        begin
            dut.if_id_register.u_IMEM.words[0] = 32'h500000b7; // lui x1,0x50000
            dut.if_id_register.u_IMEM.words[1] = 32'h05500113; // addi x2,x0,0x55
            dut.if_id_register.u_IMEM.words[2] = 32'h0020a023; // sw x2,0(x1)
            dut.if_id_register.u_IMEM.words[3] = 32'h00100193; // addi x3,x0,1, younger
        end
    endtask
    task run_case(input [31:0] expected_cause);
        begin : run_block
            faults_seen = 0;
            for (cycles=0; cycles<120; cycles=cycles+1) begin
                @(posedge clk); #1;
                if (dut.bus_fault_final) faults_seen = faults_seen + 1;
                if (dut.csr_file.mcause == expected_cause) begin
                    if (dut.csr_file.mepc !== 32'd8)
                        $fatal(1, "mepc=%h expected=8",dut.csr_file.mepc);
                    if (dut.register_file.registers[2] !== (expected_cause == 5 ? 32'd7 : 32'h55))
                        $fatal(1, "failed load/store changed x2");
                    $display("case cause=%0d mepc=%h cycles=%0d",expected_cause,dut.csr_file.mepc,cycles);
                    disable run_block;
                end
            end
            $fatal(1, "access fault timeout cause=%0d pc=%h mem_pc=%h hresp=%b ready=%b",
                   expected_cause,dut.pc,dut.MEM_pc,HRESP,HREADY);
        end
    endtask

    initial begin
        #1; init_load_program();
        repeat (4) @(posedge clk);
        @(negedge clk); reset=0;
        run_case(32'd5);
        repeat (20) @(posedge clk);
        #1;
        if (dut.register_file.registers[3] !== 0 || dut.access_fault_active !== 0)
            $fatal(1, "load fault did not flush younger instruction or finish trap");
        @(negedge clk); reset=1;
        init_store_program();
        repeat (4) @(posedge clk);
        @(negedge clk); reset=0;
        run_case(32'd7);
        repeat (20) @(posedge clk);
        #1;
        if (dut.register_file.registers[3] !== 0 || dut.access_fault_active !== 0)
            $fatal(1, "store fault did not flush younger instruction or finish trap");
        $display("SUMMARY: PASS CPU access-fault causes, mepc, failed-load writeback");
        $finish;
    end
endmodule
