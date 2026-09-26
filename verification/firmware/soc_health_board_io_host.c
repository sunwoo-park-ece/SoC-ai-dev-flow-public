/* Reuse S3's independent model and full suite; board hooks below add public
 * GPIO/SW/LED/HEX registers without replacing any accepted S3 assertion. */
#define soc_health_test_read s3_model_read
#define soc_health_test_write s3_model_write
#define main s3_prior_tests
#include "soc_health_provider_host.c"
#undef main
#undef soc_health_test_read
#undef soc_health_test_write
#include "soc_health_board_io.h"
#include "gpio.h"
#include "sw.h"
#include "led.h"
#include "hex_display.h"
static struct {
    uint32_t dir,out,ff1,ff2,sw,led,value,ctrl,low,high;
    uint32_t gpio_fault,dir_fault,out_fault,led_fault,hex_fault;
    uint32_t reads,writes,sw_reads,ctrl_writes,last_read,drive[64],ndrives;
} board;
uint32_t soc_health_test_read(uint32_t a)
{
    board.reads++;board.last_read=a;
    if(a==GPIO_BASE+GPIO_DIR)return board.dir^board.dir_fault;
    if(a==GPIO_BASE+GPIO_DATA_OUT)return board.out^board.out_fault;
    if(a==GPIO_BASE+GPIO_DATA_IN)return board.ff2<<1;
    if(a==SW_BASE){board.sw_reads++;return board.sw|0xfffffc00u;}
    if(a==LED_BASE)return (board.led^board.led_fault)|0xfffffc00u;
    if(a==HEX_DISPLAY_BASE+HEX_VALUE)return (board.value^(board.hex_fault==8?1u:0u))|0xff000000u;
    if(a==HEX_DISPLAY_BASE+HEX_CTRL)return (board.ctrl^(board.hex_fault==1?1u:0u))|0xfffffffcu;
    if(a==HEX_DISPLAY_BASE+HEX_RAW_LOW)return (board.low^(board.hex_fault==2?1u:0u))|0xffe00000u;
    if(a==HEX_DISPLAY_BASE+HEX_RAW_HIGH)return (board.high^(board.hex_fault==4?1u:0u))|0xffe00000u;
    return s3_model_read(a);
}
void soc_health_test_write(uint32_t a,uint32_t v)
{
    board.writes++;
    if(a==GPIO_BASE+GPIO_DIR){board.dir=v&0xffffu;return;}
    if(a==GPIO_BASE+GPIO_DATA_OUT){board.out=v&0xffffu;if(board.ndrives<64)board.drive[board.ndrives++]=v&1u;return;}
    if(a==SW_BASE)CHECK("READ_ONLY_SW",0);
    if(a==LED_BASE){CHECK("LED_MASK",!(v&~0x3ffu));board.led=v;return;}
    if(a==HEX_DISPLAY_BASE+HEX_CTRL){CHECK("CTRL_MASK",!(v&~3u));board.ctrl=v;board.ctrl_writes++;return;}
    if(a==HEX_DISPLAY_BASE+HEX_VALUE){CHECK("HEX_DISABLED_VALUE",!(board.ctrl&1));board.value=v&0xffffffu;return;}
    if(a==HEX_DISPLAY_BASE+HEX_RAW_LOW){CHECK("HEX_DISABLED_LOW",!(board.ctrl&1));board.low=v&0x1fffffu;return;}
    if(a==HEX_DISPLAY_BASE+HEX_RAW_HIGH){CHECK("HEX_DISABLED_HIGH",!(board.ctrl&1));board.high=v&0x1fffffu;return;}
    s3_model_write(a,v);
}
static void ticks(void)
{
    uint32_t pin=board.out&1u;
    if(board.gpio_fault==1)pin=0;
    if(board.gpio_fault==2)pin=1;
    if(board.gpio_fault==3)pin^=1;
    board.ff2=board.ff1;board.ff1=pin;timer_tick(10);
}
static void board_reset(soc_health_core_t *c,soc_health_providers_t *p,soc_health_board_io_t *b)
{
    reset(c,p);memset(&board,0,sizeof(board));board.dir=0xa5a8u;board.out=0x5a5au;
    soc_health_board_io_init(b);b->budget=200;p->budget=200;
    p->board_context=b;p->board_service=soc_health_board_io_service;
}
static void visit(soc_health_core_t *c,soc_health_board_io_t *b,soc_ip_id_t id)
{
    uint32_t r=board.reads,w=board.writes;
    ticks();soc_health_epoch_begin(c);
    soc_health_board_io_service(c,b,id);
    CHECK("BOARD_SERVICE_BOUND",board.reads-r<=5 && board.writes-w<=5);
}
/* Table indexed by external requested group and physical digit number; no
 * provider register packing code or health outputs participate in this oracle. */
