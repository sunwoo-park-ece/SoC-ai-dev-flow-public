`timescale 1ns/1ps
module tb_load_extender;
    reg memory_read;
    reg [2:0] funct3;
    reg [31:0] data_memory_read_data;
    reg [1:0] address;
    wire [31:0] register_file_write_data;
    reg [31:0] state = 32'h17a543c1, expected, observed;
    integer sample, read_en, kind, offset, lane, checks = 0;
    LoadExtender dut(.*);
    initial begin
        // Deterministic independent stimulus, including every byte value at
        // every lane in the first 256 samples; no DUT output feeds the oracle.
        for (sample=0; sample<4096; sample=sample+1) begin
            state = (state << 1) ^ (state[31] ? 32'h04c11db7 : 32'b0);
            data_memory_read_data = sample<256 ? sample*32'h01010101 : state;
            for(read_en=0;read_en<2;read_en=read_en+1)
            for(kind=0;kind<8;kind=kind+1)
            for(offset=0;offset<4;offset=offset+1) begin
                memory_read=read_en[0]; funct3=kind[2:0]; address=offset[1:0];
                expected=0;
                if(read_en) begin
                    if(kind==0 || kind==4) begin
                        lane=(data_memory_read_data >> (8*offset)) & 255;
                        expected=(kind==0 && lane>=128) ? lane-256 : lane;
                    end else if(kind==1 || kind==5) begin
                        lane=(data_memory_read_data >> (16*(offset/2))) & 65535;
                        expected=(kind==1 && lane>=32768) ? lane-65536 : lane;
                    end else if(kind==2) expected=data_memory_read_data;
                end
                #1; observed=register_file_write_data;
                if($test$plusargs("inject_load") && memory_read && funct3==0) begin
                    $display("INJECTION_REACHED LOAD_OBSERVATION"); observed=observed^1;
                end
                if(observed !== expected)
                    $fatal(1,"ASSERT_FAIL LOAD_EXTEND read=%d funct3=%d addr=%d data=%h got=%h expected=%h",
                           memory_read,funct3,address,data_memory_read_data,observed,expected);
                checks=checks+1;
            end
        end
        if(checks!=262144) $fatal(1,"ASSERT_FAIL LOAD_STIMULUS_CLOSURE");
        $display("SUMMARY_PASS LOAD_EXTENDER checks=%0d",checks);$finish;
    end
endmodule
