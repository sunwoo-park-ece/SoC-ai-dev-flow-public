//==============================================================================
// Sub-Module: Digit_Drawer (7-Segment Logic)
// 한 글자(숫자)를 그리는 모듈
//==============================================================================
module Digit_Drawer (
    input [9:0] h, v,       // 현재 스캔 좌표
    input [9:0] pos_x,      // 글자 시작 X
    input [9:0] pos_y,      // 글자 시작 Y
    input [3:0] digit,      // 출력할 숫자 (0~9, 10=Minus)
    input       en,         // Enable (부호 표시용)
    output      is_on       // 픽셀 On/Off
);
    // 글자 크기 설정
    localparam W = 15; // 너비
    localparam H = 25; // 높이
    localparam T = 3;  // 두께 (Thickness)

    // 로컬 좌표 변환
    wire [9:0] lx = h - pos_x;
    wire [9:0] ly = v - pos_y;

    // 영역 확인
    wire inside_bounds = (h >= pos_x) && (h < pos_x + W) &&
                         (v >= pos_y) && (v < pos_y + H);

    // 7-Segment 패턴 정의 (Active High)
    // Segments: a(top), b(ur), c(lr), d(bot), e(ll), f(ul), g(mid)
    reg [6:0] seg; 
    always @(*) begin
        case(digit)
            4'd0: seg = 7'b1111110;
            4'd1: seg = 7'b0110000;
            4'd2: seg = 7'b1101101;
            4'd3: seg = 7'b1111001;
            4'd4: seg = 7'b0110011;
            4'd5: seg = 7'b1011011;
            4'd6: seg = 7'b1011111;
            4'd7: seg = 7'b1110000;
            4'd8: seg = 7'b1111111;
            4'd9: seg = 7'b1111011; // or 7'b1110011
            4'd10: seg = 7'b0000001; // Minus sign (G segment only)
            default: seg = 7'b0000000;
        endcase
    end

    // 세그먼트 위치 로직 (Logic for Rectangles)
    wire seg_a = (ly < T);                                      // Top
    wire seg_b = (lx >= W-T) && (ly < H/2);                     // Upper Right
    wire seg_c = (lx >= W-T) && (ly >= H/2);                    // Lower Right
    wire seg_d = (ly >= H-T);                                   // Bottom
    wire seg_e = (lx < T) && (ly >= H/2);                       // Lower Left
    wire seg_f = (lx < T) && (ly < H/2);                        // Upper Left
    wire seg_g = (ly >= H/2 - T/2) && (ly < H/2 + T/2);         // Middle

    // 픽셀 결정
    assign is_on = en && inside_bounds && (
        (seg[6] && seg_a) | (seg[5] && seg_b) | (seg[4] && seg_c) |
        (seg[3] && seg_d) | (seg[2] && seg_e) | (seg[1] && seg_f) | (seg[0] && seg_g)
    );

endmodule
