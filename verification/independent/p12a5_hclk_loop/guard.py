"""Semantic evidence guard: process zero is insufficient without checked evidence."""
import json,sys,hashlib
from pathlib import Path
out=Path(sys.argv[1]);mode=sys.argv[2]
try:
    target=json.loads((out/('target.exit.json' if mode=='semantic' else 'elaborate.exit.json')).read_text())
    leaf=json.loads((out/'leaf.exit.json').read_text())
    checked=json.loads((out/'check.json').read_text())
    okay=target['exit']==0 and leaf['exit']==0 and checked['status']=='PASS'
    for name,h in json.loads((out/'source-inputs.json').read_text()).items():
        okay=okay and hashlib.sha256(Path(name).read_bytes()).hexdigest()==h
    if mode=='semantic':okay=okay and json.loads((out/'compile.exit.json').read_text())['exit']==0 and 'TARGET_COMPLETE' in (out/'target.log').read_text()
    result={'status':'PASS' if okay else 'FAIL','target_exit':target['exit'],'leaf_exit':leaf['exit'],'assertion':checked.get('assertion'),'mode':mode}
except (OSError,ValueError,KeyError) as e:
    okay=False;result={'status':'FAIL','assertion':'EVIDENCE_MISSING: '+str(e),'mode':mode}
(out/'guard.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));raise SystemExit(0 if okay else 1)
