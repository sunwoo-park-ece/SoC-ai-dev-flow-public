#!/usr/bin/env bash
# Portable P12A2 behavioral regression and evidence guard. Raw runs stay external.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
: "${RUN_ROOT:?Set a fresh external RUN_ROOT}"
export REPO_ROOT RUN_ROOT
python3 - <<'PY'
import concurrent.futures, datetime, hashlib, json, os, pathlib, re, subprocess, sys, threading, time
repo=pathlib.Path(os.environ['REPO_ROOT']).resolve()
run=pathlib.Path(os.environ['RUN_ROOT']).resolve()
if run==repo or repo in run.parents or run.exists():
    print('Refusing in-repository or preexisting run directory',file=sys.stderr); sys.exit(2)
run.mkdir(parents=True)
logs=run/'logs'; logs.mkdir()
sources=['rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v',
 'rtl/video/vram/HW_Cleaner.v','rtl/video/vga/VGA_SyncGen.v','rtl/soc/reset_release_sync.v',
 'verification/models/clock/vga_pll.sv','verification/models/memory/VRAM.sv',
 'verification/independent/p12a2_vga_cdc/tb/ahb_vga_bfm.sv',
 'verification/independent/p12a2_vga_cdc/tb/vga_cdc_ref_model.sv',
 'verification/independent/p12a2_vga_cdc/tb/vga_cdc_scoreboard.sv',
 'verification/independent/p12a2_vga_cdc/tb/tb_p12a2_vga_cdc.sv']
identity_sources=sources+['verification/independent/p12a2_vga_cdc/run_p12a2_regression.sh',
 'scripts/wsl/p12a2_independent_dv_test.sh','spec/08_vga.md','spec/06_reset_clock.md',
 'docs/governance/anti_cosmetic_verification_policy.md','docs/governance/reporting_policy.md']
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def source_manifest(): return {p:digest(repo/p) for p in identity_sources}
def save(name,obj):
 temp=run/(name+'.tmp'); temp.write_text(json.dumps(obj,indent=2)+'\n'); temp.replace(run/name)
pre=source_manifest(); save('source-pre.json',pre)
(run/'source-pre.sha256').write_text(''.join(f'{h}  {p}\n' for p,h in pre.items()))
record_lock=threading.Lock()
records=[]; lanes=[]; failure=None; target_exit=0; guard_exit=None
run_id=run.name+'-'+hashlib.sha256(str(run).encode()).hexdigest()[:12]
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
config={'run_id':run_id,'seed':'deterministic/no randomness','timeout_seconds':240,'parallel_functional_lanes':3,
 'simulation_budget_ns':250000000,'lint_profile':'required baseline --lint-only; uncensored -Wall diagnostic always executed',
 'environment':{k:os.environ.get(k,'0') for k in ['TEST_LINT_FAIL','TEST_MISSING_ARTIFACT','TEST_MISSING_LANE','TEST_FINAL_CONSISTENCY_FAIL','TEST_FINAL_READONLY_FAIL','TEST_B1_MISSING_BIN','TEST_B2_MISSING_BIN','B2_DEVELOP_ONLY','B3_DEVELOP_ONLY','TEST_B3_MISSING_BIN','TEST_B3_MISSING_ARTIFACT','B4_ONLY','B4_TEST_GUARD']},
 'source_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
 'source_branch':subprocess.check_output(['git','branch','--show-current'],cwd=repo,text=True).strip()}
save('config.json',config)
for tool,args in [('iverilog',['-V']),('vvp',['-V']),('verilator',['--version'])]:
 r=subprocess.run([tool]+args,capture_output=True)
 (logs/(tool+'-version.stdout')).write_bytes(r.stdout); (logs/(tool+'-version.stderr')).write_bytes(r.stderr)
 records.append({'stage':'version-'+tool,'argv':[tool]+args,'cwd':str(repo),'exit':r.returncode})

def execute(name,argv,timeout=240,missing_stderr=False):
 t=time.monotonic()
 stdout=logs/(name+'.stdout'); stderr=logs/(name+('.preserved-stderr' if missing_stderr else '.stderr'))
 with stdout.open('wb') as a, stderr.open('wb') as b:
  try: r=subprocess.run(argv,cwd=repo,stdout=a,stderr=b,timeout=timeout); rc=r.returncode if r.returncode>=0 else 128-r.returncode
  except subprocess.TimeoutExpired: rc=124
 record={'stage':name,'argv':argv,'cwd':str(repo),'timeout_seconds':timeout,
  'exit':rc,'elapsed_seconds':round(time.monotonic()-t,3),
  'stdout':str(stdout.relative_to(run)),'stderr':str(stderr.relative_to(run))}
 with record_lock:
  records.append(record); save('commands.json',records)
 return rc,stdout.read_text(errors='replace')+stderr.read_text(errors='replace')

functional=[('fn_phase_0',0,10),('fn_phase_3',3,10),('fn_phase_7',7,10),
 ('fn_phase_13',13,10),('fn_phase_17',17,10),('fn_ratio_10_11',5,11)]
controls=[('control_s01','S01'),('control_s02','S02'),('control_s09','S09'),('control_combined','COMBINED')]
b1_control=('control_b1_stale','S01','B1_STALE_CONTROL')
faults=[('self_bank','S01','MUTANT_LEDGER_BANK','FAIL_FRONT_BANK_CORRUPTED'),
 ('self_swap_premature','S01','MUTANT_CAUSALITY_INVERSION','FAIL_SWAP_PREMATURE_DONE'),
 ('self_clear_count','S09','MUTANT_CLEAR_COUNT','FAIL_INCOMPLETE_CLEAR'),
 ('self_orphan','S01','MUTANT_ORPHAN_ACK','FAIL_ORPHAN_ACK'),
 ('self_clear_premature','S09','PREMATURE_CLEAR_DONE','FAIL_CLEAR_PREMATURE_DONE'),
 ('self_swap_duplicate','S01','DUPLICATE_SWAP_DONE','FAIL_SWAP_DUPLICATE_DONE'),
 ('self_clear_duplicate','S09','DUPLICATE_CLEAR_DONE','FAIL_CLEAR_DUPLICATE_DONE'),
 ('self_boundary_shift','S02','BOUNDARY_SHIFT','FAIL_S02_EFFECT_WINDOW'),
 ('self_timing','S01','TIMING_OBSERVATION_FAULT','FAIL_EXTERNAL_TIMING'),
 ('self_scanout','S01','SCANOUT_OBSERVATION_FAULT','FAIL_SCANOUT_BANK'),
 ('self_fb_data','S01','FB_DATA_OBSERVATION_FAULT','FAIL_FB_LEDGER'),
 ('self_clear_address','S09','CLEAR_ADDRESS_OBSERVATION_FAULT','FAIL_CLEAR_SEQUENCE')]
