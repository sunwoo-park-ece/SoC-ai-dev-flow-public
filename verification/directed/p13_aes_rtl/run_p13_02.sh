#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
export P13_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to a new /home/swp/soc/runs/p13_aes_rtl_<id> directory}"
python3 - "$@" <<'PY'
import os,sys,pathlib,subprocess,json,hashlib,datetime,re
repo=pathlib.Path(os.environ['P13_REPO'])
run=pathlib.Path(os.environ['RUN_ROOT']).resolve()
if run.parent!=pathlib.Path('/home/swp/soc/runs') or not run.name.startswith('p13_aes_rtl_'):
    raise SystemExit('OUT_OF_SCOPE_WRITE: RUN_ROOT must be approved local unique run path')
run.mkdir(exist_ok=False)
negative='--guard-negative' in sys.argv[1:]
base=repo/'verification/directed/p13_aes_rtl'
wrapper=repo/'rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v'
results=[]; commands=[]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(name,data): (run/name).write_text(json.dumps(data,indent=2)+'\n')
def launch(argv,log,cwd=run):
    commands.append({'argv':list(map(str,argv)),'cwd':str(cwd),'log':str(log)})
    with (run/log).open('wb') as f:
        try: rc=subprocess.run(list(map(str,argv)),cwd=cwd,stdout=f,stderr=subprocess.STDOUT,timeout=60).returncode
        except subprocess.TimeoutExpired: rc=124
        except OSError as e: f.write(str(e).encode()); rc=127
    return rc