static uint32_t expected_digit(uint32_t s,uint32_t d)
{
    static const uint8_t select[4][6]={{1,1,1,1,1,1},{1,1,1,0,0,0},{0,0,0,1,1,1},{1,2,1,2,1,2}};
    uint32_t kind=select[(s>>7)&3u][d];
    return kind==0?127u:kind==1?127u-(s&127u):(s&127u);
}
static void check_command(uint32_t s)
{
    uint32_t d;
    CHECK("LED_EXTERNAL_ORACLE",board.led==(s&1023u));
    CHECK("HEX_CTRL_EXTERNAL_ORACLE",board.ctrl==((s&512u)?3u:1u));
    if(s&512u)for(d=0;d<6;d++) {
        uint32_t actual=((d<3?board.low:board.high)>>(7*(d%3)))&127u;
        CHECK("HEX_DIGIT_EXTERNAL_ORACLE",actual==expected_digit(s,d));
    } else {
        /* Separate nibble lookup, including the single-bit most significant digit. */
        for(d=0;d<6;d++)CHECK("HEX_DECODE_NIBBLE",((board.value>>(4*d))&15u)==((s>>(4*(d%3)))&15u));
    }
}
static void command(soc_health_core_t *c,soc_health_board_io_t *b,uint32_t s)
{
    uint32_t led_count=c->ip[SOC_IP_LED].heartbeat_count,hex_count=c->ip[SOC_IP_HEX].heartbeat_count;
    uint32_t reads=board.sw_reads;board.sw=s;visit(c,b,SOC_IP_SW);uint32_t gen=b->sw_generation;
    visit(c,b,SOC_IP_LED);
    /* Change physical stimulus after capture and before every HEX consumer visit. */
    board.sw=s^1023u;
    for(uint32_t i=0;i<5;i++) {visit(c,b,SOC_IP_SW);CHECK("CAPTURE_RETAINED",b->sw_generation==gen && b->sw_value==s);visit(c,b,SOC_IP_HEX);
        CHECK("CAPTURE_READ_ONCE",board.sw_reads==reads+1);
        if(i<3)CHECK("HEX_STAYS_DISABLED",!(board.ctrl&1));
    }
    CHECK("GENERATION_CONSUMED",b->pending==0 && c->progress_token[SOC_IP_LED]==gen && c->progress_token[SOC_IP_HEX]==gen);
    CHECK("TRANSACTION_COUNTS",c->ip[SOC_IP_LED].heartbeat_count==led_count+1 && c->ip[SOC_IP_HEX].heartbeat_count==hex_count+1);
    check_command(s);
}
static void gpio_tests(void)
{
    soc_health_core_t c;soc_health_providers_t p;soc_health_board_io_t b;
    board_reset(&c,&p,&b);
    for(uint32_t i=0;i<16;i++) {visit(&c,&b,SOC_IP_GPIO);CHECK("NO_PARTIAL_GPIO",c.ip[SOC_IP_GPIO].heartbeat_count==(i==15?1u:0u));}
    CHECK("GPIO_CYCLE",board.ndrives==4 && board.drive[0]==0 && board.drive[1]==1 && board.drive[2]==1 && board.drive[3]==0);
    CHECK("GPIO_OUTSIDE_OWNED",board.dir==0xa5a9u && board.out==0x5a5au);
    CHECK("GPIO_COMPLETE_TOKEN",c.progress_token[SOC_IP_GPIO]==1);
    /* No busy-wait/early input qualification, even when reading repeatedly. */
    board_reset(&c,&p,&b);visit(&c,&b,SOC_IP_GPIO);
    for(uint32_t i=0;i<10;i++)soc_health_board_io_service(&c,&b,SOC_IP_GPIO);
    CHECK("GPIO_SETTLE_ACROSS_EPOCHS",b.gpio_index==0 && c.ip[SOC_IP_GPIO].heartbeat_count==0);
    for(uint32_t f=1;f<=3;f++) {
        board_reset(&c,&p,&b);b.budget=30;board.gpio_fault=f;
        for(uint32_t i=0;i<32;i++)visit(&c,&b,SOC_IP_GPIO);
        CHECK("GPIO_SENSE_REJECT",c.ip[SOC_IP_GPIO].heartbeat_count==0 && c.ip[SOC_IP_GPIO].state==SOC_HB_FAIL && c.ip[SOC_IP_GPIO].miss_count==1);
        board.gpio_fault=0;for(uint32_t i=0;i<20;i++)visit(&c,&b,SOC_IP_GPIO);
        CHECK("GPIO_RECOVERY_STICKY",c.ip[SOC_IP_GPIO].state==SOC_HB_PASS && (c.sticky_fail_mask&(1u<<SOC_IP_GPIO)));
    }
    board_reset(&c,&p,&b);visit(&c,&b,SOC_IP_GPIO);board.dir_fault=2;
    for(uint32_t i=0;i<3;i++)visit(&c,&b,SOC_IP_GPIO);
    CHECK("GPIO_DIRECTION_FAIL",c.ip[SOC_IP_GPIO].state==SOC_HB_FAIL);
    board_reset(&c,&p,&b);visit(&c,&b,SOC_IP_GPIO);board.out_fault=1;
    for(uint32_t i=0;i<3;i++)visit(&c,&b,SOC_IP_GPIO);
    CHECK("GPIO_LATCH_FAIL",c.ip[SOC_IP_GPIO].state==SOC_HB_FAIL);
    puts("CASE gpio_cycle_fault_recovery PASS");
}
static void getters(void)
{
    soc_health_core_t c;soc_health_providers_t p;soc_health_board_io_t b;
    board_reset(&c,&p,&b);board.low=0x123456;board.high=0x1abcde;
    board.sw=0x321;CHECK("DIRECT_SW_MASK",sw_read()==0x321);
    hex_display_init();hex_display_set_raw_mode(1);hex_display_enable(0);
    uint32_t w=board.writes,ctrl=board.ctrl;
    CHECK("RAW_LOW_OFFSET_MASK",hex_display_read_raw_low()==0x123456 && board.last_read==HEX_DISPLAY_BASE+8);
    CHECK("RAW_HIGH_OFFSET_MASK",hex_display_read_raw_high()==0x1abcde && board.last_read==HEX_DISPLAY_BASE+12);
    CHECK("GETTER_NO_SIDE_EFFECT",board.writes==w && board.ctrl==ctrl);
    hex_display_enable(1);CHECK("GETTER_SHADOW_PRESERVED",board.ctrl==3);
    puts("CASE raw_getter_offsets_masks_shadow PASS");
}
static void commands_and_faults(void)
{
    soc_health_core_t c;soc_health_providers_t p;soc_health_board_io_t b;
    board_reset(&c,&p,&b);
    command(&c,&b,0);command(&c,&b,0x12a);command(&c,&b,0x1ff);
    for(uint32_t g=0;g<4;g++)for(uint32_t v=0;v<9;v++) {
        uint32_t on=v==0?0:v==1?127:1u<<(v-2);
        command(&c,&b,512u|(g<<7)|on);
    }
    command(&c,&b,0x12a);command(&c,&b,0x12a);
    CHECK("STATIC_SW_VALID",c.ip[SOC_IP_SW].state==SOC_HB_PASS && c.ip[SOC_IP_SW].miss_count==0 && c.ip[SOC_IP_SW].detail==0x12a);
    /* Foreign CTRL write must be resynchronized at each command's disable. */
    board.ctrl=3;command(&c,&b,0x1ff);board.ctrl=0;command(&c,&b,0x281);
    board.sw=0x15a;visit(&c,&b,SOC_IP_SW);board.led_fault=1;visit(&c,&b,SOC_IP_LED);
    CHECK("LED_MISMATCH_FAIL",c.ip[SOC_IP_LED].state==SOC_HB_FAIL);
    for(uint32_t i=0;i<5;i++)visit(&c,&b,SOC_IP_HEX);
    board.led_fault=0;command(&c,&b,0x15a);
    CHECK("LED_RECOVER_STICKY",c.ip[SOC_IP_LED].state==SOC_HB_PASS && (c.sticky_fail_mask&(1u<<SOC_IP_LED)));
    for(uint32_t f=1;f<=8;f*=2) {
        board.sw=f==8?0x12a:0x281;visit(&c,&b,SOC_IP_SW);visit(&c,&b,SOC_IP_LED);board.hex_fault=f;
        for(uint32_t i=0;i<5;i++)visit(&c,&b,SOC_IP_HEX);
        CHECK("HEX_MISMATCH_FAIL",c.ip[SOC_IP_HEX].state==SOC_HB_FAIL && ((c.ip[SOC_IP_HEX].detail>>24)&15u)==f);
        board.hex_fault=0;command(&c,&b,board.sw);
        CHECK("HEX_RECOVER_STICKY",c.ip[SOC_IP_HEX].state==SOC_HB_PASS && (c.sticky_fail_mask&(1u<<SOC_IP_HEX)));
    }
    board.sw=0;visit(&c,&b,SOC_IP_SW);c.epoch+=b.budget;
    visit(&c,&b,SOC_IP_LED);visit(&c,&b,SOC_IP_HEX);
    CHECK("CONSUMER_BOUNDED_RETIRE",b.pending==0 && c.ip[SOC_IP_LED].miss_count==1 && c.ip[SOC_IP_HEX].miss_count==1);
    command(&c,&b,0);CHECK("AFTER_DEADLINE_RECOVERY",c.ip[SOC_IP_LED].state==SOC_HB_PASS && c.ip[SOC_IP_HEX].state==SOC_HB_PASS);
    puts("CASE shared_sw_led_hex_matrix_faults PASS");
}
static void all_fairness(void)
{
    soc_health_core_t c;soc_health_providers_t p;soc_health_board_io_t b;
    board_reset(&c,&p,&b);board.gpio_fault=1;hw.adc_identity=0;hw.gs_valid=1;hw.loop=1;
    uint32_t seen[12]={0};const soc_health_snapshot_t *n=soc_health_publish_snapshot(&c);unsigned char saved[sizeof(*n)];memcpy(saved,n,sizeof(saved));
    for(uint32_t i=0;i<1005;i++) {
        ticks();soc_health_epoch_begin(&c);hw.gs_seq=i+1;
        uint32_t r=board.reads,w=board.writes;
        soc_ip_id_t id=soc_health_providers_service(&c,&p);seen[id]++;
        CHECK("DISPATCH_BOUND",board.reads-r<=5 && board.writes-w<=5);
    }
    for(uint32_t i=1;i<=10;i++)CHECK("ALL_ACTIVE_FAIR",seen[i]==100u+((i==1||i==2||i==4||i==5||i==7)?1u:0u) && p.visits[i]==seen[i]);
    CHECK("GPIO_FAIL_NOT_STARVE",c.ip[3].state==SOC_HB_FAIL && c.ip[2].heartbeat_count>0 && c.ip[4].heartbeat_count>90 && c.ip[9].heartbeat_count>0 && c.ip[10].heartbeat_count>0);
    CHECK("S4_SNAPSHOT_IMMUTABLE",memcmp(saved,n,sizeof(saved))==0);
    n=soc_health_publish_snapshot(&c);CHECK("S4_CURRENT_STICKY",(n->fail_mask&(1u<<3)) && (n->sticky_fail_mask&(1u<<3)) && (n->pass_mask&(1u<<9)));
    CHECK("AES_STILL_EXCLUDED",c.ip[11].state==SOC_HB_EXCLUDED && p.visits[11]==0);
    puts("CASE all_active_fairness_snapshot PASS");
}
int main(void)
{
    s3_prior_tests();gpio_tests();getters();commands_and_faults();all_fairness();
    puts("SUMMARY: PASS SOC_HEALTH_S4A");return 0;
}
