#!/usr/bin/env python3
"""Source-bound execution and semantic guard. Raw logs remain immutable per lane."""
import argparse, datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, time
REPO=pathlib.Path(__file__).resolve().parents[3]
NAMES=['firmware/apps/p13_05_aes_cpu_e2e.c','firmware/apps/p13_05_aes_cpu_fault.c','verification/directed/p13_aes_soc/tb_p13_05_cpu_e2e.sv','verification/directed/p13_aes_soc/tb_p13_05_cpu_fault.sv','verification/directed/p13_aes_soc/p13_05_contract_checker.sv','verification/directed/p13_aes_soc/p13_05_evidence_guard.py','scripts/wsl/p13_05_soc_e2e_test.sh']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def git(repo,*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
def check_positive(log,lane,repo,symbols,budget,case_ids=None):
 vectors=json.loads((repo/'verification/independent/p13_aes_gcm/p13_04_vectors.json').read_text())['vectors']
 expected_ids=case_ids or list(range(1,69))
 events=[]
 for line in log.splitlines():
  if 'EVENT ' in line:
   fields=line.split('EVENT ',1)[1].split();events.append((fields[0],dict(x.split('=',1) for x in fields[1:] if '=' in x)))
 rows=[];current=None;seen=[]
 for typ,e in events:
  if typ=='CASE':
   cid=int(e['id'])
   if not cid:continue
   if current is not None:raise RuntimeError('CASE_WITHOUT_RESULT')
   if cid!=expected_ids[len(rows)]:raise RuntimeError('CASE_SEQUENCE')
   current={'id':cid,'apb':[],'terminal':None,'caller':[]}
  elif current is not None and typ=='APB':current['apb'].append(e)
  elif current is not None and typ=='TERMINAL':current['terminal']=e
  elif current is not None and typ=='CALLER_WRITE':current['caller'].append(e)
  elif current is not None and typ=='RESULT':
   cid=current['id'];v=vectors[33 if case_ids else (cid-1)//2];dec=0 if case_ids else (cid-1)%2;n=v['length']
   if int(e['case'])!=cid or int(e['rc'])!=0 or int(e['status'],16)!=6 or int(e['start'])!=1 or int(e['recovery'])!=0:raise RuntimeError('FW_RESULT:'+str(e))
   expected=bytes.fromhex(v['plaintext'] if dec else v['ciphertext'])+bytes([0xa5])*(20-n)
   if bytes.fromhex(e['out'])!=expected:raise RuntimeError('CALLER_VECTOR_RESULT:'+str(cid))
   tag=bytes([0x5a])*20 if dec else bytes.fromhex(v['tag'])+bytes([0x5a])*4
   if bytes.fromhex(e['tag'])!=tag:raise RuntimeError('CALLER_TAG_RESULT:'+str(cid))
   apb=current['apb'];regs={};started=None;polls=[];version=False;reads={}
   for a in apb:
    address=int(a['addr'],16);data=int(a['data'],16);wr=int(a['wr']);cyc=int(a['cycle'])
    if not wr and address==0x40040008:
     if data!=0x322e3030:raise RuntimeError('AES_VERSION')
     version=True
    if wr:
     regs[address]=data
     if address==0x4004000c and data in (1,3):
      if started is not None:raise RuntimeError('MULTIPLE_START')
      started=cyc;start_time=int(a['time']) if 'time' in a else None
      def words(h):
       b=bytes.fromhex(h);b=b+bytes((-len(b))%16);return [int.from_bytes(b[i:i+4],'big') for i in range(0,len(b),4)]
      expected_regs={0x40040020+4*i:w for i,w in enumerate(words(v['key']))}
      expected_regs.update({0x40040030+4*i:w for i,w in enumerate(words(v['iv'])[:3])})
      expected_regs[0x4004003c]=n
      payload=bytes.fromhex(v['ciphertext'] if dec else v['plaintext']).ljust(16,b'\0')
      expected_regs.update({0x40040040+4*i:w for i,w in enumerate(words(payload.hex()))})
      if dec:expected_regs.update({0x40040050+4*i:w for i,w in enumerate(words(v['tag']))})
      if any(regs.get(k)!=val for k,val in expected_regs.items()) or data!=(3 if dec else 1):raise RuntimeError('MMIO_PACK_OR_IV:'+str(cid))
    elif started is not None:
     if address==0x40040010:polls.append((cyc,data))
     elif address>=0x40040060:reads[address]=data
   if not version or started is None or current['terminal'] is None or not polls:raise RuntimeError('MISSING_CPU_AES_WITNESS')
   if int(e['polls'])!=len(polls) or len(polls)>budget or polls[-1][1]!=6 or any(s&2 for c,s in polls[:-1]):raise RuntimeError('INDEPENDENT_POLL_COUNT')
   terminal=int(current['terminal']['cycle']);latency=terminal-started
   if start_time is not None:
    dt=int(current['terminal']['time'])-start_time
    if dt%20000:raise RuntimeError('CLOCK_TIMESTAMP_ALIGNMENT')
    latency=dt//20000
   if latency<=0:raise RuntimeError('START_TERMINAL_ORDER')
   # Verify raw reads independently as well as caller bytes. Partial final words compare only valid bytes.
   out=bytes.fromhex(v['plaintext'] if dec else v['ciphertext'])
   for i in range(0,n,4):
    word=reads.get(0x40040060+i)
    if word is None or word.to_bytes(4,'big')[:min(4,n-i)]!=out[i:i+4]:raise RuntimeError('RAW_PAYLOAD_VECTOR')
   if not dec:
    got=b''.join(reads.get(0x40040070+i,-1).to_bytes(4,'big',signed=False) for i in range(0,16,4))
    if got.hex()!=v['tag']:raise RuntimeError('RAW_TAG_VECTOR')
   for w in current['caller']:
    c=int(w['cycle']);value=int(w['data'],16);mask=int(w['lanes'],16);address=int(w['addr'],16)
    for byte in range(4):
     if mask&(1<<byte) and address+byte<symbols['p13_output']+n and (value>>(8*byte))&255 and c<terminal:raise RuntimeError('EARLY_CALLER_RELEASE')
   rows.append(dict(case=cid,vector=v['id'],length=n,decrypt=bool(dec),start_cycle=started,terminal_cycle=terminal,latency_cycles=latency,completed_polls=len(polls),poll_events=polls,fw_diagnostic_polls=int(e['polls']),verdict='PASS'))
   current=None
 if len(rows)!=len(expected_ids) or current is not None:raise RuntimeError('POSITIVE_COVERAGE_INCOMPLETE:'+str(len(rows)))
 pmax=max(r['completed_polls'] for r in rows)
 return dict(cases=rows,P_min=min(r['completed_polls'] for r in rows),P_max=pmax,N_tested=budget,N_normal=max(2*pmax+8,32),max_latency_cycles=max(r['latency_cycles'] for r in rows),min_latency_cycles=min(r['latency_cycles'] for r in rows),scope='source-bound simulation only; N is not bus timeout')

def check_negative(log,stage,symbols=None,required=None):
 rows=[];current=None
 for line in log.splitlines():
  if 'EVENT ' not in line:continue
  fs=line.split('EVENT ',1)[1].split();typ=fs[0];e=dict(x.split('=',1) for x in fs[1:] if '=' in x)
  if typ=='CASE':
   if int(e['id'])==0:continue
   if current is not None:raise RuntimeError('CASE_WITHOUT_RESULT')
   current=dict(id=int(e['id']),events=[])
  elif current is not None:
   current['events'].append((typ,e))
   if typ=='RESULT':
    cid=current['id'];apb=[a for t,a in current['events'] if t=='APB'];rc=int(e['rc']);status=int(e['status'],16)
    output=bytes.fromhex(e['out']);tag=bytes.fromhex(e['tag']);record=dict(case=cid,rc=rc,status=status,events=current['events'],verdict='PASS')
    if stage.startswith('B2_trusted'):
     expected_rc=1 if 101<=cid<=109 else 3 if cid in (110,115) else 5 if 111<=cid<=113 else 8 if cid in (116,117,119) else 0
     if rc!=expected_rc:raise RuntimeError('NEGATIVE_RETURN:'+str(cid)+':'+str(e))
     if cid in list(range(101,111))+[116,117,119] and apb:raise RuntimeError('ZERO_MMIO:'+str(cid))
     should_zero=cid in [110,111,112,113,115,116,119]
     if output!=(bytes(16) if should_zero else bytes([0xa5])*16)+bytes([0xa5])*4:raise RuntimeError('AUTH_NO_RELEASE:'+str(cid))
     if should_zero:
      for t,w in current['events']:
       if t!='CALLER_WRITE':continue
       address=int(w['addr'],16);value=int(w['data'],16);mask=int(w['lanes'],16)
       for bi in range(4):
        if mask&(1<<bi) and symbols['p13_output']<=address+bi<symbols['p13_output']+16 and (value>>(8*bi))&255:raise RuntimeError('TRANSIENT_CALLER_RELEASE:'+str(cid))
     if cid in (111,112,113) and status!=0x9a:raise RuntimeError('AUTH_FAIL_CAUSE:'+str(cid))
     if cid==115:
      starts=[a for a in apb if a['wr']=='1' and int(a['addr'],16)==0x4004000c and int(a['data'],16)==1]
      if len(starts)!=1:raise RuntimeError('TIMEOUT_START_UNREACHABLE')
      polls=[a for a in apb if a['wr']=='0' and int(a['addr'],16)==0x40040010 and int(a['time'])>int(starts[0]['time'])]
      if len(polls)!=1 or int(polls[0]['data'],16)&2 or not int(polls[0]['data'],16)&1 or int(e['polls'])!=1 or int(e['recovery'])!=1 or int(e['start'])!=1:raise RuntimeError('TIMEOUT_UNREACHABLE_OR_UNBOUNDED')
      record['N_timeout']=1;record['timeout_poll']=polls[0]
     if cid in (116,117,119) and int(e['recovery'])!=1:raise RuntimeError('RECOVERY_LATCH')
    else:
     if rc!=0:raise RuntimeError('RAW_RETURN')
     if cid in (201,202,203,204):
      expected_len=[17,65535,65536,65552][cid-201]
      if status!=0x5a or any(t=='CORE' for t,a in current['events']):raise RuntimeError('INVALID_LEN_CORE_OR_STATUS')
      if not any(a['wr']=='0' and int(a['addr'],16)==0x4004003c and int(a['data'],16)==expected_len for a in apb):raise RuntimeError('LEN_FULL_WIDTH_READBACK')
     elif cid==205:
      if status!=0x428:raise RuntimeError('MALFORMED_CTRL_CAUSE')
     elif cid in (206,207):
      if status!=0x1e2e:raise RuntimeError('STICKY_PROGRAM_ERROR:'+str(cid)+':'+hex(status))
      if cid==206:
       writes=[a for a in apb if a['wr']=='1' and int(a['before'],16)&1]
       required_busy=[(0x40040020,0xffffffff),(0x4004000c,1),(0x4004000c,8),(0x4004000c,4)]
       if any(not any(int(a['addr'],16)==addr and int(a['data'],16)==data for a in writes) for addr,data in required_busy):raise RuntimeError('REQUIRED_BUSY_COVERAGE_UNREACHABLE')
       readbacks={int(a['addr'],16):int(a['data'],16) for a in apb if a['wr']=='0'}
       for addr in range(0x40040020,0x40040060,4):
        if readbacks.get(addr)!=(16 if addr==0x4004003c else 0):raise RuntimeError('BUSY_INPUT_MUTATED')
       from cryptography.hazmat.primitives.ciphers.aead import AESGCM
       golden=AESGCM(bytes(16)).encrypt(bytes(12),bytes(16),bytes.fromhex('a55a')+bytes(12)+bytes.fromhex('0010'))
       observed=b''.join(readbacks[a].to_bytes(4,'big') for a in range(0x40040060,0x40040080,4))
       if observed!=golden:raise RuntimeError('BUSY_INFLIGHT_CRYPTO_CHANGED')
    if cid in (114,118,208):
     zero=[a for a in apb if a['wr']=='1' and int(a['addr'],16)==0x4004000c and int(a['data'],16)==8]
     if len(zero)!=1 or int(zero[0]['before'],16)&1:raise RuntimeError('ZEROIZE_ADMISSION')
     readbacks={int(a['addr'],16):int(a['data'],16) for a in apb if a['wr']=='0' and 0x40040020<=int(a['addr'],16)<=0x4004008c}
     if set(readbacks)!=set(range(0x40040020,0x40040090,4)) or any(readbacks.values()) or status!=0:raise RuntimeError('ZEROIZE_28')
     polls=[a for a in apb if a['wr']=='0' and int(a['addr'],16)==0x40040010 and int(a['time'])>int(zero[0]['time'])]
     if len(polls)!=int(e['maintenance']) or not polls or len(polls)>32:raise RuntimeError('MAINTENANCE_POLL_COUNT')
     terminal=[a for t,a in current['events'] if t=='MAINT_DONE']
     if len(terminal)!=1:raise RuntimeError('MAINTENANCE_EDGE_MISSING')
     record.update(maintenance_polls=len(polls),maintenance_cycles=(int(terminal[0]['time'])-int(zero[0]['time']))//20000,N_zeroize=max(2*len(polls)+8,32))
    rows.append(record);current=None
 expected=required if required is not None else (list(range(101,120)) if stage.startswith('B2_trusted') else list(range(201,209)))
 if [r['case'] for r in rows]!=expected or current is not None:raise RuntimeError('NEGATIVE_COVERAGE_INCOMPLETE')
 return dict(cases=rows,N_timeout=1 if stage.startswith('B2_trusted') else 'NOT_APPLICABLE',N_zeroize=max(r.get('N_zeroize',0) for r in rows),claim='independent observed bus/caller/diagnostic checks; no hardware watchdog')

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--stage',choices=['B1_calibrate_r2','B1_nominal','B2_trusted','B2_raw_r2','B2_trusted_r2','B2_raw_r3','B3_recovery']+['B2_fault_'+str(i) for i in range(10)],required=True);args=ap.parse_args()
 root=pathlib.Path(os.environ['RUN_ROOT']).resolve()
 if root.parent!=REPO.parents[1]/'runs/p13_aes_soc':raise RuntimeError('RUN_ROOT_SCOPE')
 if json.loads((root/'B0/result.json').read_text())['status']!='PASS':raise RuntimeError('B0_GATE_NOT_PASS')
 if args.stage.startswith('B2') and json.loads((root/'B1_nominal/result.json').read_text())['status']!='PASS':raise RuntimeError('B1_GATE_NOT_PASS')
 if args.stage=='B3_recovery':
  for gate in ['B2_trusted_r2','B2_raw_r3']+['B2_fault_'+str(i) for i in range(10)]:
   if json.loads((root/gate/'result.json').read_text())['status']!='PASS':raise RuntimeError('B2_GATE_NOT_PASS')
 fault=args.stage.startswith('B2_fault_');fault_id=int(args.stage.rsplit('_',1)[1]) if fault else None
 if fault:
  for gate in ['B2_trusted_r2','B2_raw_r3']+(['B2_fault_'+str(fault_id-1)] if fault_id else []):
   if json.loads((root/gate/'result.json').read_text())['status']!='PASS':raise RuntimeError('B2_PREVIOUS_GATE_NOT_PASS')
 start=json.loads((root/'task_start.json').read_text())['epoch']
 lane=root/args.stage;lane.mkdir(exist_ok=False)
 env=os.environ.copy();env.update(HOME=str(lane),TMPDIR=str(lane),PYTHONDONTWRITEBYTECODE='1',RUN_ROOT=str(lane/'generated'))
 if args.stage!='B1_calibrate_r2':
  previous=json.loads((root/'B1_calibrate_r2/calibration.json').read_text());env['EXTRA_CFLAGS']='-DP13_BUDGET='+str(previous['N_normal'])+'u'
 if args.stage.startswith('B2'):
  env['EXTRA_CFLAGS']+=' -DP13_STAGE='+('2' if args.stage.startswith('B2_trusted') else '3')
 if args.stage=='B3_recovery':env['EXTRA_CFLAGS']+=' -DP13_STAGE=4'
 if fault:env['EXTRA_CFLAGS']='-DP13_FAULT='+str(fault_id)
 fwname='p13_05_aes_cpu_fault' if fault else 'p13_05_aes_cpu_e2e'
 tbname='tb_p13_05_cpu_fault' if fault else 'tb_p13_05_cpu_e2e'
 # No tool-specific configuration or generated file may be written to the checkout.
 os.chdir(lane)
 commands=[];source={};reason='INCOMPLETE';final=1;target=None;guard=None
 def launch(argv,name,cap=120,cwd=lane):
  remaining=7200-(time.time()-start)
  if remaining<=0:raise RuntimeError('RESOURCE_BUDGET_EXCEEDED')
  argv=list(map(str,argv));t=time.time()
  with (lane/(name+'.stdout')).open('wb') as out,(lane/(name+'.stderr')).open('wb') as err:
   try:rc=subprocess.run(argv,cwd=cwd,env=env,stdout=out,stderr=err,timeout=min(cap,remaining)).returncode
   except subprocess.TimeoutExpired:rc=124
  commands.append(dict(name=name,argv=argv,cwd=str(cwd),exit=rc,wall_s=time.time()-t));save(lane/'commands.json',commands)
  if rc:raise RuntimeError(('RESOURCE_BUDGET_EXCEEDED:' if rc==124 else 'TOOL_OR_TARGET_FAILURE:')+name)
  return rc
 try:
  for r,pin in [(REPO,'f3a2e9ca484e093a6dabbe102d87d89084b3d52b'),(REPO.parent/'p13-aes-private','39f503a271af4a1537dcbe011ca2a707d19880d7')]:
   if git(r,'rev-parse','HEAD')!=pin or git(r,'branch','--show-current')!='cleanup/p13-aes' or git(r,'diff','--cached','--name-only'):raise RuntimeError('SOURCE_IDENTITY_DRIFT')
  dirty=git(REPO,'status','--porcelain=v1','--untracked-files=all')
  if any(line[:2]!='??' or line[3:] not in NAMES for line in dirty.splitlines()):raise RuntimeError('UNAPPROVED_WRITE')
  if git(REPO.parent/'p13-aes-private','status','--porcelain=v1','--untracked-files=all'):raise RuntimeError('UNEXPECTED_DIRTY_PRIVATE')
  # Hash every tracked input, plus actual new source bytes; base SHA does not contain tests.
  tracked=git(REPO,'ls-files').splitlines()
  source={p:sha(REPO/p) for p in tracked+NAMES if (REPO/p).is_file()}
  save(lane/'source_pre.json',source)
  launch(['riscv32-unknown-elf-gcc','--version'],'gcc_version')
  launch(['bash',REPO/'scripts/firmware/build_fw.sh',fwname],'build',120)
  fw=lane/'generated/fw'/fwname;elf=fw/(fwname+'.elf')
  launch(['riscv32-unknown-elf-nm','-n',elf],'symbols')
  symbols={s[2]:int(s[0],16) for line in (lane/'symbols.stdout').read_text().splitlines() if len(s:=line.split())==3}
  headroom=symbols['__stack_top']-symbols['__bss_end']
  if headroom<4096:raise RuntimeError('DMEM_STACK_HEADROOM')
  for segment,depth in [('imem',4096),('dmem',8192)]:
   data=(fw/(segment+'.bin')).read_bytes()
   if len(data)>depth*4:raise RuntimeError('IMAGE_FIT')
   padded=data+bytes((-len(data))%4)
   words=[int.from_bytes(padded[i:i+4],'little') for i in range(0,len(padded),4)]
   if b''.join(w.to_bytes(4,'little') for w in words)!=padded:raise RuntimeError('IMAGE_ROUNDTRIP')
   (lane/(segment+'.hex')).write_text(''.join(f'{w:08x}\n' for w in words))
  save(lane/'image.json',{'stack_headroom':headroom,'symbols':symbols,'hashes':{str(p.relative_to(lane)):sha(p) for p in list(fw.iterdir())+[lane/'imem.hex',lane/'dmem.hex'] if p.is_file()}})
  launch(['python3','-B',REPO/'scripts/wsl/source_list.py','OPEN_SIM_MIXED_MODELSIM','--group'],'manifest')
  groups=[s.split('\t') for s in (lane/'manifest.stdout').read_text().splitlines()]
  vhdl=[pathlib.Path(p) for g,p in groups if g=='aes_vhdl_dependency_order'];verilog=[pathlib.Path(p) for g,p in groups if g!='aes_vhdl_dependency_order']
  if len(vhdl)!=14 or any('structural_stub' in str(p) for p in verilog):raise RuntimeError('STUB_SUBSTITUTION')
  # Snapshot exact inputs. Compilers run only in fresh local output directory.
  stage=lane/'source';stage.mkdir()
  inputs=set(vhdl+verilog+list(REPO.glob('rtl/core/vh/**/*.vh'))+[REPO/('verification/directed/p13_aes_soc/'+tbname+'.sv'),REPO/'verification/directed/p13_aes_soc/p13_05_contract_checker.sv'])
  for p in inputs:
   dest=stage/p.relative_to(REPO);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
  save(lane/'staged_hashes.json',{str(p.relative_to(REPO)):sha(stage/p.relative_to(REPO)) for p in inputs})
  launch(['vlib',lane/'work'],'vlib')
  launch(['vcom','-2008','-work',lane/'work',*[stage/p.relative_to(REPO) for p in vhdl]],'vcom')
  inc=['+incdir+'+str(p) for p in sorted((stage/'rtl/core/v').glob('**/'))]
  launch(['vlog','-sv','-work',lane/'work',*inc,*[stage/p.relative_to(REPO) for p in verilog],stage/'verification/directed/p13_aes_soc/p13_05_contract_checker.sv',stage/('verification/directed/p13_aes_soc/'+tbname+'.sv')],'vlog')
  launch(['vdir','-lib',lane/'work'],'vdir')
  units=(lane/'vdir.stdout').read_text()
  for unit in ['AMBA_SoC_TOP','RV32I46F5SPMMIO','AHB_APB_bridge','apb_aes_gcm','top_aes_gcm',tbname]:
   if unit not in units:raise RuntimeError('MISSING_UNIT:'+unit)
  top=tbname
  do='onerror {quit -code 2}; onbreak {quit -code 1}; run -all; if {[examine -radix unsigned /'+top+'/completed] != 1} {quit -code 1}; quit -code 0'
  extra=['+MAIN_PC='+format(symbols['main'],'x'),'+TRAP_PC='+format(symbols['__trap_fail_stop'],'x')]
  if fault:
   addresses=[0x40040100,0x40040100]+[0x40040008]*4+[0x40040009,0x4004000a,0x40040009,0x4004000a]
   stores=[0,1,0,0,1,1,0,0,1,1];sizes=[2,2,0,1,0,1,1,2,1,2];causes=[5,7,5,5,7,7,4,4,6,6]
   extra += [f'+{arg}='+format(symbols[name],'x') for arg,name in [('FAULT_PC','p13_fault_instruction'),('YOUNGER_PC','p13_younger'),('END_PC','p13_fault_end')]]
   extra += ['+TARGET='+format(addresses[fault_id],'x'),'+CAUSE='+str(causes[fault_id]),'+SIZE='+str(sizes[fault_id]),'+STORE='+str(stores[fault_id]),'+MISALIGNED='+str(int(fault_id>=6))]
  else:
   extra += ['+SIG_ADDR='+format(symbols['p13_boot_signature'],'x')]+[f'+{arg}='+format(symbols[name],'x') for arg,name in [('CASE_ADDR','p13_case'),('DONE_ADDR','p13_done'),('RESULT_ADDR','p13_result'),('OUT_ADDR','p13_output'),('TAG_ADDR','p13_tag'),('DIAG_ADDR','p13_diag')]]
  if args.stage=='B3_recovery':extra += ['-gRECOVERY=1','+REC_ADDR='+format(symbols['v2_recovery'],'x')]
  target=launch(['/usr/bin/time','-v','vsim','-c','-onfinish','stop','-wlf',lane/'unused.wlf','-lib',lane/'work',top,'-gIMEM_FILE='+str(lane/'imem.hex'),'-gDMEM_FILE='+str(lane/'dmem.hex'),*extra,'-do',do],'target',1200)
  log=(lane/'target.stdout').read_text()
  for token in ['top_aes_gcm(arch_top_aes_gcm)','CHECK RESET_QUALIFICATION','CHECK START_RETIRE','CHECK MAIN_RETIRE',('CHECK FAULT_PASS' if fault else 'CHECK BOOT_STORE_PASS')]:
   if token not in log:raise RuntimeError('REQUIRED_WITNESS_MISSING:'+token)
  if args.stage.startswith('B1'):
   cal=check_positive(log,lane,REPO,symbols,4096 if args.stage=='B1_calibrate_r2' else previous['N_normal'])
  elif args.stage=='B3_recovery':
   parts=log.split('EVENT RESET_EPOCH epoch=1')
   if len(parts)!=2 or log.count('CHECK RESET_QUALIFICATION')!=2 or log.count('CHECK START_RETIRE')!=2 or log.count('CHECK MAIN_RETIRE')!=2 or 'CHECK BSS_CLEAR epoch=1' not in log:raise RuntimeError('RESET_EPOCH_BOOT_CHAIN')
   old=check_negative(parts[0],'B2_trusted',symbols,[115,116,117]);fresh=check_positive(parts[1],lane,REPO,symbols,32,[301])
   cal=dict(old_session=old,new_session=fresh,reset_policy='R1_FRESH_BOOT_ONLY',verdict='PASS')
  elif fault:
   m=re.search(r'CHECK FAULT_PASS cycles=(\d+) cause=(\d+) mepc=([0-9a-f]+) accepted=(\d+) first=(\d+) final=(\d+)',log)
   if not m or int(m[2])!=causes[fault_id] or int(m[3],16)!=symbols['p13_fault_instruction']:raise RuntimeError('FAULT_EVIDENCE_MISMATCH')
   dis=(fw/(fwname+'.dis')).read_text()
   if '<p13_fault_instruction>:' not in dis:raise RuntimeError('FAULT_DISASSEMBLY_LABEL')
   cal=dict(case=fault_id,cause=int(m[2]),mepc=int(m[3],16),accepted=int(m[4]),first_error=int(m[5]),final_error=int(m[6]),verdict='PASS')
  else:cal=check_negative(log,args.stage,symbols)
  save(lane/'calibration.json',cal)
  guard=0;reason=args.stage+'_PASS';final=0
 except Exception as e:
  reason=str(e)
  if target==0:guard=1
  if any(c['name']=='target' for c in commands):target=next(c['exit'] for c in commands if c['name']=='target')
 finally:
  if target is not None:final=propagated_exit(target,1 if guard is None else guard)
  post={p:sha(REPO/p) for p in source if (REPO/p).is_file()};save(lane/'source_post.json',post)
  if post!=source:reason='SOURCE_IDENTITY_DRIFT';final=1
  save(lane/'result.json',dict(stage=args.stage,status='PASS' if final==0 else 'BLOCK',reason=reason,target_exit=target,guard_exit=guard,final_exit=final,elapsed_task_s=time.time()-start,scope_new_files=[p for p in NAMES if (REPO/p).exists()],remaining_task_gates='consult final gate reconciliation; this record covers only its named stage'))
  print(json.dumps(json.loads((lane/'result.json').read_text())))
 return final
def validate_image(directory):
 image=json.loads((directory/'image.json').read_text())
 for name,expected in image['hashes'].items():
  p=directory/name
  if not p.is_file():raise RuntimeError('REQUIRED_ARTIFACT_MISSING:'+name)
  if sha(p)!=expected:raise RuntimeError('IMAGE_HASH_MISMATCH:'+name)
 return True

def probe(path):
 config=json.loads(path.read_text());root=path.parents[2]
 ref=root/config['reference'];symbols=json.loads((ref/'image.json').read_text())['symbols']
 kind=config['kind']
 if kind=='image':return validate_image(path.parent/config['directory'])
 log=(path.parent/config['trace']).read_text()
 if kind=='positive':return check_positive(log,path.parent,REPO,symbols,32)
 if kind=='trusted':return check_negative(log,'B2_trusted',symbols)
 if kind=='raw':return check_negative(log,'B2_raw_r3',symbols)
 if kind=='fault':
  m=re.search(r'CHECK FAULT_PASS cycles=(\d+) cause=(\d+) mepc=([0-9a-f]+) accepted=(\d+) first=(\d+) final=(\d+)',log)
  if not m or int(m[2])!=5 or int(m[3],16)!=symbols['p13_fault_instruction']:raise RuntimeError('FAULT_CAUSE_PC')
  first=re.findall(r'EVENT ERROR_FIRST time=(\d+)',log);last=re.findall(r'EVENT ERROR_FINAL time=(\d+)',log)
  if len(first)!=1 or len(last)!=1 or int(last[0])-int(first[0])!=20000:raise RuntimeError('ERROR_TWO_PHASE')
  return True
 raise RuntimeError('UNKNOWN_PROBE')

def propagated_exit(target,guard):return target if target else guard

def selftests(root):
 if json.loads((root/'B3_recovery/result.json').read_text())['status']!='PASS':raise RuntimeError('B3_RECOVERY_GATE')
 lane=root/'sensitivity_r2';lane.mkdir(exist_ok=False)
 commands=[];records=[];source={n:sha(REPO/n) for n in NAMES};save(lane/'source_pre.json',source)
 start=json.loads((root/'task_start.json').read_text())['epoch']
 env=os.environ.copy();env.update(HOME=str(lane),TMPDIR=str(lane),PYTHONDONTWRITEBYTECODE='1')
 def run(argv,name):
  remaining=7200-(time.time()-start)
  if remaining<=0:raise RuntimeError('RESOURCE_BUDGET_EXCEEDED')
  t=time.time()
  with (lane/(name+'.stdout')).open('wb') as out,(lane/(name+'.stderr')).open('wb') as err:
   try:rc=subprocess.run(list(map(str,argv)),cwd=lane,env=env,stdout=out,stderr=err,timeout=min(120,remaining)).returncode
   except subprocess.TimeoutExpired:rc=124
  commands.append(dict(name=name,argv=list(map(str,argv)),exit=rc,wall_s=time.time()-t));save(lane/'commands.json',commands)
  return rc,(lane/(name+'.stdout')).read_text(errors='replace')
 wrapper=REPO/'scripts/wsl/p13_05_soc_e2e_test.sh'
 refs={'positive':'B1_nominal','trusted':'B2_trusted_r2','raw':'B2_raw_r3','fault':'B2_fault_0','image':'B1_nominal'}
 def fixture(name,kind,transform=None,expect=None):
  d=lane/name;d.mkdir();ref=root/refs[kind]
  config=dict(reference=refs[kind],kind=kind,trace='trace.txt')
  if kind=='image':
   data=(ref/'imem.hex').read_bytes();(d/'test.bin').write_bytes(data)
   save(d/'image.json',{'hashes':{'test.bin':hashlib.sha256(data).hexdigest()}})
   config['directory']='.'
   if transform=='tamper':(d/'test.bin').write_bytes(bytes([data[0]^1])+data[1:])
   if transform=='missing':(d/'test.bin').unlink()
  else:
   original=(ref/'target.stdout').read_text();actual=transform(original) if transform else original
   if transform and original==actual:raise RuntimeError('FIXTURE_NOT_ACTIVATED:'+name)
   (d/'trace.txt').write_text(actual)
   save(d/'activation.json',dict(original_sha=hashlib.sha256(original.encode()).hexdigest(),adapted_sha=hashlib.sha256(actual.encode()).hexdigest(),changed=original!=actual,mechanism=name,claim='copied observation input only'))
  save(d/'probe.json',config)
  rc,log=run(['bash',wrapper,'--probe',d/'probe.json'],name)
  if expect:
   if rc!=1 or ('PROBE_REJECT:'+expect) not in log:raise RuntimeError('MEANINGLESS_REJECTION:'+name+':'+log)
   verdict='SELFTEST_EXPECTED_REJECTION'
  else:
   if rc or 'PROBE_PASS' not in log:raise RuntimeError('CONTROL_FAILED:'+name+':'+log)
   verdict='PASS_CONTROL'
  records.append(dict(name=name,kind=kind,expected=expect,guard_exit=rc,final_exit=rc,verdict=verdict))
  return rc
 try:
  for kind in refs:fixture(kind+'_control',kind)
  fixture('wrong_caller_vector','positive',lambda t:re.sub(r'(EVENT RESULT[^\n]*case=3 [^\n]*out=)[0-9a-f]{2}',r'\g<1>ff',t,count=1),'CALLER_VECTOR_RESULT')
  def duplicate_poll(t):
   lines=t.splitlines(True)
   for i,line in enumerate(lines):
    if 'EVENT APB ' in line and 'addr=40040010 wr=0 data=00000001' in line:
     lines.insert(i,line);return ''.join(lines)
   raise RuntimeError('POLL_ACTIVATION')
  fixture('extra_completed_poll','positive',duplicate_poll,'INDEPENDENT_POLL_COUNT')
  def mutate_after(t,case,needle,replacement):
   pos=t.index('id='+str(case)+'\n');prefix=t[:pos];tail=t[pos:]
   if needle not in tail:raise RuntimeError('MUTATION_REACH')
   return prefix+tail.replace(needle,replacement,1)
  def leak(t):
   pos=t.index('id=111\n');tail=t[pos:]
   match=re.search(r'(EVENT CALLER_WRITE[^\n]*data=)([0-9a-f]+)( lanes=([0-9a-f]+))',tail)
   if not match:raise RuntimeError('LEAK_REACH')
   mask=int(match[4],16);bi=(mask & -mask).bit_length()-1
   value=int(match[2],16)|(1<<(8*bi))
   return t[:pos]+tail[:match.start(2)]+f'{value:08x}'+tail[match.end(2):]
  fixture('transient_plaintext_release','trusted',leak,'TRANSIENT_CALLER_RELEASE')
  fixture('invalid_argument_mmio','trusted',lambda t:t.replace('id=101\n','id=101\n# EVENT APB time=1 cycle=1 addr=40040010 wr=0 data=00000000 before=00000000\n',1),'ZERO_MMIO')
  fixture('protected_input_changed','raw',lambda t:mutate_after(t,206,'addr=40040020 wr=0 data=00000000','addr=40040020 wr=0 data=ffffffff'),'BUSY_INPUT_MUTATED')
  fixture('zeroize_residual','raw',lambda t:mutate_after(t,208,'addr=40040020 wr=0 data=00000000','addr=40040020 wr=0 data=00000001'),'ZEROIZE_28')
  fixture('wrong_fault_cause','fault',lambda t:re.sub(r'(CHECK FAULT_PASS[^\n]*cause=)5',r'\g<1>7',t,count=1),'FAULT_CAUSE_PC')
  fixture('missing_error_first','fault',lambda t:re.sub(r'^.*EVENT ERROR_FIRST[^\n]*\n','',t,count=1,flags=re.M),'ERROR_TWO_PHASE')
  fixture('image_tampered','image','tamper','IMAGE_HASH_MISMATCH')
  fixture('image_missing','image','missing','REQUIRED_ARTIFACT_MISSING')
  # True checker-only simulator fixture: no AMBA/CPU/AES module compiled here.
  original=REPO/'verification/directed/p13_aes_soc/p13_05_contract_checker.sv';shutil.copyfile(original,lane/'checker.sv')
  for argv,name in [(['vlib',lane/'work'],'vlib'),(['vlog','-sv','-work',lane/'work',lane/'checker.sv'],'vlog'),(['vdir','-lib',lane/'work'],'vdir')]:
   if run(argv,name)[0]:raise RuntimeError('FIXTURE_COMPILE_FAILURE:'+name)
  units=(lane/'vdir.stdout').read_text()
  if 'AMBA_SoC_TOP' in units or 'RV32I46' in units or 'top_aes_gcm' in units:raise RuntimeError('FIXTURE_ISOLATION_FAILURE')
  expected=[None,'BUS_PHASE_PAIR_SETUP','APB_CONTROLS_STABLE','BUS_RESPONSE_PAIR','POST_RESET_APB_X','UNEXPECTED_AHB_ERROR']
  for mode,assertion in enumerate(expected):
   top='tb_p13_05_checker_fixture';do='onbreak {quit -code 1}; run -all; if {[examine -radix unsigned /'+top+'/completed] != 1} {quit -code 1}; quit -code 0'
   rc,log=run(['vsim','-c','-onfinish','stop','-lib',lane/'work',top,'+FAULT='+str(mode),'-do',do],'sv_fixture_'+str(mode))
   if 'FIXTURE_ACTIVATION fault='+str(mode) not in log:raise RuntimeError('SV_FIXTURE_REACH')
   if assertion:
    if rc==0 or assertion not in log:raise RuntimeError('SV_MEANINGLESS_REJECTION:'+str(mode))
   elif rc or 'FIXTURE_CONTROL_PASS' not in log:raise RuntimeError('SV_FIXTURE_CONTROL')
   records.append(dict(name='sv_fixture_'+str(mode),expected=assertion,target_exit=rc,verdict='SELFTEST_EXPECTED_REJECTION' if assertion else 'PASS_CONTROL'))
  # Actual wrapper exit propagation using real child and guard process results.
  for child_code,guard_fixture in [(0,'image_tampered'),(7,'image_control')]:
   child_rc,_=run([sys.executable,'-c','import sys;sys.exit('+str(child_code)+')'],'child_'+str(child_code))
   guard_rc,_=run(['bash',wrapper,'--probe',lane/guard_fixture/'probe.json'],'guard_for_child_'+str(child_code))
   final_rc,_=run(['bash',wrapper,'--propagate',str(child_rc),str(guard_rc)],'parent_'+str(child_code))
   expected_rc=child_rc if child_rc else guard_rc
   if final_rc!=expected_rc or not final_rc:raise RuntimeError('EXIT_PROPAGATION')
   records.append(dict(name='parent_'+str(child_code),target_exit=child_rc,guard_exit=guard_rc,final_exit=final_rc,verdict='SELFTEST_EXPECTED_REJECTION'))
  post={n:sha(REPO/n) for n in NAMES};save(lane/'source_post.json',post)
  if post!=source:raise RuntimeError('SOURCE_IDENTITY_DRIFT')
  save(lane/'result.json',dict(status='PASS',records=records,claim='CHECKER_SENSITIVITY_ONLY; not independent review or production mutant proof',final_exit=0))
  print('SENSITIVITY_PASS controls_and_rejections='+str(len(records)));return 0
 except Exception as e:
  save(lane/'result.json',dict(status='BLOCK',reason=str(e),records=records,final_exit=1));print('SENSITIVITY_BLOCK:'+str(e));return 1

if __name__=='__main__':
 if len(sys.argv)>1 and sys.argv[1]=='--selftest':sys.exit(selftests(pathlib.Path(sys.argv[2]).resolve()))
 if len(sys.argv)>1 and sys.argv[1]=='--probe':
  try:probe(pathlib.Path(sys.argv[2]).resolve());print('PROBE_PASS');sys.exit(0)
  except Exception as e:print('PROBE_REJECT:'+str(e));sys.exit(1)
 if len(sys.argv)>1 and sys.argv[1]=='--propagate':sys.exit(propagated_exit(int(sys.argv[2]),int(sys.argv[3])))
 sys.exit(main())