b1_faults=[
 ('self_b1_request_wrong','B1_REQUEST_WRONG','FAIL_B1_REQUEST_VALUE'),
 ('self_b1_request_duplicate','B1_REQUEST_DUP','FAIL_B1_REQUEST_DUPLICATE'),
 ('self_b1_commit_early','B1_COMMIT_EARLY','FAIL_B1_COMMIT_EDGE'),
 ('self_b1_commit_wrong','B1_COMMIT_WRONG','FAIL_B1_COMMIT_BANK'),
 ('self_b1_commit_duplicate','B1_COMMIT_DUP','FAIL_B1_COMMIT_DUPLICATE'),
 ('self_b1_ack_early','B1_ACK_EARLY','FAIL_B1_ACK_CAUSALITY'),
 ('self_b1_ack_orphan','B1_ACK_ORPHAN','FAIL_B1_EVENT_IDENTITY'),
 ('self_b1_ack_duplicate','B1_ACK_DUP','FAIL_B1_ACK_DUPLICATE'),
 ('self_b1_sync_early','B1_SYNC_EARLY','FAIL_B1_ACK_SYNC'),
 ('self_b1_consume_early','B1_CONSUME_EARLY','FAIL_B1_ACK_CONSUMPTION'),
 ('self_b1_owner_early','B1_OWNER_EARLY','FAIL_B1_OWNER_CAUSALITY'),
 ('self_b1_owner_wrong','B1_OWNER_WRONG','FAIL_B1_OWNER_BANK'),
 ('self_b1_owner_duplicate','B1_OWNER_DUP','FAIL_B1_OWNER_DUPLICATE'),
 ('self_b1_done_early','B1_DONE_EARLY','FAIL_B1_DONE_LINK'),
 ('self_b1_stale_ack','B1_STALE_ACK','FAIL_B1_STALE_EPOCH')]
b2_controls=[('control_b2_clear','B2_CLEAR'),('control_b2_cancel','B2_CANCEL')]
b2_functional=[(f'b2_swap_{p}', 'B2_SWAP',p,h) for _,p,h in functional]+[(f'b2_combined_{p}','B2_COMBINED',p,h) for _,p,h in functional]
b2_faults=[
 ('self_b2_early_swap','B2_SWAP','B2_EARLY_SWAP','FAIL_B2_SWAP_DONE'),
 ('self_b2_early_clear','B2_CLEAR','B2_EARLY_CLEAR','FAIL_B2_CLEAR_DONE'),
 ('self_b2_early_combined','B2_COMBINED','B2_EARLY_COMBINED','FAIL_B2_COMBINED_DONE'),
 ('self_b2_sticky_drop','B2_CLEAR','B2_STICKY_DROP','FAIL_B2_STICKY'),
 ('self_b2_transient','B2_CLEAR','B2_TRANSIENT','FAIL_B2_STICKY'),
 ('self_b2_stale_done','B2_CLEAR','B2_STALE_DONE','FAIL_B2_DONE_IDENTITY'),
 ('self_b2_canceled_done','B2_CANCEL','B2_CANCELED_DONE','FAIL_B2_DONE_IDENTITY'),
 ('self_b2_busy_low','B2_SWAP','B2_BUSY_LOW','FAIL_B2_SWAP_DONE'),
 ('self_b2_accept_forbidden','B2_SWAP','B2_ACCEPT_FORBIDDEN','FAIL_B2_WINDOW_REJECT'),
 ('self_b2_error_protocol','B2_SWAP','B2_ERROR_PROTOCOL','FAIL_B2_ERROR_PROTOCOL'),
 ('self_b2_clear_target','B2_CLEAR','B2_CLEAR_TARGET','FAIL_B2_CLEAR_TARGET'),
 ('self_b2_physical_bank','B2_CLEAR','B2_PHYSICAL_BANK','FAIL_B2_CLEAR_BANK'),
 ('self_b2_reject_write','B2_SWAP','B2_REJECT_WRITE','FAIL_B2_REJECT_WRITE'),
 ('self_b2_reject_request','B2_SWAP','B2_REJECT_REQUEST','FAIL_B2_REJECT_REQUEST'),
 ('self_b2_reject_target','B2_SWAP','B2_REJECT_TARGET','FAIL_B2_REJECT_TARGET'),
 ('self_b2_clear_sequence','B2_CLEAR','B2_CLEAR_SEQUENCE','FAIL_B2_CLEAR_SEQUENCE')]
b3_slots=['REQUEST','PRECOMMIT','COMMIT_BEFORE','POSTCOMMIT','ACKSYNC','OWNER','COMBINED_CLEAR','CLEAR9598','CLEAR9599','COMBINED9598','COMBINED9599','IDLE']
b3_controls=[]
for reset in ['FULL','PLL']:
 for slot in b3_slots:
  b3_controls.append(('b3_'+reset.lower()+'_'+slot.lower(),slot,reset,1,0,0,0,10))
 for slot in ['REQUEST','PRECOMMIT','COMMIT_BEFORE','POSTCOMMIT','ACKSYNC','OWNER','COMBINED_CLEAR','COMBINED9599']:
  b3_controls.append(('b3_'+reset.lower()+'_'+slot.lower()+'_pol0',slot,reset,0,0,0,3,10))
 b3_controls.append(('b3_'+reset.lower()+'_stop','REQUEST',reset,1,1,0,5,11))
 b3_controls.append(('b3_'+reset.lower()+'_old_done','POSTCOMMIT',reset,1,0,1,7,10))
