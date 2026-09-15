// AMBA SoC 최상위 모듈

module AMBA_SoC_TOP (

// 시스템 신호
input clk,        // 시스템 클록 (50MHz)


/*
input HRESETn,
output [31:0] debug_pc,
output [31:0] debug_X4
*/


    input [1:0] KEY,
	 input [9:0] SW,
    output [9:0] LEDR,
    inout [15:0] GPIO_IO,
	 output wire [6:0] HEX0,    
    output wire [6:0] HEX1,
    output wire [6:0] HEX2,
    output wire [6:0] HEX3,
    output wire [6:0] HEX4,
    output wire [6:0] HEX5,

//////////// Accelerometer //////////
	output		          	G_SENSOR_CS_N,
	input 		     [2:1]		G_SENSOR_INT,
	output		          	G_SENSOR_SCLK,
///////////    4-wire SPI     //////////
	output 		          	G_SENSOR_SDI, // SLAVE DATA IN , MASTER DATA OUT
	input 		          		G_SENSOR_SDO,   // SLAVE DATA OUT, MASTER DATA IN

////////// VGA Output Ports //////////
   output wire [3:0] VGA_R, VGA_G, VGA_B,
   output wire       VGA_HS, VGA_VS,	 

//////////    UART Ports       //////////
output      lora_tx,   // UART0: LoRa 송신
input       lora_rx,   // UART0: LoRa 수신
input       lora_aux,  // LoRa AUX 제어 핀
output      uart_tx,   // UART1: PC 송신
input       uart_rx    // UART1: PC 수신
	
	
);

 wire HCLK = clk;

/*
    wire HCLK;  
	 
	system_pll system_clk(
	.inclk0(clk),
	.c0(HCLK)
	);
*/







// KEY[0] reset policy: asynchronous assertion, HCLK-synchronous release after
// 1,000,000 qualified cycles (20 ms at 50 MHz), deterministic FPGA power-up.
wire PRESETN_SYS;
system_reset_controller #(
    .RELEASE_CYCLES (1_000_000),
    .COUNTER_WIDTH  (20)
) u_system_reset_controller (
    .clk            (HCLK),
    .reset_button_n (KEY[0]),
    .system_reset_n (PRESETN_SYS)
);










	wire HRESETn = PRESETN_SYS;  // System reset (active low)
	
	wire [31:0] debug_X4;
    wire [31:0] debug_pc;
   // assign LEDR = debug_X4[9:0];
















// AHB 버스 신호
wire [31:0] HADDR;
wire        HWRITE;
wire [1:0]  HTRANS;
wire [2:0]  HSIZE;
wire [2:0]  HBURST;
wire [31:0] HWDATA;
wire [31:0] HRDATA;
wire        HREADY;
wire [1:0]  HRESP;


// 개별 슬레이브 응답 신호
wire [31:0] HRDATA_MEM, HRDATA_VRAM, HRDATA_APB;
wire HREADY_MEM, HREADY_VRAM, HREADY_APB;
wire [1:0] HRESP_MEM, HRESP_VRAM, HRESP_APB;

// APB 버스 신호
wire PCLK;
wire PRESETn;

wire [31:0] PADDR;
wire        PWRITE;
wire        PENABLE;
wire [15:0] PSEL;
wire [31:0] PWDATA;
wire [31:0] PRDATA;
wire         PREADY_FLAG;


wire BRAM_HAZARD; // cpu에서 출력하는 DMEM에 읽기와 쓰기가 동시에 일어날 때 발생하는 HAZARD 조건


// APB 개별 슬레이브 응답 신호
wire [31:0] PRDATA_UART0, PRDATA_UART1, PRDATA_GPIO, PRDATA_TIMER, PRDATA_GSENSOR, PRDATA_AES, PRDATA_JOYSTICK, PRDATA_HEX, PRDATA_SW, PRDATA_LED;


// DE10-lite 보드의 BRAM 크기는 204KB 

