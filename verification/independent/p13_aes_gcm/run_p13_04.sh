#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
export P13_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT to a unique fresh run directory}"
python3 -B - "$@" <<'PY'
import argparse,datetime,hashlib,importlib.util,json,os,pathlib,re,shutil,subprocess,sys
repo=pathlib.Path(os.environ['P13_REPO']).resolve()
base=repo/'verification/independent/p13_aes_gcm'
spec=importlib.util.spec_from_file_location('guard',base/'p13_04_evidence_guard.py')
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
ap=argparse.ArgumentParser()
ap.add_argument('--mode',choices=['actual','sensitivity'],default='actual')
ap.add_argument('--fault',type=int,choices=[0,1,2,3],default=0)
ap.add_argument('--negative',choices=['missing','tamper'])
ap.add_argument('--selftest',action='store_true')
args=ap.parse_args()
run=pathlib.Path(os.environ['RUN_ROOT']).resolve()
approved=repo.parents[1]/'runs/p13_aes_dv'
if not run.is_relative_to(approved) or run==approved:raise SystemExit('OUT_OF_SCOPE_RUN_ROOT')
run.mkdir(parents=True,exist_ok=False)
os.environ['TMPDIR']=str(run)
os.chdir(run)
commands=[];artifacts=[];target=None;guard=None;reason='INCOMPLETE'
def save(n,d):g.save(run/n,d)
def git(r,*a):return subprocess.check_output(['git','-C',str(r),*a],text=True).strip()
def launch(argv,name,timeout=60):
    argv=list(map(str,argv));commands.append(dict(argv=argv,cwd=str(run),name=name,timeout=timeout))
    with (run/(name+'.stdout')).open('wb') as out,(run/(name+'.stderr')).open('wb') as err:
        try:rc=subprocess.run(argv,cwd=run,stdout=out,stderr=err,timeout=timeout).returncode
        except subprocess.TimeoutExpired:rc=124
        except OSError as e:err.write(str(e).encode());rc=127
    artifacts.extend([name+'.stdout',name+'.stderr'])
    save(name+'.exit.json',{'exit':rc});artifacts.append(name+'.exit.json')
    save('commands.json',commands)
    return rc
private=repo.parent/'p13-aes-private'
def identity(r):
    return dict(top=git(r,'rev-parse','--show-toplevel'),head=git(r,'rev-parse','HEAD'),
                branch=git(r,'branch','--show-current'),porcelain=git(r,'status','--porcelain=v1','--untracked-files=all'),
                staged=git(r,'diff','--cached','--name-status'))
