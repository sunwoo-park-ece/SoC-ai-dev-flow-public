module APB_TIMER (
    input  wire        PCLK,
    input  wire        PRESETn,

    input  wire [31:0] PADDR,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [31:0] PWDATA,

    output reg  [31:0] PRDATA,
    output wire        PREADY
);

    localparam integer ADDR_CTRL    = 16'h0000;
    localparam integer ADDR_COUNT   = 16'h0004;
    localparam integer ADDR_COMPARE = 16'h0008;
    localparam integer ADDR_STATUS  = 16'h000c;

    reg [31:0] counter;
    reg [31:0] programmed_compare;
    reg [31:0] active_compare;
    reg        running;
    reg        ready;

    wire apb_write = PSEL && PENABLE && PWRITE;
    wire write_ctrl = apb_write && (PADDR[15:0] == ADDR_CTRL);
    wire write_compare = apb_write && (PADDR[15:0] == ADDR_COMPARE);
    wire status_w1c = apb_write && (PADDR[15:0] == ADDR_STATUS) && PWDATA[0];
    wire start_cmd = write_ctrl && PWDATA[0];
    wire reload_cmd = write_ctrl && !PWDATA[0] && PWDATA[1];
    wire stop_cmd = write_ctrl && !PWDATA[0] && !PWDATA[1];

    assign PREADY = 1'b1;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            counter            <= 32'd0;
            programmed_compare <= 32'd0;
            active_compare     <= 32'd0;
            running            <= 1'b0;
            ready              <= 1'b0;
        end else begin
            if (write_compare) begin
                programmed_compare <= PWDATA;
            end

            // Command priority is START, RELOAD, then STOP. Commands suppress
            // the normal count/terminal evaluation on their commit edge.
            if (start_cmd) begin
                counter        <= 32'd0;
                active_compare <= programmed_compare;
                if (programmed_compare == 32'd0) begin
                    running <= 1'b0;
                    ready   <= 1'b1;
                end else begin
                    running <= 1'b1;
                    ready   <= 1'b0;
                end
            end else if (reload_cmd) begin
                counter <= 32'd0;
                running <= 1'b0;
                ready   <= 1'b0;
            end else if (stop_cmd) begin
                running <= 1'b0;
            end else begin
                // W1C is evaluated before the terminal event so completion is
                // explicitly set-dominant when both occur on one PCLK edge.
                if (status_w1c) begin
                    ready <= 1'b0;
                end

                if (running) begin
                    if (counter == (active_compare - 32'd1)) begin
                        counter <= active_compare;
                        running <= 1'b0;
                        ready   <= 1'b1;
                    end else begin
                        counter <= counter + 32'd1;
                    end
                end
            end
        end
    end

    always @(*) begin
        PRDATA = 32'd0;
        if (PSEL && PENABLE && !PWRITE) begin
            case (PADDR[15:0])
                ADDR_CTRL:    PRDATA = {31'd0, running};
                ADDR_COUNT:   PRDATA = counter;
                ADDR_COMPARE: PRDATA = programmed_compare;
                ADDR_STATUS:  PRDATA = {31'd0, ready};
                default:      PRDATA = 32'd0;
            endcase
        end
    end

endmodule
