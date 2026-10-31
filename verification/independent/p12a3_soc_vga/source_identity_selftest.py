#!/usr/bin/env python3
"""Source-guard tests only; never builds/runs a CPU image.

Proof/mutation matrix: approved HEAD + actual closure -> source-check control;
wrong manifest base, mismatched pre/post, consistently forged/missing closure,
and simulated wrong live HEAD -> G1C_GUARD_SOURCE. All metadata faults are fresh
local fixtures. Wrong live HEAD is mocked only inside this Python process; no
Git ref/source mutation. Semantic ELF/CPU functions are stubbed in source-boundary unit tests ONLY to bound this claim to source identity. Real CLI/leaf/parent negatives use
invalid-source fixtures without stubs, and must propagate the exact rejection.
"""
import argparse,copy,hashlib,importlib.util,json,os,shutil,subprocess,sys
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode=True

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',required=True,type=Path);ap.add_argument('--guard',type=Path);args=ap.parse_args()
    here=Path(__file__).resolve().parent;repo=here.parents[2];root=args.run.resolve()
    if root.exists() or repo==root or repo in root.parents:raise ValueError('fresh external root required')
    root.mkdir(parents=True)
    spec=importlib.util.spec_from_file_location('identity_guard',args.guard or here/'p12a3_evidence_guard.py')
    g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
    identity=g.closure(repo)[1];observations=[];commands=[]
    def save(n,v): (root/n).write_text(json.dumps(v,indent=2)+'\n')
    save('source-pre.json',identity)
    fixture=root/'control';fixture.mkdir()
    m=dict(base=g.BASE,repo=str(repo),run_root=str(fixture),run_set='targeted',source_before=dict(identity),source_after=dict(identity),images={l:{'sim':l+'.vvp'} for l in ['normal','fault']},cases={},artifacts={})
    for name,(lane,pid) in [('normal',('normal','')),('fault',('fault',''))]+list(g.TARGETED.items()):
        raw=name+'.raw.log';(fixture/raw).write_text(f'G1_ADAPTER {name} fixture\nG1_FAILURE {pid} fixture\n' if pid else 'SOURCE_ONLY_CONTROL_NOT_CPU_EVIDENCE\n')
        cmd=name+'.raw.log.command.json';(fixture/cmd).write_text(json.dumps({'argv':['vvp',str(fixture/m['images'][lane]['sim']),'+OBS_FAULT='+('NONE' if not pid else name)]}))
        m['cases'][name]=dict(raw=raw,exit=1 if pid else 0,image=m['images'][lane]['sim'],pid=pid)
    m['artifacts']={p.name:g.sha(p) for p in fixture.iterdir()};g.put(fixture/'manifest.json',m)
    with patch.object(g,'image_provenance',return_value=(b'',{},{})) as image,patch.object(g,'semantic_lane',return_value={}) as semantic:
        assert g.guard(fixture)==0 and image.call_count==2 and semantic.call_count==2
    observations.append(dict(name='valid_source_control',classification='PASS_SOURCE_ONLY',semantic_stubbed=True))
    def reject(name,manifest,wrong_head=False):
        d=root/name;shutil.copytree(fixture,d);g.put(d/'manifest.json',manifest)
        try:
            if wrong_head:
                with patch.object(g.subprocess,'check_output',return_value='0'*40+'\n'),patch.object(g,'image_provenance',return_value=(b'',{},{})),patch.object(g,'semantic_lane',return_value={}):g.guard(d)
            else:g.guard(d)
        except g.GuardFailure as e:
            assert e.pid=='G1C_GUARD_SOURCE',str(e)
            observations.append(dict(name=name,classification='SELFTEST_EXPECTED_REJECTION',pid=e.pid,detail=str(e)));return
        raise AssertionError('source rejection absent: '+name)
    a=copy.deepcopy(m);a['base']='8c3a4d6948e3061ff48021b81a6a3eec708f7788';reject('old_base',a)
    a=copy.deepcopy(m);a['source_after'][next(iter(identity))]='0'*64;reject('pre_post_mismatch',a)
    a=copy.deepcopy(m);key=next(iter(identity));a['source_before'][key]=a['source_after'][key]='0'*64;reject('forged_equal_hashes',a)
    a=copy.deepcopy(m);key=next(iter(identity));del a['source_before'][key];del a['source_after'][key];reject('missing_source',a)
    reject('wrong_live_head',copy.deepcopy(m),True)
    with patch.object(g.subprocess,'check_output',return_value='0'*40+'\n'),patch.object(g,'command') as build:
        try:g.run(repo,root/'must_not_exist')
        except g.GuardFailure as e:assert e.pid=='G1C_GUARD_SOURCE'
        else:raise AssertionError('run accepted wrong HEAD')
        assert not (root/'must_not_exist').exists() and build.call_count==0
    observations.append(dict(name='run_head_rejection_before_output_or_build',classification='SELFTEST_EXPECTED_REJECTION',pid='G1C_GUARD_SOURCE'))
    def execute(name,argv,env=None):
        with (root/(name+'.log')).open('wb') as log:rc=subprocess.run(argv,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60).returncode
        raw=(root/(name+'.log')).read_text();commands.append(dict(name=name,argv=argv,exit=rc,log_sha256=g.sha(root/(name+'.log'))));return rc,raw
    rc,raw=execute('cli_guard',[sys.executable,str(here/'p12a3_evidence_guard.py'),'guard',str(root/'old_base')])
    assert rc==1 and 'G1C_GUARD_SOURCE' in raw
    env=dict(os.environ,G1_GUARD_FIXTURE=str(root/'old_base'),G1_GUARD_MUTATION='valid',RUN_SET='owner_g1')
    env['RUN_ROOT']=str(root/'leaf')
    rc,raw=execute('leaf',['bash',str(repo/'scripts/wsl/p12a3_soc_vga_test.sh')],env)
    assert rc==1 and 'G1C_GUARD_SOURCE' in raw
    leaf=json.loads((root/'leaf/replay.result.json').read_text());assert leaf['target_exit']==0 and leaf['guard_exit']==leaf['final_exit']==1 and leaf['guard_pid']=='G1C_GUARD_SOURCE'
    env['RUN_ROOT']=str(root/'parent')
    rc,raw=execute('parent',['bash',str(here/'run_p12a3_regression.sh')],env)
    assert rc==1 and 'leaf_exit=1 guard_exit=1 final_exit=1' in raw
    assert 'G1C_GUARD_SOURCE' in (root/'parent/parent.raw.log').read_text()
    post=g.closure(repo)[1];save('source-post.json',post);assert post==identity
    for n in ['leaf','parent']:
        observations.append(dict(name=n,classification='SELFTEST_EXPECTED_REJECTION',pid='G1C_GUARD_SOURCE',final_exit=1))
    result=dict(classification='PASS_SOURCE_GUARD_SELFTEST_ONLY',cpu_e2e='NOT_RUN_OWNER_PENDING',observations=observations,commands=commands,source_hashes_unchanged=post==identity,final_exit=0)
    save('result.json',result)
    assert json.loads((root/'result.json').read_text())==result
    print(json.dumps(result))
    return 0
if __name__=='__main__':sys.exit(main())
