`timescale 1ns/1ps
// Operation ledger derived from accepted interface transactions. Observation
// adapters below never change the Production DUT or its clocks/state.
module vga_cdc_scoreboard (
    input wire hclk,pclk_25,hresetn,pll_locked,
    input wire [31:0] haddr,hwdata,hrdata,
    input wire hwrite,hsel,hready_in,hready,
    input wire [1:0] htrans,hresp,
    input wire [2:0] hsize,
    input wire dut_vram0_we,dut_vram1_we,
    input wire [13:0] dut_write_addr,
    input wire [31:0] dut_write_data,
    input wire [9:0] pixel_x,pixel_y,
    input wire timing_valid,
    input wire actual_busy,actual_done,
    input wire [3:0] vga_r,vga_g,vga_b,
    output reg all_checks_passed,
    output reg [31:0] total_assertions_checked,physical_writes_observed,clear_writes_observed
);
    bit b2_profile;
    initial b2_profile=$test$plusargs("B2_PROFILE");
    reg addr_valid=0, addr_write=0;
    reg [31:0] addr=0;
    reg [2:0] size=0;
    integer transaction_id=0, op_id=0, epoch=0, completed=0, canceled=0;
    integer swap_completed=0, clear_completed=0, combined_completed=0;
    reg active=0, completed_current=0, frame_seen=0, expected_front=0, clear_target=1;
    reg [1:0] op_type=0;
    integer op_age=0, clear_count=0, next_clear_addr=0;
    reg final_clear=0, done_seen=0, status_busy=0;
    time frame_time=0, request_time=0;
    reg [31:0] bank_word0[0:1];
    // OPEN_SIM RAM initialization is explicitly an environment assumption.
    // Functional markers overwrite word0 in both banks through accepted writes.
    reg scan_pending=0; integer scan_op_id=0, scan_checks=0;
    reg m_bank,m_causality,m_count,m_orphan,m_clear_early,m_swap_dup,m_clear_dup;
    reg m_scan,m_data,m_clear_addr;
    reg count_fault_reached=0, completion_fault_reached=0;
    integer boundary_target=-1, boundary_hits=0;
    reg boundary_armed=0;
    reg [9:0] boundary_address_x,boundary_address_y;
    time boundary_address_time;
    initial begin
        all_checks_passed=1; total_assertions_checked=0;
        physical_writes_observed=0; clear_writes_observed=0;
        bank_word0[0]=0; bank_word0[1]=0;
        m_scan=$test$plusargs("SCANOUT_OBSERVATION_FAULT");
        m_data=$test$plusargs("FB_DATA_OBSERVATION_FAULT");
        m_clear_addr=$test$plusargs("CLEAR_ADDRESS_OBSERVATION_FAULT");
        m_bank=$test$plusargs("MUTANT_LEDGER_BANK");
        m_causality=$test$plusargs("MUTANT_CAUSALITY_INVERSION");
        m_count=$test$plusargs("MUTANT_CLEAR_COUNT");
        m_orphan=$test$plusargs("MUTANT_ORPHAN_ACK");
        m_clear_early=$test$plusargs("PREMATURE_CLEAR_DONE");
        m_swap_dup=$test$plusargs("DUPLICATE_SWAP_DONE");
        m_clear_dup=$test$plusargs("DUPLICATE_CLEAR_DONE");
    end
    task automatic check_assert(input condition,input string msg,input string fail_id);
        begin
            total_assertions_checked=total_assertions_checked+1;
            if (condition !== 1'b1) begin
                all_checks_passed=0;
                $display("[ASSERT_FAIL] id=%s reason=%s time=%0t op_id=%0d type=%0d epoch=%0d",fail_id,msg,$time,op_id,op_type,epoch);
                $fatal(1,"Semantic checker rejection");
            end
        end
    endtask
    // All real/injected completion observations execute this exact predicate.
    // Sticky repeated reads are filtered by the bus observer; duplicates below
    // deliberately replay an event identity, not a legitimate sticky read.
    task automatic completion_observation(input integer observed_id,input bit injected);
        begin
            $display("[DONE_OBSERVATION] id=%0d type=%0d injected=%b active=%b completed=%b frame=%b frame_time=%0t clear_count=%0d final_word=%b time=%0t",
                observed_id,op_type,injected,active,completed_current,frame_seen,frame_time,clear_count,final_clear,$time);
            check_assert(observed_id==op_id && op_id>0,"Completion has accepted operation identity","FAIL_ORPHAN_ACK");
            if (completed_current)
                check_assert(!completed_current,"Duplicate completion for operation",
                    op_type==2 ? "FAIL_CLEAR_DUPLICATE_DONE" : "FAIL_SWAP_DUPLICATE_DONE");
            check_assert(active,"Completion without live same-epoch operation","FAIL_ORPHAN_ACK");
            if (op_type[0])
                check_assert(frame_seen && $time>=frame_time,"SWAP DONE precedes independent frame prerequisite","FAIL_SWAP_PREMATURE_DONE");
            if (op_type[1]) begin
                check_assert(final_clear,"CLEAR DONE precedes physical word9599 zero commit","FAIL_CLEAR_PREMATURE_DONE");
                check_assert(clear_count==9600,"Clear observation count must be exactly9600","FAIL_INCOMPLETE_CLEAR");
            end
            completed_current=1; active=0; completed=completed+1;
            if (op_type==1) swap_completed=swap_completed+1;
            if (op_type==2) clear_completed=clear_completed+1;
            if (op_type==3) combined_completed=combined_completed+1;
            $display("[OP_COMPLETE] id=%0d type=%0d epoch=%0d time=%0t",op_id,op_type,epoch,$time);
        end
    endtask
    task automatic arm_boundary(input integer target_pixel);
        begin
            boundary_target=target_pixel; boundary_armed=1;
            $display("[BOUNDARY_ARM] target=%0d time=%0t",target_pixel,$time);
        end
    endtask
    // Reset/PLL loss cancel the operation identity, not just a total count.
    always @(negedge hresetn or negedge pll_locked) begin
        epoch=epoch+1;
        if (active) begin
            canceled=canceled+1;
            $display("[OP_CANCEL] id=%0d type=%0d epoch=%0d frame_seen=%b time=%0t",op_id,op_type,epoch,frame_seen,$time);
        end
        active=0; completed_current=0; frame_seen=0; expected_front=0;
        scan_pending=0; status_busy=0; final_clear=0;
        if (!hresetn) begin addr_valid=0; done_seen=0; end
    end
    // Pixel prerequisite uses contract frame wrap, independent of DUT counters,
    // ownership or ACK. Four pixel edges is a conservative stimulus eligibility
    // assumption; S02 at798/799 must complete on the following frame instead.
    always @(posedge pclk_25) begin : pixel_observer
        reg [11:0] observed_rgb;
        if (timing_valid && hresetn && pll_locked) begin
            if (active && op_type[0] && !frame_seen) begin
                op_age=op_age+1;
                if (pixel_x==799 && pixel_y==524 && op_age>=4) begin
                    expected_front=~expected_front;
                    frame_seen=1; frame_time=$time;
                    if (op_type[1]) clear_target=~expected_front;
                    scan_pending=1; scan_op_id=op_id;
                    $display("[FRAME_PREREQUISITE] id=%0d type=%0d x=799 y=524 time=%0t expected_front=%b",op_id,op_type,$time,expected_front);
                end
            end
            // External scanout observes the bank's independent AHB-written marker.
            // This proves selection after wrap at pixel8, not hidden ACK timing.
            if (scan_pending && pixel_x==8 && pixel_y==0) begin
                #0.003;
                check_assert(bank_word0[0][8] != bank_word0[1][8],"Scanout banks have contrasting accepted-write markers","FAIL_SCANOUT_VACUOUS_MARKER");
                observed_rgb={vga_r,vga_g,vga_b};
                if (m_scan) begin
                    observed_rgb=observed_rgb^12'hfff;
                    $display("[FAULT_ACTIVATION] SCANOUT_OBSERVATION_FAULT id=%0d actual=%h adapted=%h",scan_op_id,{vga_r,vga_g,vga_b},observed_rgb);
                end
                check_assert(observed_rgb === (bank_word0[expected_front][8] ? 12'hfff : 12'h000),
                    "Post-frame scanout marker matches accepted-bus bank ledger","FAIL_SCANOUT_BANK");
                $display("[SCANOUT_BANK_OBSERVED] id=%0d x=8 y=0 rgb=%h expected_front=%b marker=%h time=%0t",scan_op_id,{vga_r,vga_g,vga_b},expected_front,bank_word0[expected_front],$time);
                scan_pending=0; scan_checks=scan_checks+1;
            end
        end
    end
    always @(posedge hclk) begin : bus_and_physical_observer
        reg physical_write, actual_bank, observed_bank;
        reg fb_ok;
        reg [31:0] status,observed_data;
        reg [13:0] observed_addr;
        if (hresetn) begin
            physical_write=dut_vram0_we || dut_vram1_we;
            actual_bank=dut_vram1_we;
            observed_bank=m_bank ? ~actual_bank : actual_bank;
            fb_ok=addr_valid && addr_write && addr>=32'h20000000 && addr<=32'h200095ff &&
                  hready_in && hready && hresp==0;
            if (physical_write) begin
                observed_data=dut_write_data; observed_addr=dut_write_addr;
                if (m_data && fb_ok) begin
                    observed_data=dut_write_data^32'b1;
                    $display("[FAULT_ACTIVATION] FB_DATA_OBSERVATION_FAULT actual=%h adapted=%h",dut_write_data,observed_data);
                end
                if (m_clear_addr && !fb_ok) begin
                    observed_addr=dut_write_addr^14'b1;
                    $display("[FAULT_ACTIVATION] CLEAR_ADDRESS_OBSERVATION_FAULT actual=%0d adapted=%0d",dut_write_addr,observed_addr);
                end
                check_assert(!(dut_vram0_we && dut_vram1_we),"Only one physical bank written","FAIL_DUAL_BANK_WRITE");
                check_assert(pll_locked,"No physical write while raw lock low","FAIL_WRITE_DURING_LOCK_LOSS");
                physical_writes_observed=physical_writes_observed+1;
                if (m_bank) $display("[FAULT_ACTIVATION] MUTANT_LEDGER_BANK actual=%b adapted=%b addr=%0d",actual_bank,observed_bank,dut_write_addr);
                check_assert(observed_bank != expected_front,"Physical write must target independent back bank","FAIL_FRONT_BANK_CORRUPTED");
                if (fb_ok) begin
                    check_assert(!active && !status_busy,"No framebuffer acceptance while operation busy","FAIL_BUSY_ACCEPTANCE");
                    check_assert(observed_addr==addr[15:2] && observed_data===hwdata,
                        "Accepted framebuffer transaction maps to exact physical address/data","FAIL_FB_LEDGER");
                end else begin
                    check_assert(active && op_type[1],"No orphan physical clear write","FAIL_ORPHAN_WRITE");
                    if (op_type[0]) check_assert(frame_seen && $time>frame_time,"Combined clear follows independent frame prerequisite","FAIL_COMBINED_ORDER");
                    check_assert(actual_bank==clear_target && observed_data===32'b0 && observed_addr==next_clear_addr,
                        "Clear bank/address/data sequence is exact","FAIL_CLEAR_SEQUENCE");
                    next_clear_addr=next_clear_addr+1;
                    if (m_count && !count_fault_reached && dut_write_addr==9500) begin
                        count_fault_reached=1;
                        $display("[FAULT_ACTIVATION] MUTANT_CLEAR_COUNT omit_observation_addr=9500 before_count=%0d",clear_count);
                    end else clear_count=clear_count+1;
                    clear_writes_observed=clear_writes_observed+1;
                    if (dut_write_addr==9599) begin
                        final_clear=1;
                        $display("[FINAL_CLEAR_WRITE] id=%0d type=%0d bank=%b address=9599 count=%0d time=%0t",op_id,op_type,actual_bank,clear_count,$time);
                    end
                end
                if (dut_write_addr==0) bank_word0[actual_bank]=dut_write_data;
            end
            if (fb_ok) check_assert(physical_write,"Accepted framebuffer write has physical commit","FAIL_FB_MISSING_WRITE");
            if (addr_valid && hready_in && hready) begin
                if (hresp==0 && size==2 && addr[1:0]==0) begin
                    if (addr_write && addr==32'h20010004 && hwdata[1:0]!=0) begin
                        check_assert(!active && !status_busy && pll_locked,"Exactly one live operation at command acceptance","FAIL_BUSY_ACCEPTANCE");
                        op_id=op_id+1; op_type=hwdata[1:0]; active=1;
                        completed_current=0; frame_seen=0; op_age=0;
                        clear_count=0; next_clear_addr=0; final_clear=0;
                        clear_target=~expected_front; request_time=$time;
                        completion_fault_reached=0;
                        $display("[OP_ACCEPT] id=%0d transaction=%0d type=%0d epoch=%0d x=%0d y=%0d time=%0t",op_id,transaction_id,op_type,epoch,pixel_x,pixel_y,$time);
                        if (boundary_armed) begin
                            $display("[S02_EFFECT] target=%0d address_x=%0d address_y=%0d address_time=%0t effect_x=%0d effect_y=%0d effect_time=%0t",boundary_target,boundary_address_x,boundary_address_y,boundary_address_time,pixel_x,pixel_y,$time);
                            check_assert(timing_valid && pixel_x==boundary_target && pixel_y==524,"Command final-OKAY effect in independently scheduled pixel window","FAIL_S02_EFFECT_WINDOW");
                            boundary_hits=boundary_hits+1; boundary_armed=0;
                        end
                    end
                    if (!addr_write && addr==32'h20010000) begin
                        status=hrdata;
                        if (!b2_profile && status[1] && !done_seen) begin
                            completion_observation(op_id,0);
                            if (m_swap_dup && op_type==1) begin
                                $display("[FAULT_ACTIVATION] DUPLICATE_SWAP_DONE id=%0d",op_id);
                                completion_observation(op_id,1);
                            end
                            if (m_clear_dup && op_type==2) begin
                                $display("[FAULT_ACTIVATION] DUPLICATE_CLEAR_DONE id=%0d",op_id);
                                completion_observation(op_id,1);
                            end
                        end
                        done_seen=status[1]; status_busy=status[2];
                    end
                    if (addr_write && addr==32'h20010000 && hwdata[1]) done_seen=0;
                end
            end
            // Faults inject actual event inputs while prerequisites are missing.
            if (active && !completion_fault_reached) begin
                if (m_causality && op_type==1 && !frame_seen) begin
                    completion_fault_reached=1;
                    $display("[FAULT_ACTIVATION] MUTANT_CAUSALITY_INVERSION id=%0d before_frame=%b",op_id,frame_seen);
                    completion_observation(op_id,1);
                end
                if (m_clear_early && op_type==2 && !final_clear) begin
                    completion_fault_reached=1;
                    $display("[FAULT_ACTIVATION] PREMATURE_CLEAR_DONE id=%0d final_clear=%b",op_id,final_clear);
                    completion_observation(op_id,1);
                end
                if (m_orphan) begin
                    completion_fault_reached=1;
                    $display("[FAULT_ACTIVATION] MUTANT_ORPHAN_ACK observed_id=%0d accepted_id=%0d",op_id+1,op_id);
                    completion_observation(op_id+1,1);
                end
            end
            // Address acceptance for following data phase. Pre-NBA bus sampling.
            if (hready_in && hready) begin
                addr_valid=hsel && htrans[1]; addr=haddr; addr_write=hwrite; size=hsize;
                if (addr_valid) begin
                    transaction_id=transaction_id+1;
                    if (boundary_armed && haddr==32'h20010004) begin
                        boundary_address_x=pixel_x; boundary_address_y=pixel_y; boundary_address_time=$time;
                        $display("[S02_ADDRESS] transaction=%0d x=%0d y=%0d time=%0t",transaction_id,pixel_x,pixel_y,$time);
                    end
                end
            end
        end
    end
    // B2 uses gap-free validated completion, retaining the legacy polling
    // sensitivity path unchanged in its historical 38 lanes.
    always @(posedge hclk) begin : b2_legacy_completion
        reg pre_busy;
        pre_busy=actual_busy;
        #0.008;
        if (b2_profile && hresetn && pll_locked && pre_busy && !actual_busy && active) begin
            completion_observation(op_id,0);
            status_busy=0;
        end
    end
    task automatic check_final_summary;
        begin
            check_assert(!active && !scan_pending && !boundary_armed,"No unresolved operation/scanout/window at end","FAIL_OUTSTANDING_OPERATION");
            check_assert(op_id==completed+canceled,"Every accepted operation completed or canceled once","FAIL_OPERATION_RECONCILIATION");
            $display("[SCOREBOARD_SUMMARY] accepted=%0d completed=%0d canceled=%0d swap=%0d clear=%0d combined=%0d scanout=%0d boundaries=%0d physical_writes=%0d assertions=%0d",op_id,completed,canceled,swap_completed,clear_completed,combined_completed,scan_checks,boundary_hits,physical_writes_observed,total_assertions_checked);
        end
    endtask
endmodule

// Rev6 B1 actual-event observer. Expected state has only bus/clock/reset/pin
// sources. Internal taps enter measured records, never expected-state updates.
module p12a2_b1_observer (
    input wire hclk,pclk,hresetn,lock_valid,pixel_reset_n,h_epoch_valid,
    input wire [31:0] haddr,hwdata,hrdata,
    input wire hwrite,hsel,hready_in,hready,
    input wire [1:0] htrans,hresp,
    input wire [2:0] hsize,
    input wire [9:0] pixel_x,pixel_y,
    input wire timing_valid,
    input wire actual_request,actual_front_p,actual_ack_p,
    input wire actual_ack_sync,actual_ack_seen,actual_front_h,actual_busy,actual_done,
    input wire vram0_we,vram1_we,
    input wire [13:0] physical_addr,
    input wire [31:0] physical_data,
    input wire actual_clear_target
);
    localparam REQUEST=1,COMMIT=2,ACK_P=3,ACK_SYNC=4,ACK_CONSUME=5,OWNER_H=6,DONE=7;
    integer current_id=0,current_epoch=0,age=0;
    reg live=0,expected_front=0,expected_request=0,operational=0;
    reg address_valid=0,address_write=0;
    reg [31:0] address=0;
    reg [2:0] address_size=0;
    integer op_epoch[0:63],op_type[0:63];
    reg target[0:63],request_value[0:63],cancelled[0:63],predicted_wrap[0:63];
    integer requests[0:63],commits[0:63],publications[0:63],synchronized_acks[0:63];
    integer consumptions[0:63],owners[0:63],diagnostic_done[0:63];
    time expected_wrap_time[0:63];
    integer event_total[1:7];
    integer invalidations=0,rebases=0,clear_ops=0,swap_ops=0,combined_ops=0;
    integer write_checks=0,combined_write_checks=0,busy_window_edges=0;
    integer saved_ack_id=0,saved_ack_epoch=0;
    reg saved_ack_value=0,fault_reached=0;
    string fault;
    string b2_fault;
    bit b2_reached=0,expected_sticky=0,expected_bus_busy=0;
    integer b2_completed=0,b2_first[1:3],b2_clear_count=0,b2_error_wait=0;
    integer b2_w1c=0,b2_collision=0,b2_retention=0,b2_old_sticky=0,b2_zero=0;
    integer b2_window[0:7],b2_cpu_idle=0,b2_target_checks=0,b2_rejections=0;
    integer b2_saved_id=0,b2_saved_epoch=0;
    bit b2_expected_clear=1,b2_error_started=0;
    integer b2_tx=0;
    bit b2_address_blocked=0;
    initial begin : b2_init
        integer k;
        string b3_status_alias;
        b2_fault="";
        if ($value$plusargs("B2_FAULT=%s",b2_fault)) $display("[B2_ADAPTER] %s",b2_fault);
        if($value$plusargs("B3_FAULT=%s",b3_status_alias) && b3_status_alias=="B3_STATUS_PRE_BUSY")
            b2_fault=b3_status_alias;
        for(k=1;k<=3;k=k+1) b2_first[k]=0;
        for(k=0;k<=7;k=k+1) b2_window[k]=0;
    end
    task automatic b2_activate(input string record_name,input integer original_value,input integer adapted_value);
        b2_reached=1;
        $display("[FAULT_ACTIVATION] %s record=%s actual=%0d adapted=%0d id=%0d epoch=%0d time=%0t",b2_fault,record_name,original_value,adapted_value,current_id,current_epoch,$time);
    endtask
    task automatic b2_target_observation(input reg measured);
        require(measured===b2_expected_clear,"FAIL_B2_CLEAR_TARGET","Latched target immutable and equal independently derived back bank");
    endtask
    task automatic b2_completion(input integer id,input integer ep,input bit injected);
        $display("[B2_COMPLETION_RECORD] id=%0d epoch=%0d type=%0d live=%b clear_count=%0d consumed=%0d owner=%0d injected=%b time=%0t",id,ep,op_type[current_id],live,b2_clear_count,consumptions[current_id],owners[current_id],injected,$time);
        require(id==current_id && ep==current_epoch && live && !cancelled[current_id],
                "FAIL_B2_DONE_IDENTITY","Completion belongs to current live accepted operation, never stale/canceled");
        if (op_type[current_id]==1)
            require(consumptions[current_id]==1 && owners[current_id]==1,"FAIL_B2_SWAP_DONE","First SWAP completion after actual validated ACK/owner");
        if (op_type[current_id]==2)
            require(b2_clear_count==9600,"FAIL_B2_CLEAR_DONE","First CLEAR completion after exact physical final zero word");
        if (op_type[current_id]==3)
            require(consumptions[current_id]==1 && owners[current_id]==1 && b2_clear_count==9600,
                    "FAIL_B2_COMBINED_DONE","First combined completion after ACK/owner then final zero word");
    endtask
    initial begin : init
        integer i;
        fault="";
        if ($test$plusargs("B1_REQUEST_WRONG")) fault="B1_REQUEST_WRONG";
        if ($test$plusargs("B1_REQUEST_DUP")) fault="B1_REQUEST_DUP";
        if ($test$plusargs("B1_SYNC_EARLY")) fault="B1_SYNC_EARLY";
        if ($test$plusargs("B1_CONSUME_EARLY")) fault="B1_CONSUME_EARLY";
        if ($test$plusargs("B1_OWNER_WRONG")) fault="B1_OWNER_WRONG";
        if ($test$plusargs("B1_DONE_EARLY")) fault="B1_DONE_EARLY";
        if ($test$plusargs("B1_COMMIT_EARLY")) fault="B1_COMMIT_EARLY";
        if ($test$plusargs("B1_COMMIT_WRONG")) fault="B1_COMMIT_WRONG";
        if ($test$plusargs("B1_COMMIT_DUP")) fault="B1_COMMIT_DUP";
        if ($test$plusargs("B1_ACK_EARLY")) fault="B1_ACK_EARLY";
        if ($test$plusargs("B1_ACK_ORPHAN")) fault="B1_ACK_ORPHAN";
        if ($test$plusargs("B1_ACK_DUP")) fault="B1_ACK_DUP";
        if ($test$plusargs("B1_OWNER_EARLY")) fault="B1_OWNER_EARLY";
        if ($test$plusargs("B1_OWNER_DUP")) fault="B1_OWNER_DUP";
        if ($test$plusargs("B1_STALE_ACK")) fault="B1_STALE_ACK";
        for (i=1;i<=7;i=i+1) event_total[i]=0;
        for (i=0;i<64;i=i+1) begin
            op_epoch[i]=0;op_type[i]=0;target[i]=0;request_value[i]=0;
            cancelled[i]=0;predicted_wrap[i]=0;expected_wrap_time[i]=0;
            requests[i]=0;commits[i]=0;publications[i]=0;synchronized_acks[i]=0;
            consumptions[i]=0;owners[i]=0;diagnostic_done[i]=0;
        end
    end
    task automatic require(input bit condition,input string id,input string reason);
        if (!condition) begin
            $display("[ASSERT_FAIL] id=%s reason=%s time=%0t b1_op=%0d epoch=%0d",id,reason,$time,current_id,current_epoch);
            $fatal(1,"B1 semantic rejection");
        end
    endtask
    // Actual records are associated with the unique accepted outstanding op.
    // Toggle polarity is independently expected from accepted swap publications.
    task automatic measured_event(input integer kind,input integer id,input integer ep,
                                  input reg value,input integer x,input integer y,
                                  input bit synchronized_pre,input bit injected);
        begin
            $display("[B1_EVENT] kind=%0d id=%0d epoch=%0d value=%b x=%0d y=%0d injected=%b time=%0t",kind,id,ep,value,x,y,injected,$time);
            require(ep==current_epoch,"FAIL_B1_STALE_EPOCH","Measured record belongs to current external epoch");
            require(id==current_id && id>0 && live && !cancelled[id],
                    "FAIL_B1_EVENT_IDENTITY","Actual event has one live accepted operation identity");
            if (kind!=DONE) require(op_type[id]&1,"FAIL_B1_CLEAR_SWAP_EVENT","CLEAR-only has no ownership request/ACK");
            case(kind)
                REQUEST: begin
                    require(requests[id]==0,"FAIL_B1_REQUEST_DUPLICATE","Exactly one request publication");
                    require(value===request_value[id],"FAIL_B1_REQUEST_VALUE","Request agrees with accepted-command toggle history");
                    requests[id]=requests[id]+1;
                end
                COMMIT: begin
                    require(commits[id]==0,"FAIL_B1_COMMIT_DUPLICATE","Exactly one pixel ownership commit");
                    // Geometry and causal request identity constrain the actual
                    // edge. Do not impose the legacy stimulus eligibility's
                    // first-wrap deadline or a synchronization latency bound.
                    require(requests[id]==1 && timing_valid && x==799 && y==524,
                            "FAIL_B1_COMMIT_EDGE","Actual commit at independent legal frame wrap after request");
                    require(value===target[id],"FAIL_B1_COMMIT_BANK","Commit bank agrees with independent ownership history");
                    commits[id]=commits[id]+1;
                end
                ACK_P: begin
                    require(publications[id]==0,"FAIL_B1_ACK_DUPLICATE","Exactly one postcommit ACK publication");
                    require(commits[id]==1,"FAIL_B1_ACK_CAUSALITY","Published ACK follows measured validated commit");
                    require(value===request_value[id],"FAIL_B1_ACK_VALUE","ACK belongs to accepted request polarity");
                    publications[id]=publications[id]+1;
                end
                ACK_SYNC: begin
                    require(synchronized_acks[id]==0 && publications[id]==1 && value===request_value[id],
                            "FAIL_B1_ACK_SYNC","Synchronized ACK is unique and follows actual publication");
                    synchronized_acks[id]=synchronized_acks[id]+1;
                end
                ACK_CONSUME: begin
                    require(consumptions[id]==0 && synchronized_acks[id]==1 && synchronized_pre && value===request_value[id],
                            "FAIL_B1_ACK_CONSUMPTION","Unique ACK consumption uses synchronized pre-edge value");
                    consumptions[id]=consumptions[id]+1;
                end
                OWNER_H: begin
                    require(owners[id]==0,"FAIL_B1_OWNER_DUPLICATE","Exactly one HCLK reconstruction");
                    require(consumptions[id]==1 && commits[id]==1,
                            "FAIL_B1_OWNER_CAUSALITY","Owner reconstructed only after actual synchronized ACK consumption");
                    require(value===target[id],"FAIL_B1_OWNER_BANK","HCLK owner agrees with independent expected bank");
                    owners[id]=owners[id]+1;
                end
                DONE: begin
                    if (op_type[id]&1)
                        require(owners[id]==1 && consumptions[id]==1,"FAIL_B1_DONE_LINK","Swap-bearing DONE follows ACK/reconstruction");
                    diagnostic_done[id]=diagnostic_done[id]+1;
                end
            endcase
            event_total[kind]=event_total[kind]+1;
        end
    endtask
    task automatic activation(input integer kind,input integer id,input integer ep,
                              input reg original_value,input reg adapted_value);
        begin
            fault_reached=1;
            $display("[FAULT_ACTIVATION] %s actual_kind=%0d id=%0d epoch=%0d actual_value=%b adapted_value=%b time=%0t",fault,kind,id,ep,original_value,adapted_value,$time);
        end
    endtask
    always @(negedge hresetn or negedge lock_valid) begin : invalidate
        integer old_epoch;
        old_epoch=current_epoch;
        if (live) cancelled[current_id]=1;
        current_epoch=current_epoch+1;invalidations=invalidations+1;
        live=0;expected_front=0;expected_request=0;operational=0;
        if (!hresetn) begin address_valid=0; expected_sticky=0; expected_bus_busy=0; b2_error_started=0; end
        $display("[B1_INVALIDATE] old_epoch=%0d new_epoch=%0d id=%0d cancelled=%b time=%0t",old_epoch,current_epoch,current_id,cancelled[current_id],$time);
        // Replay an archived REAL ACK record with its original measured epoch.
        // This record never feeds the DUT or changes the independent ledger.
        #0.006;
        if (!pixel_reset_n)
            require(actual_front_p===0 && actual_ack_p===0,"FAIL_B1_PIXEL_REBASE","Async pixel reset settles baseline0");
        if (!h_epoch_valid)
            require(actual_request===0 && actual_ack_sync===0,"FAIL_B1_REQUEST_REBASE","Async HCLK epoch settles request/ACK-sync baseline0");
        $display("[B1_ASYNC_BASELINE] epoch=%0d pixel_reset=%b h_epoch=%b request=%b front_p=%b ack_p=%b ack_sync=%b front_h=%b time=%0t",current_epoch,pixel_reset_n,h_epoch_valid,actual_request,actual_front_p,actual_ack_p,actual_ack_sync,actual_front_h,$time);
        if (fault=="B1_STALE_ACK" && saved_ack_id>0 && !fault_reached) begin
            activation(ACK_P,saved_ack_id,saved_ack_epoch,saved_ack_value,saved_ack_value);
            measured_event(ACK_P,saved_ack_id,saved_ack_epoch,saved_ack_value,0,0,0,1);
        end
    end
    always @(posedge pclk) begin : pixel_measurement
        reg pre_front,pre_ack,valid_before;
        integer x,y,ep;
        pre_front=actual_front_p;pre_ack=actual_ack_p;
        valid_before=hresetn && lock_valid && pixel_reset_n;
        x=pixel_x;y=pixel_y;ep=current_epoch;
        // Expected wrap is computed BEFORE looking at post-NBA actual state.
        // Existing test eligibility (4 natural pixel edges) is a tested stimulus
        // assumption, not a frozen maximum synchronization-latency contract.
        if (hresetn && lock_valid && live && (op_type[current_id]&1) && !predicted_wrap[current_id]) begin
            age=age+1;
            if (timing_valid && x==799 && y==524 && age>=4) begin
                predicted_wrap[current_id]=1;expected_wrap_time[current_id]=$time;
                expected_front=~expected_front;
                $display("[B1_EXPECT_WRAP] id=%0d epoch=%0d expected_front=%b x=%0d y=%0d time=%0t",current_id,current_epoch,expected_front,x,y,$time);
            end
        end
        #0.001;
        if (valid_before && hresetn && lock_valid && ep==current_epoch) begin
            if (actual_front_p !== pre_front) begin
                $display("[B1_SAMPLE_PIXEL] pre_front=%b post_front=%b pre_ack=%b post_ack=%b x=%0d y=%0d time=%0t",pre_front,actual_front_p,pre_ack,actual_ack_p,x,y,$time);
                if (fault=="B1_COMMIT_WRONG" && !fault_reached) begin
                    activation(COMMIT,current_id,ep,actual_front_p,~actual_front_p);
                    measured_event(COMMIT,current_id,ep,~actual_front_p,x,y,0,1);
                end else measured_event(COMMIT,current_id,ep,actual_front_p,x,y,0,0);
                if (fault=="B1_COMMIT_DUP" && !fault_reached) begin
                    activation(COMMIT,current_id,ep,actual_front_p,actual_front_p);
                    measured_event(COMMIT,current_id,ep,actual_front_p,x,y,0,1);
                end
            end
            if (actual_ack_p !== pre_ack) begin
                if (fault=="B1_ACK_ORPHAN" && !fault_reached) begin
                    activation(ACK_P,current_id,ep,actual_ack_p,actual_ack_p);
                    measured_event(ACK_P,current_id+1,ep,actual_ack_p,x,y,0,1);
                end else measured_event(ACK_P,current_id,ep,actual_ack_p,x,y,0,0);
                saved_ack_id=current_id;saved_ack_epoch=ep;saved_ack_value=actual_ack_p;
                if (fault=="B1_ACK_DUP" && !fault_reached) begin
                    activation(ACK_P,current_id,ep,actual_ack_p,actual_ack_p);
                    measured_event(ACK_P,current_id,ep,actual_ack_p,x,y,0,1);
                end
            end
        end else if (!pixel_reset_n) begin
            require(actual_front_p===0 && actual_ack_p===0,"FAIL_B1_PIXEL_REBASE","Pixel reset settles ownership/ACK baseline0");
        end
    end
    always @(posedge hclk) begin : hclk_measurement
        reg pre_req,pre_sync,pre_seen,pre_owner,pre_busy,pre_done,valid_before;
        reg physical_write,write_bank,fb_completion;
        reg w1c_done,observed_done,observed_busy,measured_target,measured_bank,status_busy_record;
        reg [1:0] response;
        reg ready_record;
        integer ep,window_kind;
        bit rejected_phase,zero_phase;
        reg pre_clear_target,post_request_record,post_target_record;
        reg [13:0] physical_addr_record;
        reg [31:0] sampled_address;
        bit unselected_w1c;
        bit completion_record;
        w1c_done=0;completion_record=0;rejected_phase=0;zero_phase=0;pre_clear_target=actual_clear_target;unselected_w1c=0;physical_addr_record=physical_addr;sampled_address=address;
        pre_req=actual_request;pre_sync=actual_ack_sync;pre_seen=actual_ack_seen;
        pre_owner=actual_front_h;pre_busy=actual_busy;pre_done=actual_done;
        valid_before=hresetn && lock_valid && h_epoch_valid;ep=current_epoch;
        physical_write=vram0_we || vram1_we;write_bank=vram1_we;
        fb_completion=address_valid && address_write && address>=32'h20000000 && address<=32'h200095ff && hready_in && hready && hresp==0;
        if (hresetn) begin
            // Sample real final/wait data phases BEFORE NBA. ERROR holds the
            // original address identity; no manual test-queue expectation.
            response=hresp;ready_record=hready;
            if (address_valid && (address==32'h20010004 || (address>=32'h20000000 && address<=32'h200095ff)) && address_write) begin
                if (b2_fault=="B2_ACCEPT_FORBIDDEN" && !b2_reached && hresp==1 && hready) begin
                    b2_activate("final_response",hresp,0);response=0;
                end
                if (b2_fault=="B2_ERROR_PROTOCOL" && !b2_reached && hresp==1 && !hready) begin
                    b2_activate("wait_ready",hready,1);ready_record=1;
                end
                if (b2_address_blocked || live || !operational) begin
                    require(response==1,"FAIL_B2_WINDOW_REJECT","Forbidden data phase cannot be accepted OKAY");
                    if (b2_fault=="B2_REJECT_WRITE" && !b2_reached) begin
                        b2_activate("rejected_physical_write",physical_write,1);physical_write=1;
                    end
                    require(!physical_write,"FAIL_B2_REJECT_WRITE","Rejected transfer has zero physical writes (cleaner pauses)");
                    rejected_phase=1;
                end
                if (response==1 && hready_in) begin
                    if (!b2_error_started) begin
                        require(!ready_record,"FAIL_B2_ERROR_PROTOCOL","First ERROR cycle is wait");
                        b2_error_started=1;b2_error_wait=b2_error_wait+1;
                    end else begin
                        require(ready_record,"FAIL_B2_ERROR_PROTOCOL","Second ERROR cycle completes");
                        b2_error_started=0;b2_rejections=b2_rejections+1;
                        window_kind=0;
                        if (live && (op_type[current_id]&1) && commits[current_id]==0) window_kind=1;
                        if (timing_valid && pixel_y==524 && (pixel_x==798 || pixel_x==799)) window_kind=2;
                        if (live && commits[current_id]==1 && consumptions[current_id]==0) window_kind=3;
                        if (live && pre_sync!==pre_seen) window_kind=4;
                        if (live && (op_type[current_id]&2) && owners[current_id]==1 && b2_clear_count==0) window_kind=5;
                        if (live && (op_type[current_id]&2) && b2_clear_count==9599) window_kind=6;
                        b2_window[window_kind]=b2_window[window_kind]+1;
                        $display("[B2_WINDOW] tx=%0d id=%0d epoch=%0d window=%0d x=%0d y=%0d addr=%h pre_busy=%b pre_sync=%b pre_seen=%b clear_count=%0d response=%b ready=%b physical=%b time=%0t",b2_tx,current_id,ep,window_kind,pixel_x,pixel_y,address,pre_busy,pre_sync,pre_seen,b2_clear_count,hresp,hready,physical_write,$time);
                    end
                end
            end
            if (address_valid && hready_in && hready && hresp==0 && address_write && address==32'h20010000 && address_size==2) begin
                w1c_done=hwdata[1];unselected_w1c=!hwdata[1];
                $display("[B2_W1C] tx=%0d id=%0d mask=%h pre_DONE=%b pre_BUSY=%b time=%0t",b2_tx,current_id,hwdata,pre_done,pre_busy,$time);
                if (w1c_done) b2_w1c=b2_w1c+1;
            end
            if (physical_write && !fb_completion) begin
                measured_bank=write_bank;measured_target=actual_clear_target;
                if (b2_fault=="B2_CLEAR_TARGET" && !b2_reached) begin
                    b2_activate("clear_target",measured_target,~measured_target & 1);measured_target=~measured_target;
                end
                if (b2_fault=="B2_PHYSICAL_BANK" && !b2_reached) begin
                    b2_activate("physical_bank",measured_bank,~measured_bank & 1);measured_bank=~measured_bank;
                end
                require(live && (op_type[current_id]&2),"FAIL_B2_ORPHAN_CLEAR","Physical clear has live accepted identity");
                b2_target_observation(measured_target);
                require(measured_bank===b2_expected_clear && measured_bank!=expected_front,"FAIL_B2_CLEAR_BANK","Each physical clear write targets independent back bank");
                if (b2_fault=="B2_CLEAR_SEQUENCE" && !b2_reached) begin
                    b2_activate("physical_clear_address",physical_addr,physical_addr^1);physical_addr_record=physical_addr^1;
                end
                require(physical_addr_record==b2_clear_count && physical_data===0 && b2_clear_count<9600,"FAIL_B2_CLEAR_SEQUENCE","Exact sequential zero commits0..9599, pauses allowed");
                if (op_type[current_id]==3) require(owners[current_id]==1 && consumptions[current_id]==1,"FAIL_B2_CLEAR_ORDER","Combined clear after measured validated ACK/owner");
                b2_clear_count=b2_clear_count+1;b2_target_checks=b2_target_checks+1;
                if (physical_addr==0 || physical_addr>=9597)
                    $display("[B2_CLEAR] id=%0d epoch=%0d bank=%b target=%b addr=%0d count=%0d time=%0t",current_id,ep,write_bank,actual_clear_target,physical_addr,b2_clear_count,$time);
            end
            if (fb_completion) begin
                require(!live,"FAIL_B2_CPU_BUSY","CPU physical write only independently idle");
                require(physical_write && write_bank!=expected_front,"FAIL_B2_CPU_BANK","Accepted CPU write targets independent writable back");
                b2_cpu_idle=b2_cpu_idle+1;
                $display("[B2_IDLE_CPU] id=%0d addr=%h bank=%b time=%0t",current_id,address,write_bank,$time);
            end
            if (address_valid && hready_in && hready && hresp==0 && address_size==2 && address[1:0]==0) begin
                if (address_write && address==32'h20010004 && hwdata[1:0]!=0) begin
                    require(!live,"FAIL_B1_OVERLAP","One independently accepted operation at a time");
                    current_id=current_id+1;
                    require(current_id<64,"FAIL_B1_CAPACITY","Bounded ledger capacity");
                    op_epoch[current_id]=current_epoch;op_type[current_id]=hwdata[1:0];
                    target[current_id]=~expected_front;
                    if (hwdata[0]) expected_request=~expected_request;
                    request_value[current_id]=expected_request;live=1;age=0;
                    b2_clear_count=0;
                    b2_expected_clear=hwdata[0] ? expected_front : ~expected_front;
                    if (expected_sticky) b2_old_sticky=b2_old_sticky+1;
                    if (b2_fault=="B2_STALE_DONE" && !b2_reached && b2_saved_id>0) begin
                        b2_activate("archived_completion_id",b2_saved_id,b2_saved_id);
                        b2_completion(b2_saved_id,b2_saved_epoch,1);
                    end
                    $display("[B1_ACCEPT] id=%0d epoch=%0d type=%0d expected_request=%b expected_target=%b time=%0t",current_id,current_epoch,op_type[current_id],request_value[current_id],target[current_id],$time);
                    if (hwdata[1:0]==1) swap_ops=swap_ops+1;
                    if (hwdata[1:0]==2) clear_ops=clear_ops+1;
                    if (hwdata[1:0]==3) combined_ops=combined_ops+1;
                end
                if (!address_write && address==32'h20010000) begin
                    if($test$plusargs("B3_PROFILE") && !live && actual_busy)
                        $display("[B3_PRE_STATUS_SAMPLE] id=%0d epoch=%0d actual_DONE=%b actual_BUSY=%b actual_ABORT=%b logical_live=%b time=%0t",current_id,ep,hrdata[1],hrdata[2],hrdata[3],live,$time);
                    status_busy_record=hrdata[2];
                    if(b2_fault=="B3_STATUS_PRE_BUSY" && !b2_reached && expected_bus_busy && !live) begin
                        b2_activate("pre_recognition_STATUS_BUSY",hrdata[2],0);status_busy_record=0;
                    end
                    require(hrdata[1]===expected_sticky && status_busy_record===expected_bus_busy,"FAIL_B2_STATUS_LEDGER","Accepted pre-edge STATUS matches independent registered state, separate from post-edge cancellation");
                    if (hrdata[4] && valid_before && pixel_reset_n) operational=1;
                    if (hrdata[1] && live && !actual_busy) begin
                        if (op_type[current_id]&1)
                            require(requests[current_id]==1 && commits[current_id]==1 && publications[current_id]==1 && synchronized_acks[current_id]==1 && consumptions[current_id]==1 && owners[current_id]==1,
                                    "FAIL_B1_COMPLETE_CHAIN","External completion reconciles the entire actual-event chain");
                    end
                end
            end
            if (address_valid && hready_in && hready && hresp==0 && address_write && address==32'h20010004 && hwdata[1:0]==0) begin
                zero_phase=1;b2_zero=b2_zero+1;
                require(!live,"FAIL_B2_ZERO_BUSY","Tested zero-command transfer is independently idle");
            end
            if (hready_in && hready) begin
                b2_address_blocked=hsel && htrans[1] && (live || !operational);
                if (hsel && htrans[1]) b2_tx=b2_tx+1;
                address_valid=hsel && htrans[1];address=haddr;address_write=hwrite;address_size=hsize;
            end
        end
        #0.004; // After pixel1ps and external reference2ps; whole-clock latency is not imposed.
        if (valid_before && hresetn && lock_valid && ep==current_epoch && operational) begin
            post_request_record=actual_request;post_target_record=actual_clear_target;
            if (rejected_phase && b2_fault=="B2_REJECT_REQUEST" && !b2_reached) begin
                b2_activate("rejected_request",actual_request,~actual_request & 1);post_request_record=~actual_request;
            end
            if (rejected_phase && actual_front_h===pre_owner && b2_fault=="B2_REJECT_TARGET" && !b2_reached) begin
                b2_activate("rejected_target",actual_clear_target,~actual_clear_target & 1);post_target_record=~actual_clear_target;
            end
            if (rejected_phase || zero_phase)
                $display("[B2_BUS_EFFECT] tx=%0d id=%0d epoch=%0d address=%h pre_request=%b post_request=%b pre_owner=%b post_owner=%b pre_target=%b post_target=%b physical=%b zero_command=%b time=%0t",b2_tx,current_id,ep,sampled_address,pre_req,actual_request,pre_owner,actual_front_h,pre_clear_target,actual_clear_target,physical_write,zero_phase,$time);
            if (rejected_phase || zero_phase)
                require(post_request_record===pre_req,"FAIL_B2_REJECT_REQUEST","Rejected/zero command causes zero post-NBA publication");
            if (rejected_phase && actual_front_h===pre_owner)
                require(post_target_record===pre_clear_target,"FAIL_B2_REJECT_TARGET","Rejected access cannot alter target (legitimate concurrent ACK reconstruction separately checked)");
            if (actual_request !== pre_req) begin
                if (fault=="B1_REQUEST_WRONG" && !fault_reached) begin
                    activation(REQUEST,current_id,ep,actual_request,~actual_request);
                    measured_event(REQUEST,current_id,ep,~actual_request,0,0,0,1);
                end else measured_event(REQUEST,current_id,ep,actual_request,0,0,0,0);
                if (fault=="B1_REQUEST_DUP" && !fault_reached) begin
                    activation(REQUEST,current_id,ep,actual_request,actual_request);
                    measured_event(REQUEST,current_id,ep,actual_request,0,0,0,1);
                end
                if (!fault_reached && (fault=="B1_COMMIT_EARLY" || fault=="B1_ACK_EARLY" || fault=="B1_OWNER_EARLY" || fault=="B1_SYNC_EARLY" || fault=="B1_CONSUME_EARLY" || fault=="B1_DONE_EARLY")) begin
                    activation(REQUEST,current_id,ep,actual_request,actual_request);
                    if (fault=="B1_COMMIT_EARLY") measured_event(COMMIT,current_id,ep,actual_request,pixel_x,pixel_y,0,1);
                    if (fault=="B1_ACK_EARLY") measured_event(ACK_P,current_id,ep,actual_request,pixel_x,pixel_y,0,1);
                    if (fault=="B1_SYNC_EARLY") measured_event(ACK_SYNC,current_id,ep,actual_request,0,0,0,1);
                    if (fault=="B1_CONSUME_EARLY") measured_event(ACK_CONSUME,current_id,ep,actual_request,0,0,0,1);
                    if (fault=="B1_DONE_EARLY") measured_event(DONE,current_id,ep,actual_request,0,0,0,1);
                    if (fault=="B1_OWNER_EARLY") measured_event(OWNER_H,current_id,ep,actual_request,pixel_x,pixel_y,0,1);
                end
            end
            if (actual_ack_sync !== pre_sync) measured_event(ACK_SYNC,current_id,ep,actual_ack_sync,0,0,0,0);
            if (actual_ack_seen !== pre_seen) measured_event(ACK_CONSUME,current_id,ep,actual_ack_seen,0,0,pre_sync!==pre_seen && pre_sync===actual_ack_seen,0);
            if (actual_front_h !== pre_owner) begin
                $display("[B1_SAMPLE_HCLK] pre_sync=%b pre_seen=%b post_sync=%b post_seen=%b pre_owner=%b post_owner=%b pre_busy=%b post_busy=%b pre_done=%b post_done=%b time=%0t",pre_sync,pre_seen,actual_ack_sync,actual_ack_seen,pre_owner,actual_front_h,pre_busy,actual_busy,pre_done,actual_done,$time);
                if (fault=="B1_OWNER_WRONG" && !fault_reached) begin
                    activation(OWNER_H,current_id,ep,actual_front_h,~actual_front_h);
                    measured_event(OWNER_H,current_id,ep,~actual_front_h,0,0,0,1);
                end else measured_event(OWNER_H,current_id,ep,actual_front_h,0,0,0,0);
                if (fault=="B1_OWNER_DUP" && !fault_reached) begin
                    activation(OWNER_H,current_id,ep,actual_front_h,actual_front_h);
                    measured_event(OWNER_H,current_id,ep,actual_front_h,0,0,0,1);
                end
            end
            if (actual_done && !pre_done) measured_event(DONE,current_id,ep,actual_done,0,0,0,0);
            if (live && (op_type[current_id]&1) && commits[current_id]==1 && consumptions[current_id]==0) begin
                busy_window_edges=busy_window_edges+1;
                require(actual_busy,"FAIL_B1_BUSY_LINK","Actual BUSY protects measured postcommit/preconsume interval");
            end
            if (physical_write) begin
                require(!(vram0_we && vram1_we) && write_bank!=expected_front,"FAIL_B1_PHYSICAL_BANK","Physical write agrees with independently predicted back bank");
                write_checks=write_checks+1;
                if (live && op_type[current_id]==3 && !fb_completion) begin
                    require(owners[current_id]==1 && consumptions[current_id]==1,"FAIL_B1_COMBINED_ACK_ORDER","Physical combined clear starts after actual ACK/owner");
                    combined_write_checks=combined_write_checks+1;
                end
            end
            observed_done=actual_done;observed_busy=actual_busy;
            if (!b2_reached && live && pre_busy && ((b2_fault=="B2_EARLY_SWAP" && op_type[current_id]==1) || (b2_fault=="B2_EARLY_CLEAR" && op_type[current_id]==2) || (b2_fault=="B2_EARLY_COMBINED" && op_type[current_id]==3))) begin
                b2_activate("post_DONE",actual_done,1);observed_done=1;
            end
            if (b2_fault=="B2_BUSY_LOW" && !b2_reached && live && pre_busy && actual_busy) begin
                b2_activate("post_BUSY",actual_busy,0);observed_busy=0;
            end
            if ((observed_done && !pre_done) || (pre_busy && !observed_busy)) begin
                b2_completion(current_id,ep,b2_reached && (observed_done!==actual_done || observed_busy!==actual_busy));
                require(!observed_busy,"FAIL_B2_DONE_BUSY","Validated new completion clears live BUSY on measured edge");
                completion_record=1;
            end
            if (pre_busy && !observed_busy) begin
                b2_first[op_type[current_id]]=b2_first[op_type[current_id]]+1;
                b2_completed=b2_completed+1;b2_saved_id=current_id;b2_saved_epoch=ep;
                $display("[B2_FIRST_DONE] id=%0d epoch=%0d type=%0d pre_done=%b post_done=%b pre_busy=%b post_busy=%b w1c=%b clear_count=%0d consumed=%0d owner=%0d time=%0t",current_id,ep,op_type[current_id],pre_done,actual_done,pre_busy,actual_busy,w1c_done,b2_clear_count,consumptions[current_id],owners[current_id],$time);
                live=0;
            end
            if (b2_fault=="B2_TRANSIENT" && !b2_reached && pre_done && actual_done && b2_completed==1 && !completion_record && !w1c_done) begin
                b2_activate("one_cycle_DONE_next_edge",actual_done,0);observed_done=0;
            end
            if (b2_fault=="B2_STICKY_DROP" && !b2_reached && pre_done && actual_done && !completion_record && unselected_w1c) begin
                b2_activate("retained_DONE",actual_done,0);observed_done=0;
            end
            expected_sticky=(expected_sticky && !w1c_done) || completion_record;
            require(observed_done===expected_sticky,"FAIL_B2_STICKY","DONE retains until selected W1C; validated event set-dominates W1C");
            if (completion_record && w1c_done) begin
                b2_collision=b2_collision+1;
                $display("[B2_COLLISION] id=%0d type=%0d selected_W1C=1 event=1 post_DONE=%b time=%0t",current_id,op_type[current_id],actual_done,$time);
            end
            if (pre_done && !completion_record && !w1c_done) b2_retention=b2_retention+1;
            if (live && (op_type[current_id]==2 || (op_type[current_id]==3 && owners[current_id]==1)))
                b2_target_observation(actual_clear_target); // includes paused ERROR edges
            require(actual_busy===live,"FAIL_B2_BUSY","Live BUSY matches accepted/validated-complete operation independently of sticky DONE");
        end else begin
            expected_sticky=expected_sticky && !w1c_done;
            if (!hresetn) expected_sticky=0;
            if (b2_fault=="B2_CANCELED_DONE" && !b2_reached && current_id>0 && cancelled[current_id] && hresetn) begin
                b2_activate("canceled_DONE",actual_done,1);
                b2_completion(current_id,ep,1);
            end
            if (hresetn && current_epoch>0) require(actual_done===expected_sticky,"FAIL_B2_STICKY","Cancellation cannot produce new DONE or erase legitimate sticky DONE");
            if (actual_front_h !== pre_owner) begin
                require(actual_front_h===0,"FAIL_B1_HCLK_REBASE","Recovery owner change is baseline0, not successful swap");
                rebases=rebases+1;
                $display("[B1_REBASE] epoch=%0d old_owner=%b new_owner=%b h_epoch=%b time=%0t",current_epoch,pre_owner,actual_front_h,h_epoch_valid,$time);
            end
        end
        expected_bus_busy=live;
    end
    task automatic check_final;
        integer i;
        begin
            require(!live,"FAIL_B1_OUTSTANDING","No live operation at final reconciliation");
            for(i=1;i<=current_id;i=i+1) begin
                require(requests[i]==(op_type[i]&1),"FAIL_B1_REQUEST_MISSING","Accepted command request count matches type");
                if (!cancelled[i] && (op_type[i]&1))
                    require(commits[i]==1 && publications[i]==1 && synchronized_acks[i]==1 && consumptions[i]==1 && owners[i]==1,
                            "FAIL_B1_CHAIN_MISSING","Every surviving swap has exactly one measured causal chain");
                if (cancelled[i]) begin
                    // Rev8 permits already committed effects before cancellation.
                    // Each event was checked live, in epoch and causal order.
                    require(diagnostic_done[i]==0 && commits[i]<=1 && publications[i]==commits[i] &&
                            synchronized_acks[i]<=publications[i] && consumptions[i]<=synchronized_acks[i] && owners[i]==consumptions[i],
                            "FAIL_B1_CANCEL_EFFECT","Canceled identity retains only legal pre-invalidation causal prefix, never DONE");
                end
                if (!(op_type[i]&1)) require(commits[i]==0 && publications[i]==0 && synchronized_acks[i]==0 && consumptions[i]==0 && owners[i]==0,
                            "FAIL_B1_CLEAR_SWAP_EVENT","CLEAR-only negative control has no ownership events");
            end
            $display("[B1_SUMMARY] accepted=%0d request=%0d commit=%0d ack_p=%0d ack_sync=%0d consumed=%0d owner=%0d done_diag=%0d clear_ops=%0d combined_ops=%0d invalidations=%0d rebases=%0d physical_checks=%0d combined_writes=%0d busy_window_edges=%0d",current_id,event_total[REQUEST],event_total[COMMIT],event_total[ACK_P],event_total[ACK_SYNC],event_total[ACK_CONSUME],event_total[OWNER_H],event_total[DONE],clear_ops,combined_ops,invalidations,rebases,write_checks,combined_write_checks,busy_window_edges);
            $display("[B1_SUBWINDOW] actual postcommit/preconsume rejection attempts=%0d; zero means NOT_REACHED",b2_window[3]);
            $display("[B2_SUMMARY] completed=%0d swap=%0d clear=%0d combined=%0d w1c=%0d collision=%0d retention=%0d old_sticky=%0d zero=%0d physical_clear=%0d idle_cpu=%0d rejections=%0d error_wait=%0d pending=%0d boundary=%0d postcommit=%0d consumption=%0d clear_start=%0d clear_last=%0d other=%0d",b2_completed,b2_first[1],b2_first[2],b2_first[3],b2_w1c,b2_collision,b2_retention,b2_old_sticky,b2_zero,b2_target_checks,b2_cpu_idle,b2_rejections,b2_error_wait,b2_window[1],b2_window[2],b2_window[3],b2_window[4],b2_window[5],b2_window[6],b2_window[0]);
        end
    endtask
endmodule

// Rev8 recovery observer. External invalidations and its own accepted-bus
// ledger supply expectations. Taps are measured records/prerequisites only.
module p12a2_b3_observer (
 input wire hclk,pclk,hresetn,lock_valid,pixel_reset_n,
 input wire pixel_ready,domain_ready,actual_busy,actual_done,actual_abort,actual_vsync,
 input wire actual_request,actual_front_p,actual_ack_p,actual_front_h,actual_ack_sync,actual_ack_seen,
 input wire vram0_we,vram1_we,
 input wire [31:0] haddr,hwdata,hrdata, input wire hwrite,hsel,hready_in,hready,
 input wire [1:0] htrans,hresp, input wire [2:0] hsize,
 input wire [9:0] pixel_x,pixel_y,input wire timing_valid,
 input wire [31:0] validated_consume,validated_owner,validated_clear
);
 bit enabled,live=0,expected_done=0,expected_abort=0,quiet=0,fresh=0,abort_pending=0;
 bit addr_valid=0,addr_write=0,reset_seen=0,destination_ready=0,adapter_reached=0;
 reg [31:0] addr=0; reg [2:0] size=0;
 integer epoch=0,op=0,typ=0,op_epoch=0,invalidations=0,active_losses=0,idle_losses=0,full_resets=0;
 integer ready_events=0,dest_ready_events=0,invalid_samples=0,quiet_wraps=0,quiet_pixels=0;
 integer rejected_fb=0,rejected_control=0,error_wait=0,fresh_accept[1:3],fresh_done[1:3];
 integer dest_edges=0,archive_epoch=0,archive_op=0,release_events=0,release_epoch=-1;
 realtime last_destination_edge=0;
 bit error_started=0;
 string fault;
 initial begin : init
  integer k;
  enabled=$test$plusargs("B3_PROFILE");fault="";
  if ($value$plusargs("B3_FAULT=%s",fault)) $display("[B3_ADAPTER] %s",fault);
  for(k=1;k<=3;k=k+1) begin fresh_accept[k]=0;fresh_done[k]=0;end
 end
 task automatic require(input bit condition,input string id,input string reason);
  if (!condition) begin
   $display("[ASSERT_FAIL] id=%s reason=%s time=%0t b3_op=%0d epoch=%0d",id,reason,$time,op,epoch);
   $fatal(1,"B3 semantic rejection");
  end
 endtask
 task automatic activate(input string record_name,input integer original,input integer adapted);
  adapter_reached=1;
  $display("[FAULT_ACTIVATION] %s record=%s actual=%0d adapted=%0d id=%0d epoch=%0d time=%0t",fault,record_name,original,adapted,op,epoch,$time);
 endtask
 // Same predicate for genuine transactional/ready records and stale replay.
 task automatic current_record(input string kind,input integer record_epoch,input integer record_op);
  $display("[B3_RECORD] kind=%s id=%0d epoch=%0d current_epoch=%0d time=%0t",kind,record_op,record_epoch,epoch,$time);
  require(record_epoch==epoch,{"FAIL_B3_STALE_",kind},"Observed event belongs to current external epoch");
  if (kind!="READY") require(live && record_op==op && op_epoch==epoch,{"FAIL_B3_STALE_",kind},"No orphan, quiet or canceled event");
 endtask
 task automatic physical_record(input bit measured);
  require(!measured,"FAIL_B3_INVALID_WRITE","No physical RAM write while reset/raw lock/current ready invalid; monitor never reset-gated");
 endtask
 task automatic release_record(input bit measured);
  if(measured) begin
   require(hresetn && lock_valid && reset_seen && dest_edges>=2 && release_epoch!=epoch &&
      ($realtime-last_destination_edge)<=0.002,"FAIL_B3_DEST_RELEASE",
      "Current destination reset releases once, at destination edge after two-stage synchronous release; held clock cannot release it");
   release_epoch=epoch;release_events=release_events+1;
   $display("[B3_DEST_RELEASE] epoch=%0d edges=%0d reset_n=%b time=%0t",epoch,dest_edges,measured,$time);
  end
 endtask
 always @(posedge pixel_reset_n) if(enabled && epoch>0) begin
  #0.001;release_record(pixel_reset_n);
 end
 task automatic ready_record(input bit measured);
  if (measured) require(hresetn && lock_valid && reset_seen && destination_ready && dest_edges>0,
   "FAIL_B3_READY","Ready requires validated current destination reset/release/ready event");
 endtask
 task automatic quiet_begin;
  require(!live && hresetn && lock_valid && destination_ready,"FAIL_B3_QUIET_START","Recovered idle epoch before quiet frames");
  quiet=1;quiet_wraps=0;quiet_pixels=0;
  $display("[B3_QUIET_BEGIN] epoch=%0d id=%0d time=%0t",epoch,op,$time);
 endtask
 task automatic quiet_end;
  require(quiet_wraps>=2 && quiet_pixels>=420000,"FAIL_B3_QUIET_FRAMES","Actual full natural frame between two wraps");
  quiet=0;
  $display("[B3_QUIET_END] epoch=%0d wraps=%0d full_pixels=%0d time=%0t",epoch,quiet_wraps,quiet_pixels,$time);
 endtask
 task automatic fresh_begin;
  fresh=1;$display("[B3_FRESH_BEGIN] epoch=%0d time=%0t",epoch,$time);
 endtask
 task automatic fresh_record(input bit present,input integer record_type);
  require(present,"FAIL_B3_FRESH_PROGRESS","Actual validated fresh completion record must be present at progress checkpoint");
  fresh_done[record_type]=fresh_done[record_type]+1;
 endtask
 always @(negedge hresetn or negedge lock_valid) if(enabled) begin : invalidate
  bit was_live;
  was_live=live;archive_epoch=epoch;archive_op=op;
  epoch=epoch+1;invalidations=invalidations+1;live=0;dest_edges=0;reset_seen=0;destination_ready=0;
  if (!hresetn) begin
   full_resets=full_resets+1;expected_done=0;expected_abort=0;abort_pending=0;addr_valid=0;error_started=0;
  end else begin
   if (was_live) begin abort_pending=1;active_losses=active_losses+1;end
   else idle_losses=idle_losses+1;
  end
  $display("[B3_INVALIDATE] old_epoch=%0d new_epoch=%0d id=%0d was_live=%b full_reset=%b expected_DONE=%b expected_ABORT=%b time=%0t",archive_epoch,epoch,op,was_live,!hresetn,expected_done,expected_abort,$time);
  #0.006;
  require(pixel_reset_n===0 && pixel_ready===0,"FAIL_B3_DEST_RESET","Destination invalidation really clears reset/ready state");reset_seen=1;
  begin : immediate_gate
   bit measured;
   measured=vram0_we || vram1_we;
   if (fault=="B3_INVALID_WRITE" && op>0 && !adapter_reached) begin activate("async_invalid_write",measured,1);measured=1;end
   physical_record(measured);
   $display("[B3_ASYNC_GATE] epoch=%0d reset=%b lock=%b physical=%b time=%0t",epoch,hresetn,lock_valid,measured,$time);
  end
  if (!hresetn) begin : full_status
   reg [4:0] measured;
   measured={domain_ready,actual_abort,actual_busy,actual_done,actual_vsync};
   if (fault=="B3_RESET_STATUS" && op>0 && !adapter_reached) begin activate("reset_status",measured,11);measured=11;end
   require(measured===0,"FAIL_B3_RESET_STATUS","Full reset clears all five live/sticky status bits");
   $display("[B3_RESET_STATUS] epoch=%0d status=%b time=%0t",epoch,measured,$time);
  end
 end
 always @(posedge pclk) if(enabled) begin : pixel
  bit pre_ready,pre_front,pre_ack,observed_pixel_ready;integer ep,x,y;
  last_destination_edge=$realtime;
  pre_ready=pixel_ready;pre_front=actual_front_p;pre_ack=actual_ack_p;ep=epoch;x=pixel_x;y=pixel_y;
  if (hresetn && lock_valid) dest_edges=dest_edges+1;
  if (quiet && timing_valid && hresetn && lock_valid) begin
   if (quiet_wraps>0) quiet_pixels=quiet_pixels+1;
   if(x==799 && y==524) begin quiet_wraps=quiet_wraps+1;$display("[B3_QUIET_WRAP] epoch=%0d wrap=%0d x=%0d y=%0d full_pixels=%0d time=%0t",epoch,quiet_wraps,x,y,quiet_pixels,$time);end
  end
  #0.003;
  if(ep==epoch && hresetn && lock_valid) begin
   observed_pixel_ready=pixel_ready;
   if(fault=="B3_DEST_EARLY_READY" && op>0 && !adapter_reached && dest_edges<3 && !pixel_ready) begin
    activate("pre_release_pixel_ready",pixel_ready,1);observed_pixel_ready=1;
   end
   if (observed_pixel_ready && !pre_ready) begin
    require(reset_seen && pixel_reset_n && dest_edges>=3,"FAIL_B3_DEST_READY","Measured pixel-ready after current external reset/release and destination clock progress");
    destination_ready=1;dest_ready_events=dest_ready_events+1;
    $display("[B3_DEST_READY] epoch=%0d edges=%0d pixel_reset=%b time=%0t",epoch,dest_edges,pixel_reset_n,$time);
   end
   if (actual_front_p!==pre_front) current_record("COMMIT",epoch,op);
   if (actual_ack_p!==pre_ack) current_record("ACK",epoch,op);
   if (quiet) require(actual_front_p===0 && actual_ack_p===0,"FAIL_B3_QUIET_PIXEL","No CONTROL means no stale transactional front/ACK across full natural quiet frames");
  end
 end
 always @(posedge hclk) if(enabled) begin : host
  bit pre_busy,pre_ready,pre_req,pre_done,pre_abort,measured_ready,measured_abort,measured_write,post_busy_record;
  bit w1c_done,w1c_abort,completion,ready_owner_record,abort_event;
  integer ep;
  pre_busy=actual_busy;pre_ready=domain_ready;pre_req=actual_request;pre_done=actual_done;pre_abort=actual_abort;
  ep=epoch;w1c_done=0;w1c_abort=0;completion=0;
  measured_write=vram0_we || vram1_we;
  if (epoch>0 && (!hresetn || !lock_valid || !domain_ready)) begin physical_record(measured_write);invalid_samples=invalid_samples+1;end
  if (hresetn && addr_valid && hready_in && hready) begin
   if (addr_write && (addr==32'h20010004 || (addr>=32'h20000000 && addr<=32'h200095ff)) && !domain_ready) begin
    require(hresp===1 && !measured_write,"FAIL_B3_NOT_READY_REJECT","Unready legal FB/CONTROL ends ERROR with zero write");
    if(addr==32'h20010004) rejected_control=rejected_control+1;else rejected_fb=rejected_fb+1;
    $display("[B3_UNREADY_ERROR] epoch=%0d addr=%h response=%b ready=%b physical=%b time=%0t",epoch,addr,hresp,hready,measured_write,$time);
   end
   if(hresp==0 && size==2 && addr[1:0]==0) begin
    if(addr_write && addr==32'h20010000) begin w1c_done=hwdata[1];w1c_abort=hwdata[3];end
    if(addr_write && addr==32'h20010004 && hwdata[1:0]!=0) begin
     require(!live && !quiet,"FAIL_B3_ACCEPT","Unique accepted operation, no CONTROL during quiet epoch");
     op=op+1;typ=hwdata[1:0];op_epoch=epoch;live=1;
     if(fresh) fresh_accept[typ]=fresh_accept[typ]+1;
     $display("[B3_ACCEPT] id=%0d epoch=%0d type=%0d fresh=%b time=%0t",op,epoch,typ,fresh,$time);
    end
    if(!addr_write && addr==32'h20010000)
     require(hrdata[1]===expected_done && hrdata[3]===expected_abort,"FAIL_B3_STATUS","Accepted STATUS DONE/ABORT matches external epoch/accepted operation ledger");
   end
  end
  if(hresetn && addr_valid && hready_in && hresp==1) begin
   if(!error_started) begin require(!hready,"FAIL_B3_ERROR_PROTOCOL","ERROR wait first");error_started=1;error_wait=error_wait+1;end
   else begin require(hready,"FAIL_B3_ERROR_PROTOCOL","ERROR final second");error_started=0;end
  end
  if(hresetn && hready_in && hready) begin addr_valid=hsel && htrans[1];addr=haddr;addr_write=hwrite;size=hsize;end
  #0.012; // B1 validation +4ps and legacy +8ps already completed.
  if(epoch==ep && epoch>0) begin
   measured_ready=domain_ready;measured_abort=actual_abort;
   if (fault=="B3_PREMATURE_READY" && op>0 && !adapter_reached && hresetn && lock_valid && !destination_ready) begin activate("unready",domain_ready,1);measured_ready=1;end
   if(fault=="B3_DEST_EARLY_RELEASE" && op>0 && !adapter_reached && hresetn && lock_valid && dest_edges<2 && !pixel_reset_n) begin
    activate("pre_synchronous_release",pixel_reset_n,1);release_record(1);
   end
   ready_record(measured_ready);
   if(domain_ready && !pre_ready) begin
    ready_owner_record=actual_front_h;
    if(fault=="B3_READY_BASELINE" && op>0 && !adapter_reached) begin activate("recovered_owner",actual_front_h,1);ready_owner_record=1;end
    require(actual_request===0 && actual_front_p===0 && actual_ack_p===0 && ready_owner_record===0 && actual_ack_sync===0 && actual_ack_seen===0,
      "FAIL_B3_READY_BASELINE","Recovery readiness follows baseline0 request/ACK/pixel/HCLK ownership rebase");
    ready_events=ready_events+1;current_record("READY",epoch,op);$display("[B3_READY] epoch=%0d destination_ready=%b time=%0t",epoch,destination_ready,$time);end
   if (hresetn && lock_valid && actual_request!==pre_req) current_record("REQUEST",epoch,op);
   if (hresetn && lock_valid && pre_busy && !actual_busy && live) begin
    current_record("DONE",epoch,op);
    require(!(typ&1) || (validated_consume==1 && validated_owner==1),"FAIL_B3_COMPLETION","Fresh/old actual completion requires checked causal ACK/owner");
    require(!(typ&2) || validated_clear==9600,"FAIL_B3_COMPLETION","Fresh/old actual completion requires physical final clear word");
    completion=1;
    if(fresh) begin : progress
     bit present;
     present=1;
     if(fault=="B3_FRESH_PROGRESS" && !adapter_reached) begin activate("validated_fresh_completion_present",1,0);present=0;end
     fresh_record(present,typ);
    end
    live=0;
    $display("[B3_COMPLETION] id=%0d epoch=%0d type=%0d fresh=%b clear=%0d consumed=%0d owner=%0d time=%0t",op,epoch,typ,fresh,validated_clear,validated_consume,validated_owner,$time);
   end
   expected_done=(expected_done && !w1c_done) || completion;
   if(w1c_abort) $display("[B3_ABORT_W1C_MEASURED] epoch=%0d id=%0d pre_abort=%b post_abort=%b pre_busy=%b post_busy=%b time=%0t",epoch,op,pre_abort,actual_abort,pre_busy,actual_busy,$time);
   // External accepted-operation cancellation creates an expected hardware
   // abort event at recognition. W1C runs first; this event is set-dominant.
   abort_event=abort_pending;abort_pending=0;
   expected_abort=(expected_abort && !w1c_abort) || abort_event;
   if(!hresetn) begin expected_done=0;expected_abort=0;end
   if(fault=="B3_ABORT_DROP" && !adapter_reached && hresetn && expected_abort && actual_abort) begin activate("active_abort",actual_abort,0);measured_abort=0;end
   if(fault=="B3_ABORT_IDLE" && !adapter_reached && idle_losses>0 && hresetn && !expected_abort) begin activate("idle_abort",actual_abort,1);measured_abort=1;end
   if(fault=="B3_ABORT_COLLISION_DROP" && !adapter_reached && abort_event && w1c_abort) begin
    activate("abort_W1C_collision",actual_abort,0);measured_abort=0;
   end
   if(abort_event && w1c_abort)
    $display("[B3_ABORT_COLLISION] epoch=%0d id=%0d event=1 selected_W1C=1 actual_ABORT=%b observed_ABORT=%b expected_ABORT=%b time=%0t",epoch,op,actual_abort,measured_abort,expected_abort,$time);
   require(measured_abort===expected_abort,"FAIL_B3_ABORT","Active PLL loss sets retained ABORT, idle loss cannot invent it; full reset clears");
   post_busy_record=actual_busy;
   if(fault=="B3_CANCEL_BUSY" && !adapter_reached && abort_event && !live) begin
    activate("post_recognition_BUSY",actual_busy,1);post_busy_record=1;
   end
   require(post_busy_record===live,"FAIL_B3_BUSY","Post-edge live BUSY follows independently accepted/completed/canceled operation state");
   require(actual_done===expected_done,"FAIL_B3_DONE","Canceled operation produces no new DONE; legitimate old DONE follows reset vs PLL rules");
   if(!hresetn) require({domain_ready,actual_abort,actual_busy,actual_done,actual_vsync}===0,"FAIL_B3_RESET_STATUS","Full reset status zero at every HCLK");
   if(quiet) begin
    require(!live && actual_request===0 && actual_front_h===0 && actual_ack_sync===0 && actual_ack_seen===0 && !actual_busy,"FAIL_B3_QUIET_HOST","Quiet current epoch has no old toggle/ACK/owner transaction");
    if(!adapter_reached && fault=="B3_STALE_READY") begin activate("archived_ready_epoch",archive_epoch,archive_epoch);current_record("READY",archive_epoch,archive_op);end
   end
  end
 end
 task automatic replay_old(input string kind,input integer old_epoch,input integer old_op);
  if(enabled && !adapter_reached && fault=={"B3_STALE_",kind}) begin activate({"archived_",kind},old_epoch,old_epoch);current_record(kind,old_epoch,old_op);end
 endtask
 task automatic check_final;
  integer k;
  if(enabled) begin
   require(!live && !quiet,"FAIL_B3_FINAL","No unresolved operation or quiet interval");
   for(k=1;k<=3;k=k+1) require(fresh_accept[k]==1 && fresh_done[k]==1,"FAIL_B3_FRESH_PROGRESS","Fresh SWAP,CLEAR,combined each accepted and actually completed once");
   require(rejected_fb>0 && rejected_control>0 && error_wait>=2 && invalid_samples>0,"FAIL_B3_COVERAGE","Actual unready ERROR and ungated invalid-period monitor reached");
   $display("[B3_SUMMARY] invalidations=%0d full_reset=%0d active_loss=%0d idle_loss=%0d dest_ready=%0d ready=%0d release=%0d invalid_samples=%0d quiet_wraps=%0d quiet_pixels=%0d reject_fb=%0d reject_control=%0d error_wait=%0d fresh_swap=%0d fresh_clear=%0d fresh_combined=%0d",invalidations,full_resets,active_losses,idle_losses,dest_ready_events,ready_events,release_events,invalid_samples,quiet_wraps,quiet_pixels,rejected_fb,rejected_control,error_wait,fresh_done[1],fresh_done[2],fresh_done[3]);
  end
 endtask
endmodule


// Rev9 B4: expected state from external reset/VS pins, accepted AHB,
// independent geometry and physical word commits. No internal bank/ready tap
// supplies a golden value. VS sampling topology is frozen reset spec13.1.
module p12a2_b4_observer (
 input wire hclk,pclk,hresetn,lock_valid,vga_vs,
 input wire [3:0] vga_r,vga_g,vga_b,
 input wire [9:0] pixel_x,pixel_y,input wire timing_valid,
 input wire [31:0] haddr,hwdata,hrdata,input wire hwrite,hsel,hready_in,hready,
 input wire [1:0] htrans,hresp,input wire [2:0] hsize,
 input wire actual_vsync,actual_busy,actual_ack_sync,actual_ack_seen,
 input wire vram0_we,vram1_we,input wire [13:0] physical_addr,
 input wire [31:0] physical_data,validated_consume,validated_owner
);
 bit enabled,addr_valid=0,addr_write=0,live=0,swap_pending=0,armed=0,front=0;
 bit q1=0,q2=0,q3=0,expected_vsync=0,reached=0,quiet=0;
 reg [31:0] addr=0;reg [2:0] size=0;
 integer epoch=0,op=0,typ=0,age=0,clear_count=0;
 integer black_checks=0,quiet_wraps=0,quiet_pixels=0,white_markers=0;
 integer vs_events=0,vs_collisions=0,vs_selected=0,vs_unselected=0,status_reads=0;
 integer consume_errors=0,idle_first=0;time completion_time=0;bit awaiting_first=0;
 string fault;
 initial begin enabled=$test$plusargs("B4_PROFILE");fault="";if($value$plusargs("B4_FAULT=%s",fault))begin end end
 task automatic require(input bit ok,input string id,input string why);
  if(!ok)begin $display("[ASSERT_FAIL] id=%s reason=%s time=%0t b4_op=%0d epoch=%0d",id,why,$time,op,epoch);$fatal(1,"B4 semantic rejection");end
 endtask
 task automatic activate(input string name,input integer real_value,input integer adapted);
  reached=1;$display("[FAULT_ACTIVATION] %s record=%s actual=%0d adapted=%0d id=%0d epoch=%0d time=%0t",fault,name,real_value,adapted,op,epoch,$time);
 endtask
 always @(negedge hresetn or negedge lock_valid) if(enabled)begin
  epoch=epoch+1;live=0;swap_pending=0;armed=0;front=0;clear_count=0;awaiting_first=0;
  if(!hresetn)begin addr_valid=0;q1=0;q2=0;q3=0;expected_vsync=0;end
  $display("[B4_DISARM] epoch=%0d external_reset=%b external_lock=%b time=%0t",epoch,hresetn,lock_valid,$time);
 end
 always @(posedge vga_vs or negedge vga_vs)if(enabled)
  $display("[B4_EXTERNAL_VS_EDGE] epoch=%0d level=%b reset=%b lock=%b time=%0t",epoch,vga_vs,hresetn,lock_valid,$time);
 task automatic quiet_begin;
  require(!live&&!armed,"FAIL_B4_QUIET","Recovered epoch is independently disarmed and idle");quiet=1;quiet_wraps=0;quiet_pixels=0;
  $display("[B4_QUIET_BEGIN] epoch=%0d time=%0t",epoch,$time);
 endtask
 task automatic quiet_end;
  require(quiet_wraps>=2&&quiet_pixels==420000,"FAIL_B4_QUIET","Full natural recovered frame black without swap");quiet=0;
  $display("[B4_QUIET_END] epoch=%0d wraps=%0d pixels=%0d time=%0t",epoch,quiet_wraps,quiet_pixels,$time);
 endtask
 always @(posedge pclk)if(enabled)begin : pixel
  bit was_unarmed;reg [11:0] rgb;integer x,y;
  x=pixel_x;y=pixel_y;
  if(hresetn&&lock_valid&&timing_valid)begin
   if(swap_pending)begin age=age+1;if(x==799&&y==524&&age>=4)begin front=~front;armed=1;swap_pending=0;$display("[B4_EXPECT_ARM] id=%0d epoch=%0d front=%b time=%0t",op,epoch,front,$time);end end
   if(quiet)begin if(quiet_wraps>0)quiet_pixels=quiet_pixels+1;if(x==799&&y==524)begin quiet_wraps=quiet_wraps+1;$display("[B4_QUIET_WRAP] epoch=%0d wrap=%0d pixels=%0d time=%0t",epoch,quiet_wraps,quiet_pixels,$time);end end
  end
  was_unarmed=!armed;
  #0.004;rgb={vga_r,vga_g,vga_b};
  if(was_unarmed)begin
   if(!reached&&epoch>=2&&timing_valid&&x==16&&y==0&&((fault=="B4_BLACK_LEAK"&&quiet)||(fault=="B4_EARLY_ARM"&&swap_pending)))begin activate("unarmed_RGB",rgb,4095);rgb=12'hfff;end
   require(rgb===0,"FAIL_B4_BLACK","External invalidation disarms display until independently accepted same-epoch swap commits");black_checks=black_checks+1;
   if(timing_valid&&x==16&&y==0)$display("[B4_BLACK_MARKER] epoch=%0d pending=%b rgb=%h quiet=%b time=%0t",epoch,swap_pending,rgb,quiet,$time);
  end else if(timing_valid&&x==16&&y==0&&rgb==12'hfff)begin
   if(fault=="B4_WHITE_DROP"&&!reached&&epoch>=2)begin activate("fresh_white_marker",rgb,0);rgb=0;end
   if(rgb==12'hfff)begin white_markers=white_markers+1;$display("[B4_WHITE_MARKER] epoch=%0d id=%0d x=%0d y=%0d rgb=%h time=%0t",epoch,op,x,y,rgb,$time);end
  end
 end
 always @(posedge hclk)if(enabled)begin : host
  bit event_expected,w1c,measured,consume_error,write_measured,bank_measured;reg [1:0] resp;integer ep;
  ep=epoch;event_expected=q2&&!q3;w1c=0;consume_error=0;
  if(hresetn)begin
   // Pre-edge STATUS value belongs to independent previous registered flag.
   if(addr_valid&&hready_in&&hready&&hresp==0&&size==2&&addr==32'h20010000)begin
    if(addr_write)begin w1c=hwdata[0];if(w1c)vs_selected=vs_selected+1;else vs_unselected=vs_unselected+1;end
    else begin
     measured=hrdata[0];if(fault=="B4_STATUS_VSYNC"&&!reached&&expected_vsync)begin activate("STATUS_VSYNC",measured,!measured);measured=!measured;end
     require(measured===expected_vsync,"FAIL_B4_STATUS","Accepted STATUS VSYNC equals independent external-pin event/W1C history");status_reads=status_reads+1;
    end
   end
   if(live&&(typ&2)&&clear_count==9600)begin live=0;completion_time=$time;awaiting_first=1;$display("[B4_EXPECT_COMPLETE] id=%0d type=%0d time=%0t",op,typ,$time);end
   if(addr_valid&&addr_write&&hready_in&&addr!=32'h20010000)begin
    if(hresp==1&&hready&&typ==3&&live&&actual_ack_sync!==actual_ack_seen)begin
     resp=hresp;write_measured=vram0_we||vram1_we;
     if(fault=="B4_REJECT_ACCEPT"&&!reached)begin activate("combined_consume_final_response",hresp,0);resp=0;end
     require(resp==1&&!write_measured,"FAIL_B4_REJECT","Live combined FB/CONTROL ERROR at consumption has zero physical write");consume_error=1;
     $display("[B4_CONSUME_ERROR] id=%0d epoch=%0d addr=%h response=%b physical=%b time=%0t",op,epoch,addr,hresp,write_measured,$time);
    end
    if(hready&&hresp==0&&size==2&&addr[1:0]==0)begin
     if(addr==32'h20010004&&hwdata[1:0]!=0)begin require(!live&&!quiet,"FAIL_B4_ACCEPT","One outstanding command; no CONTROL during quiet frame");op=op+1;typ=hwdata[1:0];live=1;clear_count=0;if(typ&1)begin swap_pending=1;age=0;end end
     if(addr>=32'h20000000&&addr<=32'h200095ff)begin
      require(!live,"FAIL_B4_ACCEPT","Accepted FB only when independently idle");bank_measured=vram1_we;
      if(fault=="B4_IDLE_BANK"&&!reached&&idle_first>0)begin activate("first_idle_physical_bank",bank_measured,!bank_measured);bank_measured=!bank_measured;end
      require((vram0_we||vram1_we)&&bank_measured==!front,"FAIL_B4_IDLE_BANK","Accepted FB commits once to independently derived back bank");
      if(idle_first>0)$display("[B4_IDLE_COMMIT] id=%0d bank=%b expected_back=%b addr=%h data=%h time=%0t",op,vram1_we,!front,addr,hwdata,$time);
     end
    end
   end
   // Count actual sequential physical clear words, independently of DUT DONE.
   if((vram0_we||vram1_we)&&!(addr_valid&&addr_write&&hready_in&&hready&&hresp==0&&addr>=32'h20000000&&addr<=32'h200095ff))begin
    require(live&&(typ&2)&&physical_addr==clear_count&&physical_data==0,"FAIL_B4_CLEAR","Accepted typed clear exact physical prefix");clear_count=clear_count+1;
   end
   if(awaiting_first&&hready_in&&hready&&hsel&&htrans[1]&&hwrite&&haddr>=32'h20000000&&haddr<=32'h200095ff)begin
    require($time==completion_time+20,"FAIL_B4_FIRST_IDLE","First idle address edge immediately after combined completion at HCLK20ns");awaiting_first=0;idle_first=idle_first+1;
    $display("[B4_FIRST_IDLE_ADDRESS] id=%0d completion_time=%0t address_time=%0t addr=%h time=%0t",op,completion_time,$time,haddr,$time);
   end
   if(hready_in&&hready)begin addr_valid=hsel&&htrans[1];addr_write=hwrite;addr=haddr;size=hsize;end
   expected_vsync=(expected_vsync&&!w1c)||event_expected;
   if(event_expected)begin vs_events=vs_events+1;$display("[B4_VSYNC_EVENT] epoch=%0d external_VS=%b oracle_q1=%b oracle_q2=%b oracle_q3=%b event=1 selected_W1C=%b time=%0t",epoch,vga_vs,q1,q2,q3,w1c,$time);if(w1c)vs_collisions=vs_collisions+1;end
   q3=q2;q2=q1;q1=vga_vs;
  end
  #0.015;
  if(ep==epoch&&hresetn)begin
   if(live&&typ==1&&validated_consume==1&&validated_owner==1)live=0;
   measured=actual_vsync;
   if(!reached&&((fault=="B4_VSYNC_DROP"&&event_expected&&vs_events>=2)||(fault=="B4_VSYNC_COLLISION"&&event_expected&&w1c)||(fault=="B4_VSYNC_UNSELECTED"&&!w1c&&expected_vsync&&vs_unselected>0)))begin activate("postedge_VSYNC",measured,!measured);measured=!measured;end
   require(measured===expected_vsync,"FAIL_B4_VSYNC","Frozen three-register external-VS edge sets independent sticky, own W1C only, event set-dominant");
   if(consume_error)begin require(validated_consume==1&&validated_owner==1&&actual_busy,"FAIL_B4_CONSUME_REACH","ERROR final edge actually consumed ACK/reconstructed owner, combined remains busy");consume_errors=consume_errors+1;end
  end
 end
 task automatic check_final(input string scenario);
  if(scenario=="B4_COMBINED")require(consume_errors==1&&idle_first==1,"FAIL_B4_COVERAGE","Actual combined consume ERROR and first-idle address/commit reached once");
  if(scenario=="B4_DISPLAY")begin
   require(quiet_wraps==2&&quiet_pixels==420000&&black_checks>420000,"FAIL_B4_COVERAGE","Full recovered quiet frame black");
   require(white_markers>=3,"FAIL_B4_WHITE_MARKER","Two measured pre-invalidation white markers and a measured fresh recovered white marker");
  end
  if(scenario=="B4_VSYNC")require(vs_events>=3&&vs_collisions==1&&vs_selected>=2&&vs_unselected>=1&&status_reads>=2,"FAIL_B4_COVERAGE","Natural repeated VSYNC, selected/unselected W1C, accepted STATUS and same-edge collision");
  $display("[B4_SUMMARY] consume_errors=%0d idle_first=%0d black_checks=%0d quiet_wraps=%0d quiet_pixels=%0d white_markers=%0d vs_events=%0d vs_collisions=%0d selected=%0d unselected=%0d status_reads=%0d",consume_errors,idle_first,black_checks,quiet_wraps,quiet_pixels,white_markers,vs_events,vs_collisions,vs_selected,vs_unselected,status_reads);
 endtask
endmodule
