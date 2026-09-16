// AHB 마스터 모듈
/*
module AHB_MASTER(
// 시스템 신호
input HCLK,    // 시스템 클록
input HRESETn, // 리셋 신호 (활성 낮음)

// AHB 마스터 출력 신호
output reg [31:0] HADDR,   // 주소 버스
output reg        HWRITE,  // 쓰기(1)/읽기(0) 제어
output reg [1:0]  HTRANS,  // 전송 유형 (IDLE, BUSY, NONSEQ, SEQ)
output reg [2:0]  HSIZE,   // 전송 크기 (바이트, 하프워드, 워드)
output reg [2:0]  HBURST,  // 버스트 유형
output reg [31:0] HWDATA,  // 쓰기 데이터


// AHB 마스터 입력 신호
input [31:0]      HRDATA,  // 읽기 데이터
input             HREADY,  // 슬레이브 준비 완료 신호
input [1:0]       HRESP,   // 응답 상태 (OKAY, ERROR, RETRY, SPLIT)


// 사용자 인터페이스 (CPU나 테스트 로직에서 사용)
input             start_trans, // 트랜잭션 시작 트리거
input [31:0]      addr,        // 목표 주소
input             write,       // 쓰기(1)/읽기(0)
input [31:0]      wdata,       // 쓰기 데이터
output reg [31:0] rdata,       // 읽기 데이터
output reg trans_done          // 트랜잭션 완료 플래그
);

reg [1:0] EDGE_SHIFT;

always @(posedge HCLK or negedge HRESETn) begin
	if(!HRESETn) begin
			EDGE_SHIFT <= 2'b0;
		end else begin
			EDGE_SHIFT <= {EDGE_SHIFT[0], start_trans};
		end
end
			
wire rising_start_trans;

assign rising_start_trans = (!EDGE_SHIFT[1])&(EDGE_SHIFT[0]);









// 마스터 상태 머신 정의
localparam [1:0] IDLE       = 2'b00; // 유휴 상태, 새 트랜잭션 대기

localparam [1:0] ADDR_PHASE = 2'b01; // 주소 단계, 주소와 제어신호 출력

localparam [1:0] DATA_PHASE = 2'b10; // 데이터 단계, 데이터 전송 완료 대기

// AHB HTRANS 프로토콜 값 정의
localparam [1:0] HTRANS_IDLE   = 2'b00;   // 버스 유휴
localparam [1:0] HTRANS_BUSY   = 2'b01;   // 버스트 중 대기
localparam [1:0] HTRANS_NONSEQ = 2'b10;   // 단일 전송 또는 버스트 첫 전송
localparam [1:0] HTRANS_SEQ    = 2'b11;   // 버스트 연속 전송

// 내부 상태 변수
reg [1:0]     state, next_state;
reg [31:0]    wdata_reg;        // 쓰기 데이터 임시 저장

// 순차 로직: 상태 업데이트
always @(posedge HCLK or negedge HRESETn) begin
if (!HRESETn)
state <= IDLE;
else
state <= next_state;
end

// 조합 로직: 다음 상태 계산
always @(*) begin
    case (state)
        IDLE: begin
            // 유휴 상태에서 트랜잭션 시작 요청이 오면 주소 단계로 이동

            if (rising_start_trans)
                next_state = ADDR_PHASE;
            else
                next_state = IDLE;
            end

        ADDR_PHASE: begin
            // 주소 단계에서 슬레이브가 준비되면 데이터 단계로 이동
             if (HREADY)
                next_state = DATA_PHASE;
            else
                next_state = ADDR_PHASE; // 슬레이브가 준비될 때까지 대기
             end


        DATA_PHASE: begin
            // 데이터 단계에서 슬레이브가 완료 신호를 보내면 유휴로 복귀
            if (HREADY)
                next_state = IDLE;
            else
                next_state = DATA_PHASE; // 데이터 전송 완료까지 대기
            end

        default: next_state = IDLE;

        endcase
end


// 순차 로직: AHB 출력 신호 및 사용자 인터페이스 제어

always @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
        // 리셋 시 모든 신호 초기화
        HADDR <= 32'h0;
        HWRITE <= 1'b0;
        HTRANS <= HTRANS_IDLE;
        HSIZE <= 3'b010; // 기본 32비트(워드) 전송
        HBURST <= 3'b000; // 단일 전송 (버스트 없음)
        HWDATA <= 32'h0;
        wdata_reg <= 32'h0;
        rdata <= 32'h0;
        trans_done <= 1'b0;
    end
    else begin
        case (state)
            IDLE: begin
            // 유휴 상태: 기본값 설정 및 새 트랜잭션 준비
                HTRANS <= HTRANS_IDLE;
                trans_done <= 1'b0;
                if (rising_start_trans) begin
                // 새 트랜잭션 시작: 주소와 제어 신호 설정
                    HADDR <= addr;
                    HWRITE <= write;
                    HTRANS <= HTRANS_NONSEQ;
                    wdata_reg <= wdata; // 쓰기 데이터 임시 저장
                end
            end

            ADDR_PHASE: begin
            // 주소 단계: 슬레이브가 주소를 받으면 다음 단계 준비
                 if (HREADY) begin
                    HTRANS <= HTRANS_IDLE; // 주소 전송 완료 후 유휴로 설정

                    // 쓰기 트랜잭션이면 저장된 데이터를 데이터 버스에 출력
                    if (HWRITE) HWDATA <= wdata_reg;
                end
            end
            

            DATA_PHASE: begin
            // 데이터 단계: 실제 데이터 전송 완료 처리
                if (HREADY) begin
                    trans_done <= 1'b1; // 트랜잭션 완료 신호
                    
                // 읽기 트랜잭션이면 받은 데이터 저장
                if (!HWRITE)
                    rdata <= HRDATA;
                end
            end
        endcase
    end
end

endmodule

*/




