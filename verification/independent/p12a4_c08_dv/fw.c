/* Reuse accepted independent register model and existing provider cases;
 * new diagnostic stimulus/oracles below use raw register inputs. */
#define soc_health_test_write legacy_test_write
#define soc_health_test_read legacy_test_read
#define main legacy_main
#include "../../firmware/soc_health_provider_host.c"
#undef main
#undef soc_health_test_write
#undef soc_health_test_read
static unsigned status_reads, fault_on_read;
uint32_t soc_health_test_read(uint32_t a)
{ if(a==VRAM_BASE+VRAM_STATUS && ++status_reads==fault_on_read) hw.vga_status|=32u;return legacy_test_read(a); }
void soc_health_test_write(uint32_t a,uint32_t v)
{ if(a==VRAM_BASE+VRAM_STATUS) {hw.writes++;hw.vga_status&=~(v&43u);} else legacy_test_write(a,v); }
#include "soc_health_observers.h"
static unsigned released, release_success;
static void release_hook(soc_health_core_t *c,void *ctx,int success)
{ (void)c;(void)ctx;released++;release_success+=(unsigned)success; }
static void diagnostic_tests(void)
{
 soc_health_core_t c;soc_health_providers_t p;
 reset(&c,&p);unsigned r=hw.reads;uint32_t raw=0xffff0030u;
 CHECK("FW_EXTRACT",vram_status_lock_loss_count(raw)==65535 && vram_status_is_cdc(raw)==1);
 CHECK("FW_EXTRACT_PURE",hw.reads==r);
 hw.vga_status=0x12340030u;
 raw=vram_status();CHECK("FW_SINGLE_READ",hw.reads==r+1 && raw==0x12340030u);
 r=hw.writes;vram_clear_events(0xffffffffu);
 CHECK("FW_ROUTINE_MASK",hw.writes==r+1 && hw.vga_status==0x12340030u);
 vram_clear_cdc_fault();CHECK("FW_CLEAR_MASK",hw.vga_status==0x12340010u);
 reset(&c,&p);hw.vga_status=0xffff0010u;
 step(&c,&p,soc_health_vga_service);
 CHECK("FW_COUNT_NO_PASS",c.ip[7].heartbeat_count==0 && c.ip[7].state!=SOC_HB_PASS && c.ip[7].detail==0xffff0010u);
 p.vga_release=release_hook;released=release_success=0;
 hw.vga_status=0x45670030u;r=hw.writes;
 step(&c,&p,soc_health_vga_service);
 CHECK("FW_FAULT_REPORT",c.ip[7].state==SOC_HB_FAIL && c.ip[7].detail==0x45670030u);
 CHECK("FW_BEFORE_CLEAR",hw.writes==r && hw.vga_status==0x45670030u);
 CHECK("FW_RELEASE",released==1 && release_success==0 && !p.vga.deadline.armed);
 vram_clear_cdc_fault();CHECK("FW_EXPLICIT_CLEAR",hw.vga_status==0x45670010u);
 step(&c,&p,soc_health_vga_service);
 CHECK("FW_FAIL_DETAIL_RETAIN",c.ip[7].detail==0x45670030u && c.ip[7].heartbeat_count==0);
 // Existing ABORT tag remains when there is no diagnostic fault.
 reset(&c,&p);hw.vga_status=0x00120018u;step(&c,&p,soc_health_vga_service);
 CHECK("FW_ABORT_TAG",c.ip[7].detail==0x60120018u);
 // Reach fresh VSYNC phase through the real sequence, inject fault only on
 // the second STATUS read of that visit, before start_operation can clear.
 reset(&c,&p);for(unsigned i=0;i<3;i++)step(&c,&p,soc_health_vga_service);
 hw.vga_status|=1u;status_reads=0;fault_on_read=2;
 step(&c,&p,soc_health_vga_service);fault_on_read=0;
 CHECK("FW_PRESWAP_FAULT",hw.swaps==0 && c.ip[7].state==SOC_HB_FAIL && (c.ip[7].detail&32u));
 // Real observer lease is released on diagnostic failure, UART lease survives.
 reset(&c,&p);soc_health_observers_t obs;soc_health_observers_init(&obs);
 const soc_health_snapshot_t *leased=soc_health_publish_snapshot(&c);
 CHECK("FW_LEASE_BEGIN",soc_health_observers_begin(&obs,leased,c.epoch));
 unsigned char saved[sizeof(*leased)];memcpy(saved,leased,sizeof(saved));
 p.vga_context=&obs;p.vga_release=soc_health_observers_vga_release;
 hw.vga_status=0xabcd0030u;step(&c,&p,soc_health_vga_service);
 CHECK("FW_REAL_LEASE",obs.vga_snapshot==0 && obs.uart_snapshot==leased && obs.pending==SOC_OBSERVER_UART && c.slot[0].readers==SOC_OBSERVER_UART);
 CHECK("FW_FROZEN_SNAPSHOT",memcmp(saved,leased,sizeof(saved))==0);
 // Pure formatter receives frozen record including saturation, with no MMIO.
 soc_health_snapshot_t snap;memset(&snap,0,sizeof(snap));
 snap.ip[7].state=SOC_HB_PASS;snap.ip[7].detail=0xffff0010u;
 char line[48];r=hw.reads;soc_health_format_line(&snap,12,line,sizeof(line));
 CHECK("FW_FORMAT_COUNT",strstr(line,"SWAP L=FFFF C=0")!=0 && hw.reads==r);
 snap.ip[7].state=SOC_HB_FAIL;snap.ip[7].detail=0x12340030u;
 soc_health_format_line(&snap,12,line,sizeof(line));CHECK("FW_FORMAT_FAULT",strstr(line,"D=12340030")!=0);
 puts("CASE c08_diagnostic_independent PASS");
}
int main(void){int rc=legacy_main();diagnostic_tests();return rc;}
