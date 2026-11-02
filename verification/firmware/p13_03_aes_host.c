/* Oracle: frozen FW 40 / AES 25. Literal addresses/status here intentionally
 * do not import the production memory map. This is a bus-contract test, NOT
 * an AES mathematical reference, CPU model, or hardware reset proof.
 * Each scenario runs in a fresh process; no production latch-reset test hook.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "aes_gcm.h"

typedef struct { char op; uint32_t addr, value; } event_t;
static event_t trace[512];
static unsigned events, starts, clears, zeroizes, polls, maintenance, pre;
static uint32_t version, initial, after_clear, programmed, terminal, done_at;
static uint32_t maintenance_done, dirty_offset;
static unsigned maintenance_mode, terminal_seen, output_reads;
static uint8_t key[16], input[16], in_tag[16], output[18], out_tag[18];
static aes_gcm_v2_request_t request;
static aes_gcm_v2_diagnostic_t diag;
static const char *case_id;
enum api_kind { TRANSACTION, ZEROIZE };
static enum api_kind active_api;
static uint8_t saved_output[18], saved_tag[18];
static uint32_t maintenance_terminal;
static unsigned inject_readback;


static void check(int ok, const char *id)
{
    if (!ok) { fprintf(stderr, "ASSERT_FAIL %s case=%s events=%u polls=%u\n", id, case_id, events, polls); exit(41); }
    printf("ASSERT_PASS %s case=%s\n", id, case_id);
}
static void record(char op, uint32_t a, uint32_t v)
{
    check(events < 512, "TRACE_CAPACITY");
    trace[events++] = (event_t){op,a,v};
    printf("MMIO %03u %c %08x %08x\n", events, op,a,v);
}
static void poll_bound(unsigned count, unsigned budget)
{ check(count <= budget, "POLL_BOUND"); }
static void auth_release(unsigned read, unsigned authenticated)
{ check(!read || authenticated, "AUTH_RELEASE"); }
static void zero_outputs(void)
{
    unsigned i;
    for (i=0; i<request.len; ++i) check(output[i+1]==0, "OUTPUT_ZERO");
    if (request.mode==AES_GCM_V2_ENCRYPT)
        for (i=1; i<=16; ++i) check(out_tag[i]==0, "TAG_ZERO");
    check(output[0]==0xcc && output[17]==0xcc && out_tag[0]==0xcc && out_tag[17]==0xcc, "OUTPUT_CANARY");
}
static void zeroize_canaries(void)
{
    check(memcmp(output,saved_output,sizeof(output))==0 &&
          memcmp(out_tag,saved_tag,sizeof(out_tag))==0,"ZEROIZE_CANARY_UNTOUCHED");
}
static void zeroize_readback(uint32_t value)
{ check(value==0,"ZEROIZE_READBACK"); }
static aes_gcm_v2_result_t zeroize_call(uint32_t budget)
{
    aes_gcm_v2_result_t r;
    active_api=ZEROIZE;
    memcpy(saved_output,output,sizeof(output)); memcpy(saved_tag,out_tag,sizeof(out_tag));
    r=aes_gcm_v2_zeroize(budget,&diag);
    zeroize_canaries();
    printf("ZEROIZE_RETURN result=%u last=%08x maintenance=%u recovery=%u\n",
           r,diag.last_status,diag.completed_maintenance_polls,diag.recovery_required);
    active_api=TRANSACTION;
    return r;
}
uint32_t mmio_read32(uint32_t a)
{
    uint32_t v=0;
    if (active_api==ZEROIZE) zeroize_canaries();
    else if (!terminal_seen) zero_outputs();
    check(a>=0x40040000u && a<=0x4004008cu && (a&3)==0, "CANONICAL_READ");
    if (a==0x40040008) v=version;
    else if (a==0x40040010) {
        if (maintenance_mode) {
            ++maintenance;
            check(maintenance<=request.poll_budget, "MAINT_BOUND");
            v=maintenance>=maintenance_done ? maintenance_terminal : 0x2001;
        } else if (starts) {
            ++polls;
            poll_bound(polls,request.poll_budget);
            check(!terminal_seen,"EARLY_STOP");
            v=(done_at && polls>=done_at) ? terminal : 1;
            if (v&2) terminal_seen=1;
        } else {
            ++pre;
            v=pre==1 ? initial : (pre==2 ? after_clear : programmed);
        }
    } else if (maintenance_mode) {
        check(maintenance>=maintenance_done,"MAINT_BEFORE_READBACK");
        check(a>=0x40040020 && a<=0x4004008c,"SENSITIVE_READBACK");
        v=(a==dirty_offset) ? 1 : 0;
        if (v && inject_readback)
            printf("INJECTION_REACHED ZEROIZE_READBACK address=%08x observed=%u\n",a,v);
    } else {
        auth_release(1,terminal_seen && terminal==6);
        check(a>=0x40040060 && a<0x40040080,"NO_KEY_READ");
        ++output_reads;
        v=0x81828384u + ((a-0x40040060u)/4u)*0x04040404u;
    }
    record('R',a,v); return v;
}
void mmio_write32(uint32_t a,uint32_t v)
{
    if (active_api==ZEROIZE) zeroize_canaries(); else zero_outputs();
    check(a>=0x4004000cu && a<=0x4004005cu && (a&3)==0,"CANONICAL_WRITE");
    check(!starts,"NO_SECOND_START_OR_BUSY_WRITE");
    if (a==0x4004000c) {
        if (v==4) { check(pre==1 && !initial,"CLEAR_IDLE"); ++clears; }
        else if (v==8) { check(pre==1 && !initial,"ZEROIZE_IDLE"); ++zeroizes; maintenance_mode=1; }
        else { check(v==(request.mode==AES_GCM_V2_ENCRYPT?1u:3u),"START_DIRECTION"); check(pre==3 && clears==1,"START_ORDER"); ++starts; }
    } else check(clears==1 && pre==2 && !after_clear,"PROGRAM_IDLE");
    record('W',a,v);
}
static void setup(void)
{
    unsigned i;
    version=0x322e3030; done_at=1; terminal=6; maintenance_done=1;
    memset(output,0xcc,sizeof(output)); memset(out_tag,0xcc,sizeof(out_tag));
    for(i=0;i<16;++i) { key[i]=(uint8_t)(i+1); input[i]=(uint8_t)(i+1); in_tag[i]=(uint8_t)(i+1); }
    request=(aes_gcm_v2_request_t){
        .mode=AES_GCM_V2_ENCRYPT,.key=key,.key_capacity=16,
        .nonce_dir=0x11223344,.seq_hi=0x55667788,.seq_lo=0x99aabbcc,
        .input=input,.input_capacity=16,.output=output+1,.output_capacity=16,
        .tag_out=out_tag+1,.tag_out_capacity=16,.len=16,.poll_budget=4};
}
static void decrypt(void)
{ request.mode=AES_GCM_V2_DECRYPT; request.tag_out=NULL; request.tag_out_capacity=0; request.tag_in=in_tag; request.tag_in_capacity=16; }
static aes_gcm_v2_result_t call(void)
{
    unsigned before_polls=polls, before_starts=starts;
    aes_gcm_v2_result_t r=aes_gcm_v2_transact(&request,&diag);
    printf("RETURN result=%u last=%08x polls=%u maintenance=%u recovery=%u start=%u\n",r,diag.last_status,diag.completed_status_polls,diag.completed_maintenance_polls,diag.recovery_required,diag.start_issued);
    check(diag.completed_status_polls==polls-before_polls,"DIAG_POLL_COUNT");
    check(diag.start_issued==starts-before_starts,"DIAG_START");
    check(diag.completed_maintenance_polls==0,"DIAG_SEPARATE_COUNTS");
    if(r!=AES_GCM_V2_OK) zero_outputs();
    return r;
}
/* Independent word prediction for the 01..10 stimulus, indexed by literal
 * canonical address, not the driver's output or production packing helper. */
