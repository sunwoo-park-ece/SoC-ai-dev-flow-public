#define soc_health_test_read prior_read
#define soc_health_test_write prior_write
#define main prior_s3_main
#include "soc_health_provider_host.c"
#undef main
#undef soc_health_test_read
#undef soc_health_test_write
#include "soc_health_observers.h"
#include "soc_health_board_io.h"
#include "soc_health_observer_reference.h"
static uint32_t pixels[9600],expected_pixels[9600],frame_writes,pc_ready=1;
static char pc[4096];static unsigned npc;
static unsigned observer_mode;
static uint32_t bd_dir,bd_out,bd_led,bd_sw,bd_hex[4],bd_ff1,bd_ff2;
uint32_t soc_health_test_read(uint32_t a)
{
 if(a==GPIO_BASE+GPIO_DIR)return bd_dir;
 if(a==GPIO_BASE+GPIO_DATA_OUT)return bd_out;
 if(a==GPIO_BASE+GPIO_DATA_IN)return bd_ff2<<1;
 if(a==SW_BASE)return bd_sw;
 if(a==LED_BASE)return bd_led;
 if(a>=HEX_DISPLAY_BASE && a<HEX_DISPLAY_BASE+16)return bd_hex[(a-HEX_DISPLAY_BASE)/4];
 if(a==UART1_BASE+UART_STATUS)return prior_read(a)|(pc_ready?1u:0u);
 return prior_read(a);
}
void soc_health_test_write(uint32_t a,uint32_t v)
{
 if(a==GPIO_BASE+GPIO_DIR){bd_dir=v;return;}
 if(a==GPIO_BASE+GPIO_DATA_OUT){bd_out=v;return;}
 if(a==LED_BASE){bd_led=v;return;}
 if(a>=HEX_DISPLAY_BASE && a<HEX_DISPLAY_BASE+16){bd_hex[(a-HEX_DISPLAY_BASE)/4]=v;return;}
 if(a==UART1_BASE+UART_DATA){CHECK("PC_READY",pc_ready && npc<sizeof(pc));pc[npc++]=(char)v;return;}
 if(observer_mode && a>=VRAM_BASE && a<VRAM_BASE+9600u*4u){
  CHECK("BACK_BUFFER_READY_IDLE",(hw.vga_status&20u)==16u);
  pixels[(a-VRAM_BASE)/4]=v;frame_writes++;return;
 }
 if(observer_mode && a==VRAM_BASE+VRAM_CONTROL){
  CHECK("FULL_FRAME_BEFORE_SWAP",memcmp(pixels,expected_pixels,sizeof(pixels))==0 && frame_writes>9600u);
 }
 prior_write(a,v);
}
static void init(soc_health_core_t *c,soc_health_providers_t *p,soc_health_observers_t *o)
{
 reset(c,p);reference_seed(c);soc_health_observers_init(o);p->budget=262144u;
 p->vga_context=o;p->vga_prepare=soc_health_observers_vga_prepare;p->vga_release=soc_health_observers_vga_release;
 observer_mode=1;pc_ready=1;npc=frame_writes=0;
 for(unsigned i=0;i<9600;i++)pixels[i]=0xdeadbeef;
}
static const soc_health_snapshot_t *begin(soc_health_core_t *c,soc_health_observers_t *o)
{
 const soc_health_snapshot_t *s=soc_health_publish_snapshot(c);
 CHECK("REAL_OBSERVER_BEGIN",soc_health_observers_begin(o,s,c->epoch));reference_frame(s,expected_pixels);return s;
}
static void formatter(void)
{
 soc_health_core_t c;reference_seed(&c);const soc_health_snapshot_t *s=soc_health_publish_snapshot(&c);char b[48],ref[48];unsigned char saved[sizeof(*s)];memcpy(saved,s,sizeof(saved));
 unsigned reads=hw.reads,writes=hw.writes;
 for(unsigned n=0;n<19;n++){reference_line(s,n,ref);unsigned len=soc_health_format_line(s,n,b,sizeof(b));CHECK("EXACT_COMMON_LINES",len==strlen(ref) && !strcmp(b,ref));char again[48];soc_health_format_line(s,n,again,sizeof(again));CHECK("FORMAT_DETERMINISTIC",!strcmp(b,again));}
 for(unsigned sz=0;sz<=48;sz++){
  char fenced[52];memset(fenced,0x5a,sizeof(fenced));unsigned len=soc_health_format_line(s,0,fenced+1,sz);
  CHECK("FORMAT_BOUNDS",fenced[0]==0x5a && fenced[sz+1]==0x5a && len==35);
  if(sz)CHECK("FORMAT_TERMINATION",fenced[sz-1+1]=='\0' || sz>len);
 }
 soc_health_snapshot_t synthetic=*s;char states[5]={'?','P','W','F','X'};
 for(unsigned st=0;st<5;st++){synthetic.ip[5].state=st;synthetic.ip[5].detail=0x71000004;synthetic.ip[5].miss_count=1;soc_health_format_line(&synthetic,10,b,sizeof(b));CHECK("STATE_ENCODING",b[6]==states[st]);if(st!=SOC_HB_PASS)CHECK("RAW_DETAIL_FALLBACK",strstr(b,"0001 D=71000004")!=0);}
 synthetic.ip[2].detail=0xfedcba98;soc_health_format_line(&synthetic,7,b,sizeof(b));CHECK("SEQ_ALL_32_BITS",strstr(b,"SEQ=FEDCBA98")!=0);
 synthetic.fail_mask=32;synthetic.sticky_fail_mask=36;soc_health_format_line(&synthetic,18,b,sizeof(b));CHECK("FAIL_FOOTER",!strcmp(b,"SYSTEM: FAIL F=00000020 S=00000024"));
 synthetic.ip[10].detail=0x200|0x181;soc_health_format_line(&synthetic,15,b,sizeof(b));CHECK("HEX_DETAIL_FROZEN",strstr(b,"M=1 P=181")!=0);
 CHECK("FORMAT_NO_MMIO",hw.reads==reads && hw.writes==writes);
 CHECK("FORMAT_IMMUTABLE",memcmp(saved,s,sizeof(saved))==0);
 puts("CASE exact_formatter_bounds_states PASS");
}
static void full_frame_and_uart(unsigned slow)
{
 soc_health_core_t c;soc_health_providers_t p;soc_health_observers_t o;init(&c,&p,&o);const soc_health_snapshot_t *s=begin(&c,&o);
 pc_ready=!slow;
 unsigned char saved[sizeof(*s)];memcpy(saved,s,sizeof(saved));char expected[2048];unsigned len=reference_uart(s,expected),oldhb=c.ip[7].heartbeat_count,uart_hb=c.ip[2].heartbeat_count;
 for(unsigned turn=0;turn<2000;turn++){
  soc_health_epoch_begin(&c);unsigned before=frame_writes,w=npc;
  soc_health_vga_service(&c,&p);soc_health_observers_uart_service(&c,&o);
  CHECK("OBSERVER_WORK_BOUND",frame_writes-before<=8 && npc-w<=1);
  c.ip[8].detail=turn^1023; /* live changes may never contaminate either output */
  CHECK("FROZEN_N_UNCHANGED",memcmp(saved,s,sizeof(saved))==0);
  if(o.vga_line==19)break;
  hw.vga_status|=1u; /* stale events during render are explicitly acknowledged */
 }
 soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p); /* acknowledge stale event */
 soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p);
 CHECK("NO_SWAP_ON_STALE_EVENT",hw.swaps==0 && o.vga_line==19);
 hw.vga_status|=1;for(unsigned i=0;i<3 && !hw.swaps;i++){soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p);}
 CHECK("FULL_FRAME_FRESH_SWAP",hw.swaps==1 && c.ip[7].heartbeat_count==oldhb);
 CHECK("VGA_LEASE_UNTIL_DONE",o.pending&SOC_OBSERVER_VGA);
 hw.vga_status&=~4u;soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p);
 CHECK("NO_HEARTBEAT_WITHOUT_DONE",c.ip[7].heartbeat_count==oldhb && (o.pending&SOC_OBSERVER_VGA));
 hw.vga_status|=2;soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p);
 CHECK("VGA_DONE_QUALIFIES_RELEASE",c.ip[7].heartbeat_count==oldhb+1 && !(o.pending&SOC_OBSERVER_VGA));
 CHECK("N_PRE_COMPLETION_STATE",c.slot[0].snapshot.ip[7].heartbeat_count==oldhb && memcmp(saved,&c.slot[0].snapshot,sizeof(saved))==0);
 if(slow){CHECK("VGA_FINISHES_FIRST",o.pending==SOC_OBSERVER_UART);pc_ready=1;for(unsigned i=0;i<len+2;i++){soc_health_epoch_begin(&c);soc_health_observers_uart_service(&c,&o);}}
 CHECK("PC_EXACT_CRLF_FORMAT",npc==len && !memcmp(pc,expected,len) && !memchr(pc,27,len));
 CHECK("TX_NOT_HEARTBEAT",c.ip[2].heartbeat_count==uart_hb);
 CHECK("LEASES_INDEPENDENT",o.pending==0 && o.vga_snapshot==0 && o.uart_snapshot==0 && c.slot[0].readers==0 && c.observer_last_epoch[0]==0x1234u && c.observer_last_epoch[1]==0x1234u);
 if(slow)puts("CASE coherent_frame_uart_swap_immutability PASS");
}
static void failures_leases(void)
{
 soc_health_core_t c;soc_health_providers_t p;soc_health_observers_t o;init(&c,&p,&o);const soc_health_snapshot_t *s=begin(&c,&o);unsigned char saved[sizeof(*s)];memcpy(saved,s,sizeof(saved));
 pc_ready=0;o.budget=20;
 for(unsigned i=0;i<21;i++){soc_health_epoch_begin(&c);soc_health_observers_uart_service(&c,&o);}
 CHECK("UART_TIMEOUT_ONLY_OWN_LEASE",c.observer_miss_count[1]==1 && (o.pending&SOC_OBSERVER_VGA) && !(o.pending&SOC_OBSERVER_UART) && npc==0);
 CHECK("TIMEOUT_SNAPSHOT_UNCHANGED",!memcmp(saved,s,sizeof(saved)));
 hw.vga_status|=8;soc_health_vga_service(&c,&p);
 CHECK("ABORT_RELEASE_STICKY",c.ip[7].state==SOC_HB_FAIL && (c.sticky_fail_mask&128) && c.observer_miss_count[0]==1 && o.pending==0);
 init(&c,&p,&o);s=begin(&c,&o);soc_health_observers_t other;soc_health_observers_init(&other);
 const soc_health_snapshot_t *n=soc_health_publish_snapshot(&c);CHECK("SECOND_SLOT",n && n!=s && soc_health_observers_begin(&other,n,c.epoch));
 CHECK("BOTH_SLOTS_BACKLOG",!soc_health_publish_snapshot(&c) && c.publication_backlog==1);
 soc_health_observers_vga_release(&c,&o,1);CHECK("UART_LEASE_PREVENTS_REUSE",!soc_health_publish_snapshot(&c));
 o.budget=0;soc_health_observers_uart_service(&c,&o);
 CHECK("AFTER_BOTH_RELEASE_REUSE",soc_health_publish_snapshot(&c)==s);
 init(&c,&p,&o);s=begin(&c,&o);p.budget=20;
 for(unsigned i=0;i<22;i++){soc_health_epoch_begin(&c);soc_health_vga_service(&c,&p);}
 CHECK("VGA_OWNER_DEADLINE_RELEASE",c.ip[7].miss_count==1 && c.observer_miss_count[0]==1 && o.vga_snapshot==0 && (o.pending&SOC_OBSERVER_UART));
 init(&c,&p,&o);s=begin(&c,&o);char stream[2048];unsigned length=reference_uart(s,stream);
 for(unsigned i=0;i<length;i++){soc_health_epoch_begin(&c);soc_health_observers_uart_service(&c,&o);}
 pc_ready=0;soc_health_epoch_begin(&c);soc_health_observers_uart_service(&c,&o);
 CHECK("UART_DRAIN_LEASE",o.pending&SOC_OBSERVER_UART);
 pc_ready=1;soc_health_epoch_begin(&c);soc_health_observers_uart_service(&c,&o);
 CHECK("UART_DRAIN_RELEASE",!(o.pending&SOC_OBSERVER_UART) && (o.pending&SOC_OBSERVER_VGA));
 puts("CASE observer_timeouts_abort_leases_backlog PASS");
}
static void sequences(void)
{
 soc_health_core_t c;soc_health_providers_t p;char b[48];const soc_health_snapshot_t *s;
 reset(&c,&p);hw.loop=1;for(unsigned i=0;i<14;i++)step(&c,&p,soc_health_uart_service);
 s=soc_health_publish_snapshot(&c);soc_health_format_line(s,7,b,sizeof(b));CHECK("FROZEN_UART_SEQUENCE",strstr(b,"SEQ=00000001")!=0 && s->ip[2].detail==1);
 reset(&c,&p);hw.gs_valid=1;hw.gs_seq=0x1a2;step(&c,&p,soc_health_gsensor_service);
 s=soc_health_publish_snapshot(&c);soc_health_format_line(s,9,b,sizeof(b));CHECK("FROZEN_GS_SEQUENCE",strstr(b,"SEQ=000001A2")!=0 && s->ip[4].detail==0x1a2);
 reset(&c,&p);adc_boot(&c,&p);publish(0x1a1,9,3,2048,2048);step(&c,&p,soc_health_adc_service);
 s=soc_health_publish_snapshot(&c);soc_health_format_line(s,10,b,sizeof(b));CHECK("FROZEN_ADC_SEQUENCE",strstr(b,"SEQ=000001A1")!=0 && s->ip[5].detail==0x1a1);
 puts("CASE qualified_sequence_snapshot_details PASS");
}
static void integrated_fairness(void)
{
 soc_health_core_t c;soc_health_providers_t p;soc_health_observers_t o;soc_health_board_io_t board;
 init(&c,&p,&o);soc_health_board_io_init(&board);p.board_context=&board;p.board_service=soc_health_board_io_service;
 const soc_health_snapshot_t *n=begin(&c,&o);unsigned char saved[sizeof(*n)];memcpy(saved,n,sizeof(saved));
 unsigned initial[12];for(unsigned i=0;i<12;i++)initial[i]=c.ip[i].heartbeat_count;
 bd_sw=0x155;bd_dir=bd_out=bd_led=bd_ff1=bd_ff2=0;memset(bd_hex,0,sizeof(bd_hex));
 hw.loop=1;hw.gs_valid=1;unsigned seen[12]={0};
 for(unsigned turn=0;turn<20005;turn++){
  timer_tick(10);hw.gs_seq=turn+1;if(turn%40==0)publish(turn+1,turn+1,3,2500,2048);
  bd_ff2=bd_ff1;bd_ff1=bd_out&1;soc_health_epoch_begin(&c);
  unsigned w=frame_writes,tx=npc;soc_ip_id_t id=soc_health_providers_service(&c,&p);seen[id]++;
  soc_health_observers_uart_service(&c,&o);CHECK("INTEGRATED_QUOTAS",frame_writes-w<=8 && npc-tx<=1);
  if(hw.rd==hw.wr)hw.rd=hw.wr=0;
  if(hw.ntx>=240)hw.ntx=0;
  if(hw.vga_status&4)hw.vga_status=(hw.vga_status&~4u)|2u;else hw.vga_status|=1u;
  if(o.pending)CHECK("FAIRNESS_IMMUTABLE",memcmp(saved,n,sizeof(saved))==0);
 }
 for(unsigned i=1;i<=10;i++){
  CHECK("ALL_PROVIDER_VISITS",seen[i]==2000u+((i==1||i==2||i==4||i==5||i==7)?1u:0u) && p.visits[i]==seen[i]);
  CHECK("ALL_PROVIDERS_CONTINUE",c.ip[i].heartbeat_count>initial[i]);
 }
 CHECK("ONLY_ONE_FRAME_FOR_N",hw.swaps==1 && c.ip[7].heartbeat_count==initial[7]+1 && o.pending==0);
 CHECK("FAIRNESS_AES_EXCLUDED",p.visits[11]==0 && c.ip[11].state==SOC_HB_EXCLUDED);
 puts("CASE real_observer_all_provider_fairness PASS");
}
int main(void)
{
 observer_mode=0;prior_s3_main();sequences();formatter();full_frame_and_uart(0);full_frame_and_uart(1);failures_leases();integrated_fairness();
 puts("SUMMARY: PASS SOC_HEALTH_S4B");return 0;
}
