`include "../../vh/branch.vh"
`include "../../vh/itype.vh"
`include "../../vh/load.vh"
`include "../../vh/rtype.vh"
`include "../../vh/store.vh"
`include "../../vh/opcode.vh"
`include "../../vh/csr.vh"

module InstructionMemory (
    input [31:0] pc,
    output reg [31:0] instruction,
	 input clk
);


reg [31:0] data [0:1023];

initial begin
// =========================================================================
    // [0] 초기 레지스터 세팅 (Base Address 및 상수 로드)
    // =========================================================================
    
    // 1. x20 = 0x4002_0000 (APB Timer Base Address)
    // LUI x20, 0x40020
    data[0] = {20'h40020, 5'd20, `OPCODE_LUI};
    
    // 2. x10 = 10 (count_cmp 값 세팅용)
    // ADDI x10, x0, 10
    data[1] = {12'd10, 5'd0, 3'b000, 5'd10, `OPCODE_ITYPE};
    
    // 3. x11 = 1 (타이머 Enable, 클리어 및 카운터 증가용 상수)
    // ADDI x11, x0, 1
    data[2] = {12'd1, 5'd0, 3'b000, 5'd11, `OPCODE_ITYPE};
    
    // 4. x15 = 0 (타이머 카운트 누적용 범용 레지스터)
    // ADDI x15, x0, 0
    data[3] = {12'd0, 5'd0, 3'b000, 5'd15, `OPCODE_ITYPE};

    // =========================================================================
    // [1] 타이머 초기화 (Configuration)
    // =========================================================================

    // 5. 32'h4002_0008 에 10 쓰기 (count_cmp 값 설정)
    // SW x10, 8(x20)  -> imm = 8 (0_01000)
    data[4] = {7'b0000000, 5'd10, 5'd20, 3'b010, 5'b01000, `OPCODE_STORE};

    // 6. 32'h4002_0000 에 1 쓰기 (Timer Enable)
    // SW x11, 0(x20)  -> imm = 0 (0_00000)
    data[5] = {7'b0000000, 5'd11, 5'd20, 3'b010, 5'b00000, `OPCODE_STORE};

    // =========================================================================
    // [2] Polling Loop (PC = 24)
    // =========================================================================

    // 7. [POLL] 32'h4002_000C 에서 완료 플래그 읽기
    // LW x12, 12(x20) -> imm = 12
    data[6] = {12'd12, 5'd20, 3'b010, 5'd12, `OPCODE_LOAD};

    // 8. 플래그(x12)가 0이면 아직 카운트 중이므로 [POLL] 로 점프 (-4 bytes 점프)
    // BEQ x12, x0, POLL  -> offset = -4 (0xFFFF_FFFC)
    // imm[12]=1, imm[11]=1, imm[10:5]=111111, imm[4:1]=1110
    data[7] = {1'b1, 6'b111111, 5'd0, 5'd12, 3'b000, 4'b1110, 1'b1, `OPCODE_BRANCH};
    // =========================================================================
    // [3] Timer Triggered (플래그가 1일 때 실행됨)
    // =========================================================================
    // 9. 32'h4002_000C 에 1 쓰기 (플래그 클리어 및 타이머 재시작)
    // SW x11, 12(x20) -> imm = 12 (0_01100)
    data[8] = {7'b0000000, 5'd11, 5'd20, 3'b010, 5'b01100, `OPCODE_STORE};
    // 10. x15 값을 1 증가
    // ADD x15, x15, x11
    data[9] = {7'b0000000, 5'd11, 5'd15, 3'b000, 5'd15, `OPCODE_RTYPE};
    // 11. 완료 후 다시 폴링 루프(PC = 24)로 복귀 (-16 bytes 점프)
    // JAL x0, POLL -> offset = -16 (0xFFFF_FFF0)
    // imm[20]=1, imm[10:1]=1111111000, imm[11]=1, imm[19:12]=11111111
    data[10] = {1'b1, 10'b1111111000, 1'b1, 8'b11111111, 5'd0, `OPCODE_JAL};
end


    always @(*) begin
            instruction = data[pc[31:2]];
    end


endmodule


		// ──────────────────────────────────────────────
		// I-타입 ALU 명령어 (9개)
		// {imm[11:0], rs1, funct3, rd, OPCODE_ITYPE}


		// ──────────────────────────────────────────────
		// R-타입 명령어 (10개)
		// {funct7, rs2, rs1, funct3, rd, OPCODE_RTYPE}
		
		// ──────────────────────────────────────────────
		// S-타입 명령어 (스토어) (3개)
		// {imm[11:5], rs2, rs1, funct3, imm[4:0], OPCODE_STORE}

		// ──────────────────────────────────────────────
		// I-타입 로드 명령어 (5개)
		// {imm[11:0], rs1, funct3, rd, OPCODE_LOAD}

		// ──────────────────────────────────────────────
		// U-타입 명령어 (2개)
		// {imm[31:12], rd, OPCODE_LUI/OPCODE_AUIPC}

		// ──────────────────────────────────────────────
		// J-타입 명령어 (1개)
		// {imm[20|10:1|11|19:12], rd, OPCODE_JAL}

		// ──────────────────────────────────────────────
		// I-타입 점프 (JALR) 명령어 (1개)
		// {imm[11:0], rs1, funct3, rd, OPCODE_JALR}

		// ──────────────────────────────────────────────
		// B-타입 명령어 (분기) (6개)
		// {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], OPCODE_BRANCH}

		
		// ──────────────────────────────────────────────
		// I-타입 Zicsr 확장 명령어 (6개)	[F11] == mvendorid, [341] = mepc, [342] = mcause, [305] = mtvec
		// {imm[11:0], rs1(uimm), funct3, rd, OPCODE_ENVIRONMENT}	
		

/*
	reg [31:0] data [0:16383];
	
	initial begin
        $readmemh("./dhrystone.mem", data);
        // ──────────────────────────────────────────────
		// Trap Handler 시작 주소. mtvec = 0000_1000 = 4096 ÷ 4 Byte = 1024
		// Trap Handler 진입 시 기존 GPR의 레지스터 내용들을 별도의 메모리 Heap 구역에 store하고 수행해야하지만, 현재 단계에서는 생략함.
		// CSR mcause 확인해서 ecall이면 x1 = 0000_0000으로 만들기, misaligned면 x2에 FF더하기
		// 조건 분기; 비교문 작성을 위한 적재 작업
		data[7000] = {12'h342, 5'd0, 3'b010, 5'd6, `OPCODE_ENVIRONMENT}; 					// csrrs x6, mcause, x0:	레지스터 x6에 mcause값 적재
		data[7001] = {12'd11, 5'd0, `ITYPE_ADDI, 5'd7, `OPCODE_ITYPE};						// addi x7, x0, 11: 		레지스터 x7에 ECALL 코드 값 11 적재 (mcause가 11인지 비교하기 위해서는 해당 11이라는 값을 레지스터 넣고 레지스터끼리 비교해야하므로)	
		data[7002] = {12'd2, 5'd0, `ITYPE_ADDI, 5'd8, `OPCODE_ITYPE};						// addi x8, x0, 2: 			레지스터 x8에 ILLEGAL INSTRUCTION 코드 값 2 적재 (mcause가 2인지 비교하기 위해서는 해당 2이라는 값을 레지스터 넣고 레지스터끼리 비교해야하므로)	

		// mcause 분석해서 해당하는 Trap Handler 주소로 분기
		data[7003] = {1'b0, 6'd0, 5'd7, 5'd6, `BRANCH_BEQ, 4'b1101, 1'b0, `OPCODE_BRANCH};	// beq x6, x7, +26: 		ECALL; x6과 x7이 같다면 26바이트 이후 주솟값으로 분기 = data[7010]
		data[7004] = {1'b0, 6'd0, 5'd0, 5'd6, `BRANCH_BEQ, 4'b1010, 1'b0, `OPCODE_BRANCH};	// beq x6, x0, +20: 		MISALIGNED; x6값이 0과 같다면 16바이트 이후 주솟값으로 분기 = data[7009]
		data[7005] = {1'b0, 6'd0, 5'd0, 5'd6, `BRANCH_BEQ, 4'b1000, 1'b0, `OPCODE_BRANCH};	// beq x6, x8, +16: 		ILLEGAL; x6값이 x8과 같다면 16바이트 이후 주솟값으로 분기 = data[1033]
		data[7006] = {1'b0, 10'b000_0001_000, 1'b0, 8'b0, 5'd0, `OPCODE_JAL};				// jal x0, +16: 			TH 끝내기 (mret 명령어 주소로 가기)
		
		// ECALL Trap Handler @ data[1029]
		data[7007] = {12'd0, 5'd0, `ITYPE_ADDI, 5'd1, `OPCODE_ITYPE};						//addi x1, x0, 0: 			레지스터 x1 값 0으로 비우기
		data[7008] = {1'b0, 10'b000_0000_100, 1'b0, 8'b0, 5'd0, `OPCODE_JAL};				//jal x0, +8:				TH 끝내기 (mret 명령어 주소로 가기)

		// ILLEGAL / MISALIGNED Trap Handler @ data[1031]
		data[7009] = {12'hFF, 5'd2, `ITYPE_ADDI, 5'd30, `OPCODE_ITYPE};						//addi x30, x2, 255: 		x30 레지스터에 x2(BC00_0000) + 0xFF = bc00_00ff

		// ESCAPE Trap Handler @ data[1032]
		data[7010] = {12'b001100000010, 5'b0, 3'b0, 5'b0, `OPCODE_ENVIRONMENT};				//MRET:						PC = CSR[mepc]

		// HINT; NOP for 'x' signal after MRET in pipeline
		data[7011] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};
		data[7012] = {12'h2BC, 5'd0, `ITYPE_ADDI, 5'd0, `OPCODE_ITYPE};		
	end
	
	always @(*) begin
		instruction = data[pc[31:2]];
	end

	wire rom_access = (rom_address[31:16] == 16'h0000);
    always @(*) begin
        if (rom_access) begin
            rom_read_data = data[rom_address[15:2]];
        end else begin
            rom_read_data = 32'b0;
        end
    end

endmodule
*/







/*
initial begin
    // ──────────────────────────────────────────────
    // 1. 초기 설정
    // x20 = 0x1000_2000 (VRAM Base)
    data[0] = {20'h10000, 5'd20, `OPCODE_LUI};
    // x15 = 0 (카운터 초기화)
    data[1] = {12'd0, 5'd0, 3'b000, 5'd15, `OPCODE_ITYPE};
    // x10 = 1 (증가값)
    data[2] = {12'd1, 5'd0, 3'b000, 5'd10, `OPCODE_ITYPE};

    // ──────────────────────────────────────────────
    // 2. [LOOP START] 무한 누적 및 해저드 스트레스 구간 (PC = 12)
    // ADD x15, x15, x10 -> x15를 1 증가시킴 (RAW 해저드 유발)
    data[3] = {7'b0000000, 5'd10, 5'd15, 3'b000, 5'd15, `OPCODE_RTYPE};
    
    // SW x15, 0(x20) -> 방금 더한 값을 BRAM에 즉시 저장
    data[4] = {7'b0000000, 5'd15, 5'd20, 3'b010, 5'b00000, `OPCODE_STORE};
    
    // LW x11, 0(x20) -> 저장한 값을 곧바로 다시 로드 (BRAM 쓰기/읽기 타이밍 및 Load-Use 스트레스)
    data[5] = {12'd0, 5'd20, 3'b010, 5'd11, `OPCODE_LOAD};
    
    // BNE x11, x15, ERROR -> 로드해 온 값(x11)이 누적된 값(x15)과 다르면 에러! (Forwarding/Branch 테스트)
    // 다를 경우 +8 bytes 점프하여 data[8]로 이동
    data[6] = {1'b0, 6'b000000, 5'd15, 5'd11, 3'b001, 4'b0100, 1'b0, `OPCODE_BRANCH};

    // JAL x0, LOOP -> 에러가 없으면 무한 반복 (-16 bytes 점프하여 data[3]으로 이동)
    data[7] = {1'b1, 10'b1111111000, 1'b1, 8'b11111111, 5'd0, `OPCODE_JAL};

    // ──────────────────────────────────────────────
    // 3. [ERROR TRAP] 오버클럭 실패 시 함정 (PC = 32)
    // 100MHz 발열이나 타이밍 에러로 단 1비트라도 튀면 이곳에 영원히 갇힙니다.
    // ADDI x15, x0, -1 -> x15를 0xFFFF_FFFF로 만들어 모든 LED를 켬
    data[8] = {12'hFFF, 5'd0, 3'b000, 5'd15, `OPCODE_ITYPE};
    // JAL x0, ERROR -> 제자리 무한 대기 (-4 bytes 점프)
    data[9] = {1'b1, 10'b1111111110, 1'b1, 8'b11111111, 5'd0, `OPCODE_JAL};
end
*/




/*
    // ──────────────────────────────────────────────
    // Trap Handler override logic
    // ──────────────────────────────────────────────
    function [31:0] trap_patch;
        input [31:0] addr;
        begin
            case (addr)

                7000: trap_patch = {12'h342, 5'd0, 3'b010, 5'd6, `OPCODE_ENVIRONMENT};
                7001: trap_patch = {12'd11, 5'd0, `ITYPE_ADDI, 5'd7, `OPCODE_ITYPE};
                7002: trap_patch = {12'd2,  5'd0, `ITYPE_ADDI, 5'd8, `OPCODE_ITYPE};

                7003: trap_patch = {1'b0, 6'd0, 5'd7, 5'd6, `BRANCH_BEQ, 4'b1101,1'b0, `OPCODE_BRANCH};
                7004: trap_patch = {1'b0, 6'd0, 5'd0, 5'd6, `BRANCH_BEQ, 4'b1010,1'b0, `OPCODE_BRANCH};
                7005: trap_patch = {1'b0, 6'd0, 5'd0, 5'd6, `BRANCH_BEQ, 4'b1000,1'b0, `OPCODE_BRANCH};
                7006: trap_patch = {1'b0,10'b000_0001_000,1'b0,8'b0,5'd0,`OPCODE_JAL};

                7007: trap_patch = {12'd0, 5'd0, `ITYPE_ADDI, 5'd1, `OPCODE_ITYPE};
                7008: trap_patch = {1'b0,10'b000_0000_100,1'b0,8'b0,5'd0,`OPCODE_JAL};

                7009: trap_patch = {12'hFF,5'd2,`ITYPE_ADDI,5'd30,`OPCODE_ITYPE};

                7010: trap_patch = {12'b001100000010,5'b0,3'b0,5'b0,`OPCODE_ENVIRONMENT};

                7011: trap_patch = {12'h2BC,5'd0,`ITYPE_ADDI,5'd0,`OPCODE_ITYPE};
                7012: trap_patch = {12'h2BC,5'd0,`ITYPE_ADDI,5'd0,`OPCODE_ITYPE};

                default: trap_patch = 32'hFFFFFFFF; // invalid
            endcase
        end
    endfunction
	 
	 // ──────────────────────────────────────────────
    // instruction fetch (PC side)
    // ──────────────────────────────────────────────
    always @(*) begin
        if (pc >= 7000 && pc <= 7012)
            instruction = trap_patch(pc[31:2]);
        else
            instruction = data[pc[31:2]];
    end
*/