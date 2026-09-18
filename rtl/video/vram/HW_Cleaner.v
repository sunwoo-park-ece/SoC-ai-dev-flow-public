module HW_Cleaner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        abort,
    input  wire        pause,
    output reg  [13:0] clr_addr,
    output wire        clr_we,
    output reg         clr_busy,
    output reg         clr_done
);

    localparam [13:0] LAST_WORD = 14'd9599;

    assign clr_we = clr_busy && !abort && !pause;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clr_addr <= 14'd0;
            clr_busy <= 1'b0;
            clr_done <= 1'b0;
        end else begin
            clr_done <= 1'b0;

            if (abort) begin
                clr_addr <= 14'd0;
                clr_busy <= 1'b0;
            end else if (start && !clr_busy) begin
                clr_addr <= 14'd0;
                clr_busy <= 1'b1;
            end else if (clr_busy && !pause) begin
                if (clr_addr == LAST_WORD) begin
                    // clr_we remains asserted for this edge. Completion is
                    // reported only after word 9599 is physically committed.
                    clr_busy <= 1'b0;
                    clr_done <= 1'b1;
                end else begin
                    clr_addr <= clr_addr + 14'd1;
                end
            end
        end
    end

endmodule
