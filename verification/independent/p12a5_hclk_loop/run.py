import argparse,json,subprocess,os,time,hashlib,sys
from pathlib import Path
from oracle import generate
HERE=Path(__file__).resolve().parent
PUB=HERE.parents[2]
def execute(argv,cwd,log,timeout=90):
    start=time.monotonic()
    with log.open('w') as f:
        try:r=subprocess.run(argv,cwd=cwd,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),stdout=f,stderr=subprocess.STDOUT,timeout=timeout);code=r.returncode
        except subprocess.TimeoutExpired:code=124
        except OSError as e:f.write(str(e)+'\n');code=127
    record={'argv':list(map(str,argv)),'cwd':str(cwd),'exit':code,'seconds':time.monotonic()-start,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()}
    log.with_suffix('.exit.json').write_text(json.dumps(record,indent=2));return code
def sources():
    return subprocess.check_output(['python3','-B','scripts/wsl/source_list.py','OPEN_SIM_VERILOG'],cwd=PUB,text=True).splitlines()
def simulate(out,replace=None,bench=None):
    bench=Path(bench) if bench else HERE/'tb.sv'
    out.mkdir(parents=True,exist_ok=False);expected=generate(out);(out/'expected.json').write_text(json.dumps(expected,indent=2))
    src=sources();src=[str(replace.get(str(Path(s).relative_to(PUB)),s)) if replace else s for s in src]
    inputs=[Path(s) for s in src]+list(HERE.glob('*.py'))+[bench,HERE/'proof_plan.md']
    inputs+=list((PUB/'rtl/core/vh').glob('*.vh'))
    if replace:
        for rel,p in replace.items():
            if rel.startswith('rtl/core/v/'):inputs+=list((Path(p).parents[4]/'rtl/core/vh').glob('*.vh'))
    (out/'source-inputs.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},indent=2))
    includes=['-I'+str(p) for p in sorted((PUB/'rtl/core/v').rglob('*')) if p.is_dir()]+['-I'+str(PUB/'rtl/core/v')]
    compile_code=execute(['iverilog','-g2012','-s','tb','-o',str(out/'sim.vvp'),*includes,*src,str(bench)],PUB,out/'compile.log')
    if compile_code:return compile_code
    return execute(['vvp',str(out/'sim.vvp')],out,out/'target.log')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run-root',required=True);args=p.parse_args();root=Path(args.run_root).resolve()
    assert not root.is_relative_to(PUB)
    raise SystemExit(simulate(root/'control'))
