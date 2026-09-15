// KEY[0]-driven system reset conditioner for the 50 MHz HCLK domain.
// The low level asserts reset asynchronously. A high input must first pass a
// two-flop release synchronizer and then remain qualified for RELEASE_CYCLES.
module system_reset_controller #(
    parameter integer RELEASE_CYCLES = 1_000_000,
    parameter integer COUNTER_WIDTH  = 20
) (
    input  wire clk,
    input  wire reset_button_n,
    output wire system_reset_n
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name POWER_UP_LEVEL LOW" *)
    reg reset_release_meta;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name POWER_UP_LEVEL LOW" *)
    reg reset_release_sync;
    (* altera_attribute = "-name POWER_UP_LEVEL LOW" *)
    reg [COUNTER_WIDTH-1:0] release_count;
    (* altera_attribute = "-name POWER_UP_LEVEL LOW" *)
    reg system_reset_n_reg;
    localparam [COUNTER_WIDTH-1:0] RELEASE_TERMINAL =
        RELEASE_CYCLES[COUNTER_WIDTH-1:0] - {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};

    assign system_reset_n = system_reset_n_reg;

    // Quartus Prime derives FPGA power-up conditions from Verilog initial
    // assignments. The attributes above state the same intended power-up level.
    initial begin
        reset_release_meta = 1'b0;
        reset_release_sync = 1'b0;
        release_count      = {COUNTER_WIDTH{1'b0}};
        system_reset_n_reg = 1'b0;
    end

    always @(posedge clk or negedge reset_button_n) begin
        if (!reset_button_n) begin
            reset_release_meta <= 1'b0;
            reset_release_sync <= 1'b0;
        end else begin
            reset_release_meta <= 1'b1;
            reset_release_sync <= reset_release_meta;
        end
    end

    always @(posedge clk or negedge reset_button_n) begin
        if (!reset_button_n) begin
            release_count  <= {COUNTER_WIDTH{1'b0}};
            system_reset_n_reg <= 1'b0;
        end else if (!reset_release_sync) begin
            release_count  <= {COUNTER_WIDTH{1'b0}};
            system_reset_n_reg <= 1'b0;
        end else if (!system_reset_n_reg) begin
            if (RELEASE_CYCLES <= 1) begin
                release_count  <= {COUNTER_WIDTH{1'b0}};
                system_reset_n_reg <= 1'b1;
            end else if (release_count == RELEASE_TERMINAL) begin
                release_count  <= release_count;
                system_reset_n_reg <= 1'b1;
            end else begin
                release_count <= release_count + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
            end
        end else begin
            release_count <= {COUNTER_WIDTH{1'b0}};
        end
    end
endmodule