static void check_program(void)
{
    unsigned i,seen=0, tag_seen=0;
    for(i=0;i<events;++i) if(trace[i].op=='W' && trace[i].addr!=0x4004000c) {
        uint32_t a=trace[i].addr,v=0, k;
        if(a==0x40040030) v=0x11223344;
        else if(a==0x40040034) v=0x55667788;
        else if(a==0x40040038) v=0x99aabbcc;
        else if(a==0x4004003c) v=request.len;
        else {
            unsigned base=a>=0x40040050?0x40040050:(a>=0x40040040?0x40040040:0x40040020);
            unsigned word=(a-base)/4,limit=base==0x40040040?request.len:16;
            for(k=0;k<4;++k) { unsigned byte=word*4+k; if(byte<limit) v|=(byte+1)<<(24-k*8); }
            if(base==0x40040050) ++tag_seen;
        }
        check(trace[i].value==v,"PACK_AND_IV_EXACT");
        /* Programming words must be monotonic and contiguous KEY..PAYLOAD,
         * plus TAG for decrypt. This checks every write's ownership/order. */
        check(a==0x40040020u+4u*seen,"PROGRAM_SEQUENCE");
        ++seen;
    }
    check(seen==(request.mode==AES_GCM_V2_DECRYPT?16u:12u),"PROGRAM_WORDS");
    check(tag_seen==(request.mode==AES_GCM_V2_DECRYPT?4u:0u),"TAG_MODE_ONLY");
}
static void success(void)
{
    unsigned i;
    check(call()==AES_GCM_V2_OK,"RESULT_OK"); check_program();
    check(diag.last_status==6 && diag.recovery_required==0,"DIAG_SUCCESS");
    for(i=0;i<request.len;++i) check(output[i+1]==0x81+i,"VALID_LEFT_BYTES");
    for(i=request.len;i<16;++i) check(output[i+1]==0xcc,"TAIL_UNTOUCHED");
    if(request.mode==AES_GCM_V2_ENCRYPT)
        for(i=0;i<16;++i) check(out_tag[i+1]==0x91+i,"TAG_BYTES");
    check(output[0]==0xcc && output[17]==0xcc && out_tag[0]==0xcc && out_tag[17]==0xcc,"OUTPUT_CANARY");
    check(output_reads==(request.len+3)/4+(request.mode==AES_GCM_V2_ENCRYPT?4u:0u),"OUTPUT_READ_COUNT");
}
static void blocked(void)
{
    unsigned n=events;
    memset(output+1,0xcc,16); memset(out_tag+1,0xcc,16);
    check(call()==AES_GCM_V2_RECOVERY_REQUIRED,"LATCH_BLOCKS_REENTRY");
    check(events==n && diag.recovery_required==1,"LATCH_ZERO_MMIO");
    check(aes_gcm_v2_acknowledge_external_reset(&diag)==AES_GCM_V2_RECOVERY_REQUIRED,"ACK_NO_RESET_PROOF");
    check(events==n && diag.recovery_required==1,"ACK_PRESERVES_LATCH");
}
static void invalid(unsigned sub)
{
    aes_gcm_v2_result_t r;
    switch(sub) {
    case 0: request.len=17; break; case 1: request.len=65535; break;
    case 2: request.len=65536; break; case 3: request.len=65552; break;
    case 4: request.key=NULL; break; case 5: request.input=NULL; break;
    case 6: request.output=NULL; break; case 7: request.tag_out=NULL; break;
    case 8: request.key_capacity=15; break; case 9: request.input_capacity=15; break;
    case 10: request.output_capacity=15; break; case 11: request.tag_out_capacity=15; break;
    case 12: request.mode=(aes_gcm_v2_mode_t)2; break;
    case 13: request.output=input; break; case 14: request.output=key; break;
    case 15: request.output=out_tag+1; break;
    case 16: request.tag_in=in_tag; request.tag_in_capacity=16; break;
    case 17: decrypt(); request.tag_in=NULL; break;
    case 18: decrypt(); request.tag_in_capacity=15; break;
    case 19: decrypt(); request.output=in_tag; break;
    case 20: request.tag_out=key; break;
    case 21: request.output=(uint8_t*)(UINTPTR_MAX-7); break;
    case 22: request.tag_out=(uint8_t*)&request; break;
    case 23: request.output=(uint8_t*)&diag; break;
    case 24: request.tag_in_capacity=1; break;
    default: break;
    }
    r=aes_gcm_v2_transact(sub==25?NULL:&request,sub==26?NULL:&diag);
    check(r==AES_GCM_V2_INVALID_ARG,"INVALID_ARG");
    check(events==0,"INVALID_ZERO_MMIO");
    check(output[1]==0xcc && out_tag[1]==0xcc,"INVALID_OUTPUT_UNTOUCHED");
    check(aes_gcm_v2_acknowledge_external_reset(&diag)==AES_GCM_V2_OK,"INVALID_NO_LATCH");
}
static void run(unsigned group,unsigned sub)
{
    aes_gcm_v2_result_t result;
    unsigned n,i;
    setup();
    if(group==1) { invalid(sub); return; }
    if(group==2) {
        version=sub?0xdeadbeef:0x312e3030;
        check(call()==AES_GCM_V2_HW_CORE_ERROR,"VERSION_REJECT");
        check(events==1 && trace[0].addr==0x40040008 && starts==0,"VERSION_ONLY_READ"); return;
    }
    if(group==3) {
        request.poll_budget=0; check(call()==AES_GCM_V2_TIMEOUT,"ZERO_BUDGET_TIMEOUT");
        check(events==0 && diag.last_status==0 && !diag.recovery_required,"ZERO_BUDGET_NO_LATCH"); return;
    }
    if(group==4) {
        request.poll_budget= sub==0?1:4; done_at=sub==0?1:(sub==1?4:2);
        success(); check(polls==done_at,"FIRST_NTH_EARLY_DONE"); return;
    }
    if(group==5 || group==6) {
        /* Each status case in a separate process: fatal latches never reset. */
        static const uint32_t statuses[]={0x9a,0x62e,0x11a,0x5a,2,4,0xa,0x21a,0x41a,0x81a,0x101a,0xfa,0x1fa,0x8000000a,0x32e,0x22a,0x42a,0x82a,0x102a,0x27a,0x2ba,0x3fa,7,0x2006,0x1a};
        static const aes_gcm_v2_result_t outcomes[]={AES_GCM_V2_AUTH_FAIL,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_LEN_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_TIMEOUT,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_AUTH_FAIL,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_PROGRAM_ERROR,AES_GCM_V2_HW_LEN_ERROR,AES_GCM_V2_AUTH_FAIL,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_CORE_ERROR,AES_GCM_V2_HW_CORE_ERROR};
        if(group==6) decrypt();
        terminal=statuses[sub];
        result=call(); check(result==outcomes[sub],"CAUSE_PRIORITY");
        check(output_reads==0,"NO_FAILURE_OUTPUT_READ");
        check(diag.last_status==terminal,"DIAG_FULL_STATUS");
        check(polls==(terminal&2?1u:4u),"TERMINAL_VS_TIMEOUT");
        if(result==AES_GCM_V2_HW_CORE_ERROR || result==AES_GCM_V2_TIMEOUT) blocked();
        else check(!diag.recovery_required,"NONFATAL_NO_LATCH");
        return;
    }
    if(group==7) {
        if(sub==0) initial=1; else if(sub==1) after_clear=1;
        else if(sub==2) programmed=1; else if(sub==3) programmed=0x228;
        else programmed=6;
        check(call()==(sub<3?AES_GCM_V2_BUSY:AES_GCM_V2_PROGRAM_ERROR),"ADMISSION_REJECT");
        check(starts==0 && output_reads==0 && !diag.recovery_required,"ADMISSION_NO_START");
        if(sub<2) for(i=0;i<events;++i) check(trace[i].op!='W'||trace[i].addr==0x4004000c,"BUSY_NO_DATA");
        return;
    }
    if(group==8) {
        if(sub==0) initial=1;
        if(sub==1) request.poll_budget=0;
        if(sub==2) maintenance_done=3;
        if(sub==3) maintenance_done=99;
        if(sub>=4) dirty_offset=0x40040020+4*(sub-4);
        result=zeroize_call(request.poll_budget);
        check(result==(sub==0?AES_GCM_V2_BUSY:((sub==1||sub==3)?AES_GCM_V2_TIMEOUT:(sub>=4?AES_GCM_V2_HW_CORE_ERROR:AES_GCM_V2_OK))),"ZEROIZE_RESULT");
        check(diag.completed_status_polls==0 && diag.completed_maintenance_polls==maintenance,"ZEROIZE_COUNTS");
        if(sub==0||sub==1) check(zeroizes==0,"ZEROIZE_NO_BUSY_CMD");
        else check(zeroizes==1,"ZEROIZE_EXACTLY_ONCE");
        if(sub==1) check(events==0,"ZEROIZE_ZERO_BUDGET_MMIO");
        if(sub==2) { unsigned reads=0; for(i=0;i<events;++i) if(trace[i].op=='R'&&trace[i].addr>=0x40040020) { check(trace[i].addr==0x40040020+reads*4,"ALL_SENSITIVE_OFFSETS"); zeroize_readback(trace[i].value); ++reads; } check(reads==28,"ALL_28_SENSITIVE_WORDS"); }
        return;
    }
    if(group==9) {
        static const unsigned lens[]={0,1,7,15,16}; request.len=lens[sub%5];
        if(sub>=5) decrypt();
        if(!request.len) { request.input=NULL; request.input_capacity=0; request.output=NULL; request.output_capacity=0; }
        success(); return;
    }
    if(group==10) {
        success();
        /* Same explicitly caller-supplied IV again: driver must not allocate,
         * increment, persist or silently retry; protocol caller owns uniqueness. */
        events=starts=clears=polls=pre=output_reads=terminal_seen=0;
        memset(output,0xcc,sizeof(output)); memset(out_tag,0xcc,sizeof(out_tag));
        success(); return;
    }
    if(group==13) {
        done_at=0; check(call()==AES_GCM_V2_TIMEOUT,"POST_START_TIMEOUT");
        check(polls==4 && diag.last_status==1 && diag.recovery_required,"TIMEOUT_LATCH");
        n=events;
        /* Invalid parameters retain priority even with latch. */
        request.len=17; check(aes_gcm_v2_transact(&request,&diag)==AES_GCM_V2_INVALID_ARG,"LATCH_INVALID_PRIORITY"); request.len=16;
        request.poll_budget=0; blocked(); check(events==n,"NO_TIMEOUT_EXTRA_READ");
        /* Raw status/clear/idle observation cannot release software latch. */
        starts=0; pre=0; initial=0; after_clear=0;
        (void)aes_gcm_status(); aes_gcm_clear_status();
        n=events; blocked(); check(events==n,"RAW_CLEAR_NO_RECOVERY");
        /* Idle sanitization works, but remains distinct from recovery proof. */
        pre=0; clears=0; request.poll_budget=4;
        check(zeroize_call(4)==AES_GCM_V2_OK,"LATCH_IDLE_ZEROIZE_OK");
        check(diag.recovery_required==1,"ZEROIZE_NO_LATCH_CLEAR");
        maintenance_mode=0; n=events; blocked(); check(events==n,"ZEROIZE_STILL_BLOCKED"); return;
    }
    if(group==14) {
        if(sub==0) { check(aes_gcm_v2_zeroize(4,NULL)==AES_GCM_V2_INVALID_ARG,"ZEROIZE_NULL_DIAG");
            check(aes_gcm_v2_acknowledge_external_reset(NULL)==AES_GCM_V2_INVALID_ARG,"ACK_NULL_DIAG");
            check(events==0,"MAINT_INVALID_ZERO_MMIO"); return; }
        if(sub==1) { version=0x312e3030; check(zeroize_call(4)==AES_GCM_V2_HW_CORE_ERROR,"ZEROIZE_VERSION");
            check(events==2 && zeroizes==0,"ZEROIZE_VERSION_NO_CMD"); return; }
        if(sub==2) { initial=0x2001; check(zeroize_call(4)==AES_GCM_V2_BUSY,"ZEROIZE_ACTIVE_BUSY");
            check(events==1 && zeroizes==0,"ZEROIZE_BUSY_ONLY_STATUS"); return; }
        if(sub==3) { maintenance_terminal=0x428; check(zeroize_call(4)==AES_GCM_V2_PROGRAM_ERROR,"ZEROIZE_CAUSE_ERROR"); return; }
        if(sub==4) { maintenance_terminal=0x11a; check(zeroize_call(4)==AES_GCM_V2_HW_CORE_ERROR,"ZEROIZE_FATAL_ERROR");
            check(diag.recovery_required==1,"ZEROIZE_FATAL_LATCH"); return; }
        if(sub==5) { decrypt(); request.poll_budget=0; check(call()==AES_GCM_V2_TIMEOUT,"DECRYPT_N0");
            check(events==0 && !diag.recovery_required,"DECRYPT_N0_NO_LATCH"); return; }
        if(sub==6) { initial=0x2001; check(call()==AES_GCM_V2_BUSY,"TRANSACTION_ZEROIZE_ACTIVE");
            check(events==2 && !starts && !clears && !diag.recovery_required,"MAINT_BUSY_NO_MUTATION"); return; }
        if(sub==7) { after_clear=0x428; check(call()==AES_GCM_V2_PROGRAM_ERROR,"CLEAR_ERROR_NO_PROGRAM");
            check(!starts && events==4,"CLEAR_ERROR_NO_DATA"); return; }
        if(sub==8) { initial=1; check(call()==AES_GCM_V2_BUSY,"BUSY_NO_LATCH");
            check(!diag.recovery_required,"BUSY_LATCH_UNCHANGED"); return; }
        if(sub==9) { request.poll_budget=1; done_at=0; check(call()==AES_GCM_V2_TIMEOUT,"N1_TIMEOUT");
            check(polls==1 && diag.last_status==1 && diag.recovery_required,"N1_TIMEOUT_DIAG"); return; }
    }
    if(group==12) {
        printf("INJECTION_REACHED checker_observation sub=%u\n",sub);
        if(sub==0) auth_release(1,0); else if(sub==1) poll_bound(5,4);
        else if(sub==2) { fprintf(stderr,"INJECTED_CHILD_FAILURE\n"); exit(37); }
        else if(sub==3) {
            dirty_offset=0x40040080; inject_readback=1;
            check(zeroize_call(4)==AES_GCM_V2_HW_CORE_ERROR,"ZEROIZE_DRIVER_FAIL_CLOSED");
            for(i=0;i<events;++i) if(trace[i].op=='R' && trace[i].addr>=0x40040020)
                zeroize_readback(trace[i].value);
        }
        check(0,"INJECTION_NOT_DETECTED");
    }
}
int main(int argc,char **argv)
{
    unsigned g,s;
    setvbuf(stdout,NULL,_IONBF,0);
    if(argc==3) { g=(unsigned)strtoul(argv[1],NULL,10); s=(unsigned)strtoul(argv[2],NULL,10); case_id=argv[1]; run(g,s); puts("CASE_PASS"); return 0; }
    fprintf(stderr,"usage: %s group subcase\n",argv[0]); return 2;
}