// 1. Address Decode (0x10000000~0x10007FFF → 0~8191) <참고로 0x1000_0000~0x1000_FFFF는 64 KB>
// 슬레이브 선택 신호 (주소 디코딩)
wire error_response_final = HREADY && (HRESP == 2'b01);
wire transfer_valid = HTRANS[1] && !error_response_final;
// The final ERROR cycle cancels the following address phase at every slave,
// not just in the top-level data-phase mux.
wire size_supported = (HSIZE == 3'b000) || (HSIZE == 3'b001) || (HSIZE == 3'b010);
wire size_aligned = (HSIZE == 3'b000) ||
                    ((HSIZE == 3'b001) && !HADDR[0]) ||
                    ((HSIZE == 3'b010) && (HADDR[1:0] == 2'b00));
wire fb_address = (HADDR >= 32'h2000_0000) && (HADDR <= 32'h2000_95ff);
wire vga_status_address = (HADDR == 32'h2001_0000);
wire vga_control_address = (HADDR == 32'h2001_0004);
wire vga_access_valid = (HSIZE == 3'b010) && (HADDR[1:0] == 2'b00) &&
                        ((fb_address && HWRITE) || vga_status_address ||
                         (vga_control_address && HWRITE));
wire HSEL_MEM = transfer_valid && size_supported && size_aligned &&
                (HADDR[31:15] == 17'h02000); // 32 KiB, no upper alias.
wire HSEL_VRAM = transfer_valid && vga_access_valid;
wire HSEL_APB = transfer_valid && (HADDR[31:20] == 12'h400);
wire HSEL_ERROR = transfer_valid && !(HSEL_MEM || HSEL_VRAM || HSEL_APB);

    // =======================================================
    // 2. Data Phase Latch (핵심 수정 사항)
    // =======================================================
    // Address Phase의 HSEL을 1클럭 지연시켜 Data Phase용으로 만듭니다.
    reg HSEL_MEM_d;
	 reg HSEL_VRAM_d;
	 reg HSEL_APB_d;
    reg HSEL_ERROR_d;
    reg default_error_final;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            HSEL_MEM_d  <= 1'b0;
				HSEL_VRAM_d <= 1'b0;
            HSEL_APB_d    <= 1'b0;
            HSEL_ERROR_d  <= 1'b0;
            default_error_final <= 1'b0;
        end else begin
          if (HSEL_ERROR_d && !default_error_final)
              default_error_final <= 1'b1;
          else if (HREADY)
              default_error_final <= 1'b0;
          if (HREADY && HRESP == 2'b01) begin
              // AHB ERROR final cycle cancels the next address phase.
              HSEL_MEM_d <= 1'b0;
              HSEL_VRAM_d <= 1'b0;
              HSEL_APB_d <= 1'b0;
              HSEL_ERROR_d <= 1'b0;
          end else if (HREADY) begin
            // [매우 중요] HREADY가 1일 때만(버스가 전진할 때만) 갱신합니다!
            // 슬레이브가 Wait State를 걸면, HSEL_d 값도 계속 유지되어야 MUX가 안 풀립니다.
            HSEL_MEM_d   <= HSEL_MEM;
				HSEL_VRAM_d <= HSEL_VRAM;
            HSEL_APB_d    <= HSEL_APB;
            HSEL_ERROR_d  <= HSEL_ERROR;
          end
        end
    end

// =======================================================
    // 3. Data Phase Multiplexer (읽기 데이터 및 HREADY 통합)
    // =======================================================
    // 이제 조합 논리(HSEL)가 아닌 순차 논리(HSEL_d)를 사용하여 MUX합니다.
    assign HRDATA = HSEL_MEM_d   ? HRDATA_MEM  :
										HSEL_VRAM_d ? HRDATA_VRAM :
									  HSEL_APB_d    ? HRDATA_APB    : 32'h0;
										

    // (참고) HREADY 신호 역시 Data Phase 기준이므로 
    // 동일하게 HSEL_d 신호로 MUX 해주어야 완벽한 버스가 됩니다.
    assign HREADY = HSEL_MEM_d  ? HREADY_MEM :
									  HSEL_VRAM_d? HREADY_VRAM :
									  HSEL_APB_d    ? HREADY_APB   :
                                      HSEL_ERROR_d ? default_error_final : 1'b1;




assign HRESP  = HSEL_MEM_d   ? HRESP_MEM :
								HSEL_VRAM_d ? HRESP_VRAM :
								HSEL_APB_d    ? HRESP_APB     :
                                HSEL_ERROR_d ? 2'b01 : 2'b00;


// APB 슬레이브 데이터 멀티플렉싱
assign PRDATA = (PSEL[0]) ? PRDATA_UART0 :      // UART0/LoRa: 0x4000_0000
                (PSEL[1]) ? PRDATA_GPIO :       // GPIO:       0x4001_0000
                (PSEL[2]) ? PRDATA_TIMER :      // TIMER:      0x4002_0000
                (PSEL[3]) ? PRDATA_GSENSOR:     // GSENSOR:    0x4003_0000
                (PSEL[4]) ? PRDATA_AES:         // AES-GCM:    0x4004_0000
                (PSEL[5]) ? PRDATA_JOYSTICK:    // JOYSTICK:   0x4005_0000
                (PSEL[6]) ? PRDATA_UART1:       // UART1/PC:   0x4006_0000
                (PSEL[7]) ? PRDATA_HEX:         // HEX:        0x4007_0000
                (PSEL[8]) ? PRDATA_SW:          // SW:         0x4008_0000
                (PSEL[9]) ? PRDATA_LED:         // LED:        0x4009_0000
		                32'h0;
		


wire TIMER_READY;
wire GPIO_READY;
wire UART0_READY;
wire UART1_READY;
wire GSENSOR_READY;
wire VGA_READY;
wire AES_READY;
wire JOYSTICK_READY;
wire HEX_READY;
wire SW_READY, LED_READY;
wire gpio_irq, sw_irq; // Local PLIC-ready sources; no CPU routing in P04.
wire APB_SLAVE_PREADY;

assign APB_SLAVE_PREADY = (PSEL[0]) ? UART0_READY :
                          (PSEL[1]) ? GPIO_READY :
                          (PSEL[2]) ? TIMER_READY :
                          (PSEL[3]) ? GSENSOR_READY :
                          (PSEL[4]) ? AES_READY :
                          (PSEL[5]) ? JOYSTICK_READY :
                          (PSEL[6]) ? UART1_READY :
                          (PSEL[7]) ? HEX_READY :
                          (PSEL[8]) ? SW_READY :
                          (PSEL[9]) ? LED_READY :
                          1'b1;



wire [3:0]write_mask;

wire         EX_memory_read_AHB;
wire         EX_memory_write_AHB;
wire [31:0] EX_alu_result_AHB;
wire [2:0]   EX_funct3_AHB;
wire [31:0] data_memory_read_data_AHB;
wire bus_stall_req;
wire [3:0] CUSTOM_WRITE_MASK_OUT;

wire [31:0] HRDATA_FROM_AHB;

// 모듈 인스턴스화
RV32I46F5SPMMIO u_CPU(
    .clk(HCLK),
    .clk_enable(1'b1),           // Added: Clock enable signal
    .reset(!HRESETn),
    .retire_instruction(),
	 .debug_X1(),
	 .debug_X2(),
    .debug_X3(),
	 .debug_X4(debug_X4),
	 .debug_pc(debug_pc),
	 .EX_memory_read_AHB (EX_memory_read_AHB),
	 .EX_memory_write_AHB(EX_memory_write_AHB),
	 .EX_alu_result_AHB      (EX_alu_result_AHB),
	 .EX_funct3_AHB          (EX_funct3_AHB),  
	 
	 .data_memory_read_data_AHB(data_memory_read_data_AHB),   // HWDATA (Store Align을 거친 쓰기 데이터)
	 	 
	 .HRDATA_FROM_AHB    (HRDATA_FROM_AHB),
	 .HRESP_FROM_AHB     (HRESP),
	 .HREADY_FROM_AHB    (HREADY),
	 .bus_stall_req                (bus_stall_req),
	 
	 .CUSTOM_WRITE_MASK(write_mask),
	 .oBRAM_HAZARD(BRAM_HAZARD)
	 
);


AHB_Master_Interface U_INTER(
    // [CPU EX 스테이지 입력] -> AHB Address Phase 제어
    .EX_memory_read(EX_memory_read_AHB),
    .EX_memory_write(EX_memory_write_AHB),
    .EX_alu_result(EX_alu_result_AHB),      // HADDR
    .EX_funct3(EX_funct3_AHB),           // HSIZE 디코딩용
    
	 // [CPU MEM 스테이지 입력] -> AHB Data Phase 제어
    .MEM_read_data2(data_memory_read_data_AHB),     // HWDATA (Store Align을 거친 쓰기 데이터)
    
	 // [CPU 출력 및 Stall 제어]
    .HRDATA_to_CPU(HRDATA_FROM_AHB),     // LoadExtender로 전달될 읽기 데이터
    .bus_stall_req(bus_stall_req),            // HazardUnit으로 보낼 Stall 요청 (HREADY == 0 일 때)
    
	 // [AHB-Lite 버스 마스터 인터페이스]
    .HADDR(HADDR),
    .HWRITE(HWRITE),
    .HTRANS(HTRANS),
    .HSIZE(HSIZE),
    .HBURST(HBURST),
    .HWDATA(HWDATA),
    .HRDATA(HRDATA),
    .HREADY(HREADY),
	 
	 .CUSTOM_WRITE_MASK_IN(write_mask),
	 .CUSTOM_WRITE_MASK_OUT(CUSTOM_WRITE_MASK_OUT)
);






// AHB 메모리 슬레이브
AHB_MEMORY_SLAVE u_memory (
.HCLK       (HCLK),
.HRESETn    (HRESETn),
.HADDR      (HADDR),
.HWRITE     (HWRITE),
.HTRANS     (HTRANS),
.HSIZE      (HSIZE),
.byteena    (CUSTOM_WRITE_MASK_OUT),
.HWDATA     (HWDATA),
.HSEL       (HSEL_MEM),
.HREADY_IN  (HREADY),
.HRDATA     (HRDATA_MEM),
.HREADY     (HREADY_MEM),
.HRESP      (HRESP_MEM),
.BRAM_HAZARD(BRAM_HAZARD),
.MEM_READ_FROM_CPU(EX_memory_read_AHB)
);


AHB_VRAM_DUAL_BUFFER U_VRAM (
.CLOCK_50 (clk),          // VGA용 25MHz PLL 소스 클럭
.HCLK        (HCLK),      // AHB HCLK 도메인
.HRESETn    (HRESETn),
.HADDR      (HADDR),
.HWRITE     (HWRITE),
.HTRANS     (HTRANS),
.HWDATA     (HWDATA),
.HSEL       (HSEL_VRAM),
.HREADY_IN  (HREADY),
.HRDATA     (HRDATA_VRAM),
.HREADY     (HREADY_VRAM),
.HRESP      (HRESP_VRAM),
 // VGA Output
.VGA_R        (VGA_R),
.VGA_G       (VGA_G),
.VGA_B        (VGA_B),
.VGA_HS     (VGA_HS),
.VGA_VS     (VGA_VS)
);



// AHB-APB 브릿지
AHB_APB_bridge u_bridge (
.HCLK       (HCLK),
.HRESETn    (HRESETn),
.HADDR      (HADDR),
.HWRITE     (HWRITE),
.HTRANS     (HTRANS),
.HSIZE      (HSIZE),
.HWDATA     (HWDATA),
.HSEL       (HSEL_APB),
.HREADY_IN  (HREADY),
.HRDATA     (HRDATA_APB),
.HREADY     (HREADY_APB),
.HRESP      (HRESP_APB),
.PCLK       (PCLK),
.PRESETn    (PRESETn),
.PADDR      (PADDR),
.PWRITE     (PWRITE),
.PENABLE    (PENABLE),
.PSEL       (PSEL),
.PWDATA     (PWDATA),
.PRDATA     (PRDATA),
.PREADY      (APB_SLAVE_PREADY),
.PSLVERR     (1'b0)
);




// APB UART0 슬레이브 -> LoRa 모듈과 연결 (0x4000_0000)
APB_UART_LORA u_uart0_lora (
.PCLK       (PCLK),
.PRESETn    (PRESETn),
.PADDR      (PADDR),
.PWRITE     (PWRITE),
.PSEL       (PSEL[0]),
.PENABLE    (PENABLE),
.PWDATA     (PWDATA),
.PRDATA     (PRDATA_UART0),
.uart_tx    (lora_tx),
.uart_rx    (lora_rx),
.lora_aux   (lora_aux),
.PREADY   (UART0_READY)
);


// APB UART1 슬레이브 -> PC와 연결 (0x4006_0000)
APB_UART u_uart1_pc (
.PCLK       (PCLK),
.PRESETn    (PRESETn),
.PADDR      (PADDR),
.PWRITE     (PWRITE),
.PSEL       (PSEL[6]),
.PENABLE    (PENABLE),
.PWDATA     (PWDATA),
.PRDATA     (PRDATA_UART1),
.uart_tx    (uart_tx),
.uart_rx    (uart_rx),
.PREADY   (UART1_READY)
);


// APB GPIO: JP1 GPIO_0..15, reset high impedance.
APB_GPIO u_gpio (
.PCLK       (PCLK),
.PRESETn    (PRESETn),
.PADDR      (PADDR),
.PWRITE     (PWRITE),
.PSEL       (PSEL[1]),
.PENABLE    (PENABLE),
.PWDATA     (PWDATA),
.PRDATA     (PRDATA_GPIO),
.GPIO_IO    (GPIO_IO),
.gpio_irq   (gpio_irq),
.PREADY   (GPIO_READY)
);

APB_SW u_sw (
    .PCLK(PCLK), .PRESETn(PRESETn), .PADDR(PADDR), .PWRITE(PWRITE),
    .PSEL(PSEL[8]), .PENABLE(PENABLE), .PWDATA(PWDATA),
    .PRDATA(PRDATA_SW), .PREADY(SW_READY), .SW(SW), .irq(sw_irq)
);

APB_LED u_led (
    .PCLK(PCLK), .PRESETn(PRESETn), .PADDR(PADDR), .PWRITE(PWRITE),
    .PSEL(PSEL[9]), .PENABLE(PENABLE), .PWDATA(PWDATA),
    .PRDATA(PRDATA_LED), .PREADY(LED_READY), .LEDR(LEDR)
);


// APB TIMER 슬레이브
	APB_TIMER u_timer (
    .PCLK    (PCLK),
    .PRESETn (PRESETn),
    .PADDR   (PADDR),
    .PSEL    (PSEL[2]),  // Bridge에서 PSEL[2]가 0x4002xxxx 디코딩 담당
    .PENABLE (PENABLE),
    .PWRITE  (PWRITE),
    .PWDATA  (PWDATA),
    .PRDATA  (PRDATA_TIMER),
	.counter_debug(),
	.PREADY  (TIMER_READY)
);

wire [15:0] debug_acc_x;
wire [15:0] debug_acc_y;

// APB GSENSOR 슬레이브
APB_GSENSOR_MB u_gsensor (
    .PCLK    (PCLK),
    .PRESETn (PRESETn),
	 .PADDR   (PADDR),
    .PSEL    (PSEL[3]),                           // Bridge에서 PSEL[3]가 0x4003xxxx 디코딩 담당
    .PENABLE (PENABLE),
    .PWRITE  (PWRITE),
    .PWDATA  (PWDATA),
    .PRDATA  (PRDATA_GSENSOR),
	 .PREADY  (GSENSOR_READY),
		//////////// Accelerometer ////////////
		.GSENSOR_CS_N(G_SENSOR_CS_N),
		.GSENSOR_INT(G_SENSOR_INT),
	.GSENSOR_SCLK(G_SENSOR_SCLK),
	.GSENSOR_SDI(G_SENSOR_SDI),                     // SLAVE DATA IN , MASTER DATA OUT
	.GSENSOR_SDO(G_SENSOR_SDO),                     // SLAVE DATA OUT, MASTER DATA IN
   .debug_acc_x(debug_acc_x),
		.debug_acc_y(debug_acc_y)	
);

// APB AES-GCM 슬레이브 (pipe0 wrapper)
apb_aes_gcm #(
    .PIPE_CFG(0)
) u_apb_aes_gcm (
    .PCLK      (PCLK),
    .PRESETn   (PRESETn),
    .PADDR     (PADDR),
    .PWRITE    (PWRITE),
    .PSEL      (PSEL[4]),
    .PENABLE   (PENABLE),
    .PWDATA    (PWDATA),
    .PRDATA    (PRDATA_AES),
    .PREADY    (AES_READY)
);


wire        adc_command_valid;
wire [4:0]  adc_command_channel;
wire        adc_command_startofpacket;
wire        adc_command_endofpacket;
wire        adc_command_ready;
wire        adc_response_valid;
wire [4:0]  adc_response_channel;
wire [11:0] adc_response_data;
wire        adc_response_startofpacket;
wire        adc_response_endofpacket;
wire        adc_sys_clk;
wire        adc_project_reset_n;
wire        joystick_adc_command_valid_unused;
wire [4:0]  joystick_adc_command_channel_unused;
wire        joystick_adc_command_sop_unused;
wire        joystick_adc_command_eop_unused;

reset_release_sync u_adc_project_reset_sync (
    .clk           (adc_sys_clk),
    .async_reset_n (HRESETn),
    .reset_n       (adc_project_reset_n)
);

adc_command_sequencer u_adc_command_sequencer (
    .clk                   (adc_sys_clk),
    .reset_n               (adc_project_reset_n),
    .command_ready          (adc_command_ready),
    .command_valid          (adc_command_valid),
    .command_channel        (adc_command_channel),
    .command_startofpacket  (adc_command_startofpacket),
    .command_endofpacket    (adc_command_endofpacket)
);

// APB ADC Joystick 슬레이브 (0x4005_0000)
adc_qsys u_adc_qsys (
    .clk_clk                              (clk),
    .clock_bridge_sys_out_clk_clk         (adc_sys_clk),
    .reset_reset_n                        (HRESETn),
    .modular_adc_0_command_valid          (adc_command_valid),
    .modular_adc_0_command_channel        (adc_command_channel),
    .modular_adc_0_command_startofpacket  (adc_command_startofpacket),
    .modular_adc_0_command_endofpacket    (adc_command_endofpacket),
    .modular_adc_0_command_ready          (adc_command_ready),
    .modular_adc_0_response_valid         (adc_response_valid),
    .modular_adc_0_response_channel       (adc_response_channel),
    .modular_adc_0_response_data          (adc_response_data),
    .modular_adc_0_response_startofpacket (adc_response_startofpacket),
    .modular_adc_0_response_endofpacket   (adc_response_endofpacket)
);

APB_ADC_Joystick_Controller u_adc_joystick (
    .PCLK                         (PCLK),
    .PRESETn                      (PRESETn),
    .PADDR                        (PADDR),
    .PWRITE                       (PWRITE),
    .PSEL                         (PSEL[5]),
    .PENABLE                      (PENABLE),
    .PWDATA                       (PWDATA),
    .PRDATA                       (PRDATA_JOYSTICK),
    .PREADY                       (JOYSTICK_READY),
    .adc_command_valid            (joystick_adc_command_valid_unused),
    .adc_command_channel          (joystick_adc_command_channel_unused),
    .adc_command_startofpacket    (joystick_adc_command_sop_unused),
    .adc_command_endofpacket      (joystick_adc_command_eop_unused),
    .adc_command_ready            (adc_command_ready),
    .adc_response_valid           (adc_response_valid),
    .adc_response_channel         (adc_response_channel),
    .adc_response_data            (adc_response_data),
    .adc_response_startofpacket   (adc_response_startofpacket),
	    .adc_response_endofpacket     (adc_response_endofpacket)
	);

	APB_HEX_display u_hex_display (
	    .PCLK    (PCLK),
	    .PRESETn (PRESETn),
	    .PADDR   (PADDR),
	    .PWRITE  (PWRITE),
	    .PSEL    (PSEL[7]),
	    .PENABLE (PENABLE),
	    .PWDATA  (PWDATA),
	    .PRDATA  (PRDATA_HEX),
	    .PREADY  (HEX_READY),
	    .HEX0    (HEX0),
	    .HEX1    (HEX1),
	    .HEX2    (HEX2),
	    .HEX3    (HEX3),
	    .HEX4    (HEX4),
	    .HEX5    (HEX5)
	);

endmodule


