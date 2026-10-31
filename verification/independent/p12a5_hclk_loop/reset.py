"""Independent reset retention/cancel oracle and checker-input negative control."""
import sys,json,shutil
from pathlib import Path
from run import HERE,execute,simulate
def leaf(out):
    model=json.loads((out/'expected.json').read_text());image=bytearray(128);uart=0
    for t in model['bus']:
        if t['addr']==0x40060000 and t['write']:
            uart+=1
            if uart==2:break
        if t['dmem'] and t['write'] and t['okay']:
            off=t['addr']-0x10000000;size=t['size'];image[off:off+size]=(t['data']&((1<<(size*8))-1)).to_bytes(size,'little')
    wanted={i:int.from_bytes(image[i*4:i*4+4],'little') for i in range(32)}
    seen={0:{},1:{},2:{}};summary=None
    for line in (out/'reset.txt').read_text().splitlines():
        a=line.split()
        if a[0]=='S':summary=[int(x) for x in a[1:]]
        else:seen[int(a[0])][int(a[1])]=int(a[2],16)
    okay=all(v==wanted for v in seen.values()) and summary and summary[0]>2000000 and summary[1]==1
    r={'status':'PASS' if okay else 'FAIL','assertion':None if okay else 'RESET_MEMORY: retention/cancel/recovery mismatch','snapshot_words':{k:len(v) for k,v in seen.items()},'summary':summary};(out/'check.json').write_text(json.dumps(r,indent=2));return 0 if okay else 1
def parent(root):
    good=root/'control';target=simulate(good,bench=HERE/'reset_tb.sv');assert target==0
    for fixture in [False,True]:
        out=root/'fixture' if fixture else good
        if fixture:
            out.mkdir(parents=True)
            for f in ['expected.json','program.json','program.hex','source-inputs.json','target.log','compile.exit.json','target.exit.json','reset.txt']:shutil.copyfile(good/f,out/f)
            rows=(out/'reset.txt').read_text().splitlines()
            for i,l in enumerate(rows):
                a=l.split()
                if a[:2]==['1','0']:a[2]=format(int(a[2],16)^1,'x');rows[i]=' '.join(a);break
            (out/'reset.txt').write_text('\n'.join(rows)+'\n')
        lc=execute([sys.executable,'-B',str(HERE/'reset.py'),'--leaf',str(out)],HERE,out/'leaf.log')
        gc=execute([sys.executable,'-B',str(HERE/'guard.py'),str(out),'semantic'],HERE,out/'guard.log');code=lc or gc
        (out/'parent.json').write_text(json.dumps({'target_exit':0,'leaf_exit':lc,'guard_exit':gc,'parent_exit':code}));assert lc==gc==code==int(fixture)
        print('RESET',fixture,(out/'check.json').read_text(),flush=True)
if __name__=='__main__':
    if sys.argv[1]=='--leaf':raise SystemExit(leaf(Path(sys.argv[2])))
    parent(Path(sys.argv[1]))
