`timescale 1ns/1ps
module tb_selected_soc;
    parameter IMEM_FILE = "";
    parameter DMEM_FILE = "";
    reg clk = 0, button_n = 0;
    wire [15:0] pins;
    wire uart_tx, lora_tx;
    selected_soc #(.RESET_CYCLES(8)) dut(
        .clk(clk), .reset_button_n(button_n), .gpio_io(pins),
        .uart_rx(1'b1), .lora_rx(1'b1), .lora_aux(1'b1),
        .uart_tx(uart_tx), .lora_tx(lora_tx));
    defparam dut.cpu.if_id_register.u_IMEM.INIT_FILE = IMEM_FILE;
    defparam dut.dmem.u_bram.INIT_FILE = DMEM_FILE;
    always #10 clk = ~clk;
    reg [31:0] sig_addr, scratch_addr, fault_pc, sig_observed;
    integer cycles = 0, busy_waits = 0, error_pairs = 0;
    integer tx0 = 0, tx1 = 0;
    reg error_pending = 0, completed = 0, observed_pending;
    reg held = 0;
    reg [31:0] held_addr, held_data;
    reg [2:0] held_size;
    reg held_write;
    reg [1:0] held_trans;
    reg finishing = 0;
    // Expectations are literal contract/firmware stimuli, never DUT-derived.
    always @(posedge clk) if (dut.reset_n && !finishing) begin
        cycles = cycles + 1;
        if (held && !(dut.hresp == 1 && dut.hready)) begin
            if ({dut.haddr,dut.hwdata,dut.hsize,dut.hwrite,dut.htrans} !==
                {held_addr,held_data,held_size,held_write,held_trans})
                $fatal(1,"ASSERT_FAIL BUS_HOLD");
        end
        held = !dut.hready;
        held_addr=dut.haddr; held_data=dut.hwdata; held_size=dut.hsize;
        held_write=dut.hwrite; held_trans=dut.htrans;
        if (dut.psel & ~16'h0057) $fatal(1,"ASSERT_FAIL EXCLUDED_PSEL");
        if (dut.psel[0] && dut.penable && !dut.pready) busy_waits=busy_waits+1;
        if (dut.penable && dut.pwrite && dut.pready && dut.paddr==32'h40000000) begin
            if (dut.pwdata !== (tx0==0 ? 32'h31 : 32'h32) || tx0>=2)
                $fatal(1,"ASSERT_FAIL UART0_EXACTLY_ONCE");
            tx0=tx0+1;
        end
        if (dut.penable && dut.pwrite && dut.pready && dut.paddr==32'h40060000) begin
            if (dut.pwdata !== (tx1==0 ? 32'h41 : 32'h42) || tx1>=2)
                $fatal(1,"ASSERT_FAIL UART1_EXACTLY_ONCE");
            tx1=tx1+1;
        end
        if (dut.hresp==1) begin
            if (!dut.hready) begin
                if (error_pending) $fatal(1,"ASSERT_FAIL ERROR_TOO_LONG");
                error_pending=1;
            end else begin
                // Fault adapter changes only checker observation, not the DUT.
                observed_pending=error_pending;
                if ($test$plusargs("inject_error")) begin
                    observed_pending=0;
                    $display("INJECTION_REACHED checker ERROR_PHASE");
                end
                if (!observed_pending) $fatal(1,"ASSERT_FAIL ERROR_PHASE");
                error_pairs=error_pairs+1; error_pending=0;
            end
        end else if(error_pending) $fatal(1,"ASSERT_FAIL ERROR_PHASE");
        if (dut.cpu.csr_file.mcause != 0 &&
            (dut.cpu.csr_file.mcause !== 5 || dut.cpu.csr_file.mepc !== fault_pc))
            $fatal(1,"ASSERT_FAIL PRECISE_TRAP");
        if (cycles>200000) $fatal(1,"ASSERT_FAIL SMOKE_TIMEOUT");
    end
    initial begin
        if (!$value$plusargs("sig_addr=%h",sig_addr) ||
            !$value$plusargs("scratch_addr=%h",scratch_addr) ||
            !$value$plusargs("fault_pc=%h",fault_pc)) $fatal(1,"SYMBOLS_REQUIRED");
        repeat(4) @(negedge clk); button_n=1;
        wait(dut.reset_n); wait(dut.cpu.csr_file.mcause==5);
        repeat(8) @(negedge clk);
        sig_observed=dut.dmem.u_bram.words[(sig_addr-32'h10000000)>>2];
        if ($test$plusargs("inject_signature")) begin
            sig_observed=sig_observed^1;
            $display("INJECTION_REACHED checker CPU_SIGNATURE");
        end
        if (sig_observed !== 32'h50313447) $fatal(1,"ASSERT_FAIL CPU_SIGNATURE");
        if (dut.dmem.u_bram.words[(scratch_addr-32'h10000000)>>2] !== 32'hf1238501 ||
            dut.dmem.u_bram.words[((scratch_addr-32'h10000000)>>2)+1] !== 32'hf1238501)
            $fatal(1,"ASSERT_FAIL MEMORY_BYTE_RAW");
        if (dut.cpu.csr_file.mepc !== fault_pc || error_pairs!=1 || error_pending)
            $fatal(1,"ASSERT_FAIL PRECISE_ERROR_PC");
        if (tx0!=2 || tx1!=2 || busy_waits<100) $fatal(1,"ASSERT_FAIL UART_WAIT");
        if (pins !== 16'ha55a) $fatal(1,"ASSERT_FAIL GPIO_OUTPUT");
        $display("CHECK CPU_SIGNATURE MEMORY_BYTE_RAW PRECISE_ERROR_PC UART_WAIT GPIO_OUTPUT pairs=%0d waits=%0d",error_pairs,busy_waits);
        finishing=1; button_n=0; #1;
        if (dut.reset_n !== 0 || pins !== 16'hzzzz)
            $fatal(1,"ASSERT_FAIL ASYNC_RESET_HIZ");
        if (dut.dmem.u_bram.words[(scratch_addr-32'h10000000)>>2] !== 32'hf1238501)
            $fatal(1,"ASSERT_FAIL RESET_MEMORY_RETENTION");
        $display("CHECK ASYNC_RESET_HIZ RESET_MEMORY_RETENTION");
        completed=1; $display("SUMMARY_PASS SELECTED_CPU_SMOKE"); $finish;
    end
    final if (!completed) $display("SELECTED_INCOMPLETE");
endmodule
