`timescale 1ns/1ps

// =============================================================================
// File: ahb_vga_bfm.sv
// Module: ahb_vga_bfm
// Project: P12A2 VGA CDC Independent DV
// Description: AHB-Lite Bus Functional Model for VGA/VRAM Slave.
//              Drives compliant address/data phases, wait states (HREADY_IN),
//              status reads/W1C writes, and asserts two-cycle ERROR responses.
// =============================================================================

module ahb_vga_bfm (
    input  wire        hclk,
    input  wire        hresetn,
    output reg  [31:0] haddr,
    output reg         hwrite,
    output reg  [1:0]  htrans,
    output reg  [2:0]  hsize,
    output reg  [31:0] hwdata,
    output reg         hsel,
    output reg         hready_in,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire [1:0]  hresp
);

    integer error_transfers=0;

    initial begin
        haddr     = 32'h0;
        hwrite    = 1'b0;
        htrans    = 2'b00;
        hsize     = 3'b010;
        hwdata    = 32'h0;
        hsel      = 1'b0;
        hready_in = 1'b1;
    end

    task automatic idle;
        begin
            @(negedge hclk);
            hsel      = 1'b0;
            htrans    = 2'b00;
            hwrite    = 1'b0;
            haddr     = 32'h0;
            hsize     = 3'b010;
            hready_in = 1'b1;
        end
    endtask

    // Canonical single-word write with OKAY expectation
    task automatic write_word_ok(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk);
            hsel      = 1'b1;
            htrans    = 2'b10; // NONSEQ
            hwrite    = 1'b1;
            hsize     = 3'b010;
            haddr     = addr;
            hwdata    = data;
            hready_in = 1'b1;
            @(posedge hclk); #1;
            while (!hready) begin
                @(posedge hclk); #1;
            end
            if (hresp != 2'b00) begin
                $display("[BFM_ERROR] write_word_ok received non-OKAY resp=%b at addr=%h time=%0t",
                         hresp, addr, $time);
                $fatal(1, "BFM write failed");
            end
            idle();
            @(posedge hclk); #1;
        end
    endtask

    // Write with injected HREADY_IN stall cycles during data phase
    task automatic write_word_stall(input [31:0] addr, input [31:0] data, input integer stalls);
        integer s;
        begin
            @(negedge hclk);
            hsel      = 1'b1;
            htrans    = 2'b10;
            hwrite    = 1'b1;
            hsize     = 3'b010;
            haddr     = addr;
            hwdata    = data;
            hready_in = 1'b1;
            @(posedge hclk); #1;
            // Inject wait states on bus master side
            for (s = 0; s < stalls; s = s + 1) begin
                @(negedge hclk);
                hready_in = 1'b0;
                @(posedge hclk); #1;
            end
            @(negedge hclk);
            hready_in = 1'b1;
            @(posedge hclk); #1;
            while (!hready) begin
                @(posedge hclk); #1;
            end
            if (hresp != 2'b00) $fatal(1, "BFM stalled write received non-OKAY resp");
            idle();
            @(posedge hclk); #1;
        end
    endtask

    // Canonical single-word read with OKAY expectation
    task automatic read_word_ok(input [31:0] addr, output [31:0] data);
        begin
            @(negedge hclk);
            hsel      = 1'b1;
            htrans    = 2'b10;
            hwrite    = 1'b0;
            hsize     = 3'b010;
            haddr     = addr;
            hready_in = 1'b1;
            @(posedge hclk); #1;
            while (!hready) begin
                @(posedge hclk); #1;
            end
            if (hresp != 2'b00) begin
                $display("[BFM_ERROR] read_word_ok received non-OKAY resp=%b at addr=%h time=%0t",
                         hresp, addr, $time);
                $fatal(1, "BFM read failed");
            end
            data = hrdata;
            idle();
            @(posedge hclk); #1;
        end
    endtask

    // Write transfer expecting 2-cycle ERROR response (HRESP=01)
    task automatic write_expect_error(input [31:0] addr, input [2:0] sz, input [31:0] data);
        begin
            @(negedge hclk);
            hsel      = 1'b1;
            htrans    = 2'b10;
            hwrite    = 1'b1;
            hsize     = sz;
            haddr     = addr;
            hwdata    = data;
            hready_in = 1'b1;
            @(posedge hclk); #1;
            // Cycle 1 of ERROR: HRESP=01, HREADY=0
            if (hready !== 1'b0 || hresp !== 2'b01) begin
                $display("[BFM_ERROR] Missing ERROR wait cycle (expected HREADY=0, HRESP=01, got HREADY=%b, HRESP=%b) addr=%h time=%0t",
                         hready, hresp, addr, $time);
                $fatal(1, "BFM error protocol violation cycle 1");
            end
            @(posedge hclk); #1;
            // Cycle 2 of ERROR: HRESP=01, HREADY=1
            if (hready !== 1'b1 || hresp !== 2'b01) begin
                $display("[BFM_ERROR] Missing ERROR final cycle (expected HREADY=1, HRESP=01, got HREADY=%b, HRESP=%b) addr=%h time=%0t",
                         hready, hresp, addr, $time);
                $fatal(1, "BFM error protocol violation cycle 2");
            end
            error_transfers=error_transfers+1;
            $display("[AHB_ERROR_OBSERVED] address=%h errors=%0d time=%0t",addr,error_transfers,$time);
            idle();
            @(posedge hclk); #1;
        end
    endtask

    // B2 narrow-window transfer: capture PRE-edge response at actual data
    // phases, cancel following address during ERROR, retain original data.
    // This drives only legal bus pins and makes no DUT-state decisions.
    task automatic window_error(input [31:0] addr,input [31:0] data);
        reg wait_ready,final_ready;
        reg [1:0] wait_resp,final_resp;
        begin
            @(negedge hclk);
            hsel=1;htrans=2'b10;hwrite=1;hsize=2;haddr=addr;hwdata=data;hready_in=1;
            @(posedge hclk);
            #0.010;
            @(negedge hclk);hsel=0;htrans=0;
            @(posedge hclk);
            wait_ready=hready;wait_resp=hresp;
            #0.010;
            if (wait_ready!==0 || wait_resp!==1) $fatal(1,"B2 actual ERROR wait protocol");
            @(posedge hclk);
            final_ready=hready;final_resp=hresp;
            $display("[B2_AHB_FINAL] address=%h response=%b ready=%b time=%0t",addr,final_resp,final_ready,$time);
            #0.010;
            if (final_ready!==1 || final_resp!==1) $fatal(1,"B2 actual ERROR final protocol");
            error_transfers=error_transfers+1;
        end
    endtask

    // High-level VGA register access helpers
    task automatic vram_status_read(output [31:0] status);
        begin
            read_word_ok(32'h2001_0000, status);
        end
    endtask

    task automatic vram_status_w1c(input [31:0] mask);
        begin
            write_word_ok(32'h2001_0000, mask);
        end
    endtask

    task automatic vram_control_write(input [31:0] cmd);
        begin
            write_word_ok(32'h2001_0004, cmd);
        end
    endtask

    task automatic vram_fb_write(input [13:0] word_idx, input [31:0] data);
        begin
            write_word_ok(32'h2000_0000 + (word_idx << 2), data);
        end
    endtask

endmodule
