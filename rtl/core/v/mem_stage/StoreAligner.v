`include "../../vh/store.vh"

module StoreAligner (
    input wire memory_write,                    // EX_memory_write
    input wire [2:0] funct3,                    // EX_funct3
    input wire [31:0] register_file_read_data,  // EX_read_data2_MUX (포워딩된 데이터)
    input wire [1:0] address,                   // alu_result[1:0] (EX 스테이지 ALU 결과)
    
    output reg [31:0] data_memory_write_data,   // BRAM write_data로 바로 연결
    output reg [3:0] write_mask                 // BRAM byteena로 바로 연결
);

    always @(*) begin
        if (memory_write) begin
            case (funct3)
                `STORE_SB: begin
                    data_memory_write_data = {4{register_file_read_data[7:0]}};
                    case (address[1:0])
                        2'b00: write_mask = 4'b0001;
                        2'b01: write_mask = 4'b0010;
                        2'b10: write_mask = 4'b0100;
                        2'b11: write_mask = 4'b1000;
                    endcase
                end
                `STORE_SH: begin
                    data_memory_write_data = {2{register_file_read_data[15:0]}};
                    case (address[1:0])
                        2'b00: write_mask = 4'b0011;
                        2'b10: write_mask = 4'b1100;
                        default: write_mask = 4'b0000;
                    endcase
                end
                `STORE_SW: begin
                    data_memory_write_data = register_file_read_data;
                    if (address[1:0] == 2'b00)
                        write_mask = 4'b1111;
                    else
                        write_mask = 4'b0000;
                end
                default: begin
                    data_memory_write_data = 32'b0;
                    write_mask = 4'b0;
                end
            endcase
        end else begin
            data_memory_write_data = 32'b0;
            write_mask = 4'b0;
        end
    end

endmodule