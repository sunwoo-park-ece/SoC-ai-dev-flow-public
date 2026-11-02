#!/usr/bin/env bash
# Source-bound host contract tests; frozen FW §40/AES §25. No crypto/CPU proof.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set a NEW /home/swp/soc/runs/p13_aes_fw/<run-id>}"
# Python owns subprocess captures and compiler temporary paths inside RUN_ROOT.
# No tee/outer sibling log, no reuse of existing evidence directories.
exec python3 - "$repo_root" "$RUN_ROOT" <<'PY'
import hashlib, json, os, pathlib, shlex, shutil, subprocess, sys, time
repo=pathlib.Path(sys.argv[1]).resolve()
run=pathlib.Path(sys.argv[2]).resolve()
base=pathlib.Path('/home/swp/soc/runs/p13_aes_fw').resolve()
if base not in run.parents or run.exists():
    sys.exit('RUN_ROOT must be fresh and within approved local scope')
run.mkdir(parents=True,exist_ok=False)
(run/'tmp').mkdir()
env=dict(os.environ,TMPDIR=str(run/'tmp'),TMP=str(run/'tmp'),TEMP=str(run/'tmp'),
         PYTHONDONTWRITEBYTECODE='1',ASAN_OPTIONS='detect_leaks=1:halt_on_error=1',
         UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
mode=os.environ.get('P13_SELFTEST','normal')
files=['firmware/drivers/aes_gcm.c','firmware/include/aes_gcm.h',
       'firmware/include/soc_memory_map.h','verification/firmware/p13_03_aes_mmio.h',
       'verification/firmware/p13_03_aes_host.c','scripts/wsl/p13_03_aes_host_test.sh']
public_head='c175d474dc09f531a4188524e9b4efb35b5ff8c2'
private=repo.parent/'p13-aes-private'
private_head='a68b6c4bc18a24890825a9573de707ddead9e0ed'
result={'status':'INCOMPLETE','mode':mode,'run_id':run.name,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
        'target_exit':None,'guard_exit':None,'final_exit':None,'cases':[],
        'claim':'host mock-MMIO unit verification + RV32I build compatibility only; pending independent review'}
class Failure(Exception):
    def __init__(self,code,reason): self.code=code; self.reason=reason

def require(condition,reason,code=42):
    if not condition: raise Failure(code,reason)

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write_json(name,value): (run/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
def git(*args,root=repo): return subprocess.check_output(['git','-C',str(root),*args],env=env,text=True)
def command(args,name):
    with (run/'commands.jsonl').open('a') as f:
        f.write(json.dumps({'argv':[str(a) for a in args],'cwd':str(repo),'capture':name,'TMPDIR':env['TMPDIR']})+'\n')
    with (run/name).open('wb') as f:
        completed=subprocess.run([str(a) for a in args],cwd=repo,env=env,stdout=f,stderr=subprocess.STDOUT)
    (run/(name+'.exit')).write_text(str(completed.returncode)+'\n')
    return completed.returncode,(run/name).read_text(errors='replace')

def must_run(args,name):
    rc,out=command(args,name)
    if rc: raise Failure(rc,'CHILD_FAILURE '+name+' exit='+str(rc))
    return out

def historical():
    old=base/'20261103_p13_03a_attempt01'
    entries={str(p.relative_to(old)):digest(p) for p in sorted(old.rglob('*')) if p.is_file()}
    fingerprint=hashlib.sha256()
    for name,h in entries.items(): fingerprint.update(name.encode()+b'\0'+bytes.fromhex(h))
    launch=base.parent/'p13_aes_fw_launch01.log'
    return {'files':entries,'tree_digest':fingerprint.hexdigest(),'launch_sha256':digest(launch)}

def identity():
    require(git('rev-parse','--show-toplevel').strip()==str(repo),'WRONG_WORKTREE')
    require(git('rev-parse','HEAD').strip()==public_head,'PUBLIC_HEAD_DRIFT')
    require(git('rev-parse','HEAD',root=private).strip()==private_head,'PRIVATE_HEAD_DRIFT')
    for root in (repo,private):
        require(git('branch','--show-current',root=root).strip()=='cleanup/p13-aes','BRANCH_DRIFT')
        require(git('diff','--cached','--name-status',root=root)=='','INDEX_NOT_EMPTY')
    require(git('status','--porcelain=v1',root=private)=='','PRIVATE_DIRTY')
    status=git('status','--porcelain=v1','--untracked-files=all')
    require(set(status.splitlines())==set([' M '+p for p in files[:3]]+['?? '+p for p in files[3:]]),'DIRTY_SCOPE_DRIFT')
    for path in ('firmware/apps/final_main.c','firmware/apps/main.c'):
        require((repo/path).read_bytes()==subprocess.check_output(['git','-C',str(repo),'show','HEAD:'+path],env=env),'HISTORICAL_CALLER_DRIFT')
    return status

def source_hashes():
    # Actual compile/include/BSP/linker/build-script inputs, not only six edits.
    paths=subprocess.check_output(['rg','--files','firmware','scripts/firmware'],cwd=repo,env=env,text=True).splitlines()
    paths+=files[3:]+['spec/19_firmware_contract.md','spec/14_aes_gcm.md',
                     'spec/kor/19_firmware_contract.ko.md','spec/kor/14_aes_gcm.ko.md']
    return {p:digest(repo/p) for p in sorted(set(paths))}

def verify_hashes(root,expected,label):
    for name,h in expected.items():
        require((root/name).is_file() and digest(root/name)==h,label+':'+name,43)

def leaf(group,sub,expected=0,assertion=None):
    name=f'fw{group}_{sub}.log'
    rc,out=command([run/'host',group,sub],name)
    entry={'id':f'{group}/{sub}','log':name,'target_exit':rc}
    result['cases'].append(entry)
    if expected:
        require(rc==expected,'NEGATIVE_EXIT:'+name)
        require('INJECTION_REACHED' in out,'INJECTION_NOT_REACHED:'+name)
        require('ASSERT_FAIL '+assertion+' ' in out,'WRONG_SEMANTIC_REJECTION:'+name)
        entry.update(semantic='SELFTEST_EXPECTED_REJECTION',assertion=assertion)
    else:
        if rc: raise Failure(rc,'CHILD_FAILURE '+name+' exit='+str(rc))
        require(out.endswith('CASE_PASS\n') and 'ASSERT_FAIL' not in out,'CASE_EVIDENCE_INVALID:'+name)
        entry.update(semantic='PASS')
    return out

try:
    status_before=identity()
    (run/'status.before').write_text(status_before)
    history_before=historical()
    require(history_before['tree_digest']=='03ff46a9c684de7e32c67a79c9cbc4289a1dcaa89a4bec2508704ba31f3e9489','HISTORICAL_TREE_DRIFT')
    require(history_before['launch_sha256']=='0c9998b887797ef9167ad3aaad07caf13256ef9294f6bdb51a999a43842e33b4','HISTORICAL_LAUNCH_DRIFT')
    write_json('historical.before.json',history_before)
    before=source_hashes(); write_json('source.before.json',before)
    write_json('six.before.json',{p:before[p] for p in files})
    result['source']={'public_head':public_head,'private_head':private_head,'branch':'cleanup/p13-aes','dirty':status_before}
    diff=git('diff','--binary')
    for p in files[3:]:
        proc=subprocess.run(['git','-C',str(repo),'diff','--no-index','--','/dev/null',p],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        require(proc.returncode==1,'DIFF_CAPTURE_FAILURE')
        diff+=proc.stdout.decode()
    (run/'task.diff').write_text(diff)
    host_cc=os.environ.get('HOST_CC','gcc'); cross=os.environ.get('CC','riscv32-unknown-elf-gcc')
    objdump=os.environ.get('OBJDUMP','riscv32-unknown-elf-objdump')
    for tool,name in [(host_cc,'host'),(cross,'cross'),(objdump,'objdump'),(os.environ.get('OBJCOPY','riscv32-unknown-elf-objcopy'),'objcopy')]:
        require(shutil.which(tool) is not None,'ENV_BLOCKED:'+tool)
        must_run([tool,'--version'],name+'.version')
    must_run([host_cc,'-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-fno-pie','-no-pie',
        '-fsanitize=address,undefined','-fno-sanitize-recover=all','-I','firmware/include',
        '-include','verification/firmware/p13_03_aes_mmio.h','firmware/drivers/aes_gcm.c',
        'verification/firmware/p13_03_aes_host.c','-o',run/'host'],'compile.log')
    if mode=='child_fail':
        # Same real leaf/parent failure path used in the full regression.
        leaf(12,2)
        raise Failure(99,'CHILD_FAILURE_WAS_IGNORED')
    if mode=='guard_fail':
        leaf(9,4)
        result['target_exit']=0
        fixture=run/'guard_fixture.log'; fixture.write_text('valid-control\n')
        expected={'guard_fixture.log':digest(fixture)}
        verify_hashes(run,expected,'GUARD_ARTIFACT_HASH')
        fixture.write_text('tampered-observation\n')
        (run/'guard_injection.log').write_text('INJECTION_REACHED artifact hash guard after passing target\n')
        result['guard_exit']=43
        verify_hashes(run,expected,'GUARD_ARTIFACT_HASH')
        raise Failure(99,'GUARD_FAILURE_WAS_IGNORED')
    require(mode=='normal','UNKNOWN_RUN_MODE')
    for group,count in [(1,27),(2,2),(3,1),(4,3),(5,25),(6,25),(7,5),(8,32),(9,10),(10,1),(13,1),(14,10)]:
        for sub in range(count): leaf(group,sub)
    # Valid control on real driver responses precedes each observation adapter.
    for sub,assertion in [(0,'AUTH_RELEASE'),(1,'POLL_BOUND'),(3,'ZEROIZE_READBACK')]:
        leaf(12,sub,41,assertion)
    for fault,expected in [('child_fail',37),('guard_fail',43)]:
        child=run/fault
        child_env=dict(env,P13_SELFTEST=fault,RUN_ROOT=str(child))
        name=fault+'.log'
        with (run/'commands.jsonl').open('a') as f:
            f.write(json.dumps({'argv':['bash','scripts/wsl/p13_03_aes_host_test.sh'],'mode':fault,'RUN_ROOT':str(child)})+'\n')
        with (run/name).open('wb') as f:
            proc=subprocess.run(['bash','scripts/wsl/p13_03_aes_host_test.sh'],cwd=repo,env=child_env,stdout=f,stderr=subprocess.STDOUT)
        child_result=json.loads((child/'result.json').read_text())
        require(proc.returncode==expected and child_result['final_exit']==expected and child_result['status']=='FAIL','PARENT_FAILURE_PROPAGATION:'+fault)
        if fault=='child_fail':
            require('INJECTED_CHILD_FAILURE' in (child/'fw12_2.log').read_text(),'CHILD_CAUSE_LOST')
        else:
            require(child_result['target_exit']==0 and child_result['guard_exit']==43 and 'GUARD_ARTIFACT_HASH' in child_result['reason'],'GUARD_FALSE_PASS')
        result['cases'].append({'id':'12/'+fault,'target_exit':expected,'semantic':'SELFTEST_EXPECTED_REJECTION','assertion':'CHILD_PROPAGATION' if fault=='child_fail' else 'GUARD_ARTIFACT_HASH'})
    # Real RV32I links of original apps, existing builder traced verbatim.
    for app in ('final_main','main'):
        must_run(['bash','-x','scripts/firmware/build_fw.sh',app],'build_'+app+'.log')
        elf=run/'fw'/app/(app+'.elf')
        require(elf.is_file() and elf.stat().st_size>0,'ELF_MISSING:'+app)
        header=must_run([objdump,'-f',elf],app+'.elf_header')
        require('architecture: riscv:rv32' in header,'ELF_NOT_RV32:'+app)
        result['cases'].append({'id':'11/'+app,'target_exit':0,'semantic':'PASS','elf':str(elf.relative_to(run))})
    must_run([cross,'-march=rv32i','-mabi=ilp32','-mstrict-align','-O2','-ffreestanding','-fno-builtin',
              '-Wall','-Wextra','-Werror','-I','firmware/include','-c','firmware/drivers/aes_gcm.c',
              '-o',run/'aes_gcm_rv32i.o'],'rv32i.log')
    result['target_exit']=0
    groups={
      'FW03-01': ['1/','4/'], 'FW03-02':['2/','4/'],
      'FW03-03':['3/','13/','14/5'], 'FW03-04':['4/','13/','14/9'],
      'FW03-05':['5/','6/','1/','13/'], 'FW03-06':['5/','6/'],
      'FW03-07':['7/','4/','9/','14/6','14/7','14/8'],
      'FW03-08':['8/','14/0','14/1','14/2','14/3','14/4','12/3','13/'],
      'FW03-09':['9/'], 'FW03-10':['10/','13/'],
      'FW03-11':['11/'], 'FW03-12':['12/'],
      'RECOVERY':['13/','5/','6/','3/','7/','14/']}
    matrix={criterion:{'status':'PASS','cases':[c['id'] for c in result['cases']
              if any(c['id'].startswith(prefix) for prefix in prefixes)],
              'oracle':'frozen FW 40 / AES 25; per-case ASSERT_PASS/FAIL and exact MMIO in logs',
              'run_id':run.name,'source_manifest':'source.before.json'}
              for criterion,prefixes in groups.items()}
    require(all(row['cases'] for row in matrix.values()),'MATRIX_MAPPING_EMPTY')
    write_json('matrix.json',matrix)
    after=source_hashes(); write_json('source.after.json',after)
    require(before==after,'SOURCE_HASHES_CHANGED')
    verify_hashes(repo,after,'SOURCE_HASH_GUARD')
    require(identity()==status_before,'FINAL_IDENTITY_CHANGED')
    history_after=historical(); write_json('historical.after.json',history_after)
    require(history_before==history_after,'HISTORICAL_EVIDENCE_CHANGED')
    must_run(['git','diff','--check'],'diff_check.log')
    # Inspect every known case and required semantic rejection before verdict.
    require(len(result['cases'])==149,'CASE_INVENTORY_INCOMPLETE')
    require(sum(c['semantic']=='SELFTEST_EXPECTED_REJECTION' for c in result['cases'])==5,'SENSITIVITY_INCOMPLETE')
    result.update(status='PASS_PENDING_REVIEW',guard_exit=0,final_exit=0,source_hashes_unchanged=True,historical_evidence_unchanged=True)
except Failure as e:
    result.update(status='FAIL',reason=e.reason,final_exit=e.code)
    if result['target_exit'] is None: result['target_exit']=e.code
except Exception as e:
    result.update(status='FAIL',reason=type(e).__name__+': '+str(e),final_exit=44)
finally:
    result['finished_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    write_json('result.json',result)
    (run/'final.exit').write_text(str(result['final_exit'])+'\n')
    (run/'verdict').write_text(result['status']+'\n')
    # No self-referential manifest: finalize records, then hash every other file.
    manifest={str(p.relative_to(run)):digest(p) for p in sorted(run.rglob('*')) if p.is_file() and p not in (run/'manifest.json',run/'manifest.check.json')}
    write_json('manifest.json',manifest)
    bad=[p for p,h in manifest.items() if digest(run/p)!=h]
    write_json('manifest.check.json',{'bad':bad,'checked_files':len(manifest),'exit':0 if not bad else 43})
    if bad:
        result.update(status='FAIL',reason='FINAL_MANIFEST_MISMATCH',guard_exit=43,final_exit=43)
        write_json('result.json',result); (run/'final.exit').write_text('43\n'); (run/'verdict').write_text('FAIL\n')
    print(json.dumps({'run':str(run),'status':result['status'],'final_exit':result['final_exit'],'reason':result.get('reason'),'cases':len(result['cases'])}))
sys.exit(result['final_exit'])
PY
