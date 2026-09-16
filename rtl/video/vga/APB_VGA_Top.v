module APB_VGA_Top(
	 input wire signed [15:0] temp_x,
	 input wire signed [15:0] temp_y,
    // System Clock & Reset
    input  wire        CLOCK_50,
    input  wire        rst_n,

    // APB Interface (Master로부터 연결됨)
    input  wire        PCLK,    // APB Clock (보통 시스템 클럭과 같거나 다름)
    input  wire        PRESETn,
    input  wire [31:0] PADDR,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [31:0] PWDATA,
    output wire [31:0] PRDATA, // 필요시 Read 구현
    output wire        PREADY,
	input              PREADY_FLAG,

    // VGA Output
    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,
	output wire [15:0]       debug_w_accel_x
);

    //======================================
    // 1. Clock Generation (VGA용 25MHz)
    //======================================
    wire pclk_25;
    wire vga_pll_locked_unused;
    
    vga_pll U_PLL (
        .inclk0 (CLOCK_50),
        .c0     (pclk_25),
        .locked (vga_pll_locked_unused)
    );

    //======================================
    // 2. APB Slave (가속도 데이터 수신)
    //======================================
    wire signed [15:0] w_accel_x; // APB로부터 받은 X값
    wire signed [15:0] w_accel_y; // APB로부터 받은 Y값
    assign debug_w_accel_x = w_accel_x;

    APB_Receiver U_APB_SLAVE (
        .PCLK    (PCLK),      // APB는 보통 별도 클럭 도메인일 수 있음
        .PRESETn (PRESETn),
        .PADDR   (PADDR),
        .PSEL    (PSEL),
        .PENABLE (PENABLE),
        .PWRITE  (PWRITE),
        .PWDATA  (PWDATA),
        .PREADY  (PREADY),
        .o_ACCEL_X (w_accel_x),
        .o_ACCEL_Y (w_accel_y)
    );

    //======================================
    // 3. VGA Sync Gen (기존 코드 활용)
    //======================================
    wire [9:0] h_cnt, v_cnt;
    wire       video_on;
    wire       vga_vsync_sig; // V-Sync 신호

    VGA_SyncGen U_SYNC (
        .iRSTn    (rst_n),
        .iPCLK    (pclk_25),
        .oHS      (VGA_HS),
        .oVS      (vga_vsync_sig),  // VSync를 Physics 모듈로 넘겨야 함
        .oHCNT    (h_cnt),          // horizontal counter (0~799)
        .oVCNT    (v_cnt),          // vertical counter (0~524)
        .oVideoOn (video_on)        // 1이면 visible 영역 (0~639, 0~479)
    );
    
    assign VGA_VS = vga_vsync_sig;

	 

    //======================================
    // 4. Physics Control (위치 계산)
    //======================================
    wire [9:0] w_obj_x;
    wire [9:0] w_obj_y;

    Object_Controller U_PHYSICS (
        .iCLK     (CLOCK_50),      // 혹은 50MHz
        .iRSTn    (rst_n),
        .iVSYNC   (vga_vsync_sig),// 프레임 단위 업데이트용
        .iACCEL_X (temp_x),    // APB에서 받은 X축 데이터
        .iACCEL_Y (temp_y),    // APB에서 받은 Y축 데이터
        .oOBJ_X   (w_obj_x),      // 계산된 오브젝트 좌표
        .oOBJ_Y   (w_obj_y)
    );



    //======================================
    // 5. VGA Renderer (도형 그리기)
    //======================================
    // 기존의 VGA_DigitDisplay 대신 사용
    // VGA_DigitDisplay는 화면의 고정된 위치(조정 가능)에 오면 ROM에서 데이터를 꺼냄
    // 데이터가 1이면 색칠하고, 0이면 검은색
    // Renderer는 현재좌표를 입력받고 현재 픽셀위치(h_cnt, v_cnt)가 
    // 오브젝트 좌표 범위 내에 있는지 수학적으로 비교 
    // if (h_cnt > Obj_X && h_cnt < Obj_X + 폭) ... 이 조건이 참이면 색칠
    // 범위 비교 (단순함, 동적임)
    // pixel_on = (h_cnt >= obj_x) && (h_cnt < obj_x + 100) && (v_cnt >= obj_y) && (v_cnt < obj_y + 100);
    
	 
	 wire [3:0] obj_r, obj_g, obj_b;
	 
    VGA_Object_Renderer U_RENDER (
        .iVideoOn (video_on),
        .iHCNT    (h_cnt),          // 현재 진행중인 수평선 위치                        
        .iVCNT    (v_cnt),          // 현재 진행중인 수직선 위치
        .iOBJ_X   (w_obj_x),        // 오브젝트의 X좌표
        .iOBJ_Y   (w_obj_y),        // 오브젝트의 Y좌표
        .oR       (obj_r),
        .oG       (obj_g),            // 범위 조건 판단 후 4bit COLOR 출력
        .oB       (obj_b)
    );
	 
	 //======================================
    // 6. [NEW] VGA HUD (텍스트 오버레이)
    //======================================
    wire [3:0] text_r, text_g, text_b;
    wire       is_text;

    VGA_HUD U_HUD (
        .iCLK     (pclk_25),
        .iRSTn    (rst_n),
        .iVideoOn (video_on),
        .iHCNT    (h_cnt),
        .iVCNT    (v_cnt),
        .iACCEL_X (temp_x), // APB에서 받은 값
        .iACCEL_Y (temp_y), // APB에서 받은 값
        .oR       (text_r),
        .oG       (text_g),
        .oB       (text_b),
        .oIsText  (is_text)
    );
	 
	 
	 
	 //======================================
    // 7. [NEW] 최종 믹싱 (Priority Mux)
    //    텍스트가 있으면 텍스트 색상, 없으면 오브젝트 색상
    //======================================
    assign VGA_R = is_text ? text_r : obj_r;
    assign VGA_G = is_text ? text_g : obj_g;
    assign VGA_B = is_text ? text_b : obj_b;
	 
	 
	 
	 
	 
	 

endmodule
