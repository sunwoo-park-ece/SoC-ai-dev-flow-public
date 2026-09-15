// Destination-domain reset synchronizer.
// Assertion is asynchronous; deassertion advances only on destination clocks.
module reset_release_sync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire async_reset_n,
    output wire reset_n
);
    // Quartus recognizes this as an asynchronous synchronizer chain. Explicit
    // LOW power-up state makes release deterministic even if async_reset_n is
    // already high when configuration completes.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name POWER_UP_LEVEL LOW" *)
    reg [STAGES-1:0] sync_ff;

    initial sync_ff = {STAGES{1'b0}};

    always @(posedge clk or negedge async_reset_n) begin
        if (!async_reset_n)
            sync_ff <= {STAGES{1'b0}};
        else
            sync_ff <= {sync_ff[STAGES-2:0], 1'b1};
    end

    assign reset_n = sync_ff[STAGES-1];
endmodule