def source_hashes():return {f:g.sha(repo/f) for f in sources}
sources=[];pre={};records={};final=1
try:
    entry={'public':identity(repo),'private':identity(private)};save('git_pre.json',entry)
    for label,pin in [('public','5b215243f125e780060aa786bfe3d64b8fcf01f3'),('private','26d17fefeb8dadbb8b76ffc0b124bc479dfdab05')]:
        if entry[label]['head']!=pin or entry[label]['branch']!='cleanup/p13-aes' or entry[label]['staged']:
            raise RuntimeError('SOURCE_IDENTITY_DRIFT')
    allowed={g.PREFIX+n for n in g.NAMES}
    delta=entry['public']['porcelain'].splitlines()
    if any(not line.startswith('?? ') or line[3:] not in allowed for line in delta) or entry['private']['porcelain']:
        raise RuntimeError('UNEXPECTED_DIRTY_OR_INDEX')
    if set(line[3:] for line in delta)!=allowed:raise RuntimeError('EIGHT_FILE_SCOPE_INCOMPLETE')
    if launch(['python3','-B',repo/'scripts/wsl/source_list.py','OPEN_SIM_MIXED_MODELSIM','--group'],'vhdl_resolution'):
        raise RuntimeError('MANIFEST_RESOLUTION')
    vhdl=[pathlib.Path(s.split('\t')[1]) for s in (run/'vhdl_resolution.stdout').read_text().splitlines() if s.startswith('aes_vhdl_dependency_order\t')]
    if [p.stem for p in vhdl]!=g.VHDL:raise RuntimeError('ACTUAL_CORE_BINDING_UNKNOWN_OR_STUB')
    deps=['scripts/wsl/source_list.py','fpga/quartus/build_profiles.json','fpga/quartus/source_manifest.yml',
          'verification/directed/aes_gcm_actual_core/run_kat.sh','verification/directed/aes_gcm_actual_core/tb_aes_gcm_actual_core_kat.sv',
          'verification/directed/p13_aes_rtl/run_p13_02.sh','verification/directed/p13_aes_rtl/tb_p13_02_apb.sv',
          'verification/directed/p13_aes_rtl/p13_02_contract_checker.sv','spec/14_aes_gcm.md','spec/kor/14_aes_gcm.ko.md',
          'spec/19_firmware_contract.md','spec/kor/19_firmware_contract.ko.md','spec/baseline_cleanup.md',
          'AGENTS.md','docs/governance/anti_cosmetic_verification_policy.md','docs/governance/reporting_policy.md']
    wrapper=repo/'rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v'
    sources=[str(p.relative_to(repo)) for p in vhdl+[wrapper]]+[g.PREFIX+n for n in g.NAMES]+deps
    pre=source_hashes();save('source_pre.json',pre)
    for tool in ['vcom','vlog','vsim','openssl','python3']:
        rc=launch([tool,'--version' if tool=='python3' else ('version' if tool=='openssl' else '-version')],tool+'.version')
        if rc:raise RuntimeError('MIXED_LANGUAGE_TOOL_UNAVAILABLE:'+tool)
    if launch(['vlib','-help'],'vlib.help'):raise RuntimeError('VLIB_UNAVAILABLE')
    if launch(['python3','-B',base/'p13_04_oracle_vectors.py','--check',base/'p13_04_vectors.json','--emit',run],'oracle'):
        raise RuntimeError('ORACLE_CIRCULARITY_OR_KAT_MISMATCH')
    artifacts.extend(['oracle.json','vectors.txt'])
    save('lane.json',{'mode':args.mode,'fault':args.fault,'lane':'ACTUAL_CORE_CRYPTO/CONTROL_NEGATIVE_REAL' if args.mode=='actual' else 'ISOLATED_CHECKER_SENSITIVITY',
                     'seed':'deterministic two asymmetric patterns','clock_ns':10,'timeout_ns':3000000})
    compiled=([*vhdl,wrapper,base/'p13_04_contract_scoreboard.sv',base/'tb_p13_04_apb.sv'] if args.mode=='actual'
              else [base/'p13_04_contract_scoreboard.sv',base/'p13_04_mutation_adapter.sv'])
    save('compiled_sources.json',{str(p.relative_to(repo)):g.sha(p) for p in compiled})
    work=run/'work'
    if launch(['vlib',work],'vlib'):raise RuntimeError('VLIB_FAILED')
    if args.mode=='actual' and launch(['vcom','-2008','-work',work,*vhdl],'vcom'):raise RuntimeError('VCOM_FAILED')
    if launch(['vlog','-sv','-work',work,*[p for p in compiled if p.suffix!='.vhd']],'vlog'):raise RuntimeError('VLOG_FAILED')
    top='tb_p13_04_apb' if args.mode=='actual' else 'tb_p13_04_sensitivity'
    do='onerror {quit -code 2}; onbreak {quit -code 1}; echo HIERARCHY_BEGIN; foreach inst [find instances -recursive /*] {echo "BOUND_INSTANCE $inst"}; echo HIERARCHY_END; run -all; if {[examine -radix unsigned /'+top+'/completed] != 1} {quit -code 1}; quit -code 0'
    argv=['vsim','-c','-onfinish','stop','-l',run/'target.transcript','-wlf',run/'target.wlf','-lib',work,top,'-do',do]
    argv+=['+vectors='+str(run/'vectors.txt')] if args.mode=='actual' else ['+fault='+str(args.fault)]
    target=launch(argv,'target',120)
    save('target_exit.json',{'exit':target})
    artifacts.extend(['target.transcript','target_exit.json'])
    # Snapshot after the simulator, before independent guard reads actual files.
    save('source_post.json',source_hashes());save('commands.json',commands)
    artifacts.extend(['source_pre.json','source_post.json','compiled_sources.json','lane.json','commands.json'])
    save('inputs.json',{n:g.sha(run/n) for n in sorted(set(artifacts)) if (run/n).is_file()})
    # Fault only an isolated evidence copy; original process streams stay intact.
    guard_input=run
    if args.negative:
        guard_input=run/'isolated_bad_evidence';guard_input.mkdir()
        inv=g.load(run/'inputs.json')
        for n in [*inv,'inputs.json']:
            if args.negative=='missing' and n=='target.transcript':continue
            shutil.copyfile(run/n,guard_input/n)
        if args.negative=='tamper':
            with (guard_input/'target.stdout').open('a') as f:f.write('\nCORRUPTED_COPY_AFTER_HASH_CAPTURE\n')
    guard=launch(['python3','-B',base/'p13_04_evidence_guard.py','--repo',repo,'--run',guard_input],'guard')
    final=target or guard
    reason='TARGET_FAILED' if target else ('GUARD_REJECTED' if guard else 'RESULT_PENDING_REVIEW')
    if final==0 and args.selftest:
        inv=g.load(run/'inputs.json');inv['commands.json']=g.sha(run/'commands.json');save('inputs.json',inv)
        rc=launch(['python3','-B',base/'p13_04_guard_selftest.py','--repo',repo,'--run',run],'selftest',240)
        final=rc;reason='SELFTEST_FAILED' if rc else 'RESULT_PENDING_REVIEW'
