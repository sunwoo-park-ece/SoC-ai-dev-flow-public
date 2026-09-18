module AHB_VRAM_DUAL_BUFFER (
    input  wire        CLOCK_50,
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire [31:0] HADDR,
    input  wire        HWRITE,
    input  wire [1:0]  HTRANS,
    input  wire [2:0]  HSIZE,
    input  wire [31:0] HWDATA,
    input  wire        HSEL,
    input  wire        HREADY_IN,
    output reg  [31:0] HRDATA,
    output wire        HREADY,
    output wire [1:0]  HRESP,
    output reg  [3:0]  VGA_R,
    output reg  [3:0]  VGA_G,
    output reg  [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS
);

    localparam [13:0] LAST_WORD = 14'd9599;

    wire pclk_25;
    wire vga_pll_locked;
    wire vga_reset_n;

    vga_pll U_PLL (
        .inclk0 (CLOCK_50),
        .c0     (pclk_25),
        .locked (vga_pll_locked)
    );

    reset_release_sync u_vga_reset_sync (
        .clk           (pclk_25),
        .async_reset_n (HRESETn & vga_pll_locked),
        .reset_n       (vga_reset_n)
    );

    wire [9:0] h_cnt;
    wire [9:0] v_cnt;
    wire video_on;
    wire vga_vsync_sig;

    VGA_SyncGen U_SYNC (
        .iRSTn    (vga_reset_n),
        .iPCLK    (pclk_25),
        .oHS      (VGA_HS),
        .oVS      (vga_vsync_sig),
        .oHCNT    (h_cnt),
        .oVCNT    (v_cnt),
        .oVideoOn (video_on)
    );

    assign VGA_VS = vga_vsync_sig;

    // Mixed-width RAM prefetch address. The frame-ownership commit occurs at
    // the exact wrap edge (799,524)->(0,0), independently of this prefetch.
    reg [18:0] vram_read_addr;
    wire end_of_prefetch_frame = (h_cnt == 10'd798) && (v_cnt == 10'd524);
    wire advance_prefetch = (h_cnt == 10'd799) ||
                            ((h_cnt < 10'd639) && (v_cnt < 10'd480));

    always @(posedge pclk_25 or negedge vga_reset_n) begin
        if (!vga_reset_n)
            vram_read_addr <= 19'd0;
        else if (end_of_prefetch_frame)
            vram_read_addr <= 19'd0;
        else if (advance_prefetch)
            vram_read_addr <= vram_read_addr + 19'd1;
    end

    // ------------------------------------------------------------------
    // Pixel-domain ownership and request/acknowledge handshake.
    // ------------------------------------------------------------------
    reg req_meta_p;
    reg req_sync_p;
    reg req_seen_p;
    reg pending_swap_p;
    reg front_bank_p;
    reg ack_toggle_p;
    reg pixel_ready_p;
    reg display_armed_p;

    reg request_toggle_h;
    reg request_swap_h;

    wire frame_wrap_p = (h_cnt == 10'd799) && (v_cnt == 10'd524);

    always @(posedge pclk_25 or negedge vga_reset_n) begin
        if (!vga_reset_n) begin
            req_meta_p       <= 1'b0;
            req_sync_p       <= 1'b0;
            req_seen_p       <= 1'b0;
            pending_swap_p   <= 1'b0;
            front_bank_p     <= 1'b0;
            ack_toggle_p     <= 1'b0;
            pixel_ready_p    <= 1'b0;
            display_armed_p  <= 1'b0;
        end else begin
            req_meta_p    <= request_toggle_h;
            req_sync_p    <= req_meta_p;
            pixel_ready_p <= 1'b1;

            if ((req_sync_p != req_seen_p) && !pending_swap_p) begin
                req_seen_p <= req_sync_p;
                if (request_swap_h)
                    pending_swap_p <= 1'b1;
                else
                    ack_toggle_p <= req_sync_p;
            end

            if (pending_swap_p && frame_wrap_p) begin
                front_bank_p    <= ~front_bank_p;
                display_armed_p <= 1'b1;
                pending_swap_p  <= 1'b0;
                ack_toggle_p    <= req_seen_p;
            end
        end
    end

    // ------------------------------------------------------------------
    // HCLK-domain readiness, event synchronization and operation state.
    // ------------------------------------------------------------------
    reg pll_lock_h1;
    reg pll_lock_h2;
    reg pixel_ready_h1;
    reg pixel_ready_h2;
    reg recovery_saw_low;
    reg domain_ready;
    reg ack_meta_h;
    reg ack_sync_h;
    reg ack_seen_h;
    reg vsync_h1;
    reg vsync_h2;
    reg vsync_h3;

    wire swap_ack_event = ack_sync_h != ack_seen_h;
    wire vsync_event = vsync_h2 && !vsync_h3;

    reg operation_busy;
    reg operation_swap;
    reg operation_clear;
    reg front_bank_h;
    reg clear_target_bank;
    reg clear_start;
    reg operation_done_sticky;
    reg operation_abort_sticky;
    reg vsync_sticky;

    wire [13:0] clear_addr;
    wire clear_we;
    wire clear_busy;
    wire clear_done;
    wire clear_abort = !domain_ready || !vga_pll_locked;
    wire reject_in_progress;

    HW_Cleaner u_cleaner (
        .clk      (HCLK),
        .rst_n    (HRESETn),
        .start    (clear_start),
        .abort    (clear_abort),
        .pause    (reject_in_progress),
        .clr_addr (clear_addr),
        .clr_we   (clear_we),
        .clr_busy (clear_busy),
        .clr_done (clear_done)
    );

    // ------------------------------------------------------------------
    // AHB data-phase ownership and VGA-local two-cycle ERROR response.
    // This slave owns every request in its 128 KiB aperture and rejects all
    // noncanonical address/size/direction combinations locally.
    // ------------------------------------------------------------------
    wire address_phase_valid = HSEL && HTRANS[1];
    wire address_is_fb = HADDR[31:0] >= 32'h2000_0000 &&
                         HADDR[31:0] <= 32'h2000_95ff;
    wire address_is_status = HADDR == 32'h2001_0000;
    wire address_is_control = HADDR == 32'h2001_0004;
    wire address_word = (HSIZE == 3'b010) && (HADDR[1:0] == 2'b00);
    wire address_supported = address_word &&
                             ((address_is_fb && HWRITE) ||
                              address_is_status ||
                              (address_is_control && HWRITE));
    wire address_needs_ready = address_is_fb || address_is_control;
    wire address_rejected = !address_supported ||
                            (address_needs_ready &&
                             (!domain_ready || operation_busy));

    reg data_valid;
    reg data_write;
    reg data_is_fb;
    reg data_is_status;
    reg data_is_control;
    reg data_rejected;
    reg [13:0] data_word_addr;
    reg error_final;

    // Address acceptance does not complete a write.  Revalidate the
    // commit-time conditions in the data phase so loss of the VGA domain
    // cannot turn a normally completed AHB write into a dropped RAM write.
    // A newly busy operation is included because pipelining can accept the
    // next address on the same edge that the preceding command starts it.
    wire data_needs_ready = data_is_fb || data_is_control;
    wire data_commit_blocked = data_valid && !data_rejected && data_write &&
                               data_needs_ready &&
                               (!vga_pll_locked || !domain_ready ||
                                operation_busy);
    wire effective_data_rejected = data_rejected || data_commit_blocked;

    assign reject_in_progress = data_valid && effective_data_rejected;

    assign HRESP = (data_valid && effective_data_rejected) ? 2'b01 : 2'b00;
    assign HREADY = !(data_valid && effective_data_rejected) || error_final;

    // HREADY_IN is the global completion qualifier.  It prevents a held
    // data phase from committing the same physical write more than once.
    wire accepted_data_phase = data_valid && !effective_data_rejected &&
                               HREADY_IN;
    wire accepted_fb_write = accepted_data_phase && data_write && data_is_fb;
    wire accepted_status_write = accepted_data_phase && data_write && data_is_status;
    wire accepted_control_write = accepted_data_phase && data_write && data_is_control;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            data_valid      <= 1'b0;
            data_write      <= 1'b0;
            data_is_fb      <= 1'b0;
            data_is_status  <= 1'b0;
            data_is_control <= 1'b0;
            data_rejected   <= 1'b0;
            data_word_addr  <= 14'd0;
            error_final     <= 1'b0;
        end else begin
            if (data_valid && effective_data_rejected && !error_final) begin
                // Preserve a commit-time rejection for the final ERROR cycle
                // even if raw lock/readiness recovers in the meantime.
                data_rejected <= 1'b1;
                error_final <= 1'b1;
            end else if (HREADY_IN) begin
                data_valid      <= address_phase_valid;
                data_write      <= HWRITE;
                data_is_fb      <= address_is_fb;
                data_is_status  <= address_is_status;
                data_is_control <= address_is_control;
                data_rejected   <= address_rejected;
                data_word_addr  <= HADDR[15:2];
                error_final     <= 1'b0;
            end
        end
    end

    always @(*) begin
        HRDATA = 32'h0000_0000;
        if (data_valid && !data_write && data_is_status) begin
            HRDATA = {27'h0, domain_ready, operation_abort_sticky,
                      operation_busy, operation_done_sticky, vsync_sticky};
        end
    end

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            pll_lock_h1            <= 1'b0;
            pll_lock_h2            <= 1'b0;
            pixel_ready_h1         <= 1'b0;
            pixel_ready_h2         <= 1'b0;
            recovery_saw_low       <= 1'b1;
            domain_ready           <= 1'b0;
            ack_meta_h             <= 1'b0;
            ack_sync_h             <= 1'b0;
            ack_seen_h             <= 1'b0;
            vsync_h1               <= 1'b0;
            vsync_h2               <= 1'b0;
            vsync_h3               <= 1'b0;
            request_toggle_h       <= 1'b0;
            request_swap_h         <= 1'b0;
            operation_busy         <= 1'b0;
            operation_swap         <= 1'b0;
            operation_clear        <= 1'b0;
            front_bank_h           <= 1'b0;
            clear_target_bank      <= 1'b1;
            clear_start            <= 1'b0;
            operation_done_sticky  <= 1'b0;
            operation_abort_sticky <= 1'b0;
            vsync_sticky           <= 1'b0;
        end else begin
            pll_lock_h1    <= vga_pll_locked;
            pll_lock_h2    <= pll_lock_h1;
            pixel_ready_h1 <= pixel_ready_p;
            pixel_ready_h2 <= pixel_ready_h1;
            ack_meta_h     <= ack_toggle_p;
            ack_sync_h     <= ack_meta_h;
            vsync_h1       <= vga_vsync_sig;
            vsync_h2       <= vsync_h1;
            vsync_h3       <= vsync_h2;
            clear_start    <= 1'b0;

            // W1C first; hardware events below dominate a coincident clear.
            if (accepted_status_write) begin
                if (HWDATA[0]) vsync_sticky <= 1'b0;
                if (HWDATA[1]) operation_done_sticky <= 1'b0;
                if (HWDATA[3]) operation_abort_sticky <= 1'b0;
            end
            if (vsync_event)
                vsync_sticky <= 1'b1;

            if (!pll_lock_h2) begin
                domain_ready     <= 1'b0;
                recovery_saw_low <= 1'b1;
                request_toggle_h <= 1'b0;
                request_swap_h   <= 1'b0;
                front_bank_h     <= 1'b0;
                ack_seen_h       <= ack_sync_h;
                if (operation_busy) begin
                    operation_busy         <= 1'b0;
                    operation_abort_sticky <= 1'b1;
                end
            end else if (recovery_saw_low) begin
                if (!pixel_ready_h2) begin
                    recovery_saw_low <= 1'b0;
                end
            end else if (!domain_ready && pixel_ready_h2) begin
                domain_ready     <= 1'b1;
                front_bank_h     <= 1'b0;
                ack_seen_h       <= ack_sync_h;
                request_toggle_h <= 1'b0;
                request_swap_h   <= 1'b0;
            end

            if (accepted_control_write && (HWDATA[1:0] != 2'b00)) begin
                operation_busy  <= 1'b1;
                operation_swap  <= HWDATA[0];
                operation_clear <= HWDATA[1];
                request_swap_h  <= HWDATA[0];

                if (HWDATA[0]) begin
                    request_toggle_h <= ~request_toggle_h;
                end else begin
                    clear_target_bank <= ~front_bank_h;
                    clear_start <= 1'b1;
                end
            end

            if (operation_busy && operation_swap && swap_ack_event) begin
                ack_seen_h   <= ack_sync_h;
                front_bank_h <= ~front_bank_h;
                if (operation_clear) begin
                    clear_target_bank <= front_bank_h;
                    clear_start <= 1'b1;
                    operation_swap <= 1'b0;
                end else begin
                    operation_busy <= 1'b0;
                    operation_swap <= 1'b0;
                    operation_done_sticky <= 1'b1;
                end
            end

            if (operation_busy && operation_clear && clear_done) begin
                operation_busy <= 1'b0;
                operation_clear <= 1'b0;
                operation_done_sticky <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Dual-port RAM routing. Raw PLL lock gates every physical write during
    // asynchronous loss; accepted CPU writes always target the HCLK back bank.
    // ------------------------------------------------------------------
    wire cpu_target_bank = ~front_bank_h;
    wire use_clear = clear_busy;
    wire write_target_bank = use_clear ? clear_target_bank : cpu_target_bank;
    wire [13:0] write_addr = use_clear ? clear_addr : data_word_addr;
    wire [31:0] write_data = use_clear ? 32'h0000_0000 : HWDATA;
    wire physical_write = vga_pll_locked && domain_ready &&
                          (clear_we || accepted_fb_write);
    wire vram0_we = physical_write && (write_target_bank == 1'b0);
    wire vram1_we = physical_write && (write_target_bank == 1'b1);

    wire vram0_q;
    wire vram1_q;

    VRAM u_VRAM0 (
        .data      (write_data),
        .rd_aclr   (~vga_reset_n),
        .rdaddress (vram_read_addr),
        .rdclock   (pclk_25),
        .wraddress (write_addr),
        .wrclock   (HCLK),
        .wren      (vram0_we),
        .q         (vram0_q)
    );

    VRAM u_VRAM1 (
        .data      (write_data),
        .rd_aclr   (~vga_reset_n),
        .rdaddress (vram_read_addr),
        .rdclock   (pclk_25),
        .wraddress (write_addr),
        .wrclock   (HCLK),
        .wren      (vram1_we),
        .q         (vram1_q)
    );

    wire displayed_bit = front_bank_p ? vram1_q : vram0_q;

    always @(*) begin
        VGA_R = 4'h0;
        VGA_G = 4'h0;
        VGA_B = 4'h0;
        if (video_on && display_armed_p && displayed_bit) begin
            VGA_R = 4'hf;
            VGA_G = 4'hf;
            VGA_B = 4'hf;
        end
    end

endmodule