module AHB_Master_Interface (
    // --------------------------------------------------------
    // [CPU EX 스테이지 입력] -> AHB Address Phase 제어
    // --------------------------------------------------------
    input wire EX_memory_read,
    input wire EX_memory_write,
    input wire [31:0] EX_alu_result,      // HADDR
    input wire [2:0] EX_funct3,           // HSIZE 디코딩용
    // --------------------------------------------------------
    // [CPU MEM 스테이지 입력] -> AHB Data Phase 제어
    // --------------------------------------------------------
    input wire [31:0] MEM_read_data2,     // HWDATA (Store Align을 거친 쓰기 데이터)
    // --------------------------------------------------------
    // [CPU 출력 및 Stall 제어]
    // --------------------------------------------------------
    output wire [31:0] HRDATA_to_CPU,     // LoadExtender로 전달될 읽기 데이터
    output wire bus_stall_req,            // HazardUnit으로 보낼 Stall 요청 (HREADY == 0 일 때)
    // --------------------------------------------------------
    // [AHB-Lite 버스 마스터 인터페이스]
    // --------------------------------------------------------
    output wire [31:0] HADDR,
    output wire HWRITE,
    output wire [1:0] HTRANS,
    output reg  [2:0] HSIZE,
    output wire [2:0] HBURST,
    output wire [31:0] HWDATA,
    input wire  [31:0] HRDATA,
    input wire  HREADY,
	 
	 input wire [3:0] CUSTOM_WRITE_MASK_IN,
	 output wire [3:0]  CUSTOM_WRITE_MASK_OUT
);

	assign CUSTOM_WRITE_MASK_OUT = CUSTOM_WRITE_MASK_IN;

    // 1. AHB 주소 페이즈 (EX 스테이지와 1:1 매핑)
    assign HADDR  = EX_alu_result;
    assign HWRITE = EX_memory_write;
    
    // 메모리 읽기/쓰기 요청이 있으면 NONSEQ(10), 없으면 IDLE(00)
    // EX-stage misalignment is handled by the CPU's existing causes 4/6.
    // It must not launch an AHB transfer that would later look like cause 5/7.
    wire ex_address_aligned = (HSIZE == 3'b001) ? !EX_alu_result[0] :
                              (HSIZE == 3'b010) ? (EX_alu_result[1:0] == 2'b00) : 1'b1;
    assign HTRANS = ((EX_memory_read || EX_memory_write) && ex_address_aligned) ? 2'b10 : 2'b00;
    assign HBURST = 3'b000; // Single Transfer

    // RV32I LOAD funct3: LB/LH/LW/LBU/LHU; STORE: SB/SH/SW.
    // Unsupported encodings deliberately use an invalid bus size so the
    // fabric returns ERROR rather than silently accepting a word transfer.
    always @(*) begin
        if (EX_memory_read) begin
            case (EX_funct3)
                3'b000, 3'b100: HSIZE = 3'b000;
                3'b001, 3'b101: HSIZE = 3'b001;
                3'b010:         HSIZE = 3'b010;
                default:        HSIZE = 3'b111;
            endcase
        end else if (EX_memory_write) begin
            case (EX_funct3)
                3'b000: HSIZE = 3'b000;
                3'b001: HSIZE = 3'b001;
                3'b010: HSIZE = 3'b010;
                default: HSIZE = 3'b111;
            endcase
        end else begin
            HSIZE = 3'b010;
        end
    end


	 
    // 2. AHB 데이터 페이즈 (MEM 스테이지와 1:1 매핑)
    // CPU 파이프라인 레지스터(EX_MEM)가 1클럭 지연시켜주므로, 자연스럽게 AHB의 Data Phase와 일치함!
    assign HWDATA = MEM_read_data2; 
    
    // 읽기 데이터는 AHB에서 바로 받아서 CPU 로직으로 전달
    assign HRDATA_to_CPU = HRDATA;

    // 3. CPU Stall 로직
    // 데이터 페이즈(MEM 스테이지)에서 버스가 아직 처리 중(HREADY=0)이면 파이프라인을 동결!
    assign bus_stall_req = ~HREADY;

endmodule


/*
3. Hazard Unit에 버스 Stall 연동하기
슬레이브(특히 APB UART나 딜레이가 있는 모듈)가 처리하느라 HREADY = 0을 뿜어낼 때,
마스터 인터페이스에서 나온 bus_stall_req를 이용해 CPU 전체를 정지시켜야 데이터가 꼬이지 않습니다.
HazardUnit.v 내부의 조합 논리에 다음 코드를 추가하세요

// HazardUnit.v 내부 always @(*) 블록
    // bus_stall_req 신호를 모듈 입력으로 받아왔다고 가정
    if (bus_stall_req) begin
        // 버스가 멈추면 파이프라인 전체를 얼려버립니다.
        IF_ID_stall = 1'b1;
        ID_EX_stall = 1'b1;
        EX_MEM_stall = 1'b1;
        MEM_WB_stall = 1'b1;
    end else if (standby_mode) begin 
        // 기존 로직 유지...
*/



/*

=> 개소리임.

5SP CPU에서 연속 "쓰기" 트랜잭션일 때 두번째로 오는 APB 쓰기 트랜잭션의 경우 

HWDATA 레지스터 역할인 EX/MEM 파이프라인 레지스터를 PWDATA로 로드해오면 

한타이밍이 밀리기 때문에 앞 트랜잭션이 APB_WRITE인 경우 

PWDATA에는 HWDATA(EX/MEM) 이 아니라 HWDATA(ID/EX) 를 넣어줘야 한다.

 SETUP: begin

                if (write_reg) begin
                // 쓰기 트랜잭션: 데이터 캡처
                    PWDATA    <= HWDATA;
                    wdata_reg <= HWDATA;
                end

*/