b3_controls.append(('b3_pll_abort_w1c','REQUEST','PLL',1,0,0,0,10,1))
b3_controls.append(('b3_pll_status_read','REQUEST','PLL',1,0,0,0,10,0,1))
b3_faults=[
 ('self_b3_stale_request','REQUEST','PLL','B3_STALE_REQUEST','FAIL_B3_STALE_REQUEST'),
 ('self_b3_stale_ack','POSTCOMMIT','PLL','B3_STALE_ACK','FAIL_B3_STALE_ACK'),
 ('self_b3_stale_commit','POSTCOMMIT','PLL','B3_STALE_COMMIT','FAIL_B3_STALE_COMMIT'),
 ('self_b3_stale_ready','REQUEST','PLL','B3_STALE_READY','FAIL_B3_STALE_READY'),
 ('self_b3_old_done','IDLE','PLL','B3_STALE_DONE','FAIL_B3_STALE_DONE'),
 ('self_b3_abort_drop','REQUEST','PLL','B3_ABORT_DROP','FAIL_B3_ABORT'),
 ('self_b3_abort_idle','IDLE','PLL','B3_ABORT_IDLE','FAIL_B3_ABORT'),
 ('self_b3_reset_status','REQUEST','FULL','B3_RESET_STATUS','FAIL_B3_RESET_STATUS'),
 ('self_b3_invalid_write','REQUEST','PLL','B3_INVALID_WRITE','FAIL_B3_INVALID_WRITE'),
 ('self_b3_premature_ready','REQUEST','PLL','B3_PREMATURE_READY','FAIL_B3_READY'),
 ('self_b3_fresh_progress','REQUEST','PLL','B3_FRESH_PROGRESS','FAIL_B3_FRESH_PROGRESS'),
 ('self_b3_ready_baseline','REQUEST','PLL','B3_READY_BASELINE','FAIL_B3_READY_BASELINE'),
 ('self_b3_dest_early_ready','REQUEST','PLL','B3_DEST_EARLY_READY','FAIL_B3_DEST_READY'),
 ('self_b3_dest_early_release','REQUEST','PLL','B3_DEST_EARLY_RELEASE','FAIL_B3_DEST_RELEASE'),
 ('self_b3_abort_collision_drop','REQUEST','PLL','B3_ABORT_COLLISION_DROP','FAIL_B3_ABORT'),
 ('self_b3_status_pre_busy','REQUEST','PLL','B3_STATUS_PRE_BUSY','FAIL_B2_STATUS_LEDGER'),
 ('self_b3_cancel_busy','REQUEST','PLL','B3_CANCEL_BUSY','FAIL_B3_BUSY')]
def b3_args(slot,reset,pol=1,stop=0,old=0,phase=0,half=10,w1c=0,status_read=0):
 return ['+SCENARIO=B3','+B2_PROFILE','+B3_PROFILE',f'+B3_SLOT={slot}',f'+B3_RESET={reset}',f'+B3_POLARITY={pol}',f'+B3_STOP_CLOCK={stop}',f'+B3_OLD_DONE={old}',f'+B3_W1C_COLLISION={w1c}',f'+B3_STATUS_READ_COLLISION={status_read}',f'+CLOCK_PHASE_NS={phase}',f'+CLK50_HALF_NS={half}']
b4_controls=[('b4_combined_fb','B4_COMBINED',0,10,'FULL',0),
 ('b4_combined_control','B4_COMBINED',0,10,'FULL',1),
 ('b4_display_full','B4_DISPLAY',3,10,'FULL',0),
 ('b4_display_pll','B4_DISPLAY',7,10,'PLL',0),
 ('b4_vsync_0','B4_VSYNC',0,10,'FULL',0),
 ('b4_vsync_ratio','B4_VSYNC',5,11,'FULL',0)]
b4_faults=[('self_b4_reject_accept','b4_combined_fb','B4_REJECT_ACCEPT','FAIL_B4_REJECT'),
 ('self_b4_idle_bank','b4_combined_fb','B4_IDLE_BANK','FAIL_B4_IDLE_BANK'),
 ('self_b4_black_leak','b4_display_full','B4_BLACK_LEAK','FAIL_B4_BLACK'),
 ('self_b4_early_arm','b4_display_full','B4_EARLY_ARM','FAIL_B4_BLACK'),
 ('self_b4_vsync_drop','b4_vsync_0','B4_VSYNC_DROP','FAIL_B4_VSYNC'),
 ('self_b4_vsync_unselected','b4_vsync_0','B4_VSYNC_UNSELECTED','FAIL_B4_VSYNC'),
 ('self_b4_vsync_collision','b4_vsync_0','B4_VSYNC_COLLISION','FAIL_B4_VSYNC'),
 ('self_b4_status_vsync','b4_vsync_0','B4_STATUS_VSYNC','FAIL_B4_STATUS'),
 ('self_b4_white_drop','b4_display_full','B4_WHITE_DROP','FAIL_B4_WHITE_MARKER')]
b4_all_controls={x[0]:x for x in b4_controls}
def b4_args(item):
 name,scenario,phase,half,reset,control=item
 return ['+SCENARIO='+scenario,'+B2_PROFILE','+B4_PROFILE',f'+CLOCK_PHASE_NS={phase}',f'+CLK50_HALF_NS={half}',f'+B4_RESET={reset}',f'+B4_CONTROL={control}']
b4_guard=os.environ.get('B4_TEST_GUARD','')
if b4_guard not in ['', 'MISSING_BIN','MISSING_ARTIFACT','MISSING_LANE','FINAL_CONSISTENCY','FINAL_READONLY','LINT']:
 raise ValueError('Unknown B4_TEST_GUARD')
if b4_guard=='FINAL_CONSISTENCY': os.environ['TEST_FINAL_CONSISTENCY_FAIL']='1'
if b4_guard=='FINAL_READONLY': os.environ['TEST_FINAL_READONLY_FAIL']='1'
if b4_guard=='LINT': os.environ['TEST_LINT_FAIL']='1'
required=[x[0] for x in functional+controls+faults]+[b1_control[0]]+[x[0] for x in b1_faults]+[x[0] for x in b2_controls+b2_functional+b2_faults]+[x[0] for x in b3_controls+b3_faults]+[x[0] for x in b4_controls+b4_faults]

if b4_guard:
 required=['b4_combined_fb']+(['b4_combined_control'] if b4_guard=='MISSING_LANE' else [])
 config['profile']='B4 isolated guard '+b4_guard+'; no B1-B3 full regression'
elif os.environ.get('B4_ONLY'):
 selected=os.environ['B4_ONLY']
 b4_controls=[x for x in b4_controls if selected=='1' or x[0] in selected.split(',')]
 b4_faults=[x for x in b4_faults if selected=='1' or x[0] in selected.split(',')]
 required=[x[0] for x in b4_controls+b4_faults]
 if not required: raise ValueError('Unknown selected B4 lane')
 config['profile']='B4_ONLY selected; full131 Owner regression NOT_RUN'
elif os.environ.get('TEST_B3_MISSING_BIN')=='1' or os.environ.get('TEST_B3_MISSING_ARTIFACT')=='1':
 required=['b3_pll_request']
 config['profile']='isolated B3 guard metadata/artifact selftest; real B3 REQUEST/PLL target'
elif os.environ.get('B3_DEVELOP_ONLY'):
 selected=os.environ.get('B3_DEVELOP_ONLY')
 b3_controls=[x for x in b3_controls if selected=='1' or x[0] in selected.split(',')]
 b3_faults=[x for x in b3_faults if selected=='1' or x[0] in selected.split(',')]
 required=[x[0] for x in b3_controls+b3_faults]
 if not required: raise ValueError('Unknown bounded B3 development lane')
 config['profile']='B3 development only; NOT final 68-lane regression'
elif os.environ.get('TEST_B2_MISSING_BIN')=='1':
 required=['control_b2_clear']
 config['profile']='isolated B2 missing first-DONE coverage metadata; real B2_CLEAR target'