# Resolve the approved dependency order read-only, never use fixture in real lane.
rc=launch(['python3',repo/'scripts/wsl/source_list.py','OPEN_SIM_MIXED_MODELSIM','--group'],'manifest_resolution.log',repo)
if rc: raise SystemExit('ENV_BLOCKED: source manifest resolution failed')
vhdl=[pathlib.Path(s.split('\t')[1]) for s in (run/'manifest_resolution.log').read_text().splitlines() if s.startswith('aes_vhdl_dependency_order\t')]
if len(vhdl)!=14: raise SystemExit('ENV_BLOCKED: expected 14 genuine VHDL dependencies')
sources=vhdl+[wrapper,base/'tb_p13_02_apb.sv',base/'p13_02_contract_checker.sv',base/'run_p13_02.sh',base/'fixtures/top_aes_gcm_control_fixture.sv',repo/'fpga/quartus/source_manifest.yml',repo/'verification/directed/aes_gcm_actual_core/tb_aes_gcm_actual_core_kat.sv',repo/'verification/directed/aes_gcm_actual_core/run_kat.sh']
pre={str(p.relative_to(repo)):sha(p) for p in sources}
save('source_pre.json',pre)
save('git_identity.json',{'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'branch':subprocess.check_output(['git','branch','--show-current'],cwd=repo,text=True).strip(),'porcelain':subprocess.check_output(['git','status','--porcelain=v1','--untracked-files=all'],cwd=repo,text=True),'diff':subprocess.check_output(['git','diff','--',str(wrapper.relative_to(repo))],cwd=repo,text=True)})
for tool in ['vsim','vcom','vlog']:
    rc=launch([tool,'-version'],tool+'_version.log')
    if rc: raise SystemExit('ENV_BLOCKED: tool '+tool)
# Independent oracle: fixed trusted inputs, exact historical ciphertext+tags.
import cryptography
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
vectors={0:('','62344254fcd95e1ec42b27bf38efba1c'),7:('5b201b5dd74bb9','e39af015075d18019e78e344b285d1ec'),16:('5b201b5dd74bb9d8aee94da16ba16356','9ee8eb4a087279dac5f75d8e930d5f69')}
oracle=[]
for n,(ct,tag) in vectors.items():
    key=bytes(range(16)); iv=bytes.fromhex('102030000000000000000001'); pt=bytes(range(16,16+n)); aad=bytes.fromhex('a55a')+iv+n.to_bytes(2,'big')
    enc=AESGCM(key).encrypt(iv,pt,aad)
    if enc.hex()!=ct+tag or AESGCM(key).decrypt(iv,enc,aad)!=pt: raise SystemExit('NONINDEPENDENT_ORACLE_OR_CHECKER: historical oracle mismatch')
    oracle.append({'len':n,'key':key.hex(),'iv':iv.hex(),'aad':aad.hex(),'plaintext':pt.hex(),'ciphertext_tag':enc.hex()})
save('independent_oracle.json',{'library':'cryptography '+cryptography.__version__,'vectors':oracle})
compile_results=[]
for lane in (['fixture'] if negative else ['fixture','actual']):
    work=run/(lane+'_work')
    lane_sources=[wrapper,base/'p13_02_contract_checker.sv',base/'tb_p13_02_apb.sv']
    if lane=='fixture': lane_sources.insert(0,base/'fixtures/top_aes_gcm_control_fixture.sv')
    else: lane_sources=vhdl+lane_sources
    save(lane+'_compiled_sources.json',{str(p.relative_to(repo)):sha(p) for p in lane_sources})
    steps=[(['vlib',work],lane+'_vlib.log')]
    if lane=='actual': steps.append((['vcom','-2008','-work',work,*vhdl],lane+'_vcom.log'))
    steps.append((['vlog','-sv','-work',work]+(['+define+P13_FIXTURE'] if lane=='fixture' else [])+[p for p in lane_sources if p.suffix!='.vhd'],lane+'_vlog.log'))
    for argv,log in steps:
        rc=launch(argv,log); compile_results.append({'log':log,'exit':rc,'sha256':sha(run/log)})
        if rc:
            save('compile_results.json',compile_results);save('commands.json',commands)
            save('result.json',{'status':'BLOCK','reason':'COMPILE_OR_TOOL_FAILURE','target_exit':rc,'guard_exit':None,'final_exit':rc})
            raise SystemExit(rc)
    tests=[(lane,0)] if lane=='actual' or negative else [('control',0),('alias',1),('busy',2),('late',3),('vector',4)]
    for name,fault in tests:
        log=name+'.log'
        argv=['vsim','-c','-onfinish','stop','-l',run/(name+'_transcript.log'),'-lib',work,'tb_p13_02_apb','-do','onerror {quit -code 2}; onbreak {quit -code 1}; run -all; if {[examine -radix unsigned /tb_p13_02_apb/completed] != 1} {quit -code 1}; quit -code 0']
        if lane=='fixture': argv+=['+fault='+str(fault)]
        target=launch(argv,log)
        raw=(run/log).read_text(errors='replace')
        failures=re.findall(r'ASSERT_FAIL (\S+)',raw)
        checks=re.findall(r'ASSERT_PASS (\S+)',raw)
        cases=re.findall(r'CASE_PASS (RTL-\d+)',raw)
        expected={1:'ALIAS_RAZ',2:'BUSY_IMMUTABLE',3:'OVERFLOW_TERMINAL',4:'BUSY_TAG_COMPARATOR'}.get(fault)
        problems=[]
        if expected:
            if failures!=[expected]: problems.append('wrong semantic assertion '+str(failures))
            if 'MUTATION_REACH fault='+str(fault) not in raw: problems.append('missing fault reach')
            if target==0: problems.append('missing target nonzero propagation')
            if 'SUMMARY_PASS' in raw: problems.append('mutant falsely passed')
        else:
            needed={'RTL-01','RTL-02','RTL-03','RTL-04','RTL-05','RTL-06','RTL-08','RTL-10'}
            needed.update({'RTL-07','RTL-09','RTL-12'} if lane=='fixture' else {'RTL-11'})
            if target!=0: problems.append('target failed '+str(target))
            if failures: problems.append('semantic failure '+str(failures))
            if not needed.issubset(set(cases)): problems.append('missing cases '+str(needed-set(cases)))
            if 'SUMMARY_PASS' not in raw or len(checks)<200: problems.append('missing completed checks')
            if lane=='actual' and set(re.findall(r'KAT_PASS (\S+)',raw))!={'E0','D0','E7','D7','E16','D16'}: problems.append('missing genuine-core KAT')
            required_artifact=run/('intentionally_absent.required' if negative else 'independent_oracle.json')
            if not required_artifact.is_file(): problems.append('MISSING_REQUIRED_ARTIFACT: '+required_artifact.name)
        guard=1 if problems else 0
        final=guard if expected else (target or guard)
        results.append({'name':name,'lane':'CHECKER_SENSITIVITY_ONLY' if fault else ('ACTUAL_CORE_KAT' if lane=='actual' else 'CONTROL_FIXTURE_ONLY'),'fault':fault,'expected_assertion':expected,'assertion_failures':failures,'assertion_passes':checks,'cases':cases,'target_exit':target,'guard_exit':guard,'final_exit':final,'verdict':'FAIL' if final else ('SELFTEST_EXPECTED_REJECTION' if fault else 'PASS'),'raw_log':log,'raw_log_sha256':sha(run/log),'problems':problems})
        print(name,'target',target,'guard',guard,'final',final,'problems',problems,flush=True)
        if final: break
    if any(r['final_exit'] for r in results): break
post={str(p.relative_to(repo)):sha(p) for p in sources}
save('source_post.json',post)
unchanged=pre==post
save('commands.json',commands);save('compile_results.json',compile_results)
final=next((r['final_exit'] for r in results if r['final_exit']),0) or (0 if unchanged else 3)
result={'authority':'Issue20 R2 comment 6580961276','run_id':run.name,'status':'FAIL' if final else 'RESULT_PENDING_REVIEW','source_hashes_unchanged':unchanged,'results':results,'final_exit':final,'legacy_kat_files':'UNCHANGED' if all(pre[str(p.relative_to(repo))]==post[str(p.relative_to(repo))] for p in sources[-2:]) else 'CHANGED','legacy_runner_against_v2':'NOT_RUN_BY_DESIGN','new_actual_core_six_kat':next((r['verdict'] for r in results if r['name']=='actual'),'NOT_RUN')}
save('result.json',result)
# Separate read-only final consistency check against actual files and raw logs.
reread=json.loads((run/'result.json').read_text())
consistent=(reread==result and all(sha(repo/p)==h for p,h in post.items()) and all(sha(run/r['raw_log'])==r['raw_log_sha256'] for r in results))
if not consistent:
    result['status']='FAIL';result['final_exit']=4;save('result.json',result);final=4
save('final_consistency.json',{'consistent':consistent,'exit':0 if consistent else 4})
print('RUN',run,'FINAL_EXIT',final,flush=True)
sys.exit(final)
PY
