// Spec-driven project-owned 640x480 timing generator.
module VGA_SyncGen (
    input  wire       iRSTn,
    input  wire       iPCLK,
    output wire       oHS,
    output wire       oVS,
    output reg  [9:0] oHCNT,
    output reg  [9:0] oVCNT,
    output wire       oVideoOn
);
    localparam [9:0] H_VISIBLE = 10'd640;
    localparam [9:0] H_FRONT   = 10'd16;
    localparam [9:0] H_SYNC    = 10'd96;
    localparam [9:0] H_TOTAL   = 10'd800;
    localparam [9:0] V_VISIBLE = 10'd480;
    localparam [9:0] V_FRONT   = 10'd10;
    localparam [9:0] V_SYNC    = 10'd2;
    localparam [9:0] V_TOTAL   = 10'd525;

    wire h_sync_window = (oHCNT >= (H_VISIBLE + H_FRONT)) &&
                         (oHCNT <  (H_VISIBLE + H_FRONT + H_SYNC));
    wire v_sync_window = (oVCNT >= (V_VISIBLE + V_FRONT)) &&
                         (oVCNT <  (V_VISIBLE + V_FRONT + V_SYNC));

    assign oHS = ~h_sync_window;
    assign oVS = ~v_sync_window;
    assign oVideoOn = (oHCNT < H_VISIBLE) && (oVCNT < V_VISIBLE);

    always @(posedge iPCLK or negedge iRSTn) begin
        if (!iRSTn) begin
            oHCNT <= 10'd0;
            oVCNT <= 10'd0;
        end else if (oHCNT == H_TOTAL - 10'd1) begin
            oHCNT <= 10'd0;
            if (oVCNT == V_TOTAL - 10'd1)
                oVCNT <= 10'd0;
            else
                oVCNT <= oVCNT + 10'd1;
        end else begin
            oHCNT <= oHCNT + 10'd1;
        end
    end
endmodule
