"""Checker-input fixtures only. They do not execute or mutate a Production DUT."""
import sys,json,shutil
from pathlib import Path
from run import HERE,execute
golden=Path(sys.argv[1]);root=Path(sys.argv[2]);raw=(golden/'trace.txt').read_text().splitlines()
fixtures=[('retire','R',2,'RETIRE_ORDER'),('gpr','R',6,'GPR_RESULT'),('trap','T',3,'TRAP_CAUSE_PC'),('csr','C',3,'CSR_EFFECT'),('ram','D',2,'RAM_IMAGE'),('uart','U',2,'UART_POLICY'),('vga','V',5,'VGA_PHYSICAL'),('request','B',2,'REQUEST_ORDER'),('response','B',9,'RESPONSE_CONTRACT'),('payload','B',6,'PAYLOAD_STABLE'),('adc-state','S',3,'PERIPHERAL_STATE'),('truncated','S',0,'COVERAGE_COMPLETE')]
results=[]
for name,tag,field,want in fixtures:
    out=root/name;out.mkdir(parents=True,exist_ok=False)
    for f in ['program.json','program.hex','expected.json','source-inputs.json','compile.exit.json','target.exit.json','target.log']:shutil.copyfile(golden/f,out/f)
    rows=list(raw);found=False
    for i,line in enumerate(rows):
        a=line.split()
        if a[0]!=tag:continue
        if name=='gpr' and a[4]!='1':continue
        if name=='vga' and a[3]!='1':continue
        if name=='request' and not(int(a[4],16)&2 and a[8]=='1' and a[9]=='0'):continue
        if name=='response' and a[9]!='1':continue
        if name=='payload' and int(a[7],16)==0:continue
        if name=='truncated':rows=rows[:i]
        else:a[field]=format(int(a[field],16)^(4 if name in ('retire','request','trap','csr') else 1),'x');rows[i]=' '.join(a)
        found=True;break
    assert found,name
    (out/'trace.txt').write_text('\n'.join(rows)+'\n')
    rc=execute([sys.executable,'-B',str(HERE/'case.py'),str(out),'semantic'],HERE,out/'case.log')
    checked=json.loads((out/'check.json').read_text());chain=json.loads((out/'parent.json').read_text())
    valid=rc==1 and checked['status']=='FAIL' and checked['assertion'].startswith(want+':') and chain['target_exit']==0 and chain['leaf_exit']==chain['guard_exit']==chain['parent_exit']==1
    results.append({'fixture':name,'kind':'checker-observation-fixture-not-DUT-run','expected':want,'actual':checked.get('assertion'),'rejected':valid,'chain':chain})
    (root/'sensitivity.json').write_text(json.dumps(results,indent=2));print(name,valid,checked['assertion'][:100],flush=True)
    if not valid:raise SystemExit(1)