elif os.environ.get('B2_DEVELOP_ONLY')=='1':
 required=[x[0] for x in b2_controls+b2_functional[:1]+b2_functional[6:7]+b2_faults]
 config['profile']='B2 development controls and sensitivity, not final regression'
elif os.environ.get('TEST_B1_MISSING_BIN')=='1':
 required=['control_s01']
 config['profile']='isolated B1 actual-event coverage metadata selftest; real S01 target'
elif os.environ.get('TEST_MISSING_ARTIFACT')=='1':
 required=['control_s09']
 config['profile']='isolated guard artifact selftest; requires real control_s09 stdout/stderr'
elif os.environ.get('TEST_MISSING_LANE')=='1':
 required=['control_s09','control_combined']
 config['profile']='isolated guard lane selftest; requires control_s09 and control_combined'
elif os.environ.get('TEST_FINAL_CONSISTENCY_FAIL')=='1' or os.environ.get('TEST_FINAL_READONLY_FAIL')=='1':
 required=['control_s09']
 config['profile']='isolated final consistency metadata fixture selftest; real S09 target'
else: config['profile']='B4 FULL:preserved B1-B3 131 lanes +6 B4 controls +9 actual-record sensitivities'
save('config.json',config)

def b4_coverage(raw,args):
 lines=re.findall(r'\[B4_SUMMARY\] (.*)',raw)
 if len(lines)!=1: raise ValueError('B4 summary absent/duplicate')
 f={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',lines[0])}
 bins={'consume_errors':len(re.findall(r'\[B4_CONSUME_ERROR\]',raw)),
  'idle_first':len(re.findall(r'\[B4_FIRST_IDLE_ADDRESS\]',raw)),
  'quiet_wraps':len(re.findall(r'\[B4_QUIET_WRAP\]',raw)),
  'vs_events':len(re.findall(r'\[B4_VSYNC_EVENT\]',raw)),
  'vs_collisions':len(re.findall(r'\[B4_VSYNC_EVENT\].*selected_W1C=1',raw))}
 scenario=next(a.split('=',1)[1] for a in args if a.startswith('+SCENARIO='))
 if scenario=='B4_COMBINED' and (f['consume_errors']!=1 or f['idle_first']!=1 or '[B4_IDLE_COMMIT]' not in raw): raise ValueError('B4 combined reach missing')
 if scenario=='B4_DISPLAY' and (f['quiet_wraps']!=2 or f['quiet_pixels']!=420000 or f['black_checks']<=420000 or f['white_markers']<3): raise ValueError('B4 full black frame/nonvacuous white reach missing')
 if scenario=='B4_VSYNC' and (f['vs_collisions']!=1 or f['vs_events']<3 or f['status_reads']<2): raise ValueError('B4 natural VSYNC/W1C collision reach missing')
 return {'scenario':scenario,'summary':f,'actual_bins':bins}

def b1_coverage(raw):
 summary=re.findall(r'\[B1_SUMMARY\] (.*)',raw)
 if len(summary)!=1: raise ValueError('B1 summary absent/duplicate')
 fields={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',summary[0])}
 accepts=re.findall(r'\[B1_ACCEPT\] id=(\d+) epoch=(\d+) type=(\d+)',raw)
 canceled=set(int(i) for i in re.findall(r'\[B1_INVALIDATE\] .*?id=(\d+) cancelled=1',raw))
 records=re.findall(r'\[B1_EVENT\] kind=(\d+) id=(\d+) epoch=(\d+) value=([01]) x=(\d+) y=(\d+) injected=0 time=(\d+)',raw)
 observed={str(k):sum(int(e[0])==k for e in records) for k in range(1,8)}
 if [int(a[0]) for a in accepts]!=list(range(1,len(accepts)+1)): raise ValueError('B1 accepted identity sequence')
 if fields['accepted']!=len(accepts): raise ValueError('B1 accepted summary mismatch')
 expected_request=sum(int(t)&1 for _,_,t in accepts)
 expected_chain=sum((int(t)&1) and int(i) not in canceled for i,_,t in accepts)
 for k,label in enumerate(['request','commit','ack_p','ack_sync','consumed','owner','done_diag'],1):
  if fields[label]!=observed[str(k)]: raise ValueError('B1 raw bin/summary mismatch:'+label)
  if k==1 and fields[label]!=expected_request: raise ValueError('B1 request coverage missing')
  if 2<=k<=6 and fields[label]!=expected_chain+sum(int(e[0])==k and int(e[1]) in canceled for e in records): raise ValueError('B1 causal-chain coverage missing:'+label)
 # Validate every surviving operation's record identity and partial ordering,
 # not only totals. Clear-only must have no swap-chain records.
 for op,epoch,typ in accepts:
  op_records=[e for e in records if e[1]==op]
  if any(e[2]!=epoch for e in op_records): raise ValueError('B1 record epoch mismatch')
  kinds=[int(e[0]) for e in op_records]
  if not (int(typ)&1):
   if any(k<7 for k in kinds): raise ValueError('B1 CLEAR ownership event')
  elif int(op) not in canceled:
   if kinds[:6]!=[1,2,3,4,5,6]: raise ValueError('B1 event identity/order')
   times=[int(e[6]) for e in op_records[:6]]
   if times!=sorted(times): raise ValueError('B1 causal timestamps')
   if tuple(map(int,op_records[1][4:6]))!=(799,524): raise ValueError('B1 commit geometry')
  else:
   if kinds!=[1,2,3,4,5,6][:len(kinds)]: raise ValueError('B1 canceled illegal causal prefix/DONE')
   if [int(e[6]) for e in op_records]!=sorted(int(e[6]) for e in op_records): raise ValueError('B1 canceled event timestamps')
 return {'summary':fields,'actual_event_bins':observed,'accepted_operations':len(accepts)}

def b2_coverage(raw):
 summaries=re.findall(r'\[B2_SUMMARY\] (.*)',raw)
 if len(summaries)!=1: raise ValueError('B2 summary absent/duplicate')
 f={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',summaries[0])}
 complete=re.findall(r'\[B2_FIRST_DONE\] (.*)',raw)
 rows=[{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',row)} for row in complete]
 if len(rows)!=f['completed']: raise ValueError('B2 complete raw mismatch')
 for row in rows:
  if row['post_busy']!=0 or row['pre_busy']!=1 or row['post_done']!=1: raise ValueError('B2 completion fields')
  if row['type']&1 and (row['consumed']!=1 or row['owner']!=1): raise ValueError('B2 ownership prerequisite')
  if row['type']&2 and row['clear_count']!=9600: raise ValueError('B2 physical prerequisite')
 bins={k:sum(row['type']==t for row in rows) for k,t in [('swap',1),('clear',2),('combined',3)]}
 for k,v in bins.items():
  if v!=f[k]: raise ValueError('B2 first-event bin mismatch:'+k)
 if f['rejections']!=len(re.findall(r'\[B2_WINDOW\]',raw)): raise ValueError('B2 rejection raw mismatch')
 if f['collision']!=len(re.findall(r'\[B2_COLLISION\]',raw)): raise ValueError('B2 collision raw mismatch')
 windows=[]
 for row in re.findall(r'\[B2_WINDOW\] (.*)',raw):
  w={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',row) if k not in ['addr','response']}
  w['address']=re.search(r'addr=(\w+)',row).group(1)
  unready=re.search(r'\[B3_UNREADY_ERROR\] epoch='+str(w['epoch'])+r' addr='+w['address']+r' response=01 ready=1 physical=0 time='+str(w['time'])+r'(?:\s|$)',raw)
  if 'response=01 ready=1 physical=0' not in row or (w['pre_busy']!=1 and not (w['window']==0 and unready)):
   raise ValueError('B2 rejection fields: requires BUSY or matching actually checked B3 unready final phase')
  windows.append(w)
 return {'window_records':windows,'summary':f,'first_done_bins':bins,'first_done_records':rows}

def b3_coverage(raw):
 summaries=re.findall(r'\[B3_SUMMARY\] (.*)',raw)
 if len(summaries)!=1: raise ValueError('B3 summary absent/duplicate')
 f={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',summaries[0])}
 slots=re.findall(r'\[B3_SLOT_REACHED\] (.*)',raw)
 if len(slots)!=1: raise ValueError('B3 slot record absent/duplicate')
 row={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',slots[0])}
 slot=re.search(r'slot=(\w+)',slots[0]).group(1)
 reset=re.search(r'reset=(\w+)',slots[0]).group(1)
 if slot=='IDLE':
  if row['live']!=0 or row['pre_DONE']!=1: raise ValueError('B3 idle not actually reached')
 else:
  if row['live']!=1: raise ValueError('B3 active slot not reached')
 if slot in ['REQUEST','PRECOMMIT','COMMIT_BEFORE'] and (row['commit']!=0 or row['ack_p']!=0): raise ValueError('B3 precommit slot')
 if slot=='PRECOMMIT' and (row['x'],row['y'])!=(798,524): raise ValueError('B3 798 reach')
 if slot=='COMMIT_BEFORE' and (row['x'],row['y'])!=(799,524): raise ValueError('B3 799 pre-edge reach')
 if slot=='POSTCOMMIT' and (row['commit']!=1 or row['ack_p']!=1 or row['sync']!=0 or row['consume']!=0): raise ValueError('B3 postcommit pre-return reach')
 if slot=='ACKSYNC' and (row['sync']!=1 or row['consume']!=0): raise ValueError('B3 ACK sync before consume reach')
 if slot=='OWNER' and (row['owner']!=1 or row['consume']!=1 or row['clear_count']!=0): raise ValueError('B3 owner/clear-start reach')
 if slot=='COMBINED_CLEAR' and row['clear_count']!=1: raise ValueError('B3 active clear reach')
 if slot.endswith('9598') and row['clear_count']!=9599: raise ValueError('B3 actual physical9598')
 if slot.endswith('9599') and row['clear_count']!=9600: raise ValueError('B3 actual physical9599 before DONE')
 wraps=re.findall(r'\[B3_QUIET_WRAP\] (.*)',raw)
 completed=re.findall(r'\[B3_COMPLETION\] (.*fresh=1.*)',raw)
 actual={'release':len(re.findall(r'\[B3_DEST_RELEASE\]',raw)),'quiet_wraps':len(wraps),'fresh_swap':0,'fresh_clear':0,'fresh_combined':0}
 for line in completed:
  t=int(re.search(r'type=(\d+)',line).group(1));actual[{1:'fresh_swap',2:'fresh_clear',3:'fresh_combined'}[t]]+=1
 if any(actual[k]!=f[k] for k in actual): raise ValueError('B3 raw summary mismatch')
 if f['quiet_pixels']<420000 or f['quiet_wraps']!=2: raise ValueError('B3 quiet full natural frame missing')
 if not all(f[k]>0 for k in ['reject_fb','reject_control','error_wait','invalid_samples','dest_ready','ready','release']): raise ValueError('B3 required bin absent')
 if any(f[k]!=1 for k in ['fresh_swap','fresh_clear','fresh_combined']): raise ValueError('B3 fresh typed progress missing')
 if reset=='FULL' and slot=='IDLE':
  prefill=re.findall(r'\[B3_PREFILLED_STATUS\] status=([0-9a-f]+)',raw)
  if len(prefill)!=1 or (int(prefill[0],16)&11)!=11: raise ValueError('B3 full-reset actual sticky prefill missing')
 if reset=='PLL' and slot!='IDLE' and f['active_loss']!=1: raise ValueError('B3 active PLL abort missing')
 if reset=='PLL' and slot=='IDLE' and f['idle_loss']!=1: raise ValueError('B3 idle PLL missing')
 return {'summary':f,'actual_bins':actual,'slot':slot,'reset':reset,'reach':row}

def lane(name,args,expected=None,activation=None,missing=False):
 global target_exit
 rc,text=execute(name,['vvp','-i',str(run/'test.vvp')]+args,missing_stderr=missing)
 if expected:
  failures=re.findall(r'\[ASSERT_FAIL\] id=(\S+)',text)
  valid=rc==1 and failures==[expected] and activation in text and 'SUMMARY: PASS' not in text
  classification='SELFTEST_EXPECTED_REJECTION' if valid else 'FAIL'
 else:
  valid=rc==0 and 'SUMMARY: PASS P12A2 Independent DV completed successfully' in text and '[ASSERT_FAIL]' not in text and 'FATAL:' not in text
  classification='PASS' if valid else 'FAIL'
  if name.startswith('fn_'):
   valid=valid and all('Starting '+s+':' in text for s in ['S01','S02','S03','S04','S05','S06','S07','S08','S09','COMBINED'])
   valid=valid and all(t in text for t in ['type=1','type=2','type=3','[SCANOUT_BANK_OBSERVED]','target=798','target=799','address=9599'])
   valid=valid and bool(re.search(r'\[SCOREBOARD_SUMMARY\] accepted=11 completed=8 canceled=3 swap=6 clear=1 combined=1 scanout=7 boundaries=2 ',text))
  if valid:
   try:
    b1_coverage(text); b2_coverage(text)
    if '+B3_PROFILE' in args: b3_coverage(text)
    if '+B3_STATUS_READ_COLLISION=1' in args and '[B3_PRE_STATUS_SAMPLE]' not in text: raise ValueError('B3 pre-recognition STATUS overlap missing')
    if '+B3_W1C_COLLISION=1' in args and not re.search(r'\[B3_ABORT_COLLISION\].*event=1 selected_W1C=1 actual_ABORT=1 observed_ABORT=1 expected_ABORT=1',text): raise ValueError('B3 actual abort/W1C collision missing')
   except (ValueError,KeyError) as e: valid=False; print(str(e),file=sys.stderr)
  classification='PASS' if valid else 'FAIL'
 row={'name':name,'args':args,'target_exit':rc,'guard_exit':0 if valid else 1,
      'final_exit':0 if valid else (rc or 1),'classification':classification,
      'expected_assertion':expected,'activation':activation,
      'stdout_sha256':digest(logs/(name+'.stdout')),
      'stderr_sha256':digest(logs/(name+('.preserved-stderr' if missing else '.stderr'))),
      'assertion_failures':re.findall(r'\[ASSERT_FAIL\] id=(\S+)',text)}
 lanes.append(row)
 print(name,classification,'target_exit='+str(rc),flush=True)
 if not valid: target_exit=rc or 1; raise RuntimeError('Lane failed: '+name)

try:
 rc,_=execute('compile',['iverilog','-g2012','-s','tb_p12a2_vga_cdc','-o',str(run/'test.vvp')]+sources)
 if rc: target_exit=rc; raise RuntimeError('compile failed')
 top='NONEXISTENT_TRIGGER_MODULE' if os.environ.get('TEST_LINT_FAIL')=='1' else 'AHB_VRAM_DUAL_BUFFER'
 rc,_=execute('lint-baseline',['verilator','--lint-only','--top-module',top]+sources[:6])
 (run/'lint-target-exit.txt').write_text(str(rc)+'\n')
 if rc: target_exit=rc; raise RuntimeError('required baseline lint failed')
 wall_rc,wall_text=execute('lint-wall',['verilator','--lint-only','-Wall','--top-module','AHB_VRAM_DUAL_BUFFER']+sources[:6])
 save('lint-profile.json',{'required_baseline_exit':0,'wall_diagnostic_exit':wall_rc,
  'wall_warnings':re.findall(r'%Warning-(\w+)',wall_text),'wall_waivers':[],
  'wall_status':'PASS' if wall_rc==0 else 'DIAGNOSTIC_NONZERO_NOT_WAIVED'})
 if b4_guard:
  lane('b4_combined_fb',b4_args(b4_all_controls['b4_combined_fb']),missing=b4_guard=='MISSING_ARTIFACT')
 elif os.environ.get('B4_ONLY'):
  def b4_job(item): lane(item[0],b4_args(item))
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(b4_job,b4_controls))
  def b4_fault_job(item):
   name,control,fault,expected=item
   lane(name,b4_args(b4_all_controls[control])+['+B4_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(b4_fault_job,b4_faults))
 elif os.environ.get('TEST_B3_MISSING_BIN')=='1' or os.environ.get('TEST_B3_MISSING_ARTIFACT')=='1':
  lane('b3_pll_request',b3_args('REQUEST','PLL'),missing=os.environ.get('TEST_B3_MISSING_ARTIFACT')=='1')
 elif os.environ.get('B3_DEVELOP_ONLY'):
  def b3_dev_job(item):
   name,*args=item;lane(name,b3_args(*args))
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(b3_dev_job,b3_controls))
  for name,slot,reset,fault,expected in b3_faults:
   lane(name,b3_args(slot,reset,w1c=1 if fault=='B3_ABORT_COLLISION_DROP' else 0,status_read=1 if fault=='B3_STATUS_PRE_BUSY' else 0)+['+B3_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
 elif os.environ.get('TEST_B2_MISSING_BIN')=='1':
  lane('control_b2_clear',['+SCENARIO=B2_CLEAR','+B2_PROFILE'])
 elif os.environ.get('B2_DEVELOP_ONLY')=='1':
  for name,scenario in b2_controls: lane(name,['+SCENARIO='+scenario,'+B2_PROFILE'])
  for name,scenario,phase,half in b2_functional[:1]+b2_functional[6:7]:
   lane(name,['+SCENARIO='+scenario,'+B2_PROFILE',f'+CLOCK_PHASE_NS={phase}',f'+CLK50_HALF_NS={half}'])
  for name,scenario,fault,expected in b2_faults:
   lane(name,['+SCENARIO='+scenario,'+B2_PROFILE','+B2_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
 elif os.environ.get('TEST_B1_MISSING_BIN')=='1':
  lane('control_s01',['+SCENARIO=S01'])
 elif os.environ.get('TEST_MISSING_ARTIFACT')=='1':
  # Preserve real target stdout/stderr under a fresh isolated run, but deliberately
  # leave the required stderr pathname absent. No historical evidence is deleted.
  lane('control_s09',['+SCENARIO=S09'],missing=True)
 elif os.environ.get('TEST_FINAL_CONSISTENCY_FAIL')=='1' or os.environ.get('TEST_FINAL_READONLY_FAIL')=='1':
  lane('control_s09',['+SCENARIO=S09'])
 elif os.environ.get('TEST_MISSING_LANE')=='1':
  # Real passing S09 exists; required combined lane is absent in this isolated profile.
  lane('control_s09',['+SCENARIO=S09'])
 else:
  def functional_job(item):
   name,phase,half=item
   lane(name,['+SCENARIO=ALL','+HCLK_HALF_NS=10',f'+CLK50_HALF_NS={half}',f'+CLOCK_PHASE_NS={phase}'])
  # Concurrent targets have distinct log files; source is immutable during runs.
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(functional_job,functional))
  for name,scenario in controls: lane(name,['+SCENARIO='+scenario])
  lane(b1_control[0],['+SCENARIO='+b1_control[1],'+'+b1_control[2]])
  for name,fault,expected in b1_faults:
   lane(name,['+SCENARIO=S01','+'+fault],expected,'[FAULT_ACTIVATION] '+fault)
  for name,scenario,fault,expected in faults:
   activation='[S02_EFFECT]' if fault=='BOUNDARY_SHIFT' else '[FAULT_ACTIVATION] '+fault
   lane(name,['+SCENARIO='+scenario,'+'+fault],expected,activation)
  for name,scenario in b2_controls: lane(name,['+SCENARIO='+scenario,'+B2_PROFILE'])
  def b2_job(item):
   name,scenario,phase,half=item
   lane(name,['+SCENARIO='+scenario,'+B2_PROFILE',f'+CLOCK_PHASE_NS={phase}',f'+CLK50_HALF_NS={half}'])
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(b2_job,b2_functional))
  for name,scenario,fault,expected in b2_faults:
   lane(name,['+SCENARIO='+scenario,'+B2_PROFILE','+B2_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
  def b3_job(item):
   name,*args=item;lane(name,b3_args(*args))
  with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
   list(pool.map(b3_job,b3_controls))
  for name,slot,reset,fault,expected in b3_faults:
   lane(name,b3_args(slot,reset,w1c=1 if fault=='B3_ABORT_COLLISION_DROP' else 0,status_read=1 if fault=='B3_STATUS_PRE_BUSY' else 0)+['+B3_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
  for item in b4_controls: lane(item[0],b4_args(item))
  for name,control,fault,expected in b4_faults:
   lane(name,b4_args(b4_all_controls[control])+['+B4_FAULT='+fault],expected,'[FAULT_ACTIVATION] '+fault)
 # Real evidence guard: validate actual files and required semantic lane results.
 reasons=[]
 b1_results={}
 b2_results={}
 b3_results={}
 b4_results={}
 by_name={l['name']:l for l in lanes}
 for name in required:
  if name not in by_name: reasons.append('missing_required_lane:'+name); continue
  for suffix in ['stdout','stderr']:
   p=logs/(name+'.'+suffix)
   if not p.is_file(): reasons.append('missing_required_artifact:'+str(p.relative_to(run)))
   elif digest(p)!=by_name[name][suffix+'_sha256']: reasons.append('artifact_hash_mismatch:'+str(p.relative_to(run)))
  if by_name[name]['final_exit']!=0: reasons.append('nonpassing_lane:'+name)
 post=source_manifest(); save('source-post.json',post)
 if post!=pre: reasons.append('source_identity_drift')
 for name in required:
  p=logs/(name+'.stdout')
  if p.is_file() and name in by_name:
   raw=p.read_text(errors='replace'); row=by_name[name]
   if row['classification']=='PASS':
    try:
     b1_results[name]=b1_coverage(raw);b2_results[name]=b2_coverage(raw)
     if '+B3_PROFILE' in row['args']: b3_results[name]=b3_coverage(raw)
     if '+B4_PROFILE' in row['args']: b4_results[name]=b4_coverage(raw,row['args'])
    except (ValueError,KeyError) as e: reasons.append('b1_coverage_reject:'+name+':'+str(e))
   if row['classification']=='PASS' and ('SUMMARY: PASS P12A2 Independent DV completed successfully' not in raw or '[ASSERT_FAIL]' in raw):
    reasons.append('semantic_log_mismatch:'+name)
   if row['classification']=='SELFTEST_EXPECTED_REJECTION' and '[ASSERT_FAIL] id='+row['expected_assertion'] not in raw:
    reasons.append('selftest_log_mismatch:'+name)
 if os.environ.get('TEST_B1_MISSING_BIN')=='1' and 'control_s01' in b1_results:
  fixture=json.loads(json.dumps(b1_results))
  fixture['control_s01']['actual_event_bins']['4']=0
  save('b1-coverage-fixture.json',{'fixture':'isolated monitor coverage metadata input; original raw log retained','coverage':fixture})
  validation=json.loads((run/'b1-coverage-fixture.json').read_text())['coverage']
 else: validation=b1_results
 for name,coverage in validation.items():
  if coverage['summary']['request']>0:
   for kind in range(2,7):
    if coverage['actual_event_bins'][str(kind)]!=coverage['summary'][['commit','ack_p','ack_sync','consumed','owner'][kind-2]]:
     reasons.append('b1_event_bin_missing:'+name+':'+str(kind))
 # Same validation predicate for raw-derived normal coverage and isolated
 # metadata fault. Original target logs remain untouched.
 if os.environ.get('TEST_B2_MISSING_BIN')=='1':
  fixture=json.loads(json.dumps(b2_results));fixture['control_b2_clear']['first_done_bins']['clear']=0
  save('b2-coverage-fixture.json',{'fixture':'isolated coverage metadata, no DUT/log mutation','coverage':fixture})
  b2_validation=json.loads((run/'b2-coverage-fixture.json').read_text())['coverage']
 else: b2_validation=b2_results
 for name,cov in b2_validation.items():
  f=cov['summary']
  for kind in ['swap','clear','combined']:
   if cov['first_done_bins'][kind]!=f[kind]: reasons.append('b2_event_bin_missing:'+name+':'+kind)
  if name.startswith('b2_swap_'):
   for key in ['swap','pending','boundary','postcommit','idle_cpu','zero','collision']:
    if f[key]==0: reasons.append('b2_required_bin_missing:'+name+':'+key)
   if f['swap']!=3: reasons.append('b2_swap_count:'+name)
   post_addresses={w['address'] for w in cov['window_records'] if w['window']==3}
   if not {'20010004','20000008'}.issubset(post_addresses): reasons.append('b2_postcommit_FB_CONTROL_missing:'+name)
  if name.startswith('b2_combined_'):
   for key in ['combined','postcommit','clear_start','clear_last','collision','idle_cpu']:
    if f[key]==0: reasons.append('b2_required_bin_missing:'+name+':'+key)
   if f['physical_clear']!=9600: reasons.append('b2_combined_clear_count:'+name)
  if name=='control_b2_clear':
   for key in ['clear','collision','old_sticky','retention','w1c','zero','clear_last']:
    if f[key]==0: reasons.append('b2_required_bin_missing:'+name+':'+key)
 if os.environ.get('TEST_B3_MISSING_BIN')=='1':
  fixture=json.loads(json.dumps(b3_results));fixture['b3_pll_request']['actual_bins']['quiet_wraps']=0
  save('b3-coverage-fixture.json',{'fixture':'isolated metadata input; real raw frames untouched','coverage':fixture})
  b3_validation=json.loads((run/'b3-coverage-fixture.json').read_text())['coverage']
 else: b3_validation=b3_results
 for name,cov in b3_validation.items():
  for key in ['quiet_wraps','fresh_swap','fresh_clear','fresh_combined']:
   if cov['actual_bins'][key]!=cov['summary'][key]: reasons.append('b3_required_bin_missing:'+name+':'+key)
 if b4_guard=='MISSING_BIN':
  fixture=json.loads(json.dumps(b4_results));fixture['b4_combined_fb']['actual_bins']['consume_errors']=0
  save('b4-coverage-fixture.json',{'fixture':'isolated metadata input; actual target logs untouched','coverage':fixture})
  b4_validation=json.loads((run/'b4-coverage-fixture.json').read_text())['coverage']
 else: b4_validation=b4_results
 for name,cov in b4_validation.items():
  for key,count in cov['actual_bins'].items():
   if count!=cov['summary'][key]:reasons.append('b4_required_bin_missing:'+name+':'+key)
 save('b4-coverage.json',{'run_id':run_id,'coverage':b4_results,'validation_fixture_used':b4_validation!=b4_results})
 save('b3-coverage.json',{'run_id':run_id,'coverage':b3_results,'validation_fixture_used':b3_validation!=b3_results})
 save('b2-coverage.json',{'run_id':run_id,'coverage':b2_results,'validation_fixture_used':b2_validation!=b2_results})
 save('b1-coverage.json',{'run_id':run_id,'coverage':b1_results,'validation_fixture_used':validation!=b1_results})
 guard_exit=1 if reasons else 0
 save('guard-result.json',{'guard_exit':guard_exit,'reasons':reasons,'source_hashes_unchanged':post==pre,
  'required_lanes':required,'observed_lanes':list(by_name),'actual_files_checked':True})
 if reasons: raise RuntimeError('EVIDENCE_GUARD_REJECT '+','.join(reasons))
except Exception as e:
 failure=str(e); print(failure,file=sys.stderr,flush=True)
 if guard_exit is None:
  save('guard-result.json',{'guard_exit':None,'classification':'NOT_RUN','reason':'target_stage_failed'})
post=source_manifest(); save('source-post.json',post)
unchanged=post==pre
final_exit=target_exit or (guard_exit or 0) or (1 if failure or not unchanged else 0)
result={'run_id':run_id,'start_time':start,'end_time':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'classification':'PASS' if final_exit==0 else 'FAIL','target_exit':target_exit,'guard_exit':guard_exit,
 'final_exit':final_exit,'failure':failure,'source_hashes_unchanged':unchanged,'lanes':lanes,
 'lint_profile':'baseline required; full -Wall diagnostic uncensored; no warning waiver',
 'claim':'Profile-scoped behavioral DV only; B4_ONLY excludes full regression/closure; structural CDC and owner acceptance excluded'}
save('result.json',result); save('commands.json',records)
for name,value in [('target-exit.txt',target_exit),('guard-exit.txt',guard_exit),('final-exit.txt',final_exit)]:
 (run/name).write_text(str(value)+'\n')
(run/'summary.md').write_text(f"# P12A2 run {run.name}\n\nResult: {result['classification']}\nTarget exit: {target_exit}\nGuard exit: {guard_exit}\nFinal exit: {final_exit}\nFailure: {failure}\n")
# Seal immutable completed artifacts after status finalization. The file manifest
# excludes itself and the separate read-only consistency report, avoiding cycles.
manifest={str(p.relative_to(run)):digest(p) for p in sorted(run.rglob('*')) if p.is_file()}
save('file-manifest.json',manifest)
errors=[p for p,h in manifest.items() if digest(run/p)!=h]
validation_input=run/'result.json'
if os.environ.get('TEST_FINAL_CONSISTENCY_FAIL')=='1':
 fixture=dict(result); fixture['final_exit']=99
 fixture['fixture']='isolated final-status metadata fault; not a final verdict'
 save('consistency-fixture.json',fixture)
 validation_input=run/'consistency-fixture.json'
actual=json.loads(validation_input.read_text())
if actual['final_exit']!=final_exit or actual['classification']!=('PASS' if final_exit==0 else 'FAIL'):
 errors.append('final_status_inconsistent')
def record_consistency_failure(error_list,stage):
 global guard_exit,final_exit,manifest
 # Every detected failure uses the same status finalizer. Raw target output is
 # untouched; rejected stage manifests remain explicit historical snapshots.
 save(stage+'-rejected-file-manifest.json',manifest)
 initial_guard_exit=guard_exit
 guard_exit=1; final_exit=target_exit or 1
 result.update(classification='FAIL',guard_exit=1,final_exit=final_exit,
               failure='FINAL_CONSISTENCY_REJECT '+','.join(error_list))
 save('result.json',result)
 old_guard=json.loads((run/'guard-result.json').read_text())
 old_guard.update(initial_guard_exit=initial_guard_exit,guard_exit=1,
                  consistency_rejection=error_list,consistency_stage=stage)
 save('guard-result.json',old_guard)
 (run/'guard-exit.txt').write_text('1\n')
 (run/'final-exit.txt').write_text(str(final_exit)+'\n')
 (run/'summary.md').write_text(f"# P12A2 run {run.name}\n\nResult: FAIL\nTarget exit: {target_exit}\nGuard exit: 1\nFinal exit: {final_exit}\nFailure: {result['failure']}\n")
 manifest={str(p.relative_to(run)):digest(p) for p in sorted(run.rglob('*'))
           if p.is_file() and p.name not in ['file-manifest.json','consistency.json']}
 save('file-manifest.json',manifest)
if errors: record_consistency_failure(errors,'initial')
# Separate read-only consistency check of the finalized actual files/exits.
final_errors=[p for p,h in manifest.items() if digest(run/p)!=h]
final_validation_input=run/'result.json'
if os.environ.get('TEST_FINAL_READONLY_FAIL')=='1':
 fixture=dict(result); fixture['final_exit']=99
 fixture['fixture']='isolated readonly-validator metadata fault; not final verdict'
 save('readonly-consistency-fixture.json',fixture)
 final_validation_input=run/'readonly-consistency-fixture.json'
final_result=json.loads(final_validation_input.read_text())
if final_result['final_exit']!=int((run/'final-exit.txt').read_text()):
 final_errors.append('final_exit_file_mismatch')
if final_result['guard_exit']!=guard_exit or final_result['classification']!=('PASS' if final_exit==0 else 'FAIL'):
 final_errors.append('final_status_mismatch')
if final_errors:
 errors.extend(final_errors)
 record_consistency_failure(errors,'readonly')
# No third acceptance loop: rejected snapshots stay rejected. The resulting
# failure metadata is checked against real final files; rejection cannot PASS.
canonical=json.loads((run/'result.json').read_text())
metadata_consistent=(canonical['final_exit']==int((run/'final-exit.txt').read_text())
 and canonical['guard_exit']==guard_exit
 and canonical['classification']==('PASS' if final_exit==0 else 'FAIL'))
if not metadata_consistent:
 errors.append('failure_finalizer_inconsistent')
 record_consistency_failure(errors,'failure-finalizer')
save('consistency.json',{'exit':1 if errors else 0,'errors':errors,
 'validation_input':str(validation_input.relative_to(run)),
 'final_validation_input':str(final_validation_input.relative_to(run)),
 'final_metadata_consistent':metadata_consistent,'files_verified':len(manifest),
 'file_manifest_sha256':digest(run/'file-manifest.json')})
for p in run.rglob('*'):
 if p.is_file(): p.chmod(0o444)
print('SUMMARY:',result['classification'],'target_exit='+str(target_exit),'guard_exit='+str(guard_exit),'final_exit='+str(final_exit),flush=True)
sys.exit(final_exit or (1 if errors else 0))
PY