except Exception as exc:
    reason=str(exc);final=1
    save('exception.json',{'type':type(exc).__name__,'message':str(exc)})
finally:
    if sources:save('source_post.json',source_hashes())
    save('commands.json',commands)
    after={'public':identity(repo),'private':identity(private)};save('git_post.json',after)
    if 'entry' in locals() and after!=entry:final=1;reason='SOURCE_IDENTITY_DRIFT'
    unchanged=bool(pre) and pre==source_hashes()
    if not unchanged:final=1;reason='SOURCE_IDENTITY_DRIFT'
    # commands.json gains guard/selftest calls; refresh its inventory once those
    # processes complete. Input stdout/transcript hashes are never refreshed.
    if (run/'inputs.json').is_file():
        inv=g.load(run/'inputs.json');inv['commands.json']=g.sha(run/'commands.json');save('inputs.json',inv)
    records={'task':'P13-04A-GENUINE-CORE-DV R1 / Owner-authorized resume','run_id':run.name,'mode':args.mode,'fault':args.fault,
             'status':'FAIL' if final else 'RESULT_PENDING_REVIEW','reason':reason,'target_exit':target,'guard_exit':guard,
             'final_exit':final,'source_hashes_unchanged':unchanged,'natural_icb_overflow':'NOT_RUN','selftest_requested':args.selftest}
    save('result.json',records)
    consistency=(g.load(run/'result.json')==records and unchanged and (bool(final) or (target==0 and guard==0 and not g.validate(run,repo))))
    save('final_consistency.json',{'consistent':consistency,'exit':0 if consistency else 1})
    if not consistency:final=1;records['status']='FAIL';records['final_exit']=1;save('result.json',records)
    save('artifact_hashes.json',{str(p.relative_to(run)):g.sha(p) for p in sorted(run.rglob('*')) if p.is_file() and p.name!='artifact_hashes.json'})
    print(json.dumps(records),flush=True)
sys.exit(final)
PY
