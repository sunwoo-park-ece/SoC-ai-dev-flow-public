// Spec-driven project-owned startup reset qualifier.
module reset_delay #(
    parameter integer DELAY_BITS = 20
) (
    input  wire iRSTN,
    input  wire iCLK,
    output reg  oRST
);
    reg [DELAY_BITS-1:0] delay_count;

    always @(posedge iCLK or negedge iRSTN) begin
        if (!iRSTN) begin
            delay_count <= {DELAY_BITS{1'b0}};
            oRST <= 1'b1;
        end else if (oRST) begin
            if (delay_count == {DELAY_BITS{1'b1}}) begin
                oRST <= 1'b0;
            end else begin
                delay_count <= delay_count + {{(DELAY_BITS-1){1'b0}}, 1'b1};
            end
        end
    end
endmodule
