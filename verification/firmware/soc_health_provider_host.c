#include "soc_health_providers.h"
#include "soc_memory_map.h"
#include "timer.h"
#include "uart.h"
#include "gsensor.h"
#include "vram.h"
#include "joystick_policy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(tag, expr) do { if (!(expr)) { fprintf(stderr,"ASSERT %s line %d: %s\n", tag,__LINE__,#expr); exit(1); } } while (0)

/* Independent register/transaction model. Inputs are raw publications, received
 * bytes and events, not provider phase or health outputs. Drivers are real. */
static struct {
    uint32_t count, compare, active, ready, running, ack_stuck, restart_stuck, starts;
    uint8_t rx[512], tx[512]; uint32_t rd, wr, ntx, rx_error, loop, tx_ready, baud[2];
    uint32_t gs_seq, gs_valid, gs_hold, gs_busy, gs_releases;
    uint32_t adc_identity, adc_enabled, adc_ack, adc_new, adc_hold, adc_count, adc_error;
    adc_frame_t live, hold;
    joystick_calibration_t cal;
    uint32_t joy_corrupt, captures, vga_status, swaps, words, reads, writes;
} hw;
static uint8_t independent_joy(const adc_frame_t *f, const joystick_calibration_t *cal)
{
    int x=(int)f->ch[0]-(int)cal->center_x, y=(int)f->ch[1]-(int)cal->center_y;
    int dz=(int)cal->deadzone; uint8_t out=0;
    if (f->valid_mask & 1u) out=(uint8_t)(16u | (x>dz?8u:0u) | (x < -dz?4u:0u));
    if (f->valid_mask & 2u) out|=(uint8_t)(32u | (y>dz?1u:0u) | (y < -dz?2u:0u));
    return out;
}
static void reset(soc_health_core_t *c, soc_health_providers_t *p)
{
    memset(&hw,0,sizeof(hw)); hw.tx_ready=1; hw.adc_identity=1; hw.adc_ack=1;
    hw.cal.center_x=hw.cal.center_y=2048; hw.cal.deadzone=100;
    hw.vga_status=VRAM_STATUS_DOMAIN_READY;
    soc_health_init(c); soc_health_providers_init(p); p->budget=20; p->timer_compare=50;
}
uint32_t soc_health_test_read(uint32_t addr)
{
    hw.reads++; CHECK("ALIGNED_MMIO", (addr & 3u)==0u);
    if (addr==TIMER_BASE+TIMER_COUNT) return hw.count;
    if (addr==TIMER_BASE+TIMER_STATUS) return hw.ready;
    if (addr==UART0_BASE+UART_STATUS) return hw.tx_ready;
    if (addr==UART1_BASE+UART_STATUS) return (hw.rd<hw.wr?2u:0u) | hw.rx_error;
    if (addr==UART1_BASE+UART_DATA) { CHECK("RX_OWNERSHIP",hw.rd<hw.wr); return hw.rx[hw.rd++]; }
    if (addr==GSENSOR_BASE+GSENSOR_STATUS) return (hw.gs_valid?1u:0u)|(hw.gs_hold||hw.gs_busy?2u:0u);
    if (addr==GSENSOR_BASE+GSENSOR_HOLD_SEQ) return hw.gs_seq;
    if (addr==GSENSOR_BASE+GSENSOR_HOLD_XY) return 0x12345678u;
    if (addr==GSENSOR_BASE+GSENSOR_HOLD_Z) return 0x9abcu;
    if (addr==ADC_BASE+ADC_NAME0) return hw.adc_identity?ADC_EXPECTED_NAME0:0u;
    if (addr==ADC_BASE+ADC_NAME1) return ADC_EXPECTED_NAME1;
    if (addr==ADC_BASE+ADC_VERSION) return ADC_EXPECTED_VERSION;
    if (addr==ADC_BASE+ADC_STATUS) return (hw.adc_enabled?3u:0u)|(hw.adc_new?0x14u:0u)|(hw.adc_hold?8u:0u);
    if (addr==ADC_BASE+ADC_FRAME_SEQ) return hw.hold.seq;
    if (addr==ADC_BASE+ADC_VALID_MASK) return hw.hold.valid_mask;
    if (addr>=ADC_BASE+ADC_CH1_RAW && addr<=ADC_BASE+ADC_CH6_RAW) return hw.hold.ch[(addr-ADC_BASE-ADC_CH1_RAW)/4u];
    if (addr==ADC_BASE+ADC_FRAME_COUNT) return hw.adc_count;
    if (addr==ADC_BASE+ADC_ERROR_STATUS) return hw.adc_error;
    if (addr==ADC_BASE+ADC_JOY_CENTER_X) return hw.cal.center_x;
    if (addr==ADC_BASE+ADC_JOY_CENTER_Y) return hw.cal.center_y;
    if (addr==ADC_BASE+ADC_JOY_DEADZONE) return hw.cal.deadzone;
    if (addr==ADC_BASE+ADC_JOY_STATUS) return independent_joy(&hw.hold,&hw.cal)^hw.joy_corrupt;
    if (addr==VRAM_BASE+VRAM_STATUS) return hw.vga_status;
    CHECK("UNEXPECTED_MMIO_READ",0); return 0;
}
void soc_health_test_write(uint32_t addr,uint32_t value)
{
    hw.writes++; CHECK("ALIGNED_MMIO", (addr&3u)==0u);
    if (addr==TIMER_BASE+TIMER_COMPARE) {hw.compare=value;return;}
    if (addr==TIMER_BASE+TIMER_CTRL) {
        if(value&1u) {hw.starts++;hw.count=hw.ready=0;hw.active=hw.compare;hw.running=!(hw.restart_stuck && hw.starts>1);}
        else if(value&2u) {hw.count=hw.ready=hw.running=0;} else hw.running=0;
        return;
    }
    if (addr==TIMER_BASE+TIMER_STATUS) {if(!hw.ack_stuck) hw.ready&=~value;return;}
    if (addr==UART0_BASE+UART_BAUD || addr==UART1_BASE+UART_BAUD) {hw.baud[addr==UART0_BASE+UART_BAUD?0:1]=value;return;}
    if (addr==UART0_BASE+UART_DATA) {
        CHECK("TX_READY",hw.tx_ready);CHECK("FIFO_BOUNDS",hw.ntx<512u);hw.tx[hw.ntx++]=(uint8_t)value;
        if(hw.loop) {CHECK("FIFO_BOUNDS",hw.wr<512u);hw.rx[hw.wr++]=(uint8_t)value;}return;
    }
    if (addr==UART1_BASE+UART_STATUS) {hw.rx_error&=~value;return;}
    if (addr==GSENSOR_BASE+GSENSOR_SNAP_CTRL) {
        if(value==1u) hw.gs_hold=hw.gs_valid;
        if(value==2u) {hw.gs_hold=0;hw.gs_releases++;}return;
    }
    if(addr==ADC_BASE+ADC_CTRL) {
        CHECK("NO_ADC_ERROR_CLEAR",!(value&4u));hw.adc_enabled=hw.adc_ack && (value&1u);
        if(value&2u) {CHECK("CAPTURE_NEW",hw.adc_new);hw.hold=hw.live;hw.adc_hold=1;hw.adc_new=0;hw.captures++;}return;
    }
    if(addr==VRAM_BASE+VRAM_STATUS) {hw.vga_status&=~(value&11u);return;}
    if(addr==VRAM_BASE+VRAM_CONTROL) {
        CHECK("SWAP_ONLY",value==1u);CHECK("VGA_OWNER",(hw.vga_status&20u)==16u);
        hw.swaps++;hw.vga_status|=4u;return;
    }
    if(addr==VRAM_BASE) {CHECK("VGA_WRITE_READY_IDLE",(hw.vga_status&20u)==16u);CHECK("MINIMAL_PREPARE",value==0u);hw.words++;return;}
    CHECK("UNEXPECTED_MMIO_WRITE",0);
}
static void timer_tick(uint32_t n)
{
    if(hw.running) {hw.count+=n;if(hw.count>=hw.active){hw.count=hw.active;hw.ready=1;hw.running=0;}}
}
static void step(soc_health_core_t *c,soc_health_providers_t *p,void (*service)(soc_health_core_t *,soc_health_providers_t *))
{
    uint32_t r=hw.reads,w=hw.writes;soc_health_epoch_begin(c);service(c,p);
    CHECK("SERVICE_BOUND", hw.reads-r<=32u && hw.writes-w<=8u);
}
static void timer_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i;
    reset(&c,&p);hw.ready=1;step(&c,&p,soc_health_timer_service);
    for(i=0;i<21;i++)step(&c,&p,soc_health_timer_service);
    CHECK("TIMER_FROZEN",c.ip[1].heartbeat_count==0 && c.ip[1].miss_count==1 && c.sticky_fail_mask==2u);
    reset(&c,&p);hw.ready=1;step(&c,&p,soc_health_timer_service);
    timer_tick(2);step(&c,&p,soc_health_timer_service);
    timer_tick(48);step(&c,&p,soc_health_timer_service);
    step(&c,&p,soc_health_timer_service);CHECK("TIMER_ACK",hw.ready==0);
    step(&c,&p,soc_health_timer_service);CHECK("TIMER_NO_EARLY",c.ip[1].heartbeat_count==0);
    timer_tick(1);step(&c,&p,soc_health_timer_service);
    CHECK("TIMER_GENERATION",c.ip[1].heartbeat_count==1 && c.progress_token[1]==1 && hw.starts==2);
    reset(&c,&p);step(&c,&p,soc_health_timer_service);timer_tick(50);step(&c,&p,soc_health_timer_service);
    hw.ack_stuck=1;step(&c,&p,soc_health_timer_service);step(&c,&p,soc_health_timer_service);
    CHECK("TIMER_ACK_FAIL",c.ip[1].state==SOC_HB_FAIL && c.ip[1].heartbeat_count==0);
    reset(&c,&p);hw.restart_stuck=1;step(&c,&p,soc_health_timer_service);timer_tick(50);
    step(&c,&p,soc_health_timer_service);step(&c,&p,soc_health_timer_service);step(&c,&p,soc_health_timer_service);
    for(i=0;i<21;i++)step(&c,&p,soc_health_timer_service);
    CHECK("TIMER_RESTART_FAIL",c.ip[1].heartbeat_count==0 && c.ip[1].miss_count>0);
    reset(&c,&p);step(&c,&p,soc_health_timer_service);hw.count=1;step(&c,&p,soc_health_timer_service);
    for(i=0;i<21;i++)step(&c,&p,soc_health_timer_service);
    CHECK("TIMER_READY_TIMEOUT",c.ip[1].miss_count>0 && c.ip[1].heartbeat_count==0);
    puts("CASE timer_transactions PASS");
}
static void token(uint8_t *b,uint32_t seq)
{
    uint32_t i;b[0]=165;b[1]=90;b[10]=195;b[11]=60;
    for(i=0;i<4;i++){b[2+i]=(uint8_t)(seq>>(8*i));b[6+i]=(uint8_t)(255u-b[2+i]);}
}
static void uart_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i,j;uint8_t b[12];
    reset(&c,&p);hw.loop=1;
    for(i=0;i<14;i++)step(&c,&p,soc_health_uart_service);
    token(b,1u);CHECK("UART_TOKEN",hw.ntx==12 && memcmp(hw.tx,b,12)==0);
    CHECK("UART_GENERATION",c.ip[2].heartbeat_count==1 && c.progress_token[2]==1 && hw.baud[0]==434 && hw.baud[1]==434);
    /* Bad header, stale sequence, complement and both trailers must reject. */
    for(j=0;j<5;j++) {
        reset(&c,&p);p.budget=100;step(&c,&p,soc_health_uart_service);step(&c,&p,soc_health_uart_service);
        for(i=0;i<12;i++)step(&c,&p,soc_health_uart_service);
        token(b,j==1?0u:1u);if(j!=1)b[j==0?0:j==2?6:j==3?10:11]^=1u;
        memcpy(hw.rx,b,12);hw.wr=12;
        for(i=0;i<4;i++)step(&c,&p,soc_health_uart_service);
        CHECK("UART_CORRUPT",c.ip[2].state==SOC_HB_FAIL && c.ip[2].heartbeat_count==0);
    }
    reset(&c,&p);step(&c,&p,soc_health_uart_service);hw.rx_error=4u;
    step(&c,&p,soc_health_uart_service);CHECK("UART_ERROR",c.ip[2].state==SOC_HB_FAIL && hw.rx_error==0);
    hw.loop=1;for(i=0;i<14;i++)step(&c,&p,soc_health_uart_service);
    CHECK("UART_RECOVERY",c.ip[2].state==SOC_HB_PASS && (c.sticky_fail_mask&4u));
    reset(&c,&p);p.budget=100;step(&c,&p,soc_health_uart_service);step(&c,&p,soc_health_uart_service);
    for(i=0;i<12;i++)step(&c,&p,soc_health_uart_service);
    token(b,1u);for(i=0;i<12;i++){hw.rx[hw.wr++]=b[i];step(&c,&p,soc_health_uart_service);CHECK("UART_PARTIAL",c.ip[2].heartbeat_count==(i==11?1u:0u));}
    reset(&c,&p);step(&c,&p,soc_health_uart_service);memset(hw.rx,0x42,100);hw.wr=100;
    step(&c,&p,soc_health_uart_service);CHECK("UART_DRAIN_QUOTA",hw.rd==4u);
    for(i=0;i<21;i++)step(&c,&p,soc_health_uart_service);
    CHECK("UART_DRAIN_TIMEOUT",c.ip[2].miss_count>0 && c.ip[2].heartbeat_count==0);
    reset(&c,&p);hw.tx_ready=0;for(i=0;i<24;i++)step(&c,&p,soc_health_uart_service);
    CHECK("UART_TX_TIMEOUT",c.ip[2].miss_count>0 && hw.ntx==0 && c.ip[2].heartbeat_count==0);
    reset(&c,&p);p.budget=100;step(&c,&p,soc_health_uart_service);step(&c,&p,soc_health_uart_service);
    for(i=0;i<12;i++)step(&c,&p,soc_health_uart_service);
    token(b,1u);memcpy(hw.rx,b,5);hw.wr=5;step(&c,&p,soc_health_uart_service);
    hw.rx_error=4;step(&c,&p,soc_health_uart_service);
    memcpy(hw.rx+hw.wr,b+5,7);hw.wr+=7;
    for(i=0;i<5;i++)step(&c,&p,soc_health_uart_service);
    CHECK("UART_OLD_PARTIAL",c.ip[2].heartbeat_count==0 && p.uart_seq==2);
    puts("CASE uart_framing_resync PASS");
}
static void gsensor_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i;
    reset(&c,&p);hw.gs_valid=1;hw.gs_seq=0xfffffffeu;step(&c,&p,soc_health_gsensor_service);
    CHECK("GS_SEQ",c.progress_token[4]==0xfffffffeu && hw.gs_releases==1);
    for(i=0;i<21;i++)step(&c,&p,soc_health_gsensor_service);
    CHECK("GS_REPEAT",c.ip[4].heartbeat_count==1 && c.ip[4].miss_count==1);
    hw.gs_seq=1u;step(&c,&p,soc_health_gsensor_service);
    CHECK("GS_WRAP",c.ip[4].heartbeat_count==2 && c.ip[4].state==SOC_HB_PASS && (c.sticky_fail_mask&16u));
    hw.gs_seq=0u;step(&c,&p,soc_health_gsensor_service);CHECK("GS_STALE",c.ip[4].heartbeat_count==2);
    for(i=0;i<2;i++) {
        reset(&c,&p);hw.gs_busy=i;
        for(uint32_t j=0;j<22;j++)step(&c,&p,soc_health_gsensor_service);
        CHECK("GS_PENDING_TIMEOUT",c.ip[4].miss_count>0 && c.ip[4].heartbeat_count==0);
    }
    reset(&c,&p);step(&c,&p,soc_health_gsensor_service);
    c.epoch=30;hw.gs_valid=1;hw.gs_seq=8;step(&c,&p,soc_health_gsensor_service);
    CHECK("GS_LATE_HISTORY",c.ip[4].miss_count==1 && c.ip[4].state==SOC_HB_PASS && (c.sticky_fail_mask&16u));
    puts("CASE gsensor_sequences PASS");
}
static void adc_boot(soc_health_core_t *c,soc_health_providers_t *p)
{
    step(c,p,soc_health_adc_service);step(c,p,soc_health_adc_service);step(c,p,soc_health_adc_service);
    CHECK("ADC_INIT_NO_PROGRESS",c->ip[5].heartbeat_count==0 && hw.adc_enabled);
    CHECK("ADC_CAL_BASELINE",p->adc_center_x==2048 && p->adc_center_y==2048 && p->adc_deadzone==100);
}
static void publish(uint32_t seq,uint32_t count,uint8_t valid,uint16_t x,uint16_t y)
{
    hw.live.seq=seq;hw.live.valid_mask=valid;hw.live.ch[0]=x;hw.live.ch[1]=y;hw.adc_count=count;hw.adc_new=1;
}
static void adc_joy_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i;
    reset(&c,&p);adc_boot(&c,&p);publish(10,8,3,2500,2048);step(&c,&p,soc_health_adc_service);
    CHECK("ADC_HOLD_TOKEN",c.progress_token[5]==10 && c.ip[5].heartbeat_count==1 && hw.captures==1);
    CHECK("JOY_SAME_FRAME",c.progress_token[6]==10 && c.ip[6].heartbeat_count==1 && c.ip[6].detail==0x3838u);
    publish(10,11,3,2500,2048);step(&c,&p,soc_health_adc_service);CHECK("ADC_REPEAT",c.ip[5].heartbeat_count==1);
    publish(9,12,3,2500,2048);step(&c,&p,soc_health_adc_service);CHECK("ADC_STALE",c.ip[5].heartbeat_count==1);
    publish(11,13,3,2148,1948);step(&c,&p,soc_health_adc_service);CHECK("JOY_EQUALITY",c.ip[6].detail==0x3030u);
    hw.cal.center_x=0;hw.cal.center_y=4095;hw.cal.deadzone=100;
    publish(12,20,3,0,4095);step(&c,&p,soc_health_adc_service);CHECK("JOY_SATURATION",c.ip[6].detail==0x3030u);
    hw.cal.center_x=2048;hw.cal.center_y=2048;hw.cal.deadzone=100;
    publish(13,21,3,2500,2048);step(&c,&p,soc_health_adc_service);
    hw.cal.center_x=3000;step(&c,&p,soc_health_joy_service);
    CHECK("JOY_LIVE_CAL",c.ip[6].detail==0x3434u && c.ip[6].heartbeat_count==4); /* current calibration, no duplicate progress */
    for(i=0;i<3;i++) {
        uint32_t hb=c.ip[6].heartbeat_count;
        publish(14+i,22+i,(uint8_t)i,2500,2048);step(&c,&p,soc_health_adc_service);
        CHECK("ADC_VALIDITY",c.ip[5].state==SOC_HB_FAIL && c.ip[6].heartbeat_count==hb);
    }
    reset(&c,&p);adc_boot(&c,&p);hw.joy_corrupt=1;publish(1,4,3,2048,2048);step(&c,&p,soc_health_adc_service);
    CHECK("JOY_MISMATCH",c.ip[6].state==SOC_HB_FAIL && c.ip[6].heartbeat_count==0 && c.ip[6].detail==0x50003031u);
    hw.joy_corrupt=0;publish(2,9,3,2048,2048);step(&c,&p,soc_health_adc_service);
    CHECK("JOY_RECOVERY",c.ip[6].state==SOC_HB_PASS && (c.sticky_fail_mask&64u));
    hw.adc_error=4;publish(3,15,3,2048,2048);step(&c,&p,soc_health_adc_service);
    CHECK("ADC_ERROR",c.ip[5].state==SOC_HB_FAIL && c.ip[5].detail==0x41000004u && hw.adc_error==4);
    reset(&c,&p);hw.adc_identity=0;step(&c,&p,soc_health_adc_service);CHECK("ADC_IDENTITY",c.ip[5].state==SOC_HB_FAIL && !hw.adc_enabled);
    reset(&c,&p);hw.adc_ack=0;for(i=0;i<23;i++)step(&c,&p,soc_health_adc_service);CHECK("ADC_ENABLE_TIMEOUT",c.ip[5].miss_count>0);
    reset(&c,&p);adc_boot(&c,&p);for(i=0;i<22;i++)step(&c,&p,soc_health_adc_service);CHECK("ADC_NO_NEW",c.ip[5].miss_count>0 && c.ip[5].heartbeat_count==0);
    reset(&c,&p);adc_boot(&c,&p);publish(1,0,3,2048,2048);step(&c,&p,soc_health_adc_service);CHECK("ADC_PRODUCER_FROZEN",c.ip[5].heartbeat_count==0);
    reset(&c,&p);adc_boot(&c,&p);
    publish(0xfffffffeu,1u,3,2048,2048);step(&c,&p,soc_health_adc_service);
    publish(1u,2u,3,2048,2048);step(&c,&p,soc_health_adc_service);
    CHECK("ADC_SEQ_WRAP",c.progress_token[5]==1u && c.ip[5].heartbeat_count==2);
    /* Pure policy validity oracle covers all defined bits independently. */
    for(i=0;i<4;i++) {adc_frame_t f={0};f.valid_mask=(uint8_t)i;f.ch[0]=4000;f.ch[1]=0;CHECK("JOY_VALID_BITS",joystick_policy_eval(&f,&hw.cal)==independent_joy(&f,&hw.cal));}
    puts("CASE adc_joy_coherence PASS");
}
static void vga_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i;
    reset(&c,&p);hw.vga_status|=3u;
    for(i=0;i<4;i++)step(&c,&p,soc_health_vga_service);
    CHECK("VGA_STALE",c.ip[7].heartbeat_count==0 && hw.swaps==0);
    hw.vga_status|=2u;step(&c,&p,soc_health_vga_service);CHECK("VGA_CLEAR_ONLY",hw.swaps==0 && c.ip[7].heartbeat_count==0);
    hw.vga_status|=1u;step(&c,&p,soc_health_vga_service);CHECK("VGA_ISSUED",hw.swaps==1 && c.ip[7].heartbeat_count==0 && !(hw.vga_status&2u));
    hw.vga_status=(hw.vga_status&~4u)|2u;step(&c,&p,soc_health_vga_service);
    CHECK("VGA_GENERATION",c.progress_token[7]==1 && c.ip[7].heartbeat_count==1);
    hw.vga_status|=3u;for(i=0;i<5;i++)step(&c,&p,soc_health_vga_service);
    CHECK("VGA_NEXT_FRESH",hw.swaps==1 && c.ip[7].heartbeat_count==1);
    hw.vga_status|=8u;step(&c,&p,soc_health_vga_service);CHECK("VGA_ABORT",c.ip[7].state==SOC_HB_FAIL && (c.ip[7].detail&8u));
    reset(&c,&p);hw.vga_status=0;for(i=0;i<22;i++)step(&c,&p,soc_health_vga_service);CHECK("VGA_NOT_READY",c.ip[7].miss_count>0 && hw.words==0);
    reset(&c,&p);for(i=0;i<22;i++)step(&c,&p,soc_health_vga_service);CHECK("VGA_TIMEOUT",c.ip[7].miss_count>0 && hw.swaps==0);
    puts("CASE vga_fresh_ownership PASS");
}
static void fairness_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;uint32_t i,observed[12]={0};const soc_health_snapshot_t *n;unsigned char saved[sizeof(*n)];
    reset(&c,&p);p.budget=200; /* 12 TX bytes across ten-way service need >=120 epochs */
    hw.adc_identity=0;hw.gs_valid=1;hw.loop=1;
    n=soc_health_publish_snapshot(&c);memcpy(saved,n,sizeof(saved));
    for(i=0;i<1005;i++) {soc_health_epoch_begin(&c);hw.gs_seq=i+1;timer_tick(10);soc_ip_id_t id=soc_health_providers_service(&c,&p);CHECK("DISPATCH_ID",(unsigned)id<12u);observed[id]++;}
    for(i=1;i<11;i++) CHECK("FAIRNESS_VISITS",p.visits[i]==observed[i] && observed[i]==100u+((i==1||i==2||i==4||i==5||i==7)?1u:0u));
    CHECK("FAIRNESS_FAILURE",c.ip[5].state==SOC_HB_FAIL && c.ip[4].heartbeat_count>90 && c.ip[2].heartbeat_count>0);
    CHECK("PROVIDER_IMMUTABLE",memcmp(saved,n,sizeof(saved))==0);
    CHECK("S4_EXCLUDED",c.ip[3].state==SOC_HB_UNKNOWN && c.ip[8].state==SOC_HB_UNKNOWN && c.ip[9].state==SOC_HB_UNKNOWN && c.ip[10].state==SOC_HB_UNKNOWN && c.ip[11].state==SOC_HB_EXCLUDED && p.visits[11]==0);
    const soc_health_snapshot_t *next=soc_health_publish_snapshot(&c);
    CHECK("PROVIDER_MASKS",(next->fail_mask&32u) && (next->sticky_fail_mask&32u) && (next->pass_mask&16u));
    puts("CASE provider_fairness_snapshot PASS");
}
int main(void)
{
    timer_tests();uart_tests();gsensor_tests();adc_joy_tests();vga_tests();fairness_tests();
    puts("SUMMARY: PASS SOC_HEALTH_S3");return 0;
}
