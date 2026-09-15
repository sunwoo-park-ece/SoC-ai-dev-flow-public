// CPU pipeline to project AHB-style master interface.

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
