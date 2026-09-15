module AHB_VRAM_DUAL_BUFFER (
    input wire CLOCK_50,  // VGA용 25MHz PLL 소스 클럭
    // AHB HCLK 도메인
    input wire HCLK,
    input wire HRESETn,
    input wire [31:0] HADDR,
    input wire HWRITE,
    input wire [1:0] HTRANS,
    input wire [31:0] HWDATA,
    input wire HSEL,
    input wire HREADY_IN,
    output reg [31:0] HRDATA,
    output wire HREADY,
    output wire [1:0] HRESP,

    // VGA Output
    output reg [3:0]  VGA_R,
    output reg [3:0]  VGA_G,
    output reg [3:0]  VGA_B,
    output wire       VGA_HS,
    output wire       VGA_VS


    

);

    assign HREADY = 1'b1; // 0-Wait State 슬레이브
    assign HRESP  = 2'b00;


    //======================================
    // 1. Clock Generation (VGA용 25MHz)
    //======================================
    wire pclk_25;
    wire vga_pll_locked;
    wire vga_reset_n;
    
    vga_pll U_PLL (
        .inclk0 (CLOCK_50),
        .c0     (pclk_25),
        .locked (vga_pll_locked)
    );

    // PLL unlock or system reset asserts immediately. Release is confined to
    // the pixel clock domain so no pclk_25 consumer sees asynchronous release.
    reset_release_sync u_vga_reset_sync (
        .clk           (pclk_25),
        .async_reset_n (HRESETn & vga_pll_locked),
        .reset_n       (vga_reset_n)
    );

    //======================================
    // 3. VGA Sync Gen (기존 코드 활용)
    //======================================
    wire [9:0] h_cnt, v_cnt;
    wire       video_on;
    wire       vga_vsync_sig; // V-Sync 신호

    VGA_SyncGen U_SYNC (
        .iRSTn    (vga_reset_n),
        .iPCLK    (pclk_25),
        .oHS      (VGA_HS),
        .oVS      (vga_vsync_sig),  // VSync를 Physics 모듈로 넘겨야 함
        .oHCNT    (h_cnt),          // horizontal counter (0~799)
        .oVCNT    (v_cnt),          // vertical counter (0~524)
        .oVideoOn (video_on)        // 1이면 visible 영역 (0~639, 0~479)
    );
    
    assign VGA_VS = vga_vsync_sig; // FPGA에서 나가는 Vsync 신호
    // 2. VRAM에 보내줄 ADDR 
    reg  [18:0] VRAM_ADDR;        //출력은 1비트   (0~640x480) => 19비트 필요.  
    wire  vga_rdata;               // 메모리 버퍼의 1비트 출력, 해당 주소값 = 최종 muxing 조건
   

    // =======================================================
    // 1. Pre-fetch Address Generator
    // =======================================================
    // 화면의 마지막 픽셀(우측 하단 끝 여백)인지 확인
    wire is_end_of_frame = (h_cnt == 10'd798) && (v_cnt == 10'd524);

    // 주소를 증가시켜야 하는 구간:
    // 1) HCNT=799 일 때: 다음 라인의 0번 픽셀을 위해 증가 (Pre-fetch 시작)
    // 2) HCNT=0 ~ 638 일 때: 다음 픽셀(1 ~ 639)을 위해 증가
    // 단, VCNT가 화면 출력 구간(0~479)일 때만 유효함
	 // [핵심 수정] 
    // 1. (h_cnt == 799) 일 때는 iVCNT 상관없이 다음 줄을 위해 무조건 1 증가!
    // 2. 화면이 그려지는 도중(0~638)일 때는 iVCNT가 보이는 구간일 때만 증가!
    wire is_addr_up = (h_cnt == 10'd799) || ((h_cnt < 10'd639) && (v_cnt < 10'd480));
	 

    always @(posedge pclk_25 or negedge vga_reset_n) begin
        if (~vga_reset_n) begin
            VRAM_ADDR <= 19'd0;
        end else begin
            if (is_end_of_frame) begin
                // 프레임이 끝나면 0번 주소로 초기화하여 0번 픽셀 데이터를 미리 준비시킴!
                VRAM_ADDR <= 19'd0;
            end else if (is_addr_up) begin
                VRAM_ADDR <= VRAM_ADDR + 19'd1;
            end
        end
    end

    //Pre - fetch 주소생성기의  VRAM_ADDR은 듀얼 포트 메모리 버퍼의 READ ADDRESS로 

    //HADDR 을 래치하는 addr_reg는 메모리 버퍼의 WRITE ADDRESS로 






    // -----------------------------------------------------------
    // 1. Clock Domain Crossing (CDC) & V-Sync Edge Detection
    // -----------------------------------------------------------
    reg vsync_d1, vsync_d2, vsync_d3;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) 
        begin {vsync_d3, vsync_d2, vsync_d1} <= 3'b0; end
        else 
        {vsync_d3, vsync_d2, vsync_d1} <= {vsync_d2, vsync_d1, vga_vsync_sig};
    end

    wire vsync_rising_edge = (vsync_d2 & ~vsync_d3); // 라이징 엣지 검출

    // -----------------------------------------------------------
    // 2. 레지스터 정의 및 주소 매핑
    // -----------------------------------------------------------
    // 주소 공간:
    // 0x00000 ~ 0x095FF : VRAM 백 버퍼 쓰기/읽기 창 (Window)
    // 0x10000           : Status 레지스터 (Bit 0: VSync Flag, Bit 1: Clear Done, Bit 2: Clear Busy)
    // 0x10004           : Control 레지스터 (Bit 0: SWAP, Bit 1: Start HW Clear)
    
    wire is_vram_access   = HSEL && (HADDR[19:16] == 4'h0);
    wire is_status_access = HSEL && (HADDR[19:0] == 20'h10000);
    wire is_ctrl_access   = HSEL && (HADDR[19:0] == 20'h10004);
    
    wire valid_write = HSEL && HWRITE && (HTRANS == 2'b10 || HTRANS == 2'b11);
    wire valid_read  = HSEL && !HWRITE && (HTRANS == 2'b10 || HTRANS == 2'b11);

    // AHB Pipeline Address/Control Latch
    reg [31:0] addr_reg;
    reg write_reg, read_reg;
    reg is_vram_reg, is_status_reg, is_ctrl_reg;
    
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_reg <= 32'h0; write_reg <= 1'b0; read_reg <= 1'b0;
            is_vram_reg <= 1'b0; is_status_reg <= 1'b0; is_ctrl_reg <= 1'b0;
        end else if (HREADY_IN) begin
            addr_reg <= HADDR;
            write_reg <= valid_write;
            read_reg <= valid_read;
            is_vram_reg <= is_vram_access;
            is_status_reg <= is_status_access;
            is_ctrl_reg <= is_ctrl_access;
        end
    end

    // -----------------------------------------------------------
    // 3. 상태(Status) / 제어(Control) 레지스터 로직
    // -----------------------------------------------------------
    reg vsync_flag;
    reg front_buffer_idx; // 0이면 VRAM0이 프론트(VGA), 1이면 VRAM1이 프론트(VGA)
    reg hw_clear_start;

    wire clr_busy, clr_done;
    wire [13:0] clr_addr;
    wire clr_we;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            vsync_flag <= 1'b0;
            front_buffer_idx <= 1'b0;
            hw_clear_start <= 1'b0;
        end else begin
            // V-Sync 엣지 캡처
            if (vsync_rising_edge) vsync_flag <= 1'b1;
            
            // Status 레지스터에 쓰면 V-Sync 플래그 클리어
            if (write_reg && is_status_reg) begin
                if (HWDATA[0]) begin
                    vsync_flag <= 1'b0;
                end
            end

            // Control 레지스터 '쓰기' (Atomic 연산)
            if (write_reg && is_ctrl_reg) begin
                // Bit 0: SWAP
                if (HWDATA[0]) front_buffer_idx <= ~front_buffer_idx;
                // Bit 1: Start HW Clear
                hw_clear_start <= HWDATA[1];
            end else begin
                hw_clear_start <= 1'b0; // 펄스(Pulse) 형태로 작동
            end
        end
    end

    // -----------------------------------------------------------
    // 4. HW Cleaner 인스턴스화
    // -----------------------------------------------------------
    reg hw_clear_run; // FSM 구동용 상태 유지 레지스터
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) 
        hw_clear_run <= 1'b0;
        else if (hw_clear_start) 
        hw_clear_run <= 1'b1;
        else if (clr_done) 
        hw_clear_run <= 1'b0;
    end

    HW_Cleaner u_cleaner (
        .clk       (HCLK), 
        .rst_n     (HRESETn), 
        .start     (hw_clear_run),
        .clr_addr  (clr_addr), 
        .clr_we    (clr_we), 
        .clr_busy  (clr_busy), 
        .clr_done  (clr_done)
    );


    // ===========================================================
    // 5. VRAM 포트 MUX/DEMUX 라우팅 (수정됨)
    // ===========================================================
    
    // CPU가 접근하는 주소 (Back Buffer)
    wire [13:0] ahb_vram_addr = addr_reg[15:2];
    // Back Buffer 쓰기 제어 (HW Cleaner가 돌고 있으면 CPU 쓰기 무시하고 Cleaner가 우선권 획득!)
    wire back_buffer_we   = write_reg && is_vram_reg;

    // --- [STEP 1] 백 버퍼(Back Buffer) 자원 점유 MUX ---
    // HW_Cleaner가 동작 중(clr_busy)이면 Cleaner가 우선권을 가짐. 끝나면 CPU(AHB)가 점유.
    wire [13:0] back_addr  = clr_busy ? clr_addr : ahb_vram_addr;
    wire        back_we    = clr_busy ? clr_we   : back_buffer_we;
    wire [31:0] back_wdata = clr_busy ? 32'h0000_0000 : HWDATA; // 클리어 시 0 쓰기

    // --- [STEP 2] VRAM0 / VRAM1 역할 분배 DEMUX ---
    // front_buffer_idx == 0 : VRAM0은 Front(VGA 출력), VRAM1은 Back(클리어 및 쓰기)
    // front_buffer_idx == 1 : VRAM1은 Front(VGA 출력), VRAM0은 Back(클리어 및 쓰기)

    // [VRAM 0 제어 신호]
    // VRAM0이 Back일 때만 쓰기 허용, Front일 때는 0
    wire        vram0_we_a   = (front_buffer_idx == 1'b1) ? back_we : 1'b0; 
    wire [13:0] vram0_addr_a = (front_buffer_idx == 1'b1) ? back_addr : 14'h0;
    wire [31:0] vram0_data_a = (front_buffer_idx == 1'b1) ? back_wdata : 32'h0;
    // VRAM0이 Front일 때 VGA Prefetch 주소 연결 (Port B는 19비트)
    wire [18:0] vram0_addr_Prefetch = (front_buffer_idx == 1'b0) ? VRAM_ADDR : 19'h0; 

    // [VRAM 1 제어 신호]
    // VRAM1이 Back일 때만 쓰기 허용, Front일 때는 0
    wire        vram1_we_a   = (front_buffer_idx == 1'b0) ? back_we : 1'b0; 
    wire [13:0] vram1_addr_a = (front_buffer_idx == 1'b0) ? back_addr : 14'h0;
    wire [31:0] vram1_data_a = (front_buffer_idx == 1'b0) ? back_wdata : 32'h0;
    // VRAM1이 Front일 때 VGA Prefetch 주소 연결 (Port B는 19비트)
    wire [18:0] vram1_addr_Prefetch = (front_buffer_idx == 1'b1) ? VRAM_ADDR : 19'h0; 

    // --- [STEP 3] BRAM 인스턴스화 ---
    wire        vram0_q_FRONT;
    wire        vram1_q_FRONT;

    // --- VRAM은 2-port RAM IP로 구현, 32비트 쓰기(14비트 주소)/ 1비트 읽기(19비트 주소) ---

VRAM u_VRAM0(
	.data      (vram0_data_a),        // 쓰기데이터는 HWCLR(32'b0) -> HWDATA 순으로 입력된다
	.rd_aclr   (~vga_reset_n),        // ACTIVE_HIGH, pclk_25-local release
	.rdaddress (vram0_addr_Prefetch), // VRAM0이 FRONT일 때 VGA Prefetch 주소 연결
	.rdclock   (pclk_25),             // 읽기는 VGA CLOCK으로  
	.wraddress (vram0_addr_a),        // 프론트에서 SWAP 후 CLR_ADDR -> HADDR
	.wrclock   (HCLK),                // 쓰기는 HCLK으로
	.wren      (vram0_we_a),          // 백버퍼로 전환 후 CLR_EN -> HW_EN-> 0 
	.q         (vram0_q_FRONT)
    );

VRAM u_VRAM1(
	.data      (vram1_data_a),
	.rd_aclr   (~vga_reset_n),        // ACTIVE_HIGH, pclk_25-local release
	.rdaddress (vram1_addr_Prefetch), // VRAM1이 FRONT일 때 VGA Prefetch 주소 연결
	.rdclock   (pclk_25),             // 읽기는 VGA CLOCK으로 
    .wraddress (vram1_addr_a),        // 프론트에서 SWAP 후 CLR_ADDR -> HADDR
	.wrclock   (HCLK),                // 쓰기는 HCLK으로
	.wren      (vram1_we_a),          // 백버퍼로 전환 후 CLR_EN -> HW_EN-> 0 
	.q         (vram1_q_FRONT)
    );

    // ===========================================================
    // 6. AHB Read Data & VGA Output MUX
    // ===========================================================
    // AHB 버스로 나가는 읽기 데이터 (현재 백 버퍼의 데이터)
    // wire [31:0] back_buffer_rdata = (front_buffer_idx == 1'b1) ? vram0_q_FRONT : vram1_q_FRONT;
    
    always @(*) begin
        HRDATA = 32'h0;
        if (read_reg) begin
           // if (is_vram_reg) HRDATA = back_buffer_rdata;   
            if (is_status_reg) 
                HRDATA = {29'h0, clr_busy, clr_done, vsync_flag};
        end
    end

    // VGA 화면으로 나가는 데이터 (현재 프론트 버퍼의 포트 B 출력)
    assign vga_rdata = (front_buffer_idx == 1'b0) ? vram0_q_FRONT : vram1_q_FRONT;

    // 7. 최종 출력 MUX
    always @(*) begin
        if(video_on) begin
            if(vga_rdata) begin
                VGA_R = 4'hf; VGA_G = 4'hf; VGA_B = 4'hf; 
            end else begin
                VGA_R = 4'h0; VGA_G = 4'h0; VGA_B = 4'h0;
            end
        end else begin
            VGA_R = 4'h0; VGA_G = 4'h0; VGA_B = 4'h0;
        end
    end

endmodule
