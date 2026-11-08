"""G3 driver. Expected mutant rejection is kept distinct from golden PASS."""
import argparse,json,sys,hashlib,difflib,os,shutil
from pathlib import Path
from run import HERE,PUB,execute,simulate,sources
def elaborate(out,replace=None):
    out.mkdir(parents=True,exist_ok=False)
    src=[Path(s) for s in sources() if Path(s).is_relative_to(PUB/'rtl')]
    src=[Path(replace.get(str(s.relative_to(PUB)),s)) if replace else s for s in src]+[HERE/'boundaries.sv']
    inputs=src+list((PUB/'rtl/core/vh').glob('*.vh'))+list(HERE.glob('*.py'))
    if replace:
        for rel,p in replace.items():
            if rel.startswith('rtl/core/v/'):inputs+=list((Path(p).parents[4]/'rtl/core/vh').glob('*.vh'))
    (out/'source-inputs.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},indent=2))
    script='read_verilog -sv -I'+str(PUB/'rtl/core/vh')+' '+' '.join(str(p) for p in src)+'; hierarchy -check -top AMBA_SoC_TOP; proc; flatten; opt_clean; write_json '+str(out/'unoptimized.json')+'; scc; opt; write_json '+str(out/'optimized.json')+'; scc; check\n'
    (out/'elaborate.ys').write_text(script)
    return execute([os.environ.get('YOSYS','yosys'),'-Q','-T','-s',str(out/'elaborate.ys')],PUB,out/'elaborate.log')
def checked(out,mode):return execute([sys.executable,'-B',str(HERE/'case.py'),str(out),mode],HERE,out/'case.log')
def main():
    p=argparse.ArgumentParser();p.add_argument('--run-root',required=True);args=p.parse_args();root=Path(args.run_root).resolve();assert not root.is_relative_to(PUB)
    outcomes=[]
    for mode in ['semantic','structural']:
        out=root/('golden-'+mode)
        target=simulate(out) if mode=='semantic' else elaborate(out)
        parent=checked(out,mode) if target==0 else target
        outcomes.append({'name':'golden-'+mode,'target':target,'parent':parent,'kind':'golden'})
        (root/'suite.json').write_text(json.dumps(outcomes,indent=2))
        print(outcomes[-1],flush=True)
        if parent:return 1
    cpu='rtl/core/v/top/RV32I46F_5SP_MMIO.v';mem='rtl/bus/AHB_MEMORY_SLAVE.v';align='rtl/core/v/mem_stage/StoreAligner.v'
    mutations=[
      ('feedback-data','structural',cpu,'assign MEM_store_data_AHB = data_memory_write_data;','assign MEM_store_data_AHB = data_memory_write_data & {32{!mem_fault_now}};','STRUCT_RESPONSE_DATA'),
      ('feedback-mask','structural',cpu,'    StoreAligner store_aligner (','    wire [3:0] mutation_raw_mask;\n    assign CUSTOM_WRITE_MASK = mutation_raw_mask & {4{!mem_fault_now}};\n    StoreAligner store_aligner (','STRUCT_RESPONSE_MASK'),
      ('shifted-mask','semantic',align,"2'b00: write_mask = 4'b0001;","2'b00: write_mask = 4'b0010;",'WRITE_LANES'),
      ('wrong-address','semantic',mem,'.wraddress (addr_reg)',".wraddress (addr_reg ^ 13'd1)",'WRITE_ADDRESS'),
      ('phantom-final','semantic',mem,'.wren        (write_en_reg)',".wren        (write_en_reg || (HREADY_IN && !HSEL && HADDR == 32'h10000040 && byteena != 0))",'WRITE_OWNER')]
    for name,mode,path,old,new,want in mutations:
        source=(PUB/path).read_text();assert source.count(old)==1,(name,old)
        changed=source.replace(old,new)
        if name=='feedback-mask':
            old2='.write_mask              (CUSTOM_WRITE_MASK)';assert changed.count(old2)==1;changed=changed.replace(old2,'.write_mask              (mutation_raw_mask)')
        copy=root/'mutant-sources'/name/path;copy.parent.mkdir(parents=True,exist_ok=True);copy.write_text(changed)
        shutil.copytree(PUB/'rtl/core/vh',root/'mutant-sources'/name/'rtl/core/vh')
        copy.with_suffix('.diff').write_text(''.join(difflib.unified_diff(source.splitlines(True),changed.splitlines(True),fromfile='original/'+path,tofile='isolated/'+path)))
        replace={path:str(copy)};out=root/name
        target=simulate(out,replace) if mode=='semantic' else elaborate(out,replace)
        parent=checked(out,mode) if target==0 else target
        result=json.loads((out/'check.json').read_text()) if (out/'check.json').exists() else {}
        chain=json.loads((out/'parent.json').read_text()) if (out/'parent.json').exists() else {}
        killed=target==0 and parent!=0 and result.get('status')=='FAIL' and (result.get('assertion') or '').startswith(want+':') and chain.get('leaf_exit')==chain.get('guard_exit')==chain.get('parent_exit')==1
        outcomes.append({'name':name,'kind':'isolated-source-copy','target':target,'parent':parent,'expected_assertion':want,'assertion':result.get('assertion'),'killed':killed,'source':str(copy),'source_sha256':hashlib.sha256(copy.read_bytes()).hexdigest()})
        (root/'suite.json').write_text(json.dumps(outcomes,indent=2));print(outcomes[-1],flush=True)
        if not killed:return 1
    return 0
if __name__=='__main__':raise SystemExit(main())
