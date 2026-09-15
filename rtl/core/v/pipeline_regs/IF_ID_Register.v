module IF_ID_Register #(
    parameter XLEN = 32
)(
    // pipeline register control signals
    input wire clk,
    input wire clk_enable,
    input wire reset,
    input wire flush,
    input wire IF_ID_stall,

    // signals from IF phase
    input wire [XLEN-1:0] IF_pc,
    input wire [XLEN-1:0] IF_pc_plus_4,

    // signals to ID/EX register
    output reg [XLEN-1:0] ID_pc,
    output reg [XLEN-1:0] ID_pc_plus_4,
    output reg ID_valid,
    output wire  [31:0]   ID_instruction
);

reg flush_flag;
reg no_stall_flag;
reg [31:0] IF_instruction_d;
wire [31:0] irom_q;


/*
MEM_I u_memi(
.clk           (clk),
.clk_enable(!reset),
.address    (IF_pc[11:2]),
.q             (irom_q)
);
*/

IMEM u_IMEM(
	.aclr      (reset),
	.address (IF_pc[13:2]),
	.clken    (clk_enable),
	.clock    (clk),
	.q         (irom_q)
	);


always @(posedge clk or posedge reset) begin
    if (reset) begin
        ID_pc <= {XLEN{1'b0}};
        ID_pc_plus_4 <= {XLEN{1'b0}};
        ID_valid <= 1'b0;
        //ID_instruction <= 32'h0000_0013;
		  
		  flush_flag     <= 1'b0;
		  no_stall_flag <= 1'b1;
		  IF_instruction_d     <= 32'h0000_0013; // 안전한 NOP로 초기화
    end 
    else if (clk_enable) begin
        if (flush) begin   
            ID_pc <= {XLEN{1'b0}};
            ID_pc_plus_4 <= {XLEN{1'b0}};
            ID_valid <= 1'b0;
				
			flush_flag <= 1'b1;
				
        end else if (!IF_ID_stall) begin
            ID_pc <= IF_pc;
            ID_pc_plus_4 <= IF_pc_plus_4;
            // IMEM q and this request PC update on the same clock edge.
            // A real NOP fetch is valid; only reset/flush create bubbles.
            ID_valid <= 1'b1;
			no_stall_flag <= 1'b1;
			flush_flag <= 1'b0;
        end else if (IF_ID_stall) begin
		  
            if (no_stall_flag) begin
			    IF_instruction_d <= irom_q;
            end
		  	no_stall_flag <= 1'b0;
			flush_flag <= 1'b0;
			// stall 시 ID_pc 등은 업데이트하지 않음 (이전 값 유지)
    end
end
end



assign ID_instruction = flush_flag ? 32'h0000_0013 :
										  no_stall_flag ? irom_q : IF_instruction_d;
										 


endmodule
