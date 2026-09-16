module HW_Cleaner (
    input clk,
    input rst_n,
    input start,                // Control 레지스터에서 인가
    
    output reg [13:0] clr_addr, // 0 ~ 9599 (최대 16383)
    output reg clr_we,
    output reg clr_busy,
    output reg clr_done
);

    localparam IDLE  = 2'b00;
    localparam CLEAR = 2'b01;
    localparam DONE  = 2'b10;
    
    reg [1:0] state, next_state;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clr_addr <= 14'd0;
        end else begin
            state <= next_state;
            
            if (state == CLEAR) begin
                clr_addr <= clr_addr + 14'd1;
            end else if (state == IDLE) begin
                clr_addr <= 14'd0;
            end
        end
    end
    
    always @(*) begin
        next_state = state;
        clr_we = 1'b0;
        clr_busy = 1'b0;
        clr_done = 1'b0;
        
        case (state)
            IDLE: begin
                if (start) next_state = CLEAR;
                clr_done = 1'b1; // 초기 상태이거나 완료 후 IDLE일 때 Done=1
            end
            CLEAR: begin
                clr_busy = 1'b1;
                clr_we = 1'b1;
                if (clr_addr == 14'd9599) begin
                    next_state = DONE;
                end
            end
            DONE: begin
                clr_done = 1'b1;
                if (!start) next_state = IDLE; // start 신호가 내려가면 IDLE 복귀
            end
        endcase
    end
endmodule