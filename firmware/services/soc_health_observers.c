#include "soc_health_observers.h"
#include "vga_text.h"
#include "vram.h"
#include "uart.h"

typedef struct { char *buffer; unsigned size, length; } text_t;
static void character(text_t *t,char c)
{
    if(t->size && t->length < t->size-1u)t->buffer[t->length]=c;
    t->length++;
}
static void string(text_t *t,const char *s)
{
    while(*s)character(t,*s++);
}
static void hex(text_t *t,uint32_t value,unsigned digits)
{
    while(digits)character(t,"0123456789ABCDEF"[(value>>(--digits*4u))&15u]);
}
unsigned soc_health_format_line(const soc_health_snapshot_t *s,unsigned line,
                                char *buffer,unsigned size)
{
    static const char *const names[SOC_IP_COUNT]={"SYS   ","TMR   ","UART  ","GPIO  ","GSEN  ","ADC   ","JOY   ","VGA   ","SW    ","LED   ","HEX   ","AES   "};
    text_t t={buffer,size,0u};
    if(!s)line=SOC_HEALTH_TEXT_LINES;
    if(line==0u){string(&t,"SOC HEALTH EP=");hex(&t,s->epoch,8);string(&t," SIG=");hex(&t,s->signature,8);}
    else if(line==1u){string(&t,"P=");hex(&t,s->pass_mask,8);string(&t," W=");hex(&t,s->warn_mask,8);string(&t," F=");hex(&t,s->fail_mask,8);}
    else if(line==2u){string(&t,"S=");hex(&t,s->sticky_fail_mask,8);string(&t," X=");hex(&t,s->excluded_mask,8);}
    else if(line==4u)string(&t,"IP    ST HB       MISS DETAIL");
    else if(line>=5u && line<17u){
        unsigned id=line-5u;const soc_ip_health_t *ip=&s->ip[id];
        char state=ip->state<=SOC_HB_EXCLUDED?"?PWFX"[ip->state]:'?';
        string(&t,names[id]);character(&t,state);string(&t,"  ");hex(&t,ip->heartbeat_count,8);character(&t,' ');hex(&t,ip->miss_count,4);character(&t,' ');
        if(id==SOC_IP_AES_GCM)string(&t,"PENDING");
        else if(ip->state!=SOC_HB_PASS){string(&t,"D=");hex(&t,ip->detail,8);}
        else switch(id){
        case SOC_IP_SYSTEM_SERVICE:string(&t,"RUN");break;
        case SOC_IP_TIMER:string(&t,"READY");break;
        case SOC_IP_UART_LOOP:case SOC_IP_GSENSOR:case SOC_IP_ADC:string(&t,"SEQ=");hex(&t,ip->detail,8);break;
        case SOC_IP_GPIO:string(&t,"LOOP");break;
        case SOC_IP_JOY_POLICY:string(&t,"MATCH");break;
        case SOC_IP_VGA:string(&t,"SWAP");break;
        case SOC_IP_SW:case SOC_IP_LED:string(&t,"V=");hex(&t,ip->detail&0x3ffu,3);break;
        case SOC_IP_HEX:string(&t,"M=");hex(&t,(ip->detail>>9)&1u,1);string(&t," P=");hex(&t,ip->detail&0x1ffu,3);break;
        default:break;
        }
    }else if(line==18u){
        string(&t,"SYSTEM: ");
        if(s->fail_mask){string(&t,"FAIL F=");hex(&t,s->fail_mask,8);string(&t," S=");hex(&t,s->sticky_fail_mask,8);}
        else string(&t,"PASS");
    }
    if(size)buffer[t.length<size?t.length:size-1u]='\0';
    return t.length;
}
void soc_health_observers_init(soc_health_observers_t *o)
{
    o->vga_snapshot=o->uart_snapshot=0;
    o->pending=o->start_epoch=o->clear_word=o->vga_line=o->vga_column=0u;
    o->uart_stage=o->uart_line=o->uart_column=o->uart_length=0u;
    o->budget=SOC_HEALTH_OBSERVER_BUDGET;
    o->vga_buffer[0]=o->uart_buffer[0]='\0';
}
int soc_health_observers_begin(soc_health_observers_t *o,
                              const soc_health_snapshot_t *s,uint32_t epoch)
{
    if(!s || o->pending)return 0;
    o->vga_snapshot=o->uart_snapshot=s;o->pending=SOC_OBSERVER_BOTH;o->start_epoch=epoch;
    o->clear_word=o->vga_line=o->vga_column=0u;
    o->uart_stage=o->uart_line=o->uart_column=o->uart_length=0u;
    return 1;
}
void soc_health_observers_vga_release(soc_health_core_t *c,void *context,int completed)
{
    soc_health_observers_t *o=context;
    if(!o->vga_snapshot)return;
    (void)soc_health_snapshot_release(c,o->vga_snapshot,SOC_OBSERVER_VGA,completed);
    o->vga_snapshot=0;o->pending&=~SOC_OBSERVER_VGA;
}
int soc_health_observers_vga_prepare(soc_health_core_t *c,void *context)
{
    soc_health_observers_t *o=context;unsigned i,length;
    if(!o->vga_snapshot)return -1;
    if(c->epoch-o->start_epoch>=o->budget){soc_health_observers_vga_release(c,o,0);return -1;}
    if(o->clear_word<9600u){
        for(i=0;i<SOC_HEALTH_CLEAR_QUOTA && o->clear_word<9600u;i++)vram_write_word(o->clear_word++,0u);
        return 0;
    }
    if(o->vga_line==SOC_HEALTH_TEXT_LINES)return 1;
    length=soc_health_format_line(o->vga_snapshot,o->vga_line,o->vga_buffer,sizeof(o->vga_buffer));
    if(o->vga_column<length){
        char chunk[5];
        for(i=0;i<4u && o->vga_column+i<length;i++)chunk[i]=o->vga_buffer[o->vga_column+i];
        chunk[i]='\0';
        vga_text_puts((SOC_HEALTH_VGA_X>>5)+(o->vga_column>>2),SOC_HEALTH_VGA_Y+o->vga_line*SOC_HEALTH_VGA_PITCH,chunk);
        o->vga_column+=i;
    }
    if(o->vga_column>=length){o->vga_column=0u;o->vga_line++;}
    return o->vga_line==SOC_HEALTH_TEXT_LINES;
}
static void uart_release(soc_health_core_t *c,soc_health_observers_t *o,int completed)
{
    (void)soc_health_snapshot_release(c,o->uart_snapshot,SOC_OBSERVER_UART,completed);
    o->uart_snapshot=0;o->pending&=~SOC_OBSERVER_UART;
}
void soc_health_observers_uart_service(soc_health_core_t *c,soc_health_observers_t *o)
{
    text_t t;
    if(!o->uart_snapshot)return;
    if(c->epoch-o->start_epoch>=o->budget){uart_release(c,o,0);return;}
    if(o->uart_stage==3u){if(uart1_tx_ready())uart_release(c,o,1);return;}
    if(o->uart_length==0u){
        t.buffer=o->uart_buffer;t.size=sizeof(o->uart_buffer);t.length=0;
        if(o->uart_stage==0u)string(&t,"=== SOC HEALTH SNAPSHOT ===");
        else if(o->uart_stage==2u)string(&t,"----------------------------------------");
        else t.length=soc_health_format_line(o->uart_snapshot,o->uart_line,t.buffer,t.size);
        string(&t,"\r\n");o->uart_length=t.length;o->uart_column=0u;
    }
    if(uart1_putc_timeout(o->uart_buffer[o->uart_column],1u)!=UART_RESULT_SUCCESS)return;
    if(++o->uart_column==o->uart_length){
        o->uart_length=0u;
        if(o->uart_stage==0u)o->uart_stage=1u;
        else if(o->uart_stage==2u)o->uart_stage=3u;
        else if(++o->uart_line==SOC_HEALTH_TEXT_LINES)o->uart_stage=2u;
    }
}
