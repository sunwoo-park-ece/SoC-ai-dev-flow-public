"""Leaf -> guard -> parent pipeline. Mutant cases must remain nonzero/FAIL."""
import sys,json
from pathlib import Path
from run import HERE,execute
out=Path(sys.argv[1]);mode=sys.argv[2]
leaf=[sys.executable,'-B',str(HERE/('check.py' if mode=='semantic' else 'structural.py')),str(out)]
lc=execute(leaf,HERE,out/'leaf.log')
gc=execute([sys.executable,'-B',str(HERE/'guard.py'),str(out),mode],HERE,out/'guard.log')
target=json.loads((out/('target.exit.json' if mode=='semantic' else 'elaborate.exit.json')).read_text())['exit']
code=target or lc or gc
(out/'parent.json').write_text(json.dumps({'status':'PASS' if code==0 else 'FAIL','target_exit':target,'leaf_exit':lc,'guard_exit':gc,'parent_exit':code},indent=2))
print(json.dumps({'target':target,'leaf':lc,'guard':gc,'parent':code}));raise SystemExit(code)
