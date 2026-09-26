#include "Vsoc_health_observer_top.h"
#include "verilated.h"
extern "C" {
#include "soc_health_providers.h"
#include "soc_memory_map.h"
#include "adc.h"
#include "soc_health_observers.h"
#include "soc_health_observer_reference.h"
}
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#define CHECK(tag,expr) do {if(!(expr)){fprintf(stderr,"ASSERT %s at %d cycle=%llu: %s\n",tag,__LINE__,(unsigned long long)cycles,#expr);exit(1);}}while(0)
static Vsoc_health_observer_top hw;
static uint64_t cycles;
static unsigned accesses,tx_count,rx_count,adc_captures,gs_captures,gs_releases;
static unsigned timer_starts,timer_acks,swap_requests;
static uint8_t tx_bytes[12];
static uint32_t expected_pixels[9600],actual_pixels[9600];
static unsigned reference_back=1,fb_seen,pc_writes,initial[12];
static bool awaiting_swap,fb_expected;
static uint32_t expected_offset,expected_data;
static char serial_pc[4096];static unsigned pc_bytes;
static bool last_tx=true;static int rx_bit=-2;static uint8_t rx_byte;static uint64_t rx_due;
static void serial_monitor()
{
 bool pin=hw.uart1_tx;
 if(rx_bit==-2){if(last_tx && !pin){rx_bit=-1;rx_due=cycles+217;rx_byte=0;}}
 else if(cycles==rx_due){
  if(rx_bit==-1)CHECK("SERIAL_START",!pin);
  else if(rx_bit<8)rx_byte|=(uint8_t)(pin?1u<<rx_bit:0u);
  else {CHECK("SERIAL_STOP",pin && pc_bytes<sizeof(serial_pc));serial_pc[pc_bytes++]=(char)rx_byte;rx_bit=-2;}
  if(rx_bit!=-2){rx_bit++;rx_due+=434;}
 }
 last_tx=pin;
}
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
  hw.clk=0;hw.eval();
  if(hw.fb_we){CHECK("NO_ORPHAN_FB_COMMIT",fb_expected && hw.fb_offset==expected_offset && hw.fb_data==expected_data);CHECK("COMMIT_OFFSET",hw.fb_offset<9600);CHECK("INDEPENDENT_BACK_BANK",hw.fb_bank==reference_back && hw.front_bank!=reference_back);actual_pixels[hw.fb_offset]=hw.fb_data;fb_seen++;}
  hw.clk=1;hw.eval();cycles++;hw.clk=0;hw.eval();serial_monitor();
 }
}
static uint32_t access(uint32_t addr,bool write,uint32_t value)
{
 accesses++;CHECK("BUS_ALIGNMENT",!(addr&3));uint32_t result=0;unsigned before_fb=fb_seen;
 fb_expected=write && addr>=VRAM_BASE && addr<VRAM_BASE+9600u*4u;expected_offset=(addr-VRAM_BASE)/4;expected_data=value;
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
  if(addr==UART1_BASE+UART_DATA)pc_writes++;
  if(addr>=VRAM_BASE && addr<VRAM_BASE+9600u*4u){CHECK("EXACT_ONE_ACCEPTED_FB_COMMIT",fb_seen==before_fb+1);CHECK("COMMIT_ADDRESS_DATA",actual_pixels[(addr-VRAM_BASE)/4]==value);}
  if(addr==VRAM_BASE+VRAM_CONTROL){CHECK("REAL_SWAP_ONLY",value==1);CHECK("INDEPENDENT_COMPLETE_FRAME",!memcmp(actual_pixels,expected_pixels,sizeof(actual_pixels)) && fb_seen>9600);CHECK("NO_DUPLICATE_SWAP",!awaiting_swap);awaiting_swap=true;swap_requests++;}
 }else{
  if(addr==UART1_BASE+UART_DATA)rx_count++;
  if(addr==VRAM_BASE+VRAM_STATUS && awaiting_swap && (result&2) && !(result&4)){reference_back^=1;awaiting_swap=false;CHECK("PRESENTED_REFERENCE_BANK",hw.front_bank==(reference_back^1u));}
  if(addr==ADC_BASE+ADC_FRAME_SEQ)CHECK("HOLD_ORACLE",hold_seen && result==hold_seq);
  if(addr==ADC_BASE+ADC_JOY_STATUS)CHECK("HW_POLICY_ORACLE",result==reference_joy());
 }
 fb_expected=false;return result;
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
 soc_health_observers_t observer;reference_seed(&c);soc_health_observers_init(&observer);
 const soc_health_snapshot_t *n=soc_health_publish_snapshot(&c);CHECK("BEGIN_N",soc_health_observers_begin(&observer,n,c.epoch));
 p.vga_context=&observer;p.vga_prepare=soc_health_observers_vga_prepare;p.vga_release=soc_health_observers_vga_release;
 reference_frame(n,expected_pixels);char expected_pc[2048];unsigned expected_length=reference_uart(n,expected_pc);
 const soc_health_snapshot_t expected_snapshot=*n;
 unsigned char saved[sizeof(*n)];memcpy(saved,n,sizeof(saved));
 for(unsigned id=0;id<12;id++)initial[id]=c.ip[id].heartbeat_count;
 CHECK("CAL_RESET",soc_health_test_read(ADC_BASE+ADC_JOY_CENTER_X)==2048 && soc_health_test_read(ADC_BASE+ADC_JOY_CENTER_Y)==2048 && soc_health_test_read(ADC_BASE+ADC_JOY_DEADZONE)==300);
 uint32_t previous[12];memcpy(previous,initial,sizeof(previous));unsigned published=0;
 for(unsigned turn=0;turn<40000;turn++){
  // Source publication enters the documented PCLK mailbox boundary, never HOLD.
  if(turn%100==50){++published;publication(published,published%2?2348:2500,published%2?1748:1700);}
  hw.gs_irq=(turn%100>=50); // deterministic sensor interrupt peer; MISO static zero
  soc_health_epoch_begin(&c);unsigned before=accesses;
  (void)soc_health_providers_service(&c,&p);soc_health_observers_uart_service(&c,&observer);
  if(observer.pending)CHECK("RTL_FROZEN_N",!memcmp(saved,n,sizeof(saved)));CHECK("RTL_SERVICE_BOUND",accesses-before<=40);
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
 for(unsigned id: {1u,2u,4u,5u,6u})CHECK("REAL_PROVIDER_PROGRESS",c.ip[id].heartbeat_count>=initial[id]+2 && c.ip[id].state==SOC_HB_PASS);
 CHECK("ONE_N_ONE_FRAME",c.ip[7].heartbeat_count==initial[7]+1 && swap_requests==1 && observer.pending==0);
 CHECK("SERIAL_EXACT_SNAPSHOT",pc_bytes==expected_length && pc_writes==expected_length && !memcmp(serial_pc,expected_pc,expected_length));
 CHECK("PC_NO_ANSI",!memchr(serial_pc,27,pc_bytes));
 CHECK("VGA_ACCEPTED_WRITES",swap_requests==hw.swap_commits && hw.framebuffer_commits==fb_seen && !awaiting_swap);
 // Live calibration changes are checked over the retained HOLD, without CAPTURE.
 unsigned captures_before=adc_captures,joy_before=c.ip[6].heartbeat_count;
 adc_set_calibration(0,4095,100);center_x=0;center_y=4095;deadzone=100;
 soc_health_joy_service(&c,&p);CHECK("LIVE_CAL_NO_CAPTURE",adc_captures==captures_before && c.ip[6].heartbeat_count==joy_before && c.ip[6].state==SOC_HB_PASS);
 publication(++published,0,4095);soc_health_adc_service(&c,&p);
 CHECK("SATURATED_SAME_HOLD",c.progress_token[6]==published && c.ip[6].detail==0x3030);
 CHECK("AES_EXCLUDED",c.ip[11].state==SOC_HB_EXCLUDED && p.visits[11]==0);
 printf("OBS cycles=%llu timer=%u uart=%u gs=%u adc=%u joy=%u vga=%u swaps=%u words=%u\n",(unsigned long long)cycles,c.ip[1].heartbeat_count,c.ip[2].heartbeat_count,c.ip[4].heartbeat_count,c.ip[5].heartbeat_count,c.ip[6].heartbeat_count,c.ip[7].heartbeat_count,hw.swap_commits,hw.framebuffer_commits);
 puts("CASE real_timer_driver_provider PASS");puts("CASE simulated_uart_serial_loopback PASS");puts("CASE real_gsensor_snapshot_driver_provider PASS");puts("CASE real_adc_hold_joy_driver_provider PASS");puts("CASE real_vga_swap_driver_provider PASS");if(argc>1){FILE *f=fopen(argv[1],"wb");CHECK("FRAME_ARTIFACT_OPEN",f);fputs("P4\n640 480\n",f);
 for(unsigned y=0;y<480;y++)for(unsigned bx=0;bx<80;bx++){unsigned byte=0;for(unsigned bit=0;bit<8;bit++){unsigned x=bx*8+bit;byte|=((actual_pixels[y*20+x/32]>>(x%32))&1u)<<(7-bit);}fputc((int)byte,f);}CHECK("FRAME_ARTIFACT_CLOSE",fclose(f)==0);}
 printf("OBS PC serial bytes=%u framebuffer commits=%u frozen EP=%08X SIG=%08X\n",pc_bytes,fb_seen,expected_snapshot.epoch,expected_snapshot.signature);
 puts("CASE real_dashboard_raster_serial_same_snapshot PASS");puts("SUMMARY: PASS SOC_HEALTH_S4B_RTL");return 0;
}
