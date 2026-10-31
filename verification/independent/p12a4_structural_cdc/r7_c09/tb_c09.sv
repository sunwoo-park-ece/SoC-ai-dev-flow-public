`timescale 1ns/1ps
module tb_c09;
    reg hclk=0, clk50=0, hresetn=0, stopped=0;
    integer phase=3, mode=0;
    string fault="NONE";
    always #10 hclk=~hclk;
    initial begin
        if ($value$plusargs("PHASE=%d",phase)) begin end
        if ($value$plusargs("MODE=%d",mode)) begin end
        if ($value$plusargs("FAULT=%s",fault)) begin end
        #(phase);
        forever begin #10; if(!stopped) clk50=~clk50; end
    end
    wire [31:0] addr,wdata,rdata;
    wire wr,sel,ready_in,ready;
    wire [1:0] trans,resp;
    wire [2:0] size;
    wire [3:0] red,green,blue;
    wire hs,vs;
    wire [11:0] rgb={red,green,blue};
    AHB_VRAM_DUAL_BUFFER dut(.CLOCK_50(clk50),.HCLK(hclk),.HRESETn(hresetn),
        .HADDR(addr),.HWRITE(wr),.HTRANS(trans),.HSIZE(size),.HWDATA(wdata),
        .HSEL(sel),.HREADY_IN(ready_in),.HRDATA(rdata),.HREADY(ready),.HRESP(resp),
        .VGA_R(red),.VGA_G(green),.VGA_B(blue),.VGA_HS(hs),.VGA_VS(vs));
    ahb_vga_bfm bfm(.hclk(hclk),.hresetn(hresetn),.haddr(addr),.hwrite(wr),
        .htrans(trans),.hsize(size),.hwdata(wdata),.hsel(sel),.hready_in(ready_in),
        .hrdata(rdata),.hready(ready),.hresp(resp));

    // Oracle values derive only from spec and accepted external transactions.
    reg [31:0] memory [0:1][0:1];
    reg known [0:1][0:1];
    reg data_valid=0, data_write=0;
    reg [31:0] data_address=0;
    integer front=0, requests=0, commits=0, writes=0;
    reg pending=0, armed=0;
    integer x=0,y=0,epoch=0;
    reg [1:0] release_ref=0;
    wire reset_request=hresetn && dut.U_PLL.locked;
    integer firsts=0,pixels=0,blacks=0,isolation=0,captures=0,stop_checks=0;
    integer zero_captures=0;
    reg [11:0] previous_rgb=0;
    integer i,j;
    initial for(i=0;i<2;i=i+1) for(j=0;j<2;j=j+1) begin memory[i][j]=0;known[i][j]=0;end

    always @(posedge hclk) begin
        if(!hresetn) data_valid=0;
        else if(ready_in && ready) begin
            if(data_valid && data_write && resp==0) begin
                if(data_address>=32'h20000000 && data_address<=32'h20000004) begin
                    if(size!=3'b010) $fatal(1,"FAIL_C09_BUS_SIZE");
                    memory[1-front][(data_address-32'h20000000)>>2]=wdata;
                    known[1-front][(data_address-32'h20000000)>>2]=1;
                    writes=writes+1;
                    $display("[WRITE_ORACLE] bank=%0d word=%0d data=%h",1-front,(data_address-32'h20000000)>>2,wdata);
                end
                if(data_address==32'h20010004 && wdata[0]) begin
                    if(pending || !reset_request || y>=524) $fatal(1,"FAIL_C09_STIMULUS_BOUNDARY");
                    pending=1;requests=requests+1;
                    $display("[SWAP_ACCEPT_ORACLE] request=%0d x=%0d y=%0d",requests,x,y);
                end
            end
            data_valid=sel && trans[1];data_write=wr;data_address=addr;
        end
        #1;
        if(!reset_request) begin
            if(rgb!==12'h000) $fatal(1,"FAIL_C09_INVALID_BLACK");
            blacks=blacks+1;
        end
    end

    // Reference release follows the contract, never DUT reset/counter outputs.
    always @(negedge reset_request) begin
        release_ref=0;x=0;y=0;front=0;pending=0;armed=0;
        captures=0;zero_captures=0;previous_rgb=0;epoch=epoch+1;
    end
    always @(posedge dut.pclk_25) begin : coordinate_check
        reg released,wrap;
        reg [11:0] expected,observed;
        integer word_index,bit_index;
        released=release_ref[1];
        release_ref={release_ref[0],reset_request};
        if(!released) begin x=0;y=0; end
        else begin
            captures=captures+1;
            if(dut.vram_read_addr===19'd0) zero_captures=zero_captures+1;
            wrap=(x==799 && y==524);
            if(wrap && pending) begin
                front=1-front;armed=1;pending=0;commits=commits+1;
                $display("[FRAME_HANDOFF] commit=%0d bank=%0d epoch=%0d",commits,front,epoch);
            end
            if(x==799) begin x=0;if(y==524)y=0;else y=y+1;end else x=x+1;
        end
        #1;
        if(hs !== !((x>=656)&&(x<752)) || vs !== !((y>=490)&&(y<492)))
            $fatal(1,"FAIL_C09_COORDINATE_SYNC x=%0d y=%0d",x,y);
        // Observed selector is checked against the transaction/frame oracle;
        // it is never used to compute expected ownership or pixels.
        if(dut.front_bank_p !== (front==1))
            $fatal(1,"FAIL_C09_FRAME_HANDOFF x=%0d y=%0d expected_bank=%0d",x,y,front);
        if(!armed || !released) begin
            if(rgb!==12'h000) $fatal(1,"FAIL_C09_BLACK_UNTIL_SWAP x=%0d y=%0d",x,y);
            blacks=blacks+1;
        end else if(y==0 && x<64) begin
            word_index=y*20+(x>>5);bit_index=x&31;
            if(!known[front][word_index]) $fatal(1,"FAIL_C09_ORACLE_UNWRITTEN");
            expected=memory[front][word_index][bit_index] ? 12'hfff:12'h000;
            observed=rgb;
            if(x==0 && firsts==0 && fault!="NONE") begin
                if(fault=="WRONG_BANK") observed=dut.u_VRAM0.q ? 12'hfff:12'h000;
                else if(fault=="PIXEL_DELAY") observed=previous_rgb;
                else $fatal(1,"FAIL_C09_FAULT_NAME");
                $display("[FAULT_ACTIVATED] fault=%s x=%0d y=%0d raw=%h injected=%h expected=%h",fault,x,y,rgb,observed,expected);
            end
            if(observed !== expected)
                $fatal(1,"FAIL_C09_PIXEL epoch=%0d x=%0d y=%0d bank=%0d expected=%h actual=%h",epoch,x,y,front,expected,observed);
            if(x==0) begin
                if(captures<2 || zero_captures<1) $fatal(1,"FAIL_C09_CAPTURE_BEFORE_VISIBLE");
                firsts=firsts+1;
                $display("[FIRST_PIXEL] n=%0d epoch=%0d x=0 y=0 bank=%0d expected=%h actual=%h captures=%0d zero_captures=%0d",firsts,epoch,front,expected,observed,captures,zero_captures);
            end
            pixels=pixels+1;
            if(firsts==2) isolation=isolation+1;
            $display("[PIXEL] n=%0d x=%0d y=0 bank=%0d word=%0d bit=%0d expected=%h actual=%h",firsts,x,front,word_index,bit_index,expected,observed);
        end
        previous_rgb=rgb;
    end

    task wait_ready;
        reg [31:0] status;
        integer polls;
        begin
            status=0;polls=0;
            while(!status[4]) begin
                bfm.read_word_ok(32'h20010000,status);polls=polls+1;
                if(polls>200) $fatal(1,"FAIL_C09_RECOVERY_TIMEOUT");
            end
        end
    endtask
    task wait_window(input integer n);
        begin
            wait(firsts>=n && x>=64);
            // ACK must reach HCLK before the next back-bank write/command.
            repeat(12) @(posedge hclk);
        end
    endtask
    task pattern(input reg [31:0] a,input reg [31:0] b);
        begin bfm.write_word_ok(32'h20000000,a);bfm.write_word_ok(32'h20000004,b);end
    endtask

    initial begin : stimulus
        reg held0,held1;
        integer n;
        repeat(5) @(posedge hclk);@(negedge hclk);hresetn=1;
        wait_ready();
        pattern(32'h96a53c69,32'h5a5ac3c3); // bit0=1, bit1=0; word boundary differs
        bfm.write_word_ok(32'h20010004,1);wait_window(1);
        pattern(32'h695ac396,32'ha5a53c3c); // distinct opposite back-bank pattern
        wait_window(2); // a complete front window while back has changed
        bfm.write_word_ok(32'h20010004,1);wait_window(3);
        wait(x==137 && y==0);@(negedge hclk);#3;
        if(mode==0) begin
            hresetn=0;repeat(5) @(posedge hclk);@(negedge hclk);#2;hresetn=1;
        end else if(mode==1) dut.U_PLL.inject_lock_loss();
        else begin
            // Stop only the external PLL source; no internal force/clock override.
            stopped=1;held0=dut.u_VRAM0.q;held1=dut.u_VRAM1.q;
            dut.U_PLL.inject_lock_loss();
            $display("[CLOCK_STOP] read_addr=%0d q0=%b q1=%b",dut.vram_read_addr,held0,held1);
            for(n=0;n<20;n=n+1) begin
                @(posedge hclk);#1;
                if(dut.u_VRAM0.q!==held0 || dut.u_VRAM1.q!==held1 || rgb!==0)
                    $fatal(1,"FAIL_C09_STOP_RETENTION_BLACK");
                stop_checks=stop_checks+1;
            end
            @(negedge hclk);#7;stopped=0;
            $display("[CLOCK_RESTART] checks=%0d",stop_checks);
        end
        wait_ready();
        pattern(32'hc35a9695,32'h3ca5696a);
        bfm.write_word_ok(32'h20010004,1);wait_window(4);
        if(firsts!=4 || pixels!=256 || isolation!=64 || commits!=3 || requests!=3 || writes!=6 || (mode==2 && stop_checks!=20))
            $fatal(1,"FAIL_C09_COVERAGE firsts=%0d pixels=%0d isolation=%0d commits=%0d requests=%0d writes=%0d",firsts,pixels,isolation,commits,requests,writes);
        $display("[C09_SUMMARY] mode=%0d firsts=%0d pixels=%0d isolation=%0d commits=%0d requests=%0d writes=%0d stop_checks=%0d black_checks=%0d",mode,firsts,pixels,isolation,commits,requests,writes,stop_checks,blacks);
        $display("C09_TARGET_PASS");$finish;
    end
    initial begin #150000000;$fatal(1,"FAIL_C09_TIMEOUT");end
endmodule
