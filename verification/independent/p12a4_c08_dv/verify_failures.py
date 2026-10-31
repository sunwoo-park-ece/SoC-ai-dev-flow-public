#!/usr/bin/env python3
"""Check real leaf/guard failure propagation through the public runner process."""
import argparse,json,subprocess,sys,hashlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--run',required=True,type=Path);a=p.parse_args()
r=a.run.resolve();r.mkdir(parents=True,exist_ok=False);lane=Path(__file__).resolve().parent
rows=[]
for mode in ['leaf','guard']:
 cmd=[sys.executable,str(lane/'run.py'),'--run',str(r/mode),'--propagate',mode]
 with (r/(mode+'.log')).open('wb') as f:rc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT).returncode
 result=json.loads((r/mode/'result.json').read_text());row=result['lanes'][0]
 ok=rc==1 and result['final_exit']==1 and row['guard_exit']==1 and row['classification']=='FAIL'
 if mode=='leaf':ok=ok and row['target_exit']==1 and row['assertion_ids']==['PORT_DATA']
 else:ok=ok and row['target_exit']==0 and row['errors']==['GUARD_TRACE']
 rows.append(dict(mode=mode,parent_exit=rc,target_exit=row['target_exit'],guard_exit=row['guard_exit'],final_exit=result['final_exit'],classification='SELFTEST_EXPECTED_REJECTION' if ok else 'FAIL',log_sha256=hashlib.sha256((r/(mode+'.log')).read_bytes()).hexdigest(),command=cmd))
(r/'result.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows));sys.exit(int(any(x['classification']=='FAIL' for x in rows)))
