module APB_TIMER (
    input  wire        PCLK,      // 시스템 클록 (50MHz)
    input  wire        PRESETn,  // 리셋 (Active Low)
    
    input  wire [31:0] PADDR,   // 주소
    input  wire        PSEL,      // 슬레이브 선택
    input  wire        PENABLE, // 활성화
    input  wire        PWRITE,   // 쓰기 제어
    input  wire [31:0] PWDATA, // 쓰기 데이터
    
    output reg  [31:0] PRDATA,  // 읽기 데이터
	output wire  [9:0] counter_debug,
	 
	output   PREADY
);

 assign PREADY = 1'b1;



    // 레지스터 오프셋 정의
    localparam [3:0] ADDR_CTRL       = 4'h0; // 제어 레지스터 (En, Clear)
    localparam [3:0] ADDR_CNT        = 4'h4; // 현재 카운터값
    localparam [3:0] ADDR_CNT_CMP = 4'h8; // 목표 비교값 SET
    localparam [3:0] ADDR_STATUS    = 4'hC;// 상태 레지스터 (Ready)

    // 내부 레지스터
    reg [31:0] counter;      // 32비트 카운터
    reg [31:0] counter_cmp;  // 카운터 비교값 설정용
    
    reg        enable;       // 타이머 활성화 플래그
    reg        READY;        // 카운트 완료 플래그

	 assign counter_debug = counter[31:22];
	 
	 
	 
    // 동작 로직
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            counter     <= 32'd0;
            counter_cmp <= 32'd0; // [수정] 오타 수정
            enable      <= 1'b0;
            READY       <= 1'b0;	
        end
        else begin
            // 1. 카운터 동작 (Enable이고 Ready가 아닐 때만 동작)
            if (enable && !READY) begin
                if (counter < counter_cmp) begin
                    counter <= counter + 1'b1;
                end 
                else begin
                    counter <= 32'd0; // 목표 도달 시 0으로 초기화
                    READY  <= 1'b1;  // 완료 플래그 셋 (카운터 정지됨)
                end 
            end

            // 2. APB 쓰기 동작
            if (PSEL && PENABLE && PWRITE) begin
					
                case (PADDR[3:0])
                    ADDR_CTRL: begin
                        enable <= PWDATA[0];
                    end
                    
                    ADDR_CNT_CMP: begin
                        counter_cmp <= PWDATA;
                    end
                    
                    ADDR_STATUS: begin
                        if (PWDATA[0] == 1'b1) begin
									READY <= 1'b0; // 1이 들어올 때만 Clear
								end
									// 0이 들어오면? 아무 짓도 안 함 (현상 유지)
							end
                endcase
            end
			end
	end
	
	
	always @(*) begin
        PRDATA = 32'd0;
	  // 3. APB 읽기 동작
            if (PSEL && PENABLE && !PWRITE) begin
		
						
                case (PADDR[3:0])
                    ADDR_CTRL   : PRDATA = {30'd0, 1'b0, enable};
                    ADDR_CNT    : PRDATA = counter;
                    ADDR_CNT_CMP: PRDATA = counter_cmp; // 설정값 확인용 추가
                    ADDR_STATUS : PRDATA = {31'd0, READY};
                    default     : PRDATA = 32'd0;
                endcase
            end
	 end

endmodule