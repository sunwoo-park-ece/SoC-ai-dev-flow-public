"""Additional held-address/control check on real observations and isolated trace fixture."""
import sys,json,shutil,hashlib
from pathlib import Path
from run import HERE,execute
def child(out):
    previous=None;count=0
    for line in (out/'trace.txt').read_text().splitlines():
        a=line.split()
        if a[0]!='B':continue
        current=[int(x,16) for x in a[2:]]
        if previous is not None and previous[6]==current[6]==0:
            if previous[:4]!=current[:4]:
                (out/'check.json').write_text(json.dumps({'status':'FAIL','assertion':'AHB_HOLD: '+line}));return 1
            count+=1
        previous=current
    okay=count>1000
    (out/'check.json').write_text(json.dumps({'status':'PASS' if okay else 'FAIL','assertion':None if okay else 'AHB_HOLD_COVERAGE: insufficient wait cycles','held_pairs':count}));return 0 if okay else 1
def parent(golden,root):
    for fixture in [False,True]:
        out=root/('fixture' if fixture else 'control');out.mkdir(parents=True,exist_ok=False)
        for f in ['program.json','program.hex','expected.json','source-inputs.json','compile.exit.json','target.exit.json','target.log','trace.txt']:shutil.copyfile(golden/f,out/f)
        if fixture:
            rows=(out/'trace.txt').read_text().splitlines();seen_wait=False
            for i,line in enumerate(rows):
                a=line.split()
                if a[0]=='B':
                    if a[8]=='0' and seen_wait:a[2]=format(int(a[2],16)^4,'x');rows[i]=' '.join(a);break
                    seen_wait=a[8]=='0'
            else:raise ValueError('no wait reached')
            (out/'trace.txt').write_text('\n'.join(rows)+'\n')
        lc=execute([sys.executable,'-B',str(HERE/'audit.py'),'--child',str(out)],HERE,out/'leaf.log')
        gc=execute([sys.executable,'-B',str(HERE/'guard.py'),str(out),'semantic'],HERE,out/'guard.log')
        code=lc or gc;(out/'parent.json').write_text(json.dumps({'target_exit':0,'leaf_exit':lc,'guard_exit':gc,'parent_exit':code}))
        assert code==int(fixture) and lc==gc==int(fixture)
        print('AHB_HOLD',fixture,code,(out/'check.json').read_text())
if __name__=='__main__':
    if sys.argv[1]=='--child':raise SystemExit(child(Path(sys.argv[2])))
    parent(Path(sys.argv[1]),Path(sys.argv[2]))
