/* Independent bus-contract model. Oracle bytes are generated outside Git from
 * P13-04 AESGCM, never obtained from app/DUT results. Fault modes affect this
 * isolated model/observation input only; no production source is mutated. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "p13_07_oracle.h"
#define main diagnostic_main
#include "../../firmware/apps/p13_07_aes_board_diag.c"
#undef main

static uint32_t regs[36], status_value;
static unsigned accesses,starts,post_polls,maintenance,zero_reads,auth_reads,done_at=3;
static unsigned api_invalid_reads, timeout_zero_reads, recovery_reads;
static unsigned auth_active, good_completion, trace_number;
static const char *fault="normal";
static void check(int condition,const char *id)
{if(!condition){fprintf(stderr,"HOST_ASSERT %s\n",id);exit(41);}}
static uint32_t packed(const unsigned char *p,unsigned n,unsigned w)
{uint32_t v=0;unsigned j;for(j=0;j<4;j++)v=(v<<8)|(w*4+j<n?p[w*4+j]:0);return v;}
static void access(char op,uint32_t a,uint32_t v)
{
 accesses++;fprintf(stderr,"MMIO %u %c %08x %08x ordinal=%u\n",++trace_number,op,a,v,ordinal);
 if(a<0x40050000u){
  if(ordinal==7 || ordinal==8)api_invalid_reads++;
  if(ordinal==12)timeout_zero_reads++;
  if(ordinal==14)recovery_reads++;
 }
}
uint32_t mmio_read32(uint32_t a)
{
 uint32_t v=0;unsigned idx;
 if(a==0x40060004u){access('R',a,1);return 1;}
 check(a>=0x40040000u && a<=0x4004008cu && !(a&3),"CANONICAL_READ");
 if(auth_active && status_value==1u)check(zeros(output,16),"NO_TRANSIENT_CALLER_RELEASE");
 if(a==0x40040008u)v=0x322e3030;
 else if(a==0x40040010u){
  if(maintenance){v=0;maintenance=0;status_value=0;}
  else if(status_value==1u){
   ++post_polls;
   if(!strcmp(fault,"timeout") || (ordinal==13))v=1;
   else if(post_polls>=done_at){status_value=auth_active?0x9a:6;v=status_value;good_completion=!auth_active;}
   else v=1;
  }else v=status_value;
  if(!strcmp(fault,"sticky") && v==6)v=0x426u;
  if(!strcmp(fault,"early") && auth_active){output[0]=0x10;}
 }else{
  idx=(a-0x40040000u)/4;v=regs[idx];
  if(a>=0x40040060u && a<=0x4004007cu && ordinal!=9){
   check(good_completion,"AUTHENTICATED_OUTPUT_READ");auth_reads++;
  }
  if(a>=0x40040020u && maintenance==0 && ordinal==9){zero_reads++;if(!strcmp(fault,"zero") && a==0x40040020u)v=1;}
 }
 access('R',a,v);return v;
}
void mmio_write32(uint32_t a,uint32_t v)
{
 unsigned i,k,n,decrypt;
 if(a==0x40060000u){putchar((char)v);return;}
 if(a==0x4006000cu){check(v==434,"UART_DIVISOR");return;}
 check(a>=0x40040000u && a<=0x4004008cu && !(a&3),"CANONICAL_WRITE");access('W',a,v);
 if(a!=0x4004000cu){regs[(a-0x40040000u)/4]=v;return;}
 if(v==4){status_value=0;auth_active=0;return;}
 if(v==8){for(i=8;i<36;i++)regs[i]=0;maintenance=1;status_value=0;auth_active=0;return;}
 check(v==1 || v==3,"COMMAND");starts++;post_polls=0;good_completion=0;
 n=regs[15];k=n==0?0:n==7?1:2;check(n==oracle_len[k],"ORACLE_LENGTH");decrypt=(v==3);
 check(regs[12]==0x10203000u && regs[13]==0xa1b2c3d4u && regs[14]==n+1,"INDEPENDENT_IV");
 for(i=0;i<4;i++){
  check(regs[8+i]==packed(oracle_key,16,i),"INDEPENDENT_KEY");
  check(regs[16+i]==packed(decrypt?oracle_cipher[k]:oracle_plain,n,i),"INDEPENDENT_PAYLOAD_PACK");
  regs[24+i]=packed(decrypt?oracle_plain:oracle_cipher[k],n,i);
  regs[28+i]=packed(oracle_tags[k],16,i);
 }
 auth_active=decrypt && regs[20]!=packed(oracle_tags[k],16,0);
 if(!strcmp(fault,"cipher"))regs[24]^=0x01000000u;
 if(!strcmp(fault,"tag"))regs[28]^=1u;
 status_value=1;
}
int main(int argc,char **argv)
{
 int rc;if(argc>1)fault=argv[1];
 rc=diagnostic_main();
 if(!strcmp(fault,"normal")){
  check(rc==0,"APP_SUCCESS");check(starts==9,"EXACT_START_COUNT");
  check(zero_reads==28,"ZEROIZE_28_READBACKS");
  /* Only AES accesses count; UART logging is excluded by access routing. */
  check(api_invalid_reads==0,"INVALID_ZERO_MMIO");
  check(timeout_zero_reads==0,"ZERO_BUDGET_ZERO_MMIO");
  check(recovery_reads==0,"RECOVERY_ZERO_MMIO");
  check(auth_reads>0,"REAL_OUTPUT_READS");
  fprintf(stderr,"HOST_PASS starts=%u zero_reads=%u\n",starts,zero_reads);
 }else check(rc!=0,"INJECTED_FAILURE_NOT_DETECTED");
 return rc;
}
