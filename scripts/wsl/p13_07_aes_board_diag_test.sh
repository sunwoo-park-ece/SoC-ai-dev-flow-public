#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
P13_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export P13_REPO
: "${RUN_ROOT:?Set a fresh runs/verification/p13_07_h0/<run-id>}"
exec python3 -B - <<'PY'
import hashlib,json,os,pathlib,re,shutil,subprocess,sys,time
repo=pathlib.Path(os.environ['P13_REPO']).resolve();ws=repo.parents[1]
run=pathlib.Path(os.environ['RUN_ROOT']).resolve()
base=ws/'runs/verification/p13_07_h0'
if not run.is_relative_to(base) or run==base or run.exists():sys.exit('FRESH_APPROVED_RUN_ROOT_REQUIRED')
run.mkdir(parents=True);(run/'tmp').mkdir()
env=dict(os.environ,TMPDIR=str(run/'tmp'),TMP=str(run/'tmp'),TEMP=str(run/'tmp'),PYTHONDONTWRITEBYTECODE='1')
app='firmware/apps/p13_07_aes_board_diag.c'
host='verification/firmware/p13_07_aes_board_diag_host.c'
tb='verification/directed/p13_aes_soc/tb_p13_07_board_diag.sv'
parser='verification/independent/p13_aes_gcm/p13_07_board_log_check.py'
runner='scripts/wsl/p13_07_aes_board_diag_test.sh'
allow={app,host,tb,parser,runner}
private=repo.parent/'p13-aes-private'
mode=os.environ.get('P13_H0_FAULT','normal')
result={'status':'INCOMPLETE','target_exit':None,'guard_exit':None,'final_exit':1,'mode':mode}
commands=[]
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def save(name,value):
 (run/name).write_text(json.dumps(value,indent=2)+'\n')
def require(ok,reason):
 if not ok:raise RuntimeError(reason)
def git(p,*args):return subprocess.check_output(['git','--no-optional-locks','-C',str(p),*args],text=True).strip()
def identity(p):return {'head':git(p,'rev-parse','HEAD'),'branch':git(p,'branch','--show-current'),
 'status':git(p,'status','--porcelain=v1','--untracked-files=all','--ignored'),'index':git(p,'diff','--cached','--name-status')}
def launch(argv,name,timeout=60,extra=None,cwd=None,expected=0):
 argv=list(map(str,argv));start=time.monotonic()
 with (run/(name+'.stdout')).open('wb') as out,(run/(name+'.stderr')).open('wb') as err:
  try:rc=subprocess.run(argv,cwd=cwd or repo,env=dict(env,**(extra or {})),stdout=out,stderr=err,timeout=timeout).returncode
  except subprocess.TimeoutExpired:rc=124
  except OSError as e:err.write(str(e).encode());rc=127
 row={'argv':argv,'cwd':str(cwd or repo),'exit':rc,'seconds':time.monotonic()-start,
      'stdout_sha256':sha(run/(name+'.stdout')),'stderr_sha256':sha(run/(name+'.stderr'))}
 commands.append(row);save('commands.json',commands);save(name+'.exit.json',row)
 print(name,'exit='+str(rc),flush=True)
 require(rc==expected,'COMMAND_EXIT:'+name+':'+str(rc));return (run/(name+'.stdout')).read_text(errors='replace')
def source_map():
 tracked=git(repo,'ls-files').splitlines()
 return {p:sha(repo/p) for p in sorted(set(tracked)|allow)}
