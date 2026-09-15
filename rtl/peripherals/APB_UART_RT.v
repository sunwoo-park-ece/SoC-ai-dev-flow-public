// APB UART 슬레이브 모듈 (Integrated RX/TX) .
module APB_UART (
    // 시스템 신호
    input  wire        PCLK,    // APB 클록 (50MHz)
    input  wire        PRESETn, // APB 리셋 (활성 낮음)

    // APB 슬레이브 인터페이스
    input  wire [31:0] PADDR,   // APB 주소
    input  wire        PWRITE,  // APB 쓰기 제어
    input  wire        PSEL,    // APB 슬레이브 선택
    input  wire        PENABLE, // APB 활성화
    input  wire [31:0] PWDATA,  // APB 쓰기 데이터

    output reg  [31:0] PRDATA,  // APB 읽기 데이터

    // UART 외부 인터페이스
    output wire        uart_tx, // UART 송신핀
    input  wire        uart_rx,  // UART 수신핀
	 
	output wire PREADY // 1 고정.
);
    assign PREADY = 1'b1;

    // =========================================================================
    // 1. 주소 맵 및 파라미터 정의
    // =========================================================================
    localparam [1:0] UART_DATA    = 2'b00; // 0x00: 데이터 레지스터 (R/W)
    localparam [1:0] UART_STATUS  = 2'b01; // 0x04: 상태 레지스터 (R)
    localparam [1:0] UART_CONTROL = 2'b10; // 0x08: 제어 레지스터 (R/W)
    localparam [1:0] UART_BAUD    = 2'b11; // 0x0C: 보드레이트 분주비 (R/W)

    // Status Register Bits
    localparam STAT_TX_READY = 0; // 1 = TX Idle (Ready to send)
    localparam STAT_RX_READY = 1; // 1 = RX Data Available
    localparam STAT_RX_ERROR = 2; // 1 = Framing Error

    // RX FSM States (Common)
    localparam S_IDLE  = 2'b00;  // START 비트가 감지되면 바로 S_START로 전이 , 50MHz 클럭으로 감지
    localparam S_START = 2'b01;  // START 비트 중앙에서 재확인
    localparam S_DATA  = 2'b10;  // 전송 DATA는 LSB부터 전송 ->  인덱스 1씩 증가시키면서 LSB부터 저장  
    localparam S_STOP  = 2'b11;  // STOP 비트 중앙에서 재확인 -> 전송 에러 플래그 제어


    // =========================================================================
    // 2. 내부 레지스터 선언
    // =========================================================================
    // Common
    reg [15:0] baud_div;    // Baud Rate Divisor
    reg [7:0]  control_reg; // 추후에 인터럽트 관련 모듈 설계 후 사용

    // TX Related
    reg [7:0]  tx_data_reg;   // 송신 데이터
    reg [9:0]  tx_shift_reg;  // 송신 시프트 레지스터 (start + 8data + stop)
    reg [3:0]  tx_bit_count;  // 송신 비트 다운카운터 (1비트시간 총 10개 카운트), 1->eff
    reg [15:0] tx_baud_cnt;   // 보드레이트 다운카운터 (1비트당 50MHz 총 434개 카운트) 0->eff
    reg        tx_busy;        // Status[0] 
                               //HW: 현재 일하고 있는가?  0:ㄴㄴ, 1:ㅇㅇ
                               //SW: 지금 보낼 수 있는가? 0:ㅇㅇ, 1:ㄴㄴ
    reg        tx_start_pulse; // Trigger logic

    // RX Related
    reg [7:0]  rx_shifter;    // RX핀을 통해 들어오는 1비트 데이터 임시 저장용
    reg [15:0] rx_baud_cnt;   // 보드레이트 카운트 업카운터
    reg [3:0]  rx_bit_index;  // 송신 비트 인덱스 업카운터
    reg [1:0]  rx_state;      // FSM 상태
    reg        rx_error;      // Status[2]

    // RX FIFO: PC control frame처럼 여러 바이트가 연속 입력될 때 1-byte register 유실을 방지.
    // APB UART_DATA read 1회당 FIFO front 1바이트를 pop합니다.
    reg [7:0]  rx_fifo [0:15];
    reg [3:0]  rx_fifo_wr_ptr;
    reg [3:0]  rx_fifo_rd_ptr;
    reg [4:0]  rx_fifo_count;
    wire       rx_ready = (rx_fifo_count != 5'd0);
    wire       rx_fifo_full = (rx_fifo_count == 5'd16);
    wire [7:0] rx_fifo_front = rx_fifo[rx_fifo_rd_ptr];
    
    // RX input synchronizer (Metastability prevention)
    reg rx_sync_1, rx_sync_2;
    wire rx_in = rx_sync_2;

    // =========================================================================
    // 3. 메인 로직
    // =========================================================================

    // UART TX Output Logic
    assign uart_tx = tx_busy ? tx_shift_reg[0] : 1'b1; // 아이들 시 high

    // RX Synchronizer 2-ff 동기화기
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_sync_1 <= 1'b1;
            rx_sync_2 <= 1'b1;
        end else begin
            rx_sync_1 <= uart_rx;
            rx_sync_2 <= rx_sync_1;
        end
    end

    // -------------------------------------------------------------------------
    // APB Register 쓰기 & Control Logic
    // -------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            baud_div    <= 16'd434; // 115200 bps @ 50MHz
            control_reg <= 8'h00;
            tx_data_reg <= 8'h00;
            tx_start_pulse <= 1'b0;
        end else begin
            tx_start_pulse <= 1'b0; // TX FSM 1클럭 펄스 트리거 자동으로 clear

            // APB Write Access
            if (PSEL && PENABLE && PWRITE) begin
                case (PADDR[3:2])
                    UART_DATA: begin
                        // Busy가 아닐 때만 쓰기 허용 (혹은 덮어쓰기)
                        if (!tx_busy) begin
                            tx_data_reg    <= PWDATA[7:0];
                            tx_start_pulse <= 1'b1; // TX FSM 펄스 트리거 생성, 자동으로 clear
                        end
                    end
                    
                    UART_CONTROL: control_reg <= PWDATA[7:0];

                    UART_BAUD:    baud_div    <= PWDATA[15:0];
                    default: ;
                endcase
            end				
        end
    end

    // -------------------------------------------------------------------------
    // APB 읽기
    // -------------------------------------------------------------------------
    always @(*) begin								
			if (PSEL && PENABLE && !PWRITE) begin
                case (PADDR[3:2])
                    UART_DATA:    PRDATA = {24'h0, rx_fifo_front};
                    // RX 데이터를 읽으면 rx_ready 클리어 되도록 설계 (line 191 참고)
                    UART_STATUS:  PRDATA = {29'h0, rx_error, rx_ready, !tx_busy}; 
                    // UART 전송 관련 펌웨어 작성 시 가독성을 위해서 busy([0]번) 비트를
                    // Active-high로 구동하고자 busy 플래그에 !을 붙임
                    UART_CONTROL: PRDATA = {24'h0, control_reg};
                    UART_BAUD:    PRDATA = {16'h0, baud_div};
                    default:      PRDATA = 32'h0;
                endcase
            end
            else begin
                                  PRDATA = 32'h0;
            end
    end





    // -------------------------------------------------------------------------
    // UART TX State Machine

    // tx_start_pulse 신호가 들어오고, 현재 송신 중이 아닐 때(!tx_busy) 새로운 전송을 시작합니다.
    // -------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_busy      <= 1'b0;
            tx_shift_reg <= 10'h3FF; // 모든 비트 high로 초기화
            tx_bit_count <= 4'd0;
            tx_baud_cnt  <= 16'd0;
        end else begin
            if (tx_start_pulse && !tx_busy) begin
                // Start Transmission
                tx_busy      <= 1'b1;
                tx_bit_count <= 4'd10; // Start(1) + Data(8) + Stop(1) 총 10개 비트 카운트
                tx_baud_cnt  <= baud_div - 1'b1;
                // LSB First: Stop(1) << 9 | Data << 1 | Start(0), 즉 LSB부터 전송한다.
                tx_shift_reg <= {1'b1, tx_data_reg, 1'b0}; 
            end
            else if (tx_busy) begin
                if (tx_baud_cnt == 0) begin
                    tx_shift_reg <= {1'b1, tx_shift_reg[9:1]}; // Shift Right
                    // 다음 비트를 전송하기 위해 오른쪽으로 시프트
                    // 새로 들어오는 MSB는 1로 채워 아이들 상태를 유지
                    tx_bit_count <= tx_bit_count - 1'b1;
                    tx_baud_cnt  <= baud_div - 1'b1;     // 다음 비트 주기를 위해 카운터 리셋
                    
                    if (tx_bit_count == 4'd0) begin
                        tx_busy <= 1'b0; // Transmission Done
                    end
                end else begin
                    tx_baud_cnt <= tx_baud_cnt - 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // UART RX State Machine
    // -------------------------------------------------------------------------
    // RX 클리어 로직: APB가 UART_DATA(0x00)를 읽으면 rx_ready 클리어
    wire rx_clear = (PSEL && PENABLE && !PWRITE && (PADDR[3:2] == UART_DATA));
    wire rx_pop = rx_clear && rx_ready;
    wire rx_fifo_can_push = !rx_fifo_full || rx_pop;
    wire rx_stop_sample = (rx_state == S_STOP) && (rx_baud_cnt == baud_div - 1);
    wire rx_push = rx_stop_sample && rx_in && rx_fifo_can_push;
    wire rx_overflow = rx_stop_sample && rx_in && !rx_fifo_can_push;
    wire rx_framing_error = rx_stop_sample && !rx_in;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_state     <= S_IDLE;
            rx_baud_cnt  <= 16'd0;
            rx_bit_index <= 4'd0;
            rx_shifter   <= 8'h00;
            rx_error     <= 1'b0;
            rx_fifo_wr_ptr <= 4'd0;
            rx_fifo_rd_ptr <= 4'd0;
            rx_fifo_count  <= 5'd0;
        end else begin
            // RX FIFO push/pop and count update are centralized here.
            if (rx_pop) begin
                rx_fifo_rd_ptr <= rx_fifo_rd_ptr + 1'b1;
            end
            if (rx_push) begin
                rx_fifo[rx_fifo_wr_ptr] <= rx_shifter;
                rx_fifo_wr_ptr <= rx_fifo_wr_ptr + 1'b1;
            end
            case ({rx_push, rx_pop})
                2'b10: rx_fifo_count <= rx_fifo_count + 1'b1;
                2'b01: rx_fifo_count <= rx_fifo_count - 1'b1;
                default: rx_fifo_count <= rx_fifo_count;
            endcase

            if (rx_pop || rx_push) begin
                rx_error <= 1'b0;
            end
            if (rx_overflow || rx_framing_error) begin
                rx_error <= 1'b1;
            end

            case (rx_state)
                S_IDLE: begin
                    rx_baud_cnt <= 16'd0;
                    rx_bit_index <= 4'd0;
                    
                    if (rx_in == 1'b0) begin // Start bit detected
                        rx_state <= S_START;
                    end
                end

                S_START: begin
                    // Check middle of start bit
                    if (rx_baud_cnt < (baud_div / 2)) begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end else begin
                        if (rx_in == 1'b0) begin // 진짜 Start Bit 라면 
                            rx_state <= S_DATA;
                            rx_baud_cnt <= 16'd0; // Reset for next full bit
                        end else begin
                            rx_state <= S_IDLE; // False Start
                        end
                    end
                end

                S_DATA: begin
                    if (rx_baud_cnt == baud_div - 1) begin
                        rx_baud_cnt <= 16'd0;
                        rx_shifter[rx_bit_index] <= rx_in; // LSB부터 MSB순서로 저장한다.
                        
                        if (rx_bit_index < 7) begin
                            rx_bit_index <= rx_bit_index + 1'b1;
                        end else begin
                            rx_bit_index <= 4'd0;
                            rx_state <= S_STOP;
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end

                S_STOP: begin  
                //비트 중앙에서 STOP 비트 확인 후 에러 플래그 제어
                    if (rx_baud_cnt == baud_div - 1) begin
                        rx_state <= S_IDLE;
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1'b1;
                    end
                end
                
                default: rx_state <= S_IDLE;
            endcase
        end
    end

endmodule
