`timescale 1ns/1ps
// Real AHB master + production AHB/APB bridge with PREADY=0 insertion.
module tb_trap_precision_apb_wait;
    reg clk = 0, reset = 1, clk_enable = 1, PREADY = 0;
    always #5 clk = ~clk;
    wire [31:0] HADDR, HWDATA, HRDATA, read_data, store_data, ex_addr;
    wire HWRITE, bus_stall_req, ex_read, ex_write, HREADY;
    wire [1:0] HTRANS, HRESP;
    wire [2:0] HSIZE, HBURST, ex_funct3;
    wire [3:0] write_mask, mask_out;
    wire [31:0] bridge_data, PADDR, PWDATA;
    wire bridge_ready, PWRITE, PENABLE, PCLK, PRESETn;
    wire [1:0] bridge_resp;
    wire [15:0] PSEL;
    wire HSEL = (HADDR[31:20] == 12'h400) && HTRANS[1];
    reg selected_d = 0;
    integer i, cycles, commits, mepc_writes, mcause_writes;
    integer mtvec_reqs, mtvec_consumes, redirects, fault_clears, apb_completions;
    integer fault_wb_cycles;
    reg [63:0] minstret_before;
    reg sampled_commit;
    reg sampled_redirect;
    reg saw_access_wait;
    reg [31:0] held_addr;
    reg held_write;
    reg [15:0] held_psel;
    assign HREADY = selected_d ? bridge_ready : 1'b1;
    assign HRESP = selected_d ? bridge_resp : 2'b00;
    assign HRDATA = selected_d ? bridge_data : 32'd0;
    always @(posedge clk or posedge reset)
        if (reset) selected_d <= 0;
        else if (HREADY) selected_d <= HSEL;

    RV32I46F5SPMMIO dut (
        .clk(clk), .clk_enable(clk_enable), .reset(reset),
        .retire_instruction(), .debug_X1(), .debug_X2(), .debug_X3(),
        .debug_X4(), .debug_pc(),
        .EX_memory_read_AHB(ex_read), .EX_memory_write_AHB(ex_write),
        .EX_alu_result_AHB(ex_addr), .EX_funct3_AHB(ex_funct3),
        .data_memory_read_data_AHB(store_data),
        .HRDATA_FROM_AHB(read_data), .HRESP_FROM_AHB(HRESP),
        .HREADY_FROM_AHB(HREADY), .bus_stall_req(bus_stall_req),
        .CUSTOM_WRITE_MASK(write_mask), .oBRAM_HAZARD()
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
    AHB_APB_bridge bridge (
        .HCLK(clk), .HRESETn(!reset), .HADDR(HADDR), .HWRITE(HWRITE),
        .HTRANS(HTRANS), .HSIZE(HSIZE), .HWDATA(HWDATA),
        .HSEL(HSEL), .HREADY_IN(HREADY),
        .HRDATA(bridge_data), .HREADY(bridge_ready), .HRESP(bridge_resp),
        .PCLK(PCLK), .PRESETn(PRESETn), .PADDR(PADDR),
        .PWRITE(PWRITE), .PENABLE(PENABLE), .PSEL(PSEL),
        .PWDATA(PWDATA), .PRDATA(32'd19),
        .PREADY(PREADY), .PSLVERR(1'b0)
    );

    always @(posedge clk) if (!reset) begin
        minstret_before = dut.csr_file.minstret;
        sampled_commit = dut.commit_valid;
        sampled_redirect = dut.trap_redirect_fire && !dut.mret_redirect_fire;
        if (sampled_commit) begin
            if (commits == 0 &&
                (dut.WB_pc !== 0 || dut.WB_instruction !== 32'h0000A103))
                $fatal(1, "APB older load commit wrong");
            if (commits == 1 &&
                (dut.WB_pc !== 4 || dut.WB_instruction !== 32'h00100193))
                $fatal(1, "APB older ALU commit wrong");
            if (commits >= 2 && !redirects)
                $fatal(1, "APB younger fault/extra token retired");
            commits = commits + 1;
        end
        if (dut.WB_valid && dut.WB_exc_valid) begin
            fault_wb_cycles = fault_wb_cycles + 1;
            if (dut.WB_pc !== 8 || dut.commit_valid ||
                dut.gpr_commit || dut.normal_csr_write)
                $fatal(1, "APB fault WB ownership wrong");
        end
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h341) begin
            mepc_writes = mepc_writes + 1;
            if (dut.trap_wr_data !== 8) $fatal(1, "APB fault mepc wrong");
        end
        if (dut.trap_wr_valid && dut.trap_wr_addr == 12'h342) begin
            mcause_writes = mcause_writes + 1;
            if (dut.trap_wr_data !== 2) $fatal(1, "APB fault cause wrong");
        end
        if (dut.trap_req_valid) mtvec_reqs = mtvec_reqs + 1;
        if (dut.trap_rsp_consume) mtvec_consumes = mtvec_consumes + 1;
        if (sampled_redirect) begin
            if (!dut.WB_valid || !dut.WB_exc_valid)
                $fatal(1, "APB trap redirect lacked fault owner");
            redirects = redirects + 1;
        end
        if (PSEL[0] && PENABLE && PREADY)
            apb_completions = apb_completions + 1;
        if (PSEL[0] && PENABLE && !PREADY) saw_access_wait = 1;
        #1;
        if (sampled_redirect) begin
            if (dut.WB_exc_valid)
                $fatal(1, "APB fault WB did not clear");
            fault_clears = fault_clears + 1;
        end
        if (dut.csr_file.minstret !== minstret_before + sampled_commit)
            $fatal(1, "APB wait minstret delta mismatch");
    end

    initial begin
        #1;
        for (i = 0; i < 32; i = i + 1)
            dut.register_file.registers[i] = 0;
        dut.register_file.registers[1] = 32'h40000000;
        for (i = 0; i < 64; i = i + 1)
            dut.if_id_register.u_IMEM.words[i] = 32'h00000013;
        dut.if_id_register.u_IMEM.words[0] = 32'h0000A103; // older APB lw
        dut.if_id_register.u_IMEM.words[1] = 32'h00100193; // older addi x3,1
        dut.if_id_register.u_IMEM.words[2] = 32'h00000000; // younger illegal
        dut.if_id_register.u_IMEM.words[3] = 32'h00900293; // killed
        dut.if_id_register.u_IMEM.words[12'hB58] = 32'h00700393;
        commits = 0; mepc_writes = 0; mcause_writes = 0;
        mtvec_reqs = 0; mtvec_consumes = 0; redirects = 0; fault_clears = 0;
        apb_completions = 0; fault_wb_cycles = 0;
        saw_access_wait = 0;
        repeat (3) @(negedge clk);
        reset = 0;
        begin : waiting_access
            for (cycles = 0; cycles < 40; cycles = cycles + 1) begin
                @(negedge clk);
                if (PSEL[0] && PENABLE && !PREADY)
                    disable waiting_access;
            end
            $fatal(1, "APB ACCESS wait not reached");
        end
        held_addr = PADDR; held_write = PWRITE; held_psel = PSEL;
        repeat (3) begin
            @(posedge clk); #1;
            if (!saw_access_wait || HREADY || !bus_stall_req ||
                PADDR !== held_addr || PWRITE !== held_write ||
                PSEL !== held_psel || !PENABLE ||
                dut.commit_valid || dut.trap_wr_valid || dut.trap_redirect_fire)
                $fatal(1, "APB wait did not hold transfer/tokens");
        end
        @(negedge clk); PREADY = 1;
        begin : waiting_trap
            for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
                @(negedge clk);
                if (redirects == 1) disable waiting_trap;
            end
            $fatal(1, "APB wait + younger fault trap timeout");
        end
        if (commits != 2 || apb_completions != 1 ||
            mepc_writes != 1 || mcause_writes != 1 ||
            mtvec_reqs != 1 || mtvec_consumes != 1 ||
            redirects != 1 || fault_clears != 1 ||
            fault_wb_cycles == 0 ||
            dut.csr_file.mepc !== 8 || dut.csr_file.mcause !== 2 ||
            dut.register_file.registers[2] !== 19 ||
            dut.register_file.registers[3] !== 1 ||
            dut.register_file.registers[5] !== 0)
            $fatal(1, "APB wait precise trap scoreboard mismatch commits=%0d apb=%0d mepc=%h cause=%h x2=%h",
                   commits, apb_completions, dut.csr_file.mepc,
                   dut.csr_file.mcause, dut.register_file.registers[2]);
        begin : target_wait
            for (cycles = 0; cycles < 8; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (dut.ID_valid) begin
                    if (dut.ID_pc !== 32'h00006d60 ||
                        dut.ID_instruction !== 32'h00700393)
                        $fatal(1, "APB stale fetch after trap redirect");
                    disable target_wait;
                end
            end
            $fatal(1, "APB trap target token absent");
        end
        $display("PASS APB PREADY wait + younger ID fault / older completion");
        $display("SUMMARY: PASS TRAP-002 APB precision");
        $finish;
    end
endmodule
