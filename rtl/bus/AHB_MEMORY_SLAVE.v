// AHB 메모리 슬레이브 모듈
module AHB_MEMORY_SLAVE (
    input          HCLK,
    input          HRESETn,
    input [31:0] HADDR,
    input         HWRITE,
    input [1:0] HTRANS,
    input [2:0] HSIZE,
    input [31:0] HWDATA,
    input        HSEL,
	 input        HREADY_IN,
	 input [3:0] byteena,
	 input        BRAM_HAZARD,

    output [31:0] HRDATA,
    output wire HREADY,
    output wire [1:0] HRESP,
	 
	 input MEM_READ_FROM_CPU
);

    // BRAM은 항상 1사이클 응답이 가능하므로 HREADY는 영구적으로 1입니다. (0-Wait State)
    assign HREADY = 1'b1;
    assign HRESP  = 2'b00; // 항상 OKAY

    wire is_valid_trans = HSEL && (HTRANS == 2'b10 || HTRANS == 2'b11); // NONSEQ or SEQ
    

	 
    // HWRITE AHB Address Phase 정보를 1클럭 지연시켜 Data Phase에 BRAM으로 전달하기 위한 레지스터
    reg [12:0] addr_reg;
    reg          write_en_reg;
	 reg          BRAM_HAZARD_d;
	 reg  [3:0]   byteena_d;           // SB, SH에 대해서도 뒤이어 오는
	 reg [31:0]  BYPASS_DATA;	   // LOAD 명령어에 대한 BRAM_HAZARD를 해결해줘야한다 !!!
	 wire [31:0] ACTUAL_HRDATA;
	 wire [31:0] ram_q;
	 
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_reg <= 13'h0;
            write_en_reg <= 1'b0;
	    end else if (HREADY_IN) begin
		  
		  if (is_valid_trans) begin
							
							addr_reg      <= HADDR[14:2]; // 워드 주소
							write_en_reg <= HWRITE;
				
			end else begin
							addr_reg      <= 13'b0; // 워드 주소
							write_en_reg <= 1'b0;		
					end			
		end							
   end
		
		
	 always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
							BRAM_HAZARD_d <= 1'b0;
							BYPASS_DATA      <= 32'b0;
							byteena_d     <= 4'b0;    // 초기화
	    end else if (HREADY_IN) begin
	
					if(BRAM_HAZARD) begin
							BRAM_HAZARD_d <= BRAM_HAZARD;
							BYPASS_DATA      <= HWDATA;
							byteena_d            <= byteena; // 현재 Store의 byteena를 함께 저장
					end else begin
							BRAM_HAZARD_d <= 1'b0;
							BYPASS_DATA      <= 32'b0;
							byteena_d     <= 4'b0;    // 초기화
					end
			end
	end
	

    // Quartus altsyncram BRAM 인스턴스 (M9K)
    memory u_bram (
        .byteena_a (byteena),          // 커스텀으로 MEM 스테이지의  StoreAligner 모듈에서 보내주는 WRITE_MASK를 사용
        .clock        (HCLK),
        .data         (HWDATA),           // Data Phase의 AHB 쓰기 데이터 다이렉트 인가
		  .rdaddress  (HADDR[14:2]),
	     .rden         (MEM_READ_FROM_CPU && HSEL && HREADY_IN),
		  .wraddress (addr_reg),
        .wren        (write_en_reg),
        .q             (ram_q)             // BRAM에서 1클럭 지연되어 나옴 (AHB HRDATA 스펙과 완벽 일치)
    );

	 
	 // assign ACTUAL_HRDATA = BRAM_HAZARD_d ? BYPASS_DATA : ram_q;
	 
	     // 핵심 수정 사항: 바이트 단위 Merging Mux
    // 해저드 상황이고 해당 바이트가 쓰기 대상(byteena_d == 1)인 경우에만 바이패스 데이터 사용
    assign ACTUAL_HRDATA[ 7: 0] = (BRAM_HAZARD_d && byteena_d[0]) ? BYPASS_DATA[ 7: 0] : ram_q[ 7: 0];
    assign ACTUAL_HRDATA[15: 8] = (BRAM_HAZARD_d && byteena_d[1]) ? BYPASS_DATA[15: 8] : ram_q[15: 8];
    assign ACTUAL_HRDATA[23:16] = (BRAM_HAZARD_d && byteena_d[2]) ? BYPASS_DATA[23:16] : ram_q[23:16];
    assign ACTUAL_HRDATA[31:24] = (BRAM_HAZARD_d && byteena_d[3]) ? BYPASS_DATA[31:24] : ram_q[31:24];
	
	 assign HRDATA =  ACTUAL_HRDATA ;   // 읽기 데이터 출력
	 
	 
endmodule







/*

2. AHB 메모리 슬레이브의 치명적 버그 수정
선우님이 작성하신 AHB_MEMORY_SLAVE에는 버스 시스템을 붕괴시킬 수 있는 아주 위험한 로직이 있었습니다.

문제점: HREADY <= 1'b0; 을 기본값으로 설정해 두셨습니다.
AHB 스펙 위반: AHB 프로토콜에서 아무 작업이 없는 IDLE 상태일 때 슬레이브의 HREADY는 
무조건 1(HIGH)을 유지해야 합니다. (0이면 마스터가 버스가 영원히 멈춘 줄 알고 진행을 못 합니다).

1-Cycle 응답: BRAM 기반 메모리는 데이터가 1클럭 만에 튀어나오므로, Wait State(HREADY=0)를 
인가할 필요 없이 항상 HREADY=1 로 묶어두는 것이 0-Wait 정석입니다.

이전 대화에서 만든 altsyncram BRAM(DataMemory)을 AHB 프로토콜에 맞게 래핑한 완벽한 
슬레이브 코드는 다음과 같습니다.

🚀 수정된 AHB_MEMORY_SLAVE.v
AHB의 Address Phase(클럭 1)에서 넘어온 제어 신호들을 레지스터에 저장해두고, 
Data Phase(클럭 2)에서 BRAM에 값을 쓰도록 1-Stage 지연 로직이 포함되어 있습니다.
*/