try:
 pre={'public':identity(repo),'private':identity(private)};save('identity.before.json',pre)
 require(pre['public']['head']=='aea5c507a0a703808f32cd49f045796642b52b09' and pre['private']['head']=='dafa0aafadb51123b960b83e344597a667a16deb','HEAD_DRIFT')
 for label in pre:require(pre[label]['branch']=='cleanup/p13-aes' and not pre[label]['index'],'BRANCH_OR_INDEX')
 require(not pre['private']['status'],'PRIVATE_DIRTY')
 require(set(pre['public']['status'].splitlines())=={'?? '+p for p in allow},'EXACT_FIVE_NEW_PATHS_REQUIRED')
 before=source_map();save('source.before.json',before)
 source=hashlib.sha256(json.dumps(before,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 vectors=repo/'verification/independent/p13_aes_gcm/p13_04_vectors.json'
 oracle=json.loads(vectors.read_text());selected=[oracle['vectors'][i] for i in (0,7,16)]
 launch(['python3','-B',repo/'verification/independent/p13_aes_gcm/p13_04_oracle_vectors.py','--check',vectors],'oracle')
 vector=sha(vectors);build=hashlib.sha256((source+vector+'rv32i-ilp32-O2-H0-1').encode()).hexdigest()
 manifest={'source':source,'vector':vector,'build':build,'public_head':pre['public']['head'],'case_ids':[x['id'] for x in selected]}
 save('image-identity.json',manifest)
 def arr(h):return '{'+','.join('0x'+h[i:i+2] for i in range(0,len(h),2))+'}'
 header='#define ORACLE_GENERATED_INDEPENDENTLY 1\n'
 header+='static const unsigned oracle_len[3]={0,7,16};\n'
 header+='static const unsigned char oracle_key[16]='+arr(selected[0]['key'])+';\n'
 header+='static const unsigned char oracle_plain[16]='+arr(selected[2]['plaintext'])+';\n'
 for name,keyname in [('cipher','ciphertext'),('tags','tag')]:
  header+='static const unsigned char oracle_'+name+'[3][16]={'+','.join(arr(x[keyname]) if x[keyname] else '{0}' for x in selected)+'};\n'
 (run/'p13_07_oracle.h').write_text(header)
 defines=['-DP13_'+k.upper()+'_ID="'+manifest[k]+'"' for k in ('build','source','vector')]
 launch(['gcc','-std=c99','-O2','-g','-Wall','-Wextra','-Werror','-I',repo/'firmware/include','-I',run,
  '-include',repo/'verification/firmware/p13_03_aes_mmio.h',*defines,repo/host,repo/'firmware/drivers/aes_gcm.c',repo/'firmware/drivers/uart.c','-o',run/'host'],'host_compile')
 if mode=='leaf':
  launch([run/'host','cipher'],'injected_leaf',expected=1)
  result['target_exit']=1;raise RuntimeError('EXPECTED_LEAF_PROPAGATION')
 launch([run/'host','normal'],'host_normal');result['target_exit']=0
 if mode=='guard':
  p=run/'tampered.log';p.write_text((run/'host_normal.stdout').read_text().replace('e=1','e=0',1))
  launch(['python3','-B',repo/parser,'--log',p,'--manifest',run/'image-identity.json'],'injected_guard',expected=43)
  result['guard_exit']=43;raise RuntimeError('EXPECTED_GUARD_PROPAGATION')
 require(mode=='normal','UNKNOWN_MODE')
 launch(['python3','-B',repo/parser,'--log',run/'host_normal.stdout','--manifest',run/'image-identity.json','--selftest'],'host_log_check')
 faults={ 'cipher':'id=E7', 'tag':'id=E0', 'sticky':'id=E0', 'early':'NO_TRANSIENT_CALLER_RELEASE', 'zero':'id=ZERO','timeout':'id=E0'}
 sensitivity=[]
 for fault,reach in faults.items():
  expect=41 if fault=='early' else 1
  launch([run/'host',fault],'host_fault_'+fault,expected=expect)
  observed=(run/('host_fault_'+fault+'.stdout')).read_text()+(run/('host_fault_'+fault+'.stderr')).read_text()
  require(reach in observed,'FAULT_NOT_REACHED:'+fault)
  if fault!='early':require('v=F' in observed,'SEMANTIC_FAILURE_MISSING:'+fault)
  sensitivity.append({'fault':fault,'target':'isolated_host_MMIO_or_caller_observation_fixture','reached':reach,'exit':expect})
 save('host-sensitivity.json',sensitivity)
 for fault in ('leaf','guard'):
  child=run/('propagation-'+fault)
  launch(['bash',repo/runner],'parent_'+fault,timeout=120,extra={'RUN_ROOT':str(child),'P13_H0_FAULT':fault},expected=1)
  child_result=json.loads((child/'result.json').read_text())
  require(child_result['status']=='FAIL' and child_result['final_exit']!=0,'PARENT_FALSE_PASS')
  if fault=='guard':require(child_result['target_exit']==0 and child_result['guard_exit']==43,'GUARD_MASKED')
 fw=ws/'runs/firmware/p13_07_h0'/run.name
 require(not fw.exists(),'FW_RUN_COLLISION');fw.mkdir(parents=True)
 launch(['bash',repo/'scripts/firmware/build_fw.sh','p13_07_aes_board_diag'],'rv32i_build',timeout=120,
  extra={'RUN_ROOT':str(fw),'EXTRA_CFLAGS':' '.join(defines)})
 image=fw/'fw/p13_07_aes_board_diag';elf=image/'p13_07_aes_board_diag.elf'
 symbols=launch(['riscv32-unknown-elf-nm','-S',elf],'symbols')
 names={r.split()[-1]:int(r.split()[0],16) for r in symbols.splitlines() if len(r.split())>=3}
 require(names['__bss_end']<names['__stack_top']-4096,'STACK_RESERVE')
 launch(['riscv32-unknown-elf-objdump','-f',elf],'elf_header')
 require('riscv:rv32' in (run/'elf_header.stdout').read_text(),'NOT_RV32')
 manifest.update(firmware_root=str(image),firmware={p.name:sha(p) for p in sorted(image.iterdir()) if p.is_file()},
  stack_reserve=names['__stack_top']-names['__bss_end'])
 save('image-identity.json',manifest)
 # MIF -> independent simulator hex view, checking depth and every word address.
 for name,depth in [('IMEM',4096),('DMEM',8192)]:
  text=(image/(name+'.mif')).read_text();rows=re.findall(r'^\s*(\d+)\s*:\s*([0-9A-Fa-f]{8});',text,re.M)
  require(len(rows)==depth and [int(a) for a,v in rows]==list(range(depth)),'MIF_DEPTH_OR_ADDRESS')
  (run/(name+'.hex')).write_text(''.join(v+'\n' for a,v in rows))
 grouped=launch(['python3','-B',repo/'scripts/wsl/source_list.py','OPEN_SIM_MIXED_MODELSIM','--group'],'source_list')
 vh=[];vl=[]
 for row in grouped.splitlines():
  group,path=row.split('\t');(vh if group=='aes_vhdl_dependency_order' else vl).append(path)
 require(len(vh)==14 and all('structural_stub' not in p for p in vl),'GENUINE_CORE_BINDING')
 save('compiled-inputs.json',{str(pathlib.Path(p).relative_to(repo)):sha(p) for p in vh+vl+[str(repo/tb)]})
 work=run/'work';launch(['vlib',work],'vlib')
 launch(['vcom','-2008','-work',work,*vh],'vcom',timeout=120)
 inc=['+incdir+'+str(p) for p in sorted((repo/'rtl/core/v').rglob('*')) if p.is_dir()]
 launch(['vlog','-sv','-work',work,*inc,*vl,repo/tb],'vlog',timeout=120)
 top='tb_p13_07_board_diag'
 do='onerror {quit -code 2}; onbreak {quit -code 3}; run -all; if {[examine -radix unsigned /'+top+'/completed] != 1} {quit -code 4}; quit -code 0'
 launch(['vsim','-c','-onfinish','stop','-voptargs=+acc','-wlf',run/'simulation.wlf','-lib',work,top,
   '-gIMEM_FILE='+str(run/'IMEM.hex'),'-gDMEM_FILE='+str(run/'DMEM.hex'),
   '+OUTPUT_ADDR='+format(names['output'],'x'),'+TRAP_PC='+format(names['__trap_fail_stop'],'x'),'-do',do],
   'actual_core_uart',timeout=1800,cwd=run)
 for epoch in (0,1):
  launch(['python3','-B',repo/parser,'--log',run/('uart'+str(epoch)+'.log'),'--manifest',run/'image-identity.json','--selftest'],'serial_check_'+str(epoch))
 require('H0_SERIAL_COMPLETE epochs=2 starts=18' in (run/'actual_core_uart.stdout').read_text(),'ACTUAL_CORE_EXECUTION_COVERAGE')
 after=source_map();save('source.after.json',after)
 require(before==after and pre=={'public':identity(repo),'private':identity(private)},'SOURCE_IDENTITY_DRIFT')
 # Re-read produced image bytes, not just the manifest fields.
 require(all(sha(image/p)==h for p,h in manifest['firmware'].items()),'FW_IMAGE_DRIFT')
 result.update(status='H0_FW_DV_PASS_BOUNDED',target_exit=0,guard_exit=0,final_exit=0,
               source_unchanged=True,identity=manifest,epochs=2)
except Exception as e:
 result.update(status='FAIL',reason=type(e).__name__+': '+str(e),final_exit=1)
finally:
 save('result.json',result);(run/'final.exit').write_text(str(result['final_exit'])+'\n')
 files={str(p.relative_to(run)):sha(p) for p in sorted(run.rglob('*')) if p.is_file() and p!=run/'artifact-sha256.json'}
 save('artifact-sha256.json',files)
 print(json.dumps({'run':str(run),'status':result['status'],'reason':result.get('reason'),'final_exit':result['final_exit']}),flush=True)
sys.exit(result['final_exit'])
PY
