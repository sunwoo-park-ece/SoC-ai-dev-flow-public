`include "../../vh/load.vh"

module LoadExtender (
    input wire memory_read,                     // MEM_memory_read
    input wire [2:0] funct3,                    // MEM_funct3
    input wire [31:0] data_memory_read_data,    // BRAM 출력 (q)
    input wire [1:0] address,                   // MEM_alu_result[1:0]
    
    output reg [31:0] register_file_write_data  // Forward Unit 및 MEM/WB 레지스터로 연결
);

    reg [7:0] byte_sel;
    reg [15:0] half_sel;

    always @(*) begin
        if (memory_read) begin
            case (funct3)
                `LOAD_LB, `LOAD_LBU: begin
                    case (address[1:0])
                        2'b00: byte_sel = data_memory_read_data[ 7: 0];
                        2'b01: byte_sel = data_memory_read_data[15: 8];
                        2'b10: byte_sel = data_memory_read_data[23:16];
                        2'b11: byte_sel = data_memory_read_data[31:24];
                    endcase

                    if (funct3 == `LOAD_LBU) begin
                        register_file_write_data = {24'b0, byte_sel};                // Zero-extend
                    end else begin
                        register_file_write_data = {{24{byte_sel[7]}}, byte_sel};   // Sign-extend
                    end
                end

                `LOAD_LH, `LOAD_LHU: begin
                    case (address[1])
                        1'b0 : half_sel = data_memory_read_data[15:0];
                        1'b1 : half_sel = data_memory_read_data[31:16];
                    endcase

                    if (funct3 == `LOAD_LHU) begin
                        register_file_write_data = {16'b0, half_sel};                // Zero-extend
                    end else begin
                        register_file_write_data = {{16{half_sel[15]}}, half_sel};   // Sign-extend
                    end
                end

                `LOAD_LW: begin
                    register_file_write_data = data_memory_read_data;
                end

                default: begin
                    register_file_write_data = 32'b0;
                end
            endcase
        end else begin
            register_file_write_data = 32'b0;
        end
    end

endmodule