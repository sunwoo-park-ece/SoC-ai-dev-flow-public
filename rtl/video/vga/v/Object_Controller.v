//================================================================================
// Module Name: Object_Controller
// Description: 가속도 센서 데이터를 기반으로 오브젝트의 다음 좌표를 계산
//              - VSYNC 신호에 동기화하여 프레임당 1회 업데이트
//              - 화면 경계 충돌 처리 (Wall Collision Logic)
//================================================================================

module Object_Controller (
    // 1. 시스템 및 동기 신호
    input  wire        iCLK,        // 시스템 클럭 (50MHz or 25MHz)
    input  wire        iRSTn,       // 리셋 (Active-Low)
    input  wire        iVSYNC,      // V-Sync 신호 (프레임 시작 알림용)

    // 2. 가속도 센서 입력 (from APB_Receiver)
    input  wire signed [15:0] iACCEL_X, // X축 기울기 (-512 ~ +511)
    input  wire signed [15:0] iACCEL_Y, // Y축 기울기 (-512 ~ +511)

    // 3. 좌표 출력 (to VGA_Object_Renderer)
    output reg  [9:0]  oOBJ_X,      // 계산된 X 좌표
    output reg  [9:0]  oOBJ_Y       // 계산된 Y 좌표
);

    //==========================================================================
    // 파라미터 정의
    //==========================================================================
    // 화면 해상도
    localparam SCREEN_W = 640;
    localparam SCREEN_H = 480;

    // 오브젝트 크기 (Renderer 모듈과 일치시켜야 함)
    localparam OBJ_W    = 40;
    localparam OBJ_H    = 40;

    // 이동 감도 (Sensitivity)
    // 값이 클수록 느리게, 작을수록 빠르게 움직임.
    // 6비트 Shift = 나누기 64 (512 입력 시 최대 8픽셀 이동/프레임)
    localparam SPEED_SHIFT = 6; 

    // 초기 위치 (화면 중앙)
    localparam START_X  = (SCREEN_W - OBJ_W) / 2; // (640-40)/2 = 300
    localparam START_Y  = (SCREEN_H - OBJ_H) / 2; // (480-40)/2 = 220


    //==========================================================================
    // 1. V-Sync 엣지 검출 (Rising Edge Detection)
    //    VSYNC 신호가 0에서 1로 변하는 순간(프레임 시작)을 포착
    //==========================================================================
    reg  r_vsync_prev;
    wire w_vsync_posedge;

    always @(posedge iCLK or negedge iRSTn) begin
        if (!iRSTn) r_vsync_prev <= 1'b0;
        else        r_vsync_prev <= iVSYNC;
    end

    // 현재는 1이고 이전이 0이면 상승 엣지
    assign w_vsync_posedge = (iVSYNC == 1'b1) && (r_vsync_prev == 1'b0);


    //==========================================================================
    // 2. 물리 연산 및 위치 업데이트
    //==========================================================================
    
    // 계산을 위한 임시 변수 (음수 처리를 위해 signed 사용)
    // 넉넉한 비트 수 할당 (Overflow 방지)
    reg signed [11:0] next_x;
    reg signed [11:0] next_y;

    // 실제 이동량 계산 (가속도 값 >> 감도)
    // >>> 연산자는 부호 비트를 유지하며 쉬프트합니다 (Arithmetic Shift)
    wire signed [15:0] move_x = iACCEL_X >>> SPEED_SHIFT;
    wire signed [15:0] move_y = iACCEL_Y >>> SPEED_SHIFT;

    always @(posedge iCLK or negedge iRSTn) begin
        if (!iRSTn) begin
            // 리셋 시 화면 중앙으로 이동
            oOBJ_X <= START_X[9:0];
            oOBJ_Y <= START_Y[9:0];
        end
        else if (w_vsync_posedge) begin
            //------------------------------------------------------
            // X축 계산 및 경계 처리
            //------------------------------------------------------
            // 1. 현재 위치에 이동량을 더함
            //    (가속도 +: 오른쪽 기울임 -> 좌표 증가)
            //    (가속도 -: 왼쪽 기울임 -> 좌표 감소)
            next_x = $signed({1'b0, oOBJ_X}) - move_x; // {1'b0, ...}로 양수 변환 후 계산

            // 2. 경계값 체크 (Clamping)
            if (next_x < 0) 
                oOBJ_X <= 10'd0;              // 왼쪽 벽
            else if (next_x > (SCREEN_W - OBJ_W)) 
                oOBJ_X <= (SCREEN_W - OBJ_W); // 오른쪽 벽
            else 
                oOBJ_X <= next_x[9:0];        // 이동 가능

            //------------------------------------------------------
            // Y축 계산 및 경계 처리
            //------------------------------------------------------
            // 1. 현재 위치에 이동량을 더함
            //    (가속도 +: 남쪽/아래 기울임 -> 좌표 증가)
            next_y = $signed({1'b0, oOBJ_Y}) + move_y;

            // 2. 경계값 체크
            if (next_y < 0) 
                oOBJ_Y <= 10'd0;              // 위쪽 벽
            else if (next_y > (SCREEN_H - OBJ_H)) 
                oOBJ_Y <= (SCREEN_H - OBJ_H); // 아래쪽 벽
            else 
                oOBJ_Y <= next_y[9:0];        // 이동 가능
        end
    end

endmodule