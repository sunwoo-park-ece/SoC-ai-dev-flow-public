#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the checkout}"
python3 - "$root" <<'PY'
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import os,sys,json,shutil,subprocess,hashlib
repo=Path(sys.argv[1]).resolve();run=Path(os.environ['RUN_ROOT']).resolve()/'soc_health_observer_negative'
if run==repo or repo in run.parents:raise SystemExit('RUN_ROOT must be outside checkout')
run.mkdir(parents=True,exist_ok=False)
f='firmware/services/soc_health_observers.c';p='firmware/services/soc_health_providers.c';h='firmware/include/soc_health_observers.h'
mutations=[
 ('uart_old_detail',p,'p->uart_seq, p->uart_seq);','p->uart_seq, 434u);','FROZEN_UART_SEQUENCE'),
 ('gs_old_detail',p,'SOC_STEP_PROGRESS, sample.seq, sample.seq)','SOC_STEP_PROGRESS, sample.seq, 0u)','FROZEN_GS_SEQUENCE'),
 ('adc_old_detail',p,'SOC_STEP_PROGRESS, p->frame.seq, p->frame.seq)','SOC_STEP_PROGRESS, p->frame.seq, count)','FROZEN_ADC_SEQUENCE'),
 ('wrong_epoch',f,'hex(&t,s->epoch,8)','hex(&t,s->epoch+1u,8)','EXACT_COMMON_LINES'),
 ('sequence_truncated',f,'hex(&t,ip->detail,8);break;','hex(&t,ip->detail,4);break;','FROZEN_UART_SEQUENCE'),
 ('wrong_masks',f,'hex(&t,s->pass_mask,8)','hex(&t,s->fail_mask,8)','EXACT_COMMON_LINES'),
 ('wrong_footer',f,'if(s->fail_mask)','if(0)','FAIL_FOOTER'),
 ('wrong_raw_detail',f,'hex(&t,ip->detail,8)','hex(&t,ip->heartbeat_count,8)','RAW_DETAIL_FALLBACK'),
 ('nondeterministic_text',f,'return t.length;','static unsigned repeat; if(size && line==0u && (repeat++&1u))buffer[0]="?"[0]; return t.length;','FORMAT_DETERMINISTIC'),
 ('wrong_uart_snapshot',f,'o->vga_snapshot=o->uart_snapshot=s;','static soc_health_snapshot_t wrong; wrong=*s; wrong.epoch++; o->vga_snapshot=s; o->uart_snapshot=&wrong;','PC_EXACT_CRLF_FORMAT'),
 ('normal_vga_lease_leak',f,'(void)soc_health_snapshot_release(c,o->vga_snapshot','if(!completed)(void)soc_health_snapshot_release(c,o->vga_snapshot','LEASES_INDEPENDENT'),
 ('wrong_state',f,'?PWFX','?PFFX','STATE_ENCODING'),
 ('bounds_overflow',f,'t->length < t->size-1u','t->length <= t->size','FORMAT_BOUNDS'),
 ('snapshot_mutation',f,'if(size)buffer','if(s)((soc_health_snapshot_t *)s)->publication_id++;\n    if(size)buffer','FORMAT_IMMUTABLE'),
 ('vga_completion_mutates_n',f,'if(!o->vga_snapshot)return;','if(!o->vga_snapshot)return;\n    if(completed)((soc_health_snapshot_t *)o->vga_snapshot)->ip[7].heartbeat_count++;','N_PRE_COMPLETION_STATE'),
 ('formatter_mmio',f,'if(!s)line','if(s)(void)uart1_status();\n    if(!s)line','FORMAT_NO_MMIO'),
 ('x_wrong',h,'VGA_X 32u','VGA_X 64u','FULL_FRAME_BEFORE_SWAP'),
 ('pitch_dense',h,'VGA_PITCH 16u','VGA_PITCH 8u','FULL_FRAME_BEFORE_SWAP'),
 ('unbounded_clear',h,'CLEAR_QUOTA 8u','CLEAR_QUOTA 32u','OBSERVER_WORK_BOUND'),
 ('uart_wrong_bytes',f,'uart_buffer[o->uart_column]','uart_buffer[0]','PC_EXACT_CRLF_FORMAT'),
 ('uart_no_crlf',f,'string(&t,"\\r\\n")','string(&t,"\\n")','PC_EXACT_CRLF_FORMAT'),
 ('uart_qualifies_heartbeat',f,'(void)soc_health_snapshot_release(c,o->uart_snapshot','(void)soc_health_report(c,SOC_IP_UART_LOOP,SOC_STEP_PROGRESS,c->epoch,0u);\n    (void)soc_health_snapshot_release(c,o->uart_snapshot','TX_NOT_HEARTBEAT'),
 ('timeout_releases_both',f,'(void)soc_health_snapshot_release(c,o->uart_snapshot','if(!completed)soc_health_observers_vga_release(c,o,0);\n    (void)soc_health_snapshot_release(c,o->uart_snapshot','UART_TIMEOUT_ONLY_OWN_LEASE'),
 ('uart_early_drain_release',f,'if(uart1_tx_ready())','if(1)','UART_DRAIN_LEASE'),
 ('early_vga_release',p,'else if (prepared) t->phase = VGA_ARM;','else if (prepared) { if (p->vga_release) p->vga_release(c,p->vga_context,1); t->phase = VGA_ARM; }','VGA_LEASE_UNTIL_DONE'),
 ('early_swap',p,'else if (prepared) t->phase = VGA_ARM;','else if (prepared>=0) t->phase = VGA_ARM;','FULL_FRAME_BEFORE_SWAP'),
 ('missing_done',p,'if ((status & VRAM_STATUS_OP_DONE) == 0u ||','if (0u ||','NO_HEARTBEAT_WITHOUT_DONE'),
]
def fixture(name):
 src=run/name/'source';src.mkdir(parents=True)
 for folder in ('firmware','rtl','verification'):shutil.copytree(repo/folder,src/folder)
 return src
