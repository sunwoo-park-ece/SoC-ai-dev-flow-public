/* Dedicated, single-owner diagnostic. Public fixed KAT context only.
 * UART reports comparison results, never keys or caller plaintext.
 * Returning from main enters the BSP fail-stop loop. No automatic retry.
 */
#include <stdint.h>
#include "aes_gcm.h"
#include "uart.h"
#include "soc_mmio.h"

#ifndef P13_BUILD_ID
#define P13_BUILD_ID "UNBOUND"
#endif
#ifndef P13_SOURCE_ID
#define P13_SOURCE_ID "UNBOUND"
#endif
#ifndef P13_VECTOR_ID
#define P13_VECTOR_ID "UNBOUND"
#endif
static const uint8_t key[16]={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
static const uint8_t plain[16]={0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f};
static const uint8_t cipher[3][16]={
 {0}, {0x0e,0xd8,0xf1,0x55,0xc4,0xf7,0xb0},
 {0xc5,0x18,0x03,0x04,0x30,0xe6,0x37,0x87,0x86,0x59,0x81,0x8a,0x06,0x73,0xd5,0xb5}};
static const uint8_t tags[3][16]={
 {0xa6,0xfd,0x19,0x6a,0x49,0xd3,0xef,0xde,0x44,0x1b,0xb3,0x93,0x7d,0xbc,0x27,0x0b},
 {0x23,0xa3,0x12,0xf0,0x18,0xf4,0xe3,0xd9,0xdb,0xe6,0x45,0x98,0xaa,0xbe,0xae,0x34},
 {0xb5,0x57,0x3f,0x54,0xdd,0x05,0x64,0xb7,0xfa,0x57,0x08,0xd6,0xb7,0xc8,0x9b,0xb4}};
static uint8_t output[16], tag_output[16], bad_tag[16];
static aes_gcm_v2_request_t req;
static aes_gcm_v2_diagnostic_t diagnostic;
static unsigned ordinal, passes, failures, unavailable;
static int tx_failed;

static void text(const char *s)
{
 if(!tx_failed && uart1_puts_timeout(s,100000u)!=UART_RESULT_SUCCESS)tx_failed=1;
}
static void hex(uint32_t v,unsigned digits)
{
 while(digits && !tx_failed){char c="0123456789abcdef"[(v>>(4u*--digits))&15u];
  if(uart1_putc_timeout(c,100000u)!=UART_RESULT_SUCCESS)tx_failed=1;}
}
static int equal(const uint8_t *a,const uint8_t *b,unsigned n)
{unsigned i;for(i=0;i<n;i++)if(a[i]!=b[i])return 0;return 1;}
static int zeros(const uint8_t *a,unsigned n)
{unsigned i;for(i=0;i<n;i++)if(a[i])return 0;return 1;}
static void prepare(unsigned vector,unsigned decrypt)
{
 unsigned i,n=vector==0?0u:vector==1?7u:16u;
 req.mode=decrypt?AES_GCM_V2_DECRYPT:AES_GCM_V2_ENCRYPT;
 req.key=key;req.key_capacity=16;req.nonce_dir=0x10203000u;req.seq_hi=0xa1b2c3d4u;
 req.seq_lo=n+1u;req.len=n;req.poll_budget=32;
 req.input=decrypt?cipher[vector]:plain;req.input_capacity=n;
 req.output=output;req.output_capacity=n;
 req.tag_in=decrypt?tags[vector]:0;req.tag_in_capacity=decrypt?16u:0u;
 req.tag_out=decrypt?0:tag_output;req.tag_out_capacity=decrypt?0u:16u;
 for(i=0;i<16;i++){output[i]=0xa5;tag_output[i]=0x5a;}
 diagnostic.last_status=diagnostic.completed_status_polls=0;
 diagnostic.completed_maintenance_polls=diagnostic.recovery_required=diagnostic.start_issued=0;
}
static int record(const char *id,const char *mode,unsigned len,unsigned rc,int ok,const char *verdict)
{
 text("CASE o=");hex(++ordinal,2);text(" id=");text(id);text(" m=");text(mode);
 text(" l=");hex(len,8);text(" r=");hex(rc,2);text(" s=");hex(diagnostic.last_status,8);
 text(" c=");hex(diagnostic.last_status&0x1fc0u,8);
 text(" p=");hex(diagnostic.completed_status_polls+diagnostic.completed_maintenance_polls,2);
 text(" e=");hex(ok?1u:0u,1);text(" v=");text(verdict);text("\n");
 if(verdict[0]=='N')unavailable++;else if(ok)passes++;else failures++;
 return ok && !tx_failed;
}
static int kat(unsigned v,unsigned decrypt,const char *id)
{
 unsigned rc;int ok;prepare(v,decrypt);rc=aes_gcm_v2_transact(&req,&diagnostic);
 ok=rc==AES_GCM_V2_OK && diagnostic.last_status==6u &&
    equal(output,decrypt?plain:cipher[v],req.len) &&
    (decrypt || equal(tag_output,tags[v],16));
 return record(id,decrypt?"D":"E",req.len,rc,ok,ok?"P":"F");
}
static void finish(void)
{
 text("SUMMARY pass=");hex(passes,2);text(" fail=");hex(failures,2);
 text(" skip=00 nt=");hex(unavailable,2);text("\nEND complete=");
 text(!failures && ordinal==17u?"1\n":"0\n");
}
int main(void)
{
 unsigned i,rc;int ok;
 if(uart1_set_baud_div(434u)!=UART_RESULT_SUCCESS)return 2;
 text("BEGIN app=P13H0 schema=1 build=" P13_BUILD_ID " source=" P13_SOURCE_ID " vector=" P13_VECTOR_ID " count=11\n");
 if(!kat(0,0,"E0") || !kat(0,1,"D0") || !kat(1,0,"E7") || !kat(1,1,"D7") ||
    !kat(2,0,"E16") || !kat(2,1,"D16"))goto failed;
 prepare(2,1);for(i=0;i<16;i++)bad_tag[i]=tags[2][i];bad_tag[0]^=1u;req.tag_in=bad_tag;
 rc=aes_gcm_v2_transact(&req,&diagnostic);
 ok=rc==AES_GCM_V2_AUTH_FAIL && diagnostic.last_status==0x9au && zeros(output,16);
 if(!record("AUTH","D",16,rc,ok,ok?"P":"F"))goto failed;
 prepare(2,1);req.len=17;req.input_capacity=req.output_capacity=65535;
 rc=aes_gcm_v2_transact(&req,&diagnostic);ok=rc==AES_GCM_V2_INVALID_ARG;
 if(!record("ARG17","D",17,rc,ok,ok?"P":"F"))goto failed;
 req.len=65535;rc=aes_gcm_v2_transact(&req,&diagnostic);ok=rc==AES_GCM_V2_INVALID_ARG;
 if(!record("ARG65535","D",65535,rc,ok,ok?"P":"F"))goto failed;
 prepare(2,1);rc=aes_gcm_v2_zeroize(32,&diagnostic);
 ok=rc==AES_GCM_V2_OK && diagnostic.last_status==0;
 if(!record("ZERO","M",0,rc,ok,ok?"P":"F"))goto failed;
 /* Serialized raw status-clear inspection. No busy collision or raw START. */
 mmio_write32(0x4004000cu,4u);diagnostic.last_status=mmio_read32(0x40040010u);
 ok=diagnostic.last_status==0 && mmio_read32(0x4004000cu)==0 && mmio_read32(0x40040020u)==0;
 diagnostic.completed_maintenance_polls=0;
 if(!record("CLEAR","M",0,0,ok,ok?"P":"F"))goto failed;
 if(!kat(2,0,"NEXT"))goto failed;
 prepare(2,1);req.poll_budget=0;rc=aes_gcm_v2_transact(&req,&diagnostic);
 ok=rc==AES_GCM_V2_TIMEOUT && !diagnostic.start_issued && zeros(output,16);
 if(!record("TIMEOUT0","D",16,rc,ok,ok?"P":"F"))goto failed;
 prepare(2,1);req.poll_budget=1;rc=aes_gcm_v2_transact(&req,&diagnostic);
 ok=rc==AES_GCM_V2_TIMEOUT && diagnostic.start_issued && diagnostic.recovery_required &&
    diagnostic.completed_status_polls==1u && (diagnostic.last_status&1u) && zeros(output,16);
 if(!record("TIMEOUT1","D",16,rc,ok,ok?"P":"F"))goto failed;
 prepare(2,1);rc=aes_gcm_v2_transact(&req,&diagnostic);
 ok=rc==AES_GCM_V2_RECOVERY_REQUIRED && !diagnostic.start_issued && zeros(output,16);
 if(!record("RECOVERY","D",16,rc,ok,ok?"P":"F"))goto failed;
 diagnostic.last_status=diagnostic.completed_status_polls=0;
 record("BUSY","X",0,0,0,"NT");record("OVERFLOW","X",0,0,0,"NR");
 finish();return tx_failed?2:0;
failed:
 finish();return 1;
}
