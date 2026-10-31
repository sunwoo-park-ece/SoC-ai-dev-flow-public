#!/usr/bin/env python3
import argparse,hashlib,json,re,subprocess,sys
from pathlib import Path

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 a=argparse.ArgumentParser();a.add_argument('--run',type=Path,required=True);args=a.parse_args()
 lane=Path(__file__).resolve().parent;repo=lane.parents[2];r=args.run.resolve()
 if r.exists() or repo==r or repo in r.parents:raise ValueError('fresh external run required')
 r.mkdir(parents=True)
 original=json.loads((repo/'scripts/wsl/soc_health_provider_test.sh').read_text().split('inputs = ',1)[1].split('\ndef manifest',1)[0].replace("'",'"'))
 src=[repo/p for p in original if p.endswith('.c') and not p.endswith('soc_health_provider_host.c')]
 src+=[repo/'firmware/services/soc_health_observers.c',repo/'firmware/drivers/vga_text.c',lane/'fw.c']
 inputs=list(dict.fromkeys(list((repo/'firmware/include').glob('*.h'))+src+[repo/p for p in original]+[Path(__file__)]))
 def manifest():return {str(p.relative_to(repo)):sha(p) for p in inputs}
 pre=manifest();results=[];records=[]
 with (r/'gcc-version.log').open('wb') as f: subprocess.run(['gcc','--version'],stdout=f,stderr=subprocess.STDOUT,check=True)
 for name in ['control','clear_mutant','fault_mutant']:
  d=r/name;d.mkdir();sources=src[:]
  if name!='control':
   path=repo/('firmware/drivers/vram.c' if name=='clear_mutant' else 'firmware/services/soc_health_providers.c')
   s=path.read_text()
   if name=='clear_mutant':
    s=s.replace('VRAM_STATUS_IS_CDC);','VRAM_STATUS_OP_DONE);')
   else:s=s.replace('if (vram_status_is_cdc(status)) {','if (0) {')
   assert s!=path.read_text();copy=d/path.name;copy.write_text(s);sources[sources.index(path)]=copy
  cmd=['gcc','-std=c11','-Wall','-Wextra','-Werror','-O1','-fsanitize=undefined','-fno-sanitize-recover=all','-I',str(repo/'firmware/include'),'-include',str(repo/'verification/firmware/soc_health_provider_mmio.h')]+[str(p) for p in sources]+['-o',str(d/'test')]
  with (d/'compile.log').open('wb') as f:ce=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT).returncode
  rc=None
  if ce==0:
   with (d/'target.log').open('wb') as f:rc=subprocess.run([str(d/'test')],stdout=f,stderr=subprocess.STDOUT).returncode
  raw=(d/'target.log').read_text() if rc is not None else ''
  expected={'clear_mutant':'FW_CLEAR_MASK','fault_mutant':'FW_FAULT_REPORT'}.get(name)
  ids=re.findall(r'ASSERT (\w+)',raw)
  ok=ce==0 and ((rc==0 and not ids and raw.count('CASE c08_diagnostic_independent PASS')==1) if not expected else rc==1 and ids==[expected])
  results.append(dict(name=name,compile_exit=ce,target_exit=rc,guard_exit=0 if ok else 1,final_exit=0 if ok else 1,classification=('SELFTEST_EXPECTED_REJECTION' if expected else 'PASS') if ok else 'FAIL',assertion_ids=ids))
  records.append(dict(name=name,argv=cmd,source_hashes={str(p):sha(p) for p in sources},logs={p.name:sha(p) for p in d.glob('*.log')}))
 post=manifest();result=dict(results=results,source_pre=pre,source_post=post,source_hashes_unchanged=pre==post,commands=records,final_exit=int(pre!=post or any(x['final_exit'] for x in results)))
 (r/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(results));return result['final_exit']
if __name__=='__main__':sys.exit(main())
