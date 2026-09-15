module VGA_HUD (
    input  wire        iCLK,        // 25MHz Pixel Clock
    input  wire        iRSTn,
    input  wire        iVideoOn,
    input  wire [9:0]  iHCNT,
    input  wire [9:0]  iVCNT,
    
    // 표시할 데이터 (Signed 16-bit)
    input  wire signed [15:0] iACCEL_X,
    input  wire signed [15:0] iACCEL_Y,

    output reg  [3:0]  oR,
    output reg  [3:0]  oG,
    output reg  [3:0]  oB,
    output wire        oIsText      // 텍스트 영역인지 알려주는 플래그 (배경 합성을 위해)
);

    //==========================================================================
    // 1. 숫자 분리 (Binary to Decimal)
    //==========================================================================
    // X축
    wire x_is_neg = (iACCEL_X < 0);
    wire [15:0] x_abs = x_is_neg ? -iACCEL_X : iACCEL_X;

    wire [3:0] x_100 = (x_abs / 100) % 10;
    wire [3:0] x_10  = (x_abs / 10) % 10;
    wire [3:0] x_1   = x_abs % 10;

    // Y축
    wire y_is_neg = (iACCEL_Y < 0);
    wire [15:0] y_abs = y_is_neg ? -iACCEL_Y : iACCEL_Y;

    wire [3:0] y_100 = (y_abs / 100) % 10;
    wire [3:0] y_10  = (y_abs / 10) % 10;
    wire [3:0] y_1   = y_abs % 10;

    //==========================================================================
    // 2. 숫자 그리기 인스턴스 (X축: 왼쪽 상단, Y축: 오른쪽 상단)
    //==========================================================================
    wire p_x_sign, p_x_100, p_x_10, p_x_1;
    wire p_y_sign, p_y_100, p_y_10, p_y_1;

    // --- X축 데이터 표시 (위치: 20, 20) ---
    Digit_Drawer D_X_SIGN (.h(iHCNT), .v(iVCNT), .pos_x(10'd20), .pos_y(10'd20), .digit(4'd10), .is_on(p_x_sign), .en(x_is_neg)); // 10=Minus
    Digit_Drawer D_X_100  (.h(iHCNT), .v(iVCNT), .pos_x(10'd40), .pos_y(10'd20), .digit(x_100), .is_on(p_x_100), .en(1'b1));
    Digit_Drawer D_X_10   (.h(iHCNT), .v(iVCNT), .pos_x(10'd60), .pos_y(10'd20), .digit(x_10),  .is_on(p_x_10),  .en(1'b1));
    Digit_Drawer D_X_1    (.h(iHCNT), .v(iVCNT), .pos_x(10'd80), .pos_y(10'd20), .digit(x_1),   .is_on(p_x_1),   .en(1'b1));

    // --- Y축 데이터 표시 (위치: 20, 60) ---
    Digit_Drawer D_Y_SIGN (.h(iHCNT), .v(iVCNT), .pos_x(10'd20), .pos_y(10'd60), .digit(4'd10), .is_on(p_y_sign), .en(y_is_neg));
    Digit_Drawer D_Y_100  (.h(iHCNT), .v(iVCNT), .pos_x(10'd40), .pos_y(10'd60), .digit(y_100), .is_on(p_y_100), .en(1'b1));
    Digit_Drawer D_Y_10   (.h(iHCNT), .v(iVCNT), .pos_x(10'd60), .pos_y(10'd60), .digit(y_10),  .is_on(p_y_10),  .en(1'b1));
    Digit_Drawer D_Y_1    (.h(iHCNT), .v(iVCNT), .pos_x(10'd80), .pos_y(10'd60), .digit(y_1),   .is_on(p_y_1),   .en(1'b1));

    // 텍스트 픽셀 통합
    wire text_pixel_on_X = p_x_sign | p_x_100 | p_x_10 | p_x_1; 
    wire text_pixel_on_Y = p_y_sign | p_y_100 | p_y_10 | p_y_1;

    assign oIsText = text_pixel_on_X || text_pixel_on_Y;

    //==========================================================================
    // 3. 색상 출력
    //==========================================================================
    always @(*) begin
        if (!iVideoOn) begin
            oR = 0; oG = 0; oB = 0;
        end
        else if (text_pixel_on_X) begin
            oR = 4'hF; oG = 4'h0; oB = 4'h0; // X는 빨간색 텍스트
        end
        else if (text_pixel_on_Y)begin
            oR = 4'h0; oG = 4'hF; oB = 4'h0; // Y는 초록색 텍스트
        end
        else begin
            oR = 0; oG = 0; oB = 0; // 배경은 투명(Top에서 처리)
        end
    end

endmodule