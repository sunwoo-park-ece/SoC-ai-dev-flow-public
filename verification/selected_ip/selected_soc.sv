// Test-only composition of existing selected IP; not a production board top.
// Removed slots are errors here. The legacy SoC and bridge remain unchanged.
module selected_soc #(
    parameter RESET_CYCLES = 1_000_000
) (
    input wire clk, reset_button_n,
    input wire uart_rx, lora_rx, lora_aux,
    output wire uart_tx, lora_tx,
    inout wire [15:0] gpio_io
);
    wire reset_n;
    system_reset_controller #(.RELEASE_CYCLES(RESET_CYCLES)) reset_ctrl(
        .clk(clk), .reset_button_n(reset_button_n), .system_reset_n(reset_n));
    wire ex_read, ex_write, raw_hazard, bus_stall;
    wire [31:0] ex_addr, store_data, cpu_rdata;
    wire [2:0] ex_funct3;
    wire [3:0] cpu_mask, mask;
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0] htrans, hresp;
    wire [2:0] hsize, hburst;
    wire hwrite, hready;
    RV32I46F5SPMMIO cpu(
        .clk(clk), .clk_enable(1'b1), .reset(!reset_n),
        .retire_instruction(), .debug_X1(), .debug_X2(), .debug_X3(),
        .debug_X4(), .debug_pc(), .EX_memory_read_AHB(ex_read),
        .EX_memory_write_AHB(ex_write), .EX_alu_result_AHB(ex_addr),
        .EX_funct3_AHB(ex_funct3), .MEM_store_data_AHB(store_data),
        .HRDATA_FROM_AHB(cpu_rdata), .HRESP_FROM_AHB(hresp),
        .HREADY_FROM_AHB(hready), .bus_stall_req(bus_stall),
        .CUSTOM_WRITE_MASK(cpu_mask), .oBRAM_HAZARD(raw_hazard));
    AHB_Master_Interface master(
        .EX_memory_read(ex_read), .EX_memory_write(ex_write),
        .EX_alu_result(ex_addr), .EX_funct3(ex_funct3),
        .MEM_read_data2(store_data), .HRDATA_to_CPU(cpu_rdata),
        .bus_stall_req(bus_stall), .HADDR(haddr), .HWRITE(hwrite),
        .HTRANS(htrans), .HSIZE(hsize), .HBURST(hburst), .HWDATA(hwdata),
        .HRDATA(hrdata), .HREADY(hready),
        .CUSTOM_WRITE_MASK_IN(cpu_mask), .CUSTOM_WRITE_MASK_OUT(mask));
    wire valid = htrans[1] && !(hready && hresp == 2'b01);
    wire size_ok = (hsize == 0) || (hsize == 1 && !haddr[0]) ||
                   (hsize == 2 && haddr[1:0] == 0);
    wire mem_sel = valid && size_ok && haddr[31:15] == 17'h02000;
    wire selected_slot = haddr[19:16] == 0 || haddr[19:16] == 1 ||
                         haddr[19:16] == 2 || haddr[19:16] == 4 ||
                         haddr[19:16] == 6;
    wire apb_sel = valid && haddr[31:20] == 12'h400 && selected_slot;
    wire err_sel = valid && !(mem_sel || apb_sel);
    reg mem_owner, apb_owner, err_owner, err_final;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mem_owner <= 0; apb_owner <= 0; err_owner <= 0; err_final <= 0;
        end else begin
            if (err_owner && !err_final) err_final <= 1;
            else if (hready) err_final <= 0;
            if (hready && hresp == 1) begin
                mem_owner <= 0; apb_owner <= 0; err_owner <= 0;
            end else if (hready) begin
                mem_owner <= mem_sel; apb_owner <= apb_sel; err_owner <= err_sel;
            end
        end
    end
    wire [31:0] mem_data, apb_data;
    wire mem_ready, apb_ready;
    wire [1:0] mem_resp, apb_resp;
    assign hrdata = mem_owner ? mem_data : apb_owner ? apb_data : 32'b0;
    assign hready = mem_owner ? mem_ready : apb_owner ? apb_ready :
                    err_owner ? err_final : 1'b1;
    assign hresp = mem_owner ? mem_resp : apb_owner ? apb_resp :
                   err_owner ? 2'b01 : 2'b00;
    AHB_MEMORY_SLAVE dmem(
        .HCLK(clk), .HRESETn(reset_n), .HADDR(haddr), .HWRITE(hwrite),
        .HTRANS(htrans), .HSIZE(hsize), .HWDATA(hwdata), .HSEL(mem_sel),
        .HREADY_IN(hready), .byteena(mask), .BRAM_HAZARD(raw_hazard),
        .HRDATA(mem_data), .HREADY(mem_ready), .HRESP(mem_resp),
        .MEM_READ_FROM_CPU(ex_read));
    wire pclk, presetn, pwrite, penable, pready;
    wire [31:0] paddr, pwdata, prdata;
    wire [15:0] psel;
    AHB_APB_bridge bridge(
        .HCLK(clk), .HRESETn(reset_n), .HADDR(haddr), .HWRITE(hwrite),
        .HTRANS(htrans), .HSIZE(hsize), .HWDATA(hwdata), .HSEL(apb_sel),
        .HREADY_IN(hready), .HRDATA(apb_data), .HREADY(apb_ready),
        .HRESP(apb_resp), .PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(prdata), .PREADY(pready), .PSLVERR(1'b0));
    wire [31:0] uart0_data, uart1_data, timer_data, gpio_data, aes_data;
    wire uart0_ready, uart1_ready, timer_ready, gpio_ready, aes_ready, gpio_irq;
    assign prdata = psel[0] ? uart0_data : psel[1] ? gpio_data :
                    psel[2] ? timer_data : psel[4] ? aes_data :
                    psel[6] ? uart1_data : 32'b0;
    assign pready = psel[0] ? uart0_ready : psel[1] ? gpio_ready :
                    psel[2] ? timer_ready : psel[4] ? aes_ready :
                    psel[6] ? uart1_ready : 1'b1;
    APB_UART_LORA uart0(.PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel[0]), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(uart0_data), .PREADY(uart0_ready), .uart_rx(lora_rx),
        .uart_tx(lora_tx), .lora_aux(lora_aux));
    APB_UART uart1(.PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel[6]), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(uart1_data), .PREADY(uart1_ready), .uart_rx(uart_rx), .uart_tx(uart_tx));
    APB_TIMER timer(.PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel[2]), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(timer_data), .PREADY(timer_ready));
    APB_GPIO gpio(.PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel[1]), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(gpio_data), .PREADY(gpio_ready), .GPIO_IO(gpio_io), .gpio_irq(gpio_irq));
    apb_aes_gcm aes(.PCLK(pclk), .PRESETn(presetn), .PADDR(paddr),
        .PWRITE(pwrite), .PSEL(psel[4]), .PENABLE(penable), .PWDATA(pwdata),
        .PRDATA(aes_data), .PREADY(aes_ready));
endmodule