def execute(name,source,tag=None,rtl=False,compiler=None):
 env=dict(os.environ,RUN_ROOT=str(run/name/'evidence'),SOC_HEALTH_TEST_SOURCE_ROOT=str(source))
 if compiler:env['HOST_CC']=str(compiler)
 script='soc_health_observer_rtl_test.sh' if rtl else 'soc_health_observer_test.sh'
 with (run/name/'parent.log').open('wb') as log:rc=subprocess.run(['bash',str(repo/'scripts/wsl'/script)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300).returncode
 result_dir=run/name/'evidence'/('soc_health_observer_rtl' if rtl else 'soc_health_observers');d=json.loads((result_dir/'result.json').read_text())
 good=rc!=0 and d['classification']=='FAIL' and d['final_exit']==rc
 if tag:good=good and d['compile_exit']==0 and d['target_exit']==1 and ('ASSERT '+tag) in (result_dir/'target.log').read_text()
 elif name=='compile_failure':good=good and d['compile_exit']==1 and d['target_exit'] is None
 elif name in ('guard_failure','rtl_guard_missing_frame'):good=good and d['target_exit']==0 and d['guard_exit']==2 and rc==2
 row=dict(name=name,expected_assertion=tag,compile_exit=d['compile_exit'],target_exit=d['target_exit'],guard_exit=d['guard_exit'],parent_exit=rc,classification=d['classification'],rejected=good)
 (run/name/'verdict.json').write_text(json.dumps(row,indent=2)+'\n');print(row,flush=True);return row
def mutant(m):
 name,path,old,new,tag=m;src=fixture(name);file=src/path;text=file.read_text();assert old in text,(name,old)
 file.write_text(text.replace(old,new,1));(run/name/'mutation.json').write_text(json.dumps(dict(path=path,old=old,new=new,sha256=hashlib.sha256(file.read_bytes()).hexdigest()),indent=2)+'\n');return execute(name,src,tag)
with ThreadPoolExecutor(max_workers=3) as pool:rows=list(pool.map(mutant,mutations))
# Actual RTL framebuffer side-effect and serial monitors reject targeted faults.
for name,path,old,new,tag in [
 ('rtl_fb_wrong_address','rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v','use_clear ? clear_addr : data_word_addr','use_clear ? clear_addr : (data_word_addr ^ 14\'d1)','NO_ORPHAN_FB_COMMIT'),
 ('rtl_uart_serial_wrong_byte',f,'uart_buffer[o->uart_column]','uart_buffer[0]','SERIAL_EXACT_SNAPSHOT')]:
 src=fixture(name);file=src/path;text=file.read_text();assert old in text;file.write_text(text.replace(old,new,1));rows.append(execute(name,src,tag,rtl=True))
src=fixture('rtl_guard_missing_frame');file=src/'verification/directed/firmware/soc_health_observer_rtl.cpp';file.write_text(file.read_text().replace('if(argc>1)','if(argc>2)',1));rows.append(execute('rtl_guard_missing_frame',src,rtl=True))
src=fixture('compile_failure');rows.append(execute('compile_failure',src,compiler='/bin/false'))
src=fixture('guard_failure');fake=run/'guard_failure/fake_cc.py';fake.write_text('''#!/usr/bin/env python3
import pathlib,sys
p=pathlib.Path(sys.argv[sys.argv.index('-o')+1])
p.write_text("#!/bin/sh\\necho 'SUMMARY: PASS SOC_HEALTH_S4B'\\nexit 0\\n")
p.chmod(0o755)
''');fake.chmod(0o755);rows.append(execute('guard_failure',src,compiler=fake))
ok=all(r['rejected'] for r in rows)
result=dict(classification='PASS' if ok else 'FAIL',cases=rows,final_exit=0 if ok else 1,runner_sha256=hashlib.sha256((repo/'scripts/wsl/soc_health_observer_negative_test.sh').read_bytes()).hexdigest())
(run/'result.json').write_text(json.dumps(result,indent=2)+'\n');(run/'result.md').write_text('# S4-B isolated rejection fixtures\n\n'+result['classification']+'\n\n'+ '\n'.join(str(r) for r in rows)+'\n');(run/'exit_code.txt').write_text(str(result['final_exit'])+'\n');sys.exit(result['final_exit'])
PY
