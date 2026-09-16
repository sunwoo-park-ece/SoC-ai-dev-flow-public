// OPEN_SIM frequency abstraction only. Not a production FPGA PLL replacement.
module vga_pll (
    input  wire inclk0,
    output reg  c0,
    output reg  locked
);
    integer lock_count;

    initial begin
        c0         = 1'b0;
        locked     = 1'b0;
        lock_count = 0;
    end

    always @(posedge inclk0) begin
        c0 <= ~c0;
        if (!locked) begin
            if (lock_count == 3) begin
                locked <= 1'b1;
            end else begin
                lock_count <= lock_count + 1;
            end
        end
    end

    // Test-only behavioral hook. It changes no production-facing port and
    // lets directed tests exercise lock loss and deterministic reacquisition.
    task inject_lock_loss;
        begin
            locked     = 1'b0;
            lock_count = 0;
        end
    endtask
endmodule
