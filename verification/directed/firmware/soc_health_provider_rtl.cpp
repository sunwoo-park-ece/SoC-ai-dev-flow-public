#include "Vsoc_health_provider_top.h"
#include "verilated.h"
extern "C" {
#include "soc_health_providers.h"
#include "soc_memory_map.h"
#include "adc.h"
}
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#define CHECK(tag,expr) do {if(!(expr)){fprintf(stderr,"ASSERT %s at %d cycle=%llu: %s\n",tag,__LINE__,(unsigned long long)cycles,#expr);exit(1);}}while(0)
static Vsoc_health_provider_top hw;
static uint64_t cycles;
static unsigned accesses,tx_count,rx_count,adc_captures,gs_captures,gs_releases;
static unsigned timer_starts,timer_acks,swap_requests;
static uint8_t tx_bytes[12];
static bool hold_seen;
static uint32_t hold_seq,latest_published;
static uint16_t source_x,source_y,held_x,held_y;
static unsigned center_x=2048,center_y=2048,deadzone=300;
static uint32_t reference_joy()
{
 int dx=(int)held_x-(int)center_x,dy=(int)held_y-(int)center_y;int dz=(int)deadzone;
 return 48u|(dx>dz?8u:0u)|(dx< -dz?4u:0u)|(dy>dz?1u:0u)|(dy< -dz?2u:0u);
}
static void tick(unsigned n=1)
{
 for(unsigned i=0;i<n;i++){
  hw.clk=0;hw.eval();hw.clk=1;hw.eval();cycles++;hw.clk=0;hw.eval();
 }
}
static uint32_t access(uint32_t addr,bool write,uint32_t value)
{
 accesses++;CHECK("BUS_ALIGNMENT",!(addr&3));uint32_t result=0;
 if((addr>>28)==2){
  hw.haddr=addr;hw.hwrite=write;hw.hwdata=value;hw.hsel=1;hw.htrans=2;hw.eval();
  unsigned waits=0;while(!hw.hready){CHECK("BUS_BOUNDED",++waits<100);tick();}
  tick();hw.hsel=0;hw.htrans=0;hw.eval();waits=0;
  while(!hw.hready){CHECK("BUS_BOUNDED",++waits<100);tick();}
  CHECK("AHB_OKAY",hw.hresp==0);result=hw.hrdata;tick();
 }else{
  hw.address=addr;hw.wdata=value;hw.write=write;hw.select=1;hw.enable=0;tick();hw.enable=1;hw.eval();
  unsigned waits=0;while(!hw.ready){CHECK("BUS_BOUNDED",++waits<100);tick();}
  CHECK("APB_OKAY",!hw.error);result=hw.rdata;tick();hw.select=hw.enable=0;tick();
 }
 if(write){
  if(addr==TIMER_BASE+TIMER_CTRL && (value&1))timer_starts++;
  if(addr==TIMER_BASE+TIMER_STATUS && (value&1))timer_acks++;
  if(addr==UART0_BASE+UART_DATA){if(tx_count<12)tx_bytes[tx_count]=(uint8_t)value;tx_count++;}
  if(addr==GSENSOR_BASE+0x10){if(value==1)gs_captures++;if(value==2)gs_releases++;}
  if(addr==ADC_BASE+ADC_CTRL && (value&2)){adc_captures++;hold_seen=true;hold_seq=latest_published;held_x=source_x;held_y=source_y;}
  if(addr==VRAM_BASE+VRAM_CONTROL){CHECK("REAL_SWAP_ONLY",value==1);CHECK("ONE_PREPARE_PER_SWAP",hw.framebuffer_commits==swap_requests+1);swap_requests++;}
 }else{
  if(addr==UART1_BASE+UART_DATA)rx_count++;
  if(addr==ADC_BASE+ADC_FRAME_SEQ)CHECK("HOLD_ORACLE",hold_seen && result==hold_seq);
  if(addr==ADC_BASE+ADC_JOY_STATUS)CHECK("HW_POLICY_ORACLE",result==reference_joy());
 }
 return result;
}
extern "C" uint32_t soc_health_test_read(uint32_t addr){return access(addr,false,0);}
extern "C" void soc_health_test_write(uint32_t addr,uint32_t value){(void)access(addr,true,value);}
static void publication(uint32_t seq,uint16_t x,uint16_t y)
{
 latest_published=seq;source_x=x;source_y=y;hw.adc_seq=seq;hw.adc_valid=3;
 hw.adc_samples[0]=x|((uint32_t)y<<12);hw.adc_samples[1]=hw.adc_samples[2]=0;
 hw.adc_frame_pulse=1;tick();hw.adc_frame_pulse=0;tick();

}
int main(int argc,char**argv)
{
 Verilated::commandArgs(argc,argv);hw.reset_n=0;hw.gs_miso=0;hw.gs_irq=0;tick(10);hw.reset_n=1;tick(100);
 soc_health_core_t c;soc_health_providers_t p;soc_health_init(&c);soc_health_providers_init(&p);
 CHECK("CAL_RESET",soc_health_test_read(ADC_BASE+ADC_JOY_CENTER_X)==2048 && soc_health_test_read(ADC_BASE+ADC_JOY_CENTER_Y)==2048 && soc_health_test_read(ADC_BASE+ADC_JOY_DEADZONE)==300);
 uint32_t previous[12]={0};unsigned published=0;
 for(unsigned turn=0;turn<12000;turn++){
  // Source publication enters the documented PCLK mailbox boundary, never HOLD.
  if(turn%100==50){++published;publication(published,published%2?2348:2500,published%2?1748:1700);}
  hw.gs_irq=(turn%100>=50); // deterministic sensor interrupt peer; MISO static zero
  soc_health_epoch_begin(&c);unsigned before=accesses;
  (void)soc_health_providers_service(&c,&p);CHECK("RTL_SERVICE_BOUND",accesses-before<=40);
  for(unsigned id=1;id<8;id++){
   if(c.ip[id].heartbeat_count!=previous[id]){
    CHECK("ONE_EVENT",c.ip[id].heartbeat_count==previous[id]+1);
    if(id==1)CHECK("TIMER_TRANSACTION",timer_acks>0 && timer_starts>=2);
    if(id==2)CHECK("UART_TRANSACTION",tx_count>=12 && rx_count>=12 && c.progress_token[id]>0);
    if(id==4)CHECK("GS_TRANSACTION",gs_captures==gs_releases && gs_captures>0 && c.progress_token[id]>0);
    if(id==5||id==6)CHECK("ADC_JOY_TRANSACTION",adc_captures>0 && c.progress_token[id]==hold_seq);
    if(id==7)CHECK("VGA_TRANSACTION",swap_requests==hw.swap_commits && c.progress_token[id]<=swap_requests);
    previous[id]=c.ip[id].heartbeat_count;
   }
  }
  tick(200); // simulated bus/service spacing, not a real-time scheduling claim
 }
 uint8_t expected[12]={0xa5,0x5a,1,0,0,0,0xfe,0xff,0xff,0xff,0xc3,0x3c};
 CHECK("SERIAL_FRAME",tx_count>=12 && !memcmp(tx_bytes,expected,12));
 for(unsigned id: {1u,2u,4u,5u,6u,7u})CHECK("REAL_PROVIDER_PROGRESS",c.ip[id].heartbeat_count>=2 && c.ip[id].state==SOC_HB_PASS);
 CHECK("VGA_ACCEPTED_WRITES",swap_requests==hw.swap_commits && hw.framebuffer_commits>=swap_requests && hw.framebuffer_commits<=swap_requests+1);
 // Live calibration changes are checked over the retained HOLD, without CAPTURE.
 unsigned captures_before=adc_captures,joy_before=c.ip[6].heartbeat_count;
 adc_set_calibration(0,4095,100);center_x=0;center_y=4095;deadzone=100;
 soc_health_joy_service(&c,&p);CHECK("LIVE_CAL_NO_CAPTURE",adc_captures==captures_before && c.ip[6].heartbeat_count==joy_before && c.ip[6].state==SOC_HB_PASS);
 publication(++published,0,4095);soc_health_adc_service(&c,&p);
 CHECK("SATURATED_SAME_HOLD",c.progress_token[6]==published && c.ip[6].detail==0x3030);
 CHECK("AES_EXCLUDED",c.ip[11].state==SOC_HB_EXCLUDED && p.visits[11]==0);
 printf("OBS cycles=%llu timer=%u uart=%u gs=%u adc=%u joy=%u vga=%u swaps=%u words=%u\n",(unsigned long long)cycles,c.ip[1].heartbeat_count,c.ip[2].heartbeat_count,c.ip[4].heartbeat_count,c.ip[5].heartbeat_count,c.ip[6].heartbeat_count,c.ip[7].heartbeat_count,hw.swap_commits,hw.framebuffer_commits);
 puts("CASE real_timer_driver_provider PASS");puts("CASE simulated_uart_serial_loopback PASS");puts("CASE real_gsensor_snapshot_driver_provider PASS");puts("CASE real_adc_hold_joy_driver_provider PASS");puts("CASE real_vga_swap_driver_provider PASS");puts("SUMMARY: PASS SOC_HEALTH_S3_RTL");return 0;
}
