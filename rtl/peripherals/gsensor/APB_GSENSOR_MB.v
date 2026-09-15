module APB_GSENSOR_MB #(
    parameter integer RESET_DELAY_BITS = 20,
    parameter integer POLL_BITS = 14
) (
	//////////// CLOCK //////////
	input 		          	  PCLK,
	input                     PRESETn,
	// APB 슬레이브 인터페이스
	input         [31:0]      PADDR,   	// APB 주소
	input                     PWRITE,  	// APB 쓰기 제어
	input                     PSEL,    		// APB 슬레이브 선택
	input                     PENABLE, 	// APB 활성화
	input 		  [31:0]      PWDATA,  	// APB 쓰기 데이터
	output reg 	  [31:0]      PRDATA,  	// APB 읽기 데이터
    output wire               PREADY,
	//////////// Accelerometer //////////
	output		          		GSENSOR_CS_N,
	input 		     [2:1]		GSENSOR_INT,
	output		          		GSENSOR_SCLK,
	output 		          	    GSENSOR_SDI, // SLAVE DATA IN , MASTER DATA OUT
	input 		          		GSENSOR_SDO,   // SLAVE DATA OUT, MASTER DATA IN
    output          [15:0]      debug_acc_x,
	output          [15:0]      debug_acc_y
	
);

	assign PREADY = 1'b1;

//=======================================================
//  REG/WIRE declarations
//=======================================================
wire	        dly_rst;
wire [15:0] out_acc_x;
wire [15:0] out_acc_y;
wire [15:0] out_acc_z;

assign debug_acc_x = out_acc_x;
assign debug_acc_y = out_acc_y;

//=======================================================
//  Structural coding
//=======================================================

//	Reset
reset_delay #(.DELAY_BITS(RESET_DELAY_BITS)) u_reset_delay (
            .iRSTN(PRESETn),
            .iCLK(PCLK),
            .oRST(dly_rst));

//  Initial Setting and Data Read Back
spi_ee_config #(.POLL_BITS(POLL_BITS)) u_spi_ee_config (
						.iRSTN(!dly_rst),								
						.iPCLK(PCLK),
						.iG_INT2(GSENSOR_INT[1]),            
						.out_acc_x(out_acc_x),
						.out_acc_y(out_acc_y),
						.out_acc_z(out_acc_z),
						.SPI_SDI(GSENSOR_SDI),
						.SPI_SDO(GSENSOR_SDO),
						.oSPI_CSN(GSENSOR_CS_N),
						.oSPI_CLK(GSENSOR_SCLK),
						.gsensor_ready()
						);
			

// GSENSOR 레지스터 주소 맵 (워드 오프셋 기준)
localparam [1:0] GSENSOR_x_y_DATA = 2'b00; // 0x00: x축,y축 데이터 레지스터 (16+16) 			
localparam [1:0] GSENSOR_z_DATA = 2'b01; // 0x04: z축 데이터 레지스터 (0+16) 			
					
// APB 레지스터 액세스 제어
always @(*) begin
        // APB 읽기 액세스
        if (PSEL && !PWRITE && PENABLE) begin
            case (PADDR[3:2])
                GSENSOR_x_y_DATA:  PRDATA ={out_acc_x, out_acc_y};
				GSENSOR_z_DATA:    PRDATA ={16'b0, out_acc_z};
                default: PRDATA  = 32'h0;
            endcase
		end	else begin
			PRDATA = 32'h0;
		end
		
end
	
			
			
			



						
endmodule

/*

양수 (+): 최상위 비트(MSB, 15번 비트)가 0입니다. (예: 0x00FF = +255)

음수 (-): 최상위 비트(MSB, 15번 비트)가 1입니다. (예: 0xFFFF = -1)

*/




