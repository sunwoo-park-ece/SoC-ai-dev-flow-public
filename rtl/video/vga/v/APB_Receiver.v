//================================================================================
// Module Name: APB_Receiver
// Description: APB 버스를 통해 마스터로부터 가속도 센서 데이터를 수신하는 슬레이브 모듈
//              - 32비트 데이터를 받아 상위 16비트(X), 하위 16비트(Y)로 분리
//              - X, Y 데이터는 Signed 16-bit (-512 ~ +511 범위)
//================================================================================

module APB_Receiver (
    // 1. 시스템 클럭 및 리셋
    input  wire        PCLK,        // APB 버스 클럭 (System Clock)
    input  wire        PRESETn,     // APB 리셋 (Active-Low)

    // 2. APB 슬레이브 인터페이스
    input  wire [31:0] PADDR,       // 주소 버스
    input  wire        PSEL,        // 슬레이브 선택 신호
    input  wire        PENABLE,     // 데이터 전송 활성화 (2nd cycle)
    input  wire        PWRITE,      // 1: 쓰기, 0: 읽기
    input  wire [31:0] PWDATA,      // 마스터 -> 슬레이브 데이터 (Write)
    output reg  [31:0] PRDATA,      // 슬레이브 -> 마스터 데이터 (Read, 디버깅용)
    output reg         PREADY,
    // 3. 사용자 인터페이스 (VGA 모듈로 전달)
    output wire signed [15:0] o_ACCEL_X, // 가속도 X축 (상위 16비트)
    output wire signed [15:0] o_ACCEL_Y  // 가속도 Y축 (하위 16비트)
);

    //==========================================================================
    // 주소 매핑 및 내부 레지스터
    //==========================================================================
    // 레지스터 주소 오프셋 (0x00번지 사용)
    localparam [1:0] ADDR_XY_DATA = 2'b00;
    localparam [1:0] ADDR_ZZ_DATA = 2'b01;

    // 실제 가속도 데이터를 저장할 내부 32비트 레지스터
    // [31:16]: X축 데이터, [15:0]: Y축 데이터
    reg [31:0] r_accel_data;

 


    //==========================================================================
    // APB Write 동작 (데이터 수신)
    //==========================================================================
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            // 리셋 시 중앙값(0) 혹은 초기값으로 초기화
            r_accel_data <= 32'd0;
        end
        else begin
            // 쓰기 조건: 선택됨(PSEL) + 쓰기모드(PWRITE) + 활성화(PENABLE)
            if (PSEL && PENABLE && PWRITE) begin
                // 주소 디코딩: 0번지일 경우 데이터 래치
                if (PADDR[3:2] == ADDR_XY_DATA) begin
                    r_accel_data <= PWDATA;
                end
            end
        end
    end
    //==========================================================================
    // APB Read 동작 (데이터 확인용)
    //==========================================================================
    always @(*) begin
        // 읽기 요청이 오면 저장된 데이터를 버스에 실어줌
        if (PSEL && !PWRITE && PENABLE) begin
            PRDATA = r_accel_data; 
        end
        else begin
            PRDATA = 32'd0;
        end
    end


    //==========================================================================
    // 출력 데이터 슬라이싱 (Output Slicing)
    //==========================================================================
    // 명세서 3번: 상위 16비트 = X축, 하위 16비트 = Y축
    // signed 타입으로 연결하여 부호 비트 유지
    assign o_ACCEL_X = r_accel_data[31:16]; 
    assign o_ACCEL_Y = r_accel_data[15:0];

endmodule