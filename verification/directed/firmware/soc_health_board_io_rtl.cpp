#include "Vsoc_health_board_io_top.h"
#include "verilated.h"
extern "C" {
#include "soc_health_board_io.h"
#include "soc_memory_map.h"
#include "hex_display.h"
}
#include <cstdio>
#include <cstdlib>
#include <cstring>
#define CHECK(tag,e) do{if(!(e)){fprintf(stderr,"ASSERT %s line=%d cycles=%llu: %s\n",tag,__LINE__,(unsigned long long)cycles,#e);exit(1);}}while(0)
static Vsoc_health_board_io_top hw;
static uint64_t cycles;
static unsigned accesses,sw_reads,ctrl_state,drive_count,drives[256];
static void tick(unsigned n=1)
{
 for(unsigned i=0;i<n;i++){hw.clk=0;hw.eval();hw.clk=1;hw.eval();cycles++;hw.clk=0;hw.eval();}
}
static uint32_t access(uint32_t a,bool w,uint32_t v)
{
 accesses++;hw.address=a;hw.wdata=v;hw.write=w;hw.select=1;hw.enable=0;tick();hw.enable=1;hw.eval();
 CHECK("READY_BOUNDED",hw.ready);uint32_t r=hw.rdata;tick();hw.select=hw.enable=0;tick();
 if(w){
  if(a==HEX_DISPLAY_BASE+HEX_CTRL)ctrl_state=v&3;
  if(a==HEX_DISPLAY_BASE+HEX_VALUE||a==HEX_DISPLAY_BASE+HEX_RAW_LOW||a==HEX_DISPLAY_BASE+HEX_RAW_HIGH)
   CHECK("SAFE_DISABLED_DATA_WRITES",!(ctrl_state&1));
  if(a==GPIO_BASE+GPIO_DATA_OUT){if(drive_count<256)drives[drive_count]=v&1;drive_count++;CHECK("REAL_GPIO_OUTPUT_PIN",hw.drive_pin==(v&1));}
 }else if(a==SW_BASE)sw_reads++;
 return r;
}
extern "C" uint32_t soc_health_test_read(uint32_t a){return access(a,false,0);}
extern "C" void soc_health_test_write(uint32_t a,uint32_t v){(void)access(a,true,v);}
static void visit(soc_health_core_t *c,soc_health_board_io_t *b,soc_ip_id_t id)
{
 tick(10);soc_health_epoch_begin(c);unsigned before=accesses;
 soc_health_board_io_service(c,b,id);CHECK("BOUNDED_VISIT",accesses-before<=10);
}
static uint32_t digit(uint32_t s,unsigned d)
{
 static const unsigned map[4][6]={{1,1,1,1,1,1},{1,1,1,0,0,0},{0,0,0,1,1,1},{1,2,1,2,1,2}};
 static const unsigned seg[16]={0x40,0x79,0x24,0x30,0x19,0x12,2,0x78,0,0x10,8,3,0x46,0x21,6,0x0e};
 if(!(s&512))return seg[(s>>(4*(d%3)))&15];
 unsigned k=map[(s>>7)&3][d];return k==0?127:k==1?127-(s&127):s&127;
}
static void command(soc_health_core_t *c,soc_health_board_io_t *b,unsigned s)
{
 unsigned reads=sw_reads;hw.switches=s;tick(3);visit(c,b,SOC_IP_SW);
 unsigned gen=b->sw_generation;CHECK("CANONICAL_ONE_CAPTURE",sw_reads==reads+1 && b->sw_value==s);
 visit(c,b,SOC_IP_LED);hw.switches=s^1023;tick(3);
 for(unsigned i=0;i<5;i++){visit(c,b,SOC_IP_SW);CHECK("SHARED_GENERATION_RETAINED",sw_reads==reads+1);visit(c,b,SOC_IP_HEX);if(i<3)CHECK("HEX_STAYS_DISABLED",ctrl_state%2==0);}
 CHECK("REGISTER_TRANSACTION_COMPLETED",c->ip[SOC_IP_HEX].state==SOC_HB_PASS && c->progress_token[SOC_IP_HEX]==gen);
 CHECK("LED_PIN_ORACLE",hw.leds==s);
 for(unsigned d=0;d<6;d++)CHECK("HEX_SEGMENT_ORACLE",((hw.segments>>(7*d))&127)==digit(s,d));
 CHECK("COMPLETE_MIRROR_COMMAND_TOKENS",c->progress_token[SOC_IP_LED]==gen && c->progress_token[SOC_IP_HEX]==gen && b->pending==0);
 CHECK("REGISTER_READBACK_CLASS",c->ip[SOC_IP_LED].evidence==SOC_EV_REGISTER_READBACK && c->ip[SOC_IP_HEX].evidence==SOC_EV_REGISTER_READBACK);
}
int main(int argc,char **argv)
{
 Verilated::commandArgs(argc,argv);hw.reset_n=0;tick(5);hw.reset_n=1;tick(5);
 soc_health_core_t c;soc_health_board_io_t b;soc_health_init(&c);soc_health_board_io_init(&b);b.budget=40;
 for(unsigned i=0;i<16;i++){visit(&c,&b,SOC_IP_GPIO);CHECK("FULL_CYCLE_ONLY",c.ip[3].heartbeat_count==(i==15?1u:0u));}
 CHECK("REAL_DRIVE_CYCLE",drive_count==4 && drives[0]==0 && drives[1]==1 && drives[2]==1 && drives[3]==0);
 for(unsigned f=1;f<=3;f++){
  hw.loop_fault=f;unsigned before=c.ip[3].heartbeat_count,miss=c.ip[3].miss_count;
  for(unsigned i=0;i<42;i++)visit(&c,&b,SOC_IP_GPIO);
  CHECK("REAL_SENSE_FAULT_REJECT",c.ip[3].heartbeat_count==before && c.ip[3].miss_count==miss+1 && c.ip[3].state==SOC_HB_FAIL);
  hw.loop_fault=0;for(unsigned i=0;i<20;i++)visit(&c,&b,SOC_IP_GPIO);
  CHECK("REAL_GPIO_RECOVERY",c.ip[3].state==SOC_HB_PASS && (c.sticky_fail_mask&8));
 }
 puts("CASE simulated_gpio_loop_cycle_faults PASS");
 b.budget=200;command(&c,&b,0);command(&c,&b,0x12a);command(&c,&b,0x1ff);
 for(unsigned g=0;g<4;g++)for(unsigned v=0;v<9;v++)command(&c,&b,512|(g<<7)|(v==0?0:v==1?127:1u<<(v-2)));
 command(&c,&b,0x12a);command(&c,&b,0x12a);
 CHECK("STATIC_SWITCH_INPUT_OBSERVATION",c.ip[8].state==SOC_HB_PASS && c.ip[8].evidence==SOC_EV_INPUT_OBSERVATION);
 CHECK("AES_EXCLUDED",c.ip[11].state==SOC_HB_EXCLUDED);
 printf("OBS cycles=%llu gpio=%u observations=%u led=%u hex=%u raw_vectors=36 decoder_vectors=5\n",(unsigned long long)cycles,c.ip[3].heartbeat_count,c.ip[8].heartbeat_count,c.ip[9].heartbeat_count,c.ip[10].heartbeat_count);
 puts("CASE real_sw_led_shared_generation PASS");puts("CASE real_hex_register_segments_matrix PASS");
 puts("SUMMARY: PASS SOC_HEALTH_S4A_RTL");return 0;
}
