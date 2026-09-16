//================================================================================
// Module Name: VGA_Object_Renderer
// Description: VGA 좌표와 오브젝트 좌표를 비교하여 픽셀 색상을 결정하는 모듈
//              - 메모리(MIF) 없이 논리 연산만으로 도형 생성
//              - 기본: 사각형 (Square) / 옵션: 원 (Circle)
//================================================================================

module VGA_Object_Renderer (
    // 1. VGA 동기 신호 및 좌표
    input  wire        iVideoOn,    // 화면 표시 구간 신호 (Active High)
    input  wire [9:0]  iHCNT,       // 현재 그리는 가로 픽셀 좌표 (0~639)
    input  wire [9:0]  iVCNT,       // 현재 그리는 세로 픽셀 좌표 (0~479)

    // 2. 오브젝트 위치 정보 (Physics 모듈에서 계산됨)
    input  wire [9:0]  iOBJ_X,      // 오브젝트 좌상단 X 좌표
    input  wire [9:0]  iOBJ_Y,      // 오브젝트 좌상단 Y 좌표

    // 3. RGB 출력
    output reg  [3:0]  oR,          // Red (4-bit)
    output reg  [3:0]  oG,          // Green (4-bit)
    output reg  [3:0]  oB           // Blue (4-bit)
);

    //==========================================================================
    // 파라미터 설정 (크기 및 색상)
    //==========================================================================
    localparam OBJ_WIDTH  = 40;     // 오브젝트 가로 크기 (픽셀)
    localparam OBJ_HEIGHT = 40;     // 오브젝트 세로 크기 (픽셀)
    
    // 오브젝트 색상 (Cyan: R=0, G=F, B=F) (청록색)
    localparam [3:0] COLOR_R = 4'h0;
    localparam [3:0] COLOR_G = 4'hF;
    localparam [3:0] COLOR_B = 4'hF;


    //==========================================================================
    // 1. 사각형 (Square) 그리기 로직
    //==========================================================================
    // 현재 스캔 중인 픽셀(h, v)이 오브젝트 박스 영역 안에 있는지 확인
    
    wire is_in_box_x;
    wire is_in_box_y;
    wire is_object_region;

    // X축 범위 확인: (현재 H값 >= 시작점) AND (현재 H값 < 시작점 + 폭)
    assign is_in_box_x = (iHCNT >= iOBJ_X) && (iHCNT < iOBJ_X + OBJ_WIDTH);
    
    // Y축 범위 확인: (현재 V값 >= 시작점) AND (현재 V값 < 시작점 + 높이)
    assign is_in_box_y = (iVCNT >= iOBJ_Y) && (iVCNT < iOBJ_Y + OBJ_HEIGHT);

    // 두 조건이 모두 맞으면 "여기가 오브젝트다!"
    assign is_object_region = is_in_box_x && is_in_box_y;


    //==========================================================================
    // 2. (옵션) 원 (Circle) 그리기 로직 - 주석 처리됨
    //==========================================================================
    /* 원을 그리려면 "중심점과의 거리 제곱" 공식을 써야 합니다: (x-a)^2 + (y-b)^2 <= r^2
       FPGA에서 Multiplier를 쓰게 되므로 리소스가 더 듭니다. 필요시 주석 해제하여 사용하세요.
    */
    /*
    wire [9:0] center_x = iOBJ_X + (OBJ_WIDTH / 2);
    wire [9:0] center_y = iOBJ_Y + (OBJ_HEIGHT / 2);
    wire signed [10:0] dist_x = $signed({1'b0, iHCNT}) - $signed({1'b0, center_x});
    wire signed [10:0] dist_y = $signed({1'b0, iVCNT}) - $signed({1'b0, center_y});
    wire [20:0] dist_sq = (dist_x * dist_x) + (dist_y * dist_y);
    wire [20:0] radius_sq = (OBJ_WIDTH / 2) * (OBJ_WIDTH / 2);
    
    assign is_object_region = (dist_sq <= radius_sq); 
    */


    //==========================================================================
    // 3. 최종 색상 출력 (Output Multiplexer)
    //==========================================================================
    always @(*) begin
        if (!iVideoOn) begin
            // 1) 화면 표시 구간이 아니면 무조건 Black (Sync 신호 보호)
            oR = 4'h0;
            oG = 4'h0;
            oB = 4'h0;
        end
        else if (is_object_region) begin
            // 2) 오브젝트 영역이면 지정된 색상 출력
            oR = COLOR_R;
            oG = COLOR_G;
            oB = COLOR_B;
        end
        else begin
            // 3) 그 외 배경은 Black
            oR = 4'h0;
            oG = 4'h0;
            oB = 4'h0;
        end
    end

endmodule