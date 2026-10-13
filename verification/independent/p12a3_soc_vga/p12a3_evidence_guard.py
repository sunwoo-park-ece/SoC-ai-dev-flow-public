#!/usr/bin/env python3
"""G1 build/run evidence and independent raw-evidence guard. No RTL writes."""
import hashlib,json,os,re,shutil,struct,subprocess,sys,time
from pathlib import Path
BASE='8c3a4d6948e3061ff48021b81a6a3eec708f7788'
ADAPTERS={'RESET':('normal','FAIL_G1_RESET'),'ROUTE':('normal','FAIL_G1_ROUTE'),'PHASE':('normal','FAIL_G1_PHASE'),'BANK':('normal','FAIL_G1_COMMIT'),'DATA':('normal','FAIL_G1_COMMIT'),'STATUS':('normal','FAIL_G1_STATUS'),'NOOP':('normal','FAIL_G1_NOOP'),'BOOT':('normal','FAIL_G1_BOOT'),'ERROR':('fault','FAIL_G1_ERROR'),'CAUSE':('fault','FAIL_G1_CPU_FAULT'),'MEPC':('fault','FAIL_G1_CPU_FAULT'),'RETIRE':('fault','FAIL_G1_RETIRE'),'YOUNGER':('fault','FAIL_G1_RETIRE'),'IMAGE':('normal','FAIL_G1_IMAGE'),'MEMORY':('normal','FAIL_G1_COMMIT')}
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v): p.write_text(json.dumps(v,indent=2)+'\n')
def command(args,out,budget=240):
    put(Path(str(out)+'.command.json'),{'argv':args,'budget_seconds':budget,'started_ns':time.time_ns()})
    with out.open('w') as f:
        try: c=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT,timeout=budget);return c.returncode
        except subprocess.TimeoutExpired:return 124

def closure(repo):
    profile=json.loads((repo/'fpga/quartus/build_profiles.json').read_text());sources=[]
    for g in profile['profiles']['OPEN_SIM_VERILOG']['groups']:
        for pat in profile['source_groups'][g]:sources+=sorted(repo.glob(pat))
    sources=list(dict.fromkeys(sources))
    extra=list(repo.glob('rtl/core/vh/**/*.vh'))+list(repo.glob('verification/independent/p12a3_soc_vga/**/*'))
    extra+=[repo/'scripts/wsl/p12a3_soc_vga_test.sh',repo/'scripts/wsl/source_list.py',repo/'firmware/bsp/linker.ld',repo/'fpga/quartus/build_profiles.json']
    extra+=list(repo.glob('spec/*.md'))+list(repo.glob('docs/governance/*.md'))
    return sources,{str(p.relative_to(repo)):sha(p) for p in sources+extra if p.is_file()}
NEW_ADAPTERS={
 'DMEM_WE':('normal','FAIL_G1C_DMEM_PHYSICAL'),
 'DMEM_ADDR':('fault','FAIL_G1C_DMEM_PHYSICAL'),
 'DMEM_MASK':('normal','FAIL_G1C_DMEM_PHYSICAL'),
 'DMEM_DATA':('fault','FAIL_G1C_DMEM_PHYSICAL'),
 'DMEM_POST':('normal','FAIL_G1C_DMEM_POST'),
 'DMEM_FAULT_POST':('fault','FAIL_G1C_DMEM_POST'),
 'ERR_WAIT_DROP':('fault','FAIL_G1C_ERROR_SEQUENCE'),
 'ERR_FINAL_DROP':('fault','FAIL_G1C_ERROR_SEQUENCE'),
 'ERR_ORDER':('fault','FAIL_G1C_ERROR_SEQUENCE'),
 'ERR_RESPONSE':('fault','FAIL_G1C_ERROR_RESPONSE'),
 'ERR_HOLD':('fault','FAIL_G1C_CPU_HOLD'),
 'ERR_HOLD_PC':('fault','FAIL_G1C_CPU_HOLD'),
 'ERR_RELEASE':('fault','FAIL_G1C_CPU_RELEASE'),
 'ERR_TOKEN':('fault','FAIL_G1C_CPU_RELEASE'),
}
TARGETED=dict(NEW_ADAPTERS,NOOP=ADAPTERS['NOOP'])
OWNER_G1=dict(ADAPTERS,**NEW_ADAPTERS)
class GuardFailure(Exception):
    def __init__(self,pid,detail): super().__init__(pid+' '+str(detail));self.pid=pid

def need(condition,pid,detail):
    if not condition: raise GuardFailure(pid,detail)

def selected(mode):
    need(mode in ('targeted','owner_g1'),'G1C_GUARD_CASE_SET',mode)
    return TARGETED if mode=='targeted' else OWNER_G1

def safe_artifact(root,m,name):
    need(isinstance(name,str) and Path(name).name==name,'G1C_GUARD_ARTIFACT','nonlocal artifact '+str(name))
    p=root/name
    need(name in m['artifacts'] and p.is_file() and not p.is_symlink(),'G1C_GUARD_ARTIFACT',name)
    need(sha(p)==m['artifacts'][name],'G1C_GUARD_ARTIFACT',name+' checksum')
    return p

def read_elf(path):
    """Independent ELF32 section/symbol parsing, without producer nm/hex truth."""
    b=path.read_bytes();need(len(b)>=52 and b[:7]==b'\x7fELF\x01\x01\x01','G1C_GUARD_ELF','ELF32 little-endian')
    h=struct.unpack_from('<HHIIIIIHHHHHH',b,16)
    need(h[1]==243 and h[3]==0 and h[10]==40 and h[11]>0,'G1C_GUARD_ELF','RISC-V entry/sections')
    sections=[]
    for i in range(h[11]):
        off=h[5]+i*h[10];need(off+40<=len(b),'G1C_GUARD_ELF','section boundary')
        sections.append(struct.unpack_from('<IIIIIIIIII',b,off))
    need(h[12]<len(sections),'G1C_GUARD_ELF','names index')
    def payload(q):
        need(q[4]+q[5]<=len(b),'G1C_GUARD_ELF','payload boundary')
        return b[q[4]:q[4]+q[5]]
    names=payload(sections[h[12]])
    def name(table,off):
        need(off<len(table),'G1C_GUARD_ELF','string boundary')
        return table[off:].split(b'\0',1)[0].decode('ascii')
    by_name={name(names,q[0]):q for q in sections}
    need('.imem' in by_name and '.symtab' in by_name,'G1C_GUARD_ELF','required sections')
    imem=by_name['.imem'];need(imem[3]==0 and 0<imem[5]<=16384 and imem[5]%4==0,'G1C_GUARD_ELF','imem size/address')
    q=by_name['.symtab'];need(q[9]==16 and q[6]<len(sections),'G1C_GUARD_ELF','symtab layout')
    strings=payload(sections[q[6]]);symbols={}
    symdata=payload(q)
    for off in range(0,len(symdata),16):
        n,value,size,info,other,index=struct.unpack_from('<IIIBBH',symdata,off)
        if n and index: symbols[name(strings,n)]=value
    for key in ('_start','fault_store','younger_sentinel','trap_entry','normal_terminal','trap_terminal'):
        need(key in symbols and symbols[key]%4==0 and symbols[key]<imem[5],'G1C_GUARD_ELF',key)
    need(symbols['_start']==0,'G1C_GUARD_ELF','entry symbol')
    return payload(imem),symbols

def sext(v,bits):return (v & ((1<<(bits-1))-1))-(v & (1<<(bits-1)))

def program_oracle(binary,symbols,lane):
    """Tiny RV32I source-image interpreter. STATUS is contract-ready/idle;
    ERROR cause/PC are frozen CPU rules. No actual DUT/raw value supplies truth.
    """
    regs=[0]*32;csr={0x305:0,0x342:0,0x341:0};pc=0;events=[]
    for _ in range(300):
        need(pc%4==0 and 0<=pc<len(binary),'G1C_GUARD_PROGRAM','PC boundary')
        w=int.from_bytes(binary[pc:pc+4],'little');op=w&127;rd=(w>>7)&31;f=(w>>12)&7;r1=(w>>15)&31;r2=(w>>20)&31;npc=pc+4
        if op==0x37:regs[rd]=w&0xfffff000
        elif op==0x17:regs[rd]=(pc+(w&0xfffff000))&0xffffffff
        elif op==0x13 and f in (0,7):
            imm=sext(w>>20,12);regs[rd]=((regs[r1]+imm) if f==0 else (regs[r1]&imm))&0xffffffff
        elif op==0x03 and f==2:
            a=(regs[r1]+sext(w>>20,12))&0xffffffff
            need(a==0x20010000,'G1C_GUARD_PROGRAM','only STATUS loads in G1')
            events.append({'addr':a,'write':0,'size':2,'pc':pc});regs[rd]=0x10
        elif op==0x23 and f==2:
            imm=sext(((w>>25)<<5)|((w>>7)&31),12);a=(regs[r1]+imm)&0xffffffff
            events.append({'addr':a,'write':1,'size':2,'data':regs[r2],'pc':pc})
            if a==0x20009600:
                need(lane=='fault' and pc==symbols['fault_store'],'G1C_GUARD_PROGRAM','fault owner')
                csr[0x342]=7;csr[0x341]=pc;npc=csr[0x305]
        elif op==0x63 and f==0:
            imm=((w>>31)<<12)|(((w>>7)&1)<<11)|(((w>>25)&63)<<5)|(((w>>8)&15)<<1)
            if regs[r1]==regs[r2]:npc=pc+sext(imm,13)
        elif op==0x6f:
            imm=((w>>31)<<20)|(((w>>12)&255)<<12)|(((w>>20)&1)<<11)|(((w>>21)&1023)<<1)
            regs[rd]=(pc+4)&0xffffffff;npc=pc+sext(imm,21)
            if npc==pc:
                need(pc==symbols['trap_terminal' if lane=='fault' else 'normal_terminal'],'G1C_GUARD_PROGRAM','terminal')
                return events
        elif op==0x73 and f in (1,2):
            a=w>>20;need(a in csr,'G1C_GUARD_PROGRAM','CSR address')
            old=csr[a]
            if f==1:csr[a]=regs[r1]
            elif r1:csr[a]=old|regs[r1]
            regs[rd]=old
        else: raise GuardFailure('G1C_GUARD_PROGRAM',f'unsupported opcode {w:08x} at {pc:x}')
        regs[0]=0;pc=npc
    raise GuardFailure('G1C_GUARD_PROGRAM','source program did not terminate')

def source_recipe(repo,lane,symbols):
    # Expected constants are read from the unchanged test-only assembly, not
    # inferred from ELF/DUT/producer-printed expected fields.
    text=(repo/'verification/independent/p12a3_soc_vga/firmware/p12a3_soc_vga_e2e.S').read_text()
    def literal(pattern,part=text):
        values=re.findall(pattern,part);need(len(values)==1,'G1C_GUARD_PROGRAM_CONTRACT',pattern);return int(values[0],16)
    status=literal(r'lui s0, (0x[0-9a-f]+)')<<12
    dmem=literal(r'lui s1, (0x[0-9a-f]+)')<<12
    def read(a):return {'addr':a,'write':0,'size':2}
    def write(a,d):return {'addr':a,'write':1,'size':2,'data':d}
    if lane=='normal':
        part=text.split('normal_path:\n',1)[1].split('normal_terminal:',1)[0]
        values=[int(v,16) for v in re.findall(r'li t4, (0x[0-9a-f]+)',part)];need(len(values)==2,'G1C_GUARD_PROGRAM_CONTRACT','FB constants')
        first=literal(r'lui t3, (0x[0-9a-f]+)',part)<<12;last=literal(r'li t3, (0x[0-9a-f]+)',part);done=literal(r'li t0, (0x[0-9a-f]+)',part)
        return [read(status),write(first,values[0]),write(last,values[1]),write(status+4,0),read(status),write(dmem,done)]
    part=text.split('fault_path:\n',1)[1].split('fault_store:',1)[0]
    gap=literal(r'li t3, (0x[0-9a-f]+)',part);data=literal(r'li t4, (0x[0-9a-f]+)',part)
    done=literal(r'li t2, (0x[0-9a-f]+)')
    return [read(status),write(gap,data),write(dmem+4,7),write(dmem+8,symbols['fault_store']),write(dmem,done)]

def fields(line):return dict(re.findall(r'(\w+)=([^\s]+)',line))
def num(d,k,base=10):
    need(k in d,'G1C_GUARD_RAW','missing '+k)
    try:return int(d[k],base)
    except ValueError:raise GuardFailure('G1C_GUARD_RAW','non-numeric '+k+'='+d[k])

def csr_evidence(raw,lane,symbols,finals,paired,retired):
    """Reconcile actual architectural observations; printed expected_pc is not truth.

    The unchanged observer emits one CSR_POST per HCLK, after the fault
    signature post and until the eighth terminal retirement. CSR records lack
    timestamps, so infer their ordinal edges and check every dated anchor.
    This detects missing/extra records and redistribution across dated anchors;
    identical compensating edits inside an undated interval are unobservable.
    """
    pid='G1C2_GUARD_CSR'
    records=[fields(x) for x in raw.splitlines() if x.startswith('G1_CSR_POST')]
    if lane=='normal':
        need(not records,pid,'normal unexpected architectural CSR record');return
    def diagnostic(addr,value):
        ids=[i for i,d in finals.items() if num(d,'addr',16)==addr]
        need(len(ids)==1 and ids[0] in paired['G1_DMEM_POST'],pid,'missing physical diagnostic')
        i=ids[0];post=paired['G1_DMEM_POST'][i]
        need(num(finals[i],'data',16)==value and num(post,'actual',16)==value,pid,'physical diagnostic contradiction')
        return num(post,'edge')
    cause_edge=diagnostic(0x10000004,7)
    pc_edge=diagnostic(0x10000008,symbols['fault_store'])
    done=[i for i,d in finals.items() if num(d,'addr',16)==0x10000000]
    need(len(done)==1 and done[0] in paired['G1_DMEM_POST'],pid,'fault signature anchor')
    start=num(paired['G1_DMEM_POST'][done[0]],'edge')
    terminals=[num(d,'edge') for d in retired if num(d,'pc',16)==symbols['trap_terminal']]
    need(len(terminals)==8 and cause_edge<pc_edge<start,pid,'diagnostic/terminal ordering')
    end=max(start,terminals[7])
    # Source CSR reads must actually retire before their diagnostic stores.
    for csr,edge in ((0x342,cause_edge),(0x341,pc_edge)):
        hits=[d for d in retired if num(d,'instruction',16)&0x707f==0x2073 and num(d,'instruction',16)>>20==csr]
        need(len(hits)==1 and num(hits[0],'edge')<edge,pid,'source CSR-read retirement')
    need(len(records)==end-start+1,pid,f'CSR window {start}..{end}, records={len(records)}')
    seen=0;signature_post_seen=False
    for line in raw.splitlines():
        kind=line.split(' ',1)[0];d=fields(line)
        if kind=='G1_CSR_POST':
            need(signature_post_seen,pid,'CSR precedes physical signature post')
            need(set(d)=={'cause','mepc','expected_pc'} and all(re.fullmatch(r'[0-9a-fA-F]{8}',d[k]) for k in d),pid,'malformed CSR record')
            need(int(d['cause'],16)==7 and int(d['mepc'],16)==symbols['fault_store'] and int(d['expected_pc'],16)==symbols['fault_store'],pid,'CSR cause/PC versus frozen fault and independently bound ELF')
            seen+=1
        elif kind.startswith('G1_') and 'edge' in d:
            edge=num(d,'edge')
            need(edge<=end,pid,'dated event beyond observer completion')
            if edge>=start:need(seen==edge-start,pid,'CSR ordinal contradicts dated anchor '+kind+' edge='+str(edge))
            else:need(seen==0,pid,'CSR before observation window')
            if kind=='G1_DMEM_POST' and num(d,'id')==done[0]:signature_post_seen=True
        elif kind=='G1_SUMMARY':need(seen==end-start+1,pid,'incomplete CSR window at summary')
    need(seen==len(records),pid,'malformed CSR record kind')

def image_provenance(root,m,lane):
    image=m['images'][lane];origin=Path(m['run_root']);repo=Path(m['repo'])
    for key in ('elf','hex','binary','sim','disassembly','symbols'):
        need(key in image,'G1C_GUARD_IMAGE_IDENTITY',lane+' '+key)
        safe_artifact(root,m,image[key])
    binary,symbols=read_elf(root/image['elf'])
    need(binary==(root/image['binary']).read_bytes(),'G1C_GUARD_ELF_BINARY',lane)
    try:words=[int(x,16) for x in (root/image['hex']).read_text().splitlines()]
    except ValueError:raise GuardFailure('G1C_GUARD_HEX',lane)
    expect=[int.from_bytes(binary[i:i+4],'little') for i in range(0,len(binary),4)]
    need(words==expect and len(words)==image['words'],'G1C_GUARD_HEX',lane)
    nm={s:int(a,16) for a,t,s in re.findall(r'^([0-9a-f]+)\s+(\w)\s+(\w+)$',(root/image['symbols']).read_text(),re.M)}
    need(nm==image['pc'] and all(symbols.get(k)==v for k,v in nm.items()),'G1C_GUARD_SYMBOLS',lane)
    ops={int(a,16):int(w,16) for a,w in re.findall(r'^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s', (root/image['disassembly']).read_text(),re.M)}
    need(ops=={i:expect[i//4] for i in range(0,len(binary),4)},'G1C_GUARD_DISASSEMBLY',lane)
    sim=(root/image['sim']).read_text()
    blocks=re.split(r'(?=^S_\S+ \.scope )',sim,flags=re.M)
    top=[b for b in blocks if '.scope module, "tb_p12a3_soc_vga" "tb_p12a3_soc_vga"' in b]
    imem=[b for b in blocks if '.scope module, "u_IMEM" "IMEM"' in b]
    need(len(top)==len(imem)==1,'G1C_GUARD_IMAGE_BINDING','unique top/u_IMEM')
    def strparam(block,key):
        hits=re.findall(r'\.param/str "'+re.escape(key)+r'"[^\n]*, "([^"\n]*)";',block)
        need(len(hits)==1,'G1C_GUARD_IMAGE_BINDING',key);return hits[0]
    image_path=str(origin/image['hex'])
    need(strparam(top[0],'IMEM_FILE')==image_path and strparam(imem[0],'INIT_FILE')==image_path,'G1C_GUARD_IMAGE_BINDING',lane+' actual elaborated top/IMEM parameter')
    expected_params={'FAULT_CASE':int(lane=='fault'),'FAULT_PC':symbols['fault_store'],'YOUNGER_PC':symbols['younger_sentinel'],'TRAP_PC':symbols['trap_entry'],'TERMINAL_PC':symbols['trap_terminal' if lane=='fault' else 'normal_terminal'],'START_INSTRUCTION':expect[0]}
    for key,value in expected_params.items():
        hits=re.findall(r'\.param/l "'+key+r'"[^\n]*C4<([01]+)>;',top[0]);need(len(hits)==1 and int(hits[0],2)==value,'G1C_GUARD_IMAGE_PARAMETERS',key)
    def argv(log):
        name=log+'.log.command.json';safe_artifact(root,m,name);return json.loads((root/name).read_text())['argv']
    compile_args=argv(lane+'.compile')
    need(compile_args[0]=='iverilog' and '-g2012' in compile_args and compile_args[compile_args.index('-s')+1]=='tb_p12a3_soc_vga' and compile_args[compile_args.index('-o')+1]==str(origin/image['sim']),'G1C_GUARD_COMPILE_ARGV',lane)
    need(f'-Ptb_p12a3_soc_vga.IMEM_FILE="{image_path}"' in compile_args,'G1C_GUARD_COMPILE_ARGV','static image parameter')
    for key,value in expected_params.items():need(f'-Ptb_p12a3_soc_vga.{key}={value}' in compile_args,'G1C_GUARD_COMPILE_ARGV',key)
    sources,_=closure(repo);tb=sorted((repo/'verification/independent/p12a3_soc_vga/tb').glob('*.sv'))
    need([a for a in compile_args if a.endswith(('.v','.sv'))]==[str(x) for x in sources+tb],'G1C_GUARD_COMPILE_ARGV','source closure/order')
    gcc=argv(lane+'.gcc');asm=str(repo/'verification/independent/p12a3_soc_vga/firmware/p12a3_soc_vga_e2e.S')
    need(gcc==['riscv32-unknown-elf-gcc','-march=rv32i_zicsr','-mabi=ilp32','-nostdlib','-nostartfiles','-Wl,--no-relax','-T',str(repo/'firmware/bsp/linker.ld'),f'-DFAULT_CASE={int(lane=="fault")}',asm,'-o',str(origin/image['elf'])],'G1C_GUARD_BUILD_ARGV',lane)
    need(argv(lane+'.objcopy')==['riscv32-unknown-elf-objcopy','--dump-section',f'.imem={origin/image["binary"]}',str(origin/image['elf'])],'G1C_GUARD_BUILD_ARGV','objcopy')
    for key,tool,args in [('disassembly','riscv32-unknown-elf-objdump',['-d']),('symbols','riscv32-unknown-elf-nm',['-n'])]:
        cmd=safe_artifact(root,m,image[key]+'.command.json');actual=json.loads(cmd.read_text())['argv']
        need(actual==[tool,*args,str(origin/image['elf'])],'G1C_GUARD_BUILD_ARGV',key)
    includes=sorted(set(q.parent for q in list(repo.glob('rtl/core/v/**/*.v'))+list(repo.glob('rtl/core/vh/**/*.vh'))))
    exact=['iverilog','-g2012','-s','tb_p12a3_soc_vga','-o',str(origin/image['sim']),f'-Ptb_p12a3_soc_vga.IMEM_FILE="{image_path}"']
    for key in ('FAULT_CASE','FAULT_PC','YOUNGER_PC','TERMINAL_PC'):exact.append(f'-Ptb_p12a3_soc_vga.{key}={expected_params[key]}')
    for directory in includes:exact+=['-I',str(directory)]
    for key in ('TRAP_PC','START_INSTRUCTION'):exact.append(f'-Ptb_p12a3_soc_vga.{key}={expected_params[key]}')
    exact += [str(q) for q in sources+tb]
    need(compile_args==exact,'G1C_GUARD_COMPILE_ARGV','all flags/includes/source inputs')
    oracle=program_oracle(binary,symbols,lane)
    need([{k:v for k,v in event.items() if k!='pc'} for event in oracle]==source_recipe(repo,lane,symbols),'G1C_GUARD_PROGRAM_CONTRACT',lane+' ELF semantics versus original assembly constants/fault rules')
    return binary,symbols,oracle

def semantic_lane(root,m,lane,binary,symbols,oracle):
    case=m['cases'][lane];raw=(root/case['raw']).read_text();origin=Path(m['run_root'])
    need(case['exit']==0 and 'G1_SUMMARY PASS' in raw and 'G1_FAILURE' not in raw,'G1C_GUARD_CASE_VERDICT',lane)
    image=m['images'][lane]
    need(f'G1_IMAGE static={origin/image["hex"]} fault={int(lane=="fault")} pc={symbols["fault_store"]:08x}' in raw,'G1C_GUARD_RAW_IMAGE',lane)
    need(f'IMEM: loaded {len(binary)//4} words from {origin/image["hex"]}' in raw,'G1C_GUARD_RAW_IMAGE','loader')
    events=[];by_kind={};previous_edge=0
    for line in raw.splitlines():
        kind=line.split(' ',1)[0]
        if kind not in ('G1_ADDR','G1_FINAL','G1_COMMIT_POST','G1_DMEM_PRE','G1_DMEM_POST','G1_NOOP_POST','G1_GAP_PHASE','G1_GAP_POST','G1_GAP_WAIT','G1_RETIRE'):continue
        d=fields(line);edge=num(d,'edge');t=num(d,'time')
        need(edge>=previous_edge,'G1C_GUARD_STALE_EVENT',kind+' nonmonotonic edge');previous_edge=edge
        post=kind in ('G1_COMMIT_POST','G1_DMEM_POST','G1_NOOP_POST','G1_GAP_POST')
        need(t==edge*20000-10000+int(post),'G1C_GUARD_EDGE_TIME',kind)
        events.append((kind,d));by_kind.setdefault(kind,[]).append(d)
    addresses={};finals={}
    for kind,d in events:
        if kind=='G1_ADDR':
            i=num(d,'id');need(i not in addresses and i==len(addresses)+1,'G1C_GUARD_TX_ID','duplicate/stale address ID')
            need(num(d,'ready')==1 and num(d,'resp')==0,'G1C_GUARD_TX_PHASE','address acceptance');addresses[i]=d
        elif kind=='G1_FINAL':
            i=num(d,'id');need(i in addresses and i not in finals,'G1C_GUARD_TX_ID','orphan/duplicate final ID')
            a=addresses[i]
            need(all(d.get(k)==a.get(k) for k in ('addr','write','size')),'G1C_GUARD_TX_OWNER',i)
            need(num(d,'edge')>num(a,'edge') and num(d,'ready')==1,'G1C_GUARD_TX_PHASE',i);finals[i]=d
    need(set(finals)==set(addresses),'G1C_GUARD_TX_ID','unfinished address IDs')
    ordered=[finals[i] for i in sorted(finals)]
    status=[d for d in ordered if num(d,'addr',16)==0x20010000]
    ready_reads=0
    for d in status:
        need(num(d,'write')==0 and num(d,'size')==2 and num(d,'resp')==0,'G1C2_GUARD_STATUS_REACH','accepted STATUS read identity')
        value=num(d,'rdata',16);need(value&0xffffffee==0,'G1C_GUARD_STATUS',num(d,'id'))
        if value&16:ready_reads+=1
        else:need(ready_reads==0,'G1C2_GUARD_STATUS_REACH','not-ready read after source poll completed in unchanged epoch')
    need(ready_reads>=(2 if lane=='normal' else 1),'G1C2_GUARD_STATUS_REACH',lane+' required source ready-read roles')
    # Extra leading STATUS polls that are not ready are legal source-loop iterations.
    while ordered and num(ordered[0],'addr',16)==0x20010000 and not(num(ordered[0],'rdata',16)&16):
        need(num(ordered[0],'write')==0 and num(ordered[0],'size')==2 and num(ordered[0],'resp')==0,'G1C2_GUARD_STATUS_REACH','initial poll identity')
        ordered=ordered[1:]
    need(len(ordered)==len(oracle),'G1C_GUARD_TX_PROGRAM','source event count')
    for d,e in zip(ordered,oracle):
        need(num(d,'addr',16)==e['addr'] and num(d,'write')==e['write'] and num(d,'size')==e['size'],'G1C_GUARD_TX_PROGRAM',num(d,'id'))
        if e['write'] and e['addr']!=0x20009600:need(num(d,'data',16)==e['data'],'G1C_GUARD_TX_DATA',num(d,'id'))
    paired={'G1_COMMIT_POST':{},'G1_DMEM_PRE':{},'G1_DMEM_POST':{},'G1_NOOP_POST':{}}
    for kind in paired:
        for d in by_kind.get(kind,[]):
            i=num(d,'id');need(i in finals and i not in paired[kind],'G1C_GUARD_TX_ID',kind+' duplicate/orphan');paired[kind][i]=d
            need(num(d,'edge')==num(finals[i],'edge'),'G1C_GUARD_TX_PHASE',kind+' edge')
    expected_fb=set();expected_dm=set();expected_noop=set()
    for i,d in finals.items():
        a=num(d,'addr',16);w=num(d,'write');resp=num(d,'resp');route=2 if 0x20000000<=a<0x20020000 else 1
        need(num(d,'route')==route and resp==int(a==0x20009600),'G1C_GUARD_TX_ROUTE',i)
        if w and 0x20000000<=a<0x20009600:
            expected_fb.add(i);need(d['we']=='10' and num(d,'wa')==(a-0x20000000)//4 and num(d,'wd',16)==num(d,'data',16),'G1C_GUARD_TX_COMMIT',i)
            need(i in paired['G1_COMMIT_POST'],'G1C_GUARD_TX_COMMIT','missing post '+str(i));post=paired['G1_COMMIT_POST'][i]
            need(num(post,'bank')==1 and num(post,'addr')==(a-0x20000000)//4 and num(post,'actual',16)==num(d,'data',16),'G1C_GUARD_TX_COMMIT',i)
        else:need(d['we']=='00','G1C_GUARD_TX_COMMIT','non-FB side effect')
        if w and 0x10000000<=a<0x10008000:
            expected_dm.add(i);need(i in paired['G1_DMEM_PRE'] and i in paired['G1_DMEM_POST'],'G1C_GUARD_DMEM','missing physical ID '+str(i))
            pre=paired['G1_DMEM_PRE'][i];post=paired['G1_DMEM_POST'][i];word=(a-0x10000000)//4
            need(num(pre,'addr',16)==a and num(pre,'we')==1 and num(pre,'wa')==word and num(pre,'mask')==15 and num(pre,'data',16)==num(d,'data',16) and num(pre,'ready')==1 and num(pre,'resp')==0,'G1C_GUARD_DMEM',i)
            need(num(post,'wa')==word and num(post,'actual',16)==num(d,'data',16),'G1C_GUARD_DMEM',i)
        if a==0x20010000:
            value=num(d,'rdata',16);need(value&0xffffffee==0,'G1C_GUARD_STATUS',i)
        if a==0x20010004:
            expected_noop.add(i);need(i in paired['G1_NOOP_POST'],'G1C_GUARD_NOOP','missing origin ID');post=paired['G1_NOOP_POST'][i]
            need(w==1 and num(d,'data',16)==0 and all(num(post,k)==0 for k in ('request','busy','clear','front')),'G1C_GUARD_NOOP',i)
    need(set(paired['G1_COMMIT_POST'])==expected_fb and set(paired['G1_DMEM_PRE'])==set(paired['G1_DMEM_POST'])==expected_dm and set(paired['G1_NOOP_POST'])==expected_noop,'G1C_GUARD_TX_ID','orphan side-effect record')
    phases=by_kind.get('G1_GAP_PHASE',[]);posts=by_kind.get('G1_GAP_POST',[]);waits=by_kind.get('G1_GAP_WAIT',[])
    if lane=='fault':
        gap=[i for i,d in finals.items() if num(d,'addr',16)==0x20009600];need(len(gap)==1 and len(phases)==len(posts)==2 and len(waits)==1,'G1C_GUARD_ERROR_SEQUENCE','phase count')
        wait,final=phases;need(wait['stage']=='WAIT' and final['stage']=='FINAL' and num(final,'edge')==num(wait,'edge')+1,'G1C_GUARD_ERROR_SEQUENCE','order/adjacent edges')
        for d in phases:need(num(d,'id')==gap[0] and num(d,'resp')==1 and num(d,'owner_pc',16)==symbols['fault_store'] and num(d,'owner_valid')==1 and d['vwe']=='00' and num(d,'dwe')==0,'G1C_GUARD_ERROR_OWNER',gap[0])
        need(num(wait,'ready')==0 and all(num(wait,k)==1 for k in ('bus_stall','cpu_hold','if_hold','id_hold','ex_hold','wb_hold')) and num(wait,'fault_final')==0,'G1C_GUARD_CPU_HOLD','wait')
        need(num(final,'ready')==1 and all(num(final,k)==0 for k in ('bus_stall','cpu_hold','ex_hold','wb_hold')) and num(final,'fault_final')==1,'G1C_GUARD_CPU_RELEASE','final')
        need(num(final,'edge')==num(finals[gap[0]],'edge') and num(wait,'edge')==num(waits[0],'edge') and num(waits[0],'id')==gap[0] and num(waits[0],'ready')==0 and num(waits[0],'resp')==1,'G1C_GUARD_ERROR_SEQUENCE','wait/final ownership')
        for phase,post in zip(phases,posts):need(post['stage']==phase['stage'] and num(post,'id')==gap[0] and num(post,'edge')==num(phase,'edge'),'G1C_GUARD_ERROR_SEQUENCE','post attribution')
        need(num(posts[0],'owner_pc',16)==symbols['fault_store'] and num(posts[0],'owner_valid')==1,'G1C_GUARD_CPU_HOLD','post hold')
        need(num(posts[1],'wb_pc',16)==symbols['fault_store'] and all(num(posts[1],k)==1 for k in ('active','wb_valid','wb_exc')),'G1C_GUARD_CPU_RELEASE','post token')
    else:need(not phases and not posts and not waits,'G1C_GUARD_ERROR_SEQUENCE','normal unexpected gap')
    retired=by_kind.get('G1_RETIRE',[])
    for d in retired:
        pc=num(d,'pc',16);need(pc%4==0 and 0<=pc<len(binary) and num(d,'instruction',16)==int.from_bytes(binary[pc:pc+4],'little'),'G1C_GUARD_RETIRED_IMAGE',pc)
        if lane=='fault':need(not(symbols['fault_store']<=pc<symbols['trap_entry']),'G1C_GUARD_RETIRE',pc)
    csr_evidence(raw,lane,symbols,finals,paired,retired)
    summaries=[x for x in raw.splitlines() if x.startswith('G1_SUMMARY PASS ')];need(len(summaries)==1,'G1C_GUARD_REACH','one final summary')
    reach={k:int(v) for k,v in fields(summaries[0]).items()};need(reach==case['reach'],'G1C_GUARD_REACH','raw/manifest')
    actual_counts={'boot':sum(num(d,'pc',16)==0 for d in retired),'release':raw.count('G1_RESET_RELEASE '),'status':sum(num(d,'addr',16)==0x20010000 and bool(num(d,'rdata',16)&16) for d in finals.values()),'writes':len(expected_fb),'noop':len(expected_noop),'gap_wait':len(waits),'gap_final':len([d for d in finals.values() if num(d,'addr',16)==0x20009600]),'cause_diag':sum(num(d,'addr',16)==0x10000004 for d in finals.values()),'pc_diag':sum(num(d,'addr',16)==0x10000008 for d in finals.values()),'done':sum(num(d,'addr',16)==0x10000000 for d in finals.values()),'terminal':sum(num(d,'pc',16)==symbols['trap_terminal' if lane=='fault' else 'normal_terminal'] for d in retired),'finals':len(finals),'dmem_physical':len(paired['G1_DMEM_PRE']),'dmem_post':len(paired['G1_DMEM_POST'])}
    need(reach==actual_counts and reach['boot']>=1 and reach['terminal']>=8 and reach['release']==reach['done']==1,'G1C_GUARD_REACH','independent record counts')
    need('G1_RESET_RELEASE qualified=1000000 time=20000130000' in raw,'G1C_GUARD_RESET','qualified source clock/reset')
    return actual_counts

def guard(root):
    m=json.loads((root/'manifest.json').read_text());repo=Path(m['repo']);mode=m.get('run_set');adapters=selected(mode)
    need(m['base']==BASE and m['source_before']==m['source_after'],'G1C_GUARD_SOURCE','producer source closure')
    live=closure(repo)[1]
    if (root/'replay.json').exists():
        # An explicitly copied replay may validate old CPU evidence with a new
        # guard only. Never rewrite producer source identity or claim a new sim.
        # Ordinary simulations/Owner runs retain exact live-source equality.
        context=root/'replay.json'
        need(context.is_file() and not context.is_symlink(),'G1C_GUARD_SOURCE','live-source mismatch without replay lineage')
        c=json.loads(context.read_text());original=Path(m['run_root']);manifest=original/'manifest.json'
        guard_path=str(Path(__file__).resolve().relative_to(repo.resolve()))
        need(c.get('kind')=='GUARD_FIXTURE_REPLAY_NOT_NEW_SIMULATION' and c.get('original_run')==str(original) and root.resolve()!=original.resolve(),'G1C_GUARD_SOURCE','explicit original producer')
        need(manifest.is_file() and sha(manifest)==c.get('original_manifest_sha256'),'G1C_GUARD_SOURCE','immutable original manifest')
        old=json.loads(manifest.read_text())
        need(old['base']==m['base'] and old['repo']==m['repo'] and old['source_before']==old['source_after']==m['source_after'],'G1C_GUARD_SOURCE','producer lineage')
        need(set(live)==set(old['source_after']) and {k for k in live if live[k]!=old['source_after'][k]}<={guard_path},'G1C_GUARD_SOURCE','only validating guard may differ')
        need(c.get('validator_source')==live and c.get('validator_guard_sha256')==sha(Path(__file__))==live[guard_path],'G1C_GUARD_SOURCE','actual validator closure')
        for name in old['artifacts']:safe_artifact(original,old,name)
    else:need(live==m['source_after'],'G1C_GUARD_SOURCE','live-source mismatch without replay lineage')
    for name in m['artifacts']:safe_artifact(root,m,name)
    need(set(m['cases'])=={'normal','fault'}|set(adapters),'G1C_GUARD_CASE_SET',mode)
    for lane in ('normal','fault'):
        binary,symbols,oracle=image_provenance(root,m,lane)
        safe_artifact(root,m,m['cases'][lane]['raw']);semantic_lane(root,m,lane,binary,symbols,oracle)
    for name,(lane,pid) in [('normal',('normal','')),('fault',('fault',''))]+list(adapters.items()):
        c=m['cases'][name];safe_artifact(root,m,c['raw']);cmd=safe_artifact(root,m,name+'.raw.log.command.json');a=json.loads(cmd.read_text())['argv']
        need(c['image']==m['images'][lane]['sim'] and a==['vvp',str(Path(m['run_root'])/c['image']),'+OBS_FAULT='+('NONE' if not pid else name)],'G1C_GUARD_RUN_ARGV',name)
        if pid:
            raw=(root/c['raw']).read_text();need(c['exit']==1 and c['pid']==pid and f'G1_ADAPTER {name} ' in raw and f'G1_FAILURE {pid} ' in raw and 'G1_SUMMARY PASS' not in raw,'G1C_GUARD_ADAPTER',name)
    return 0

def run(repo,root):
    root.mkdir(exist_ok=False,parents=True)
    sources,identity=closure(repo)
    mode=os.environ.get('RUN_SET','targeted');adapters=selected(mode)
    m={'schema':'P12A3-G1C-v1','run_set':mode,'run_root':str(root),'repo':str(repo),'base':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),'source_before':identity,'images':{},'cases':{},'artifacts':{}}
    put(root/'manifest.json',m)
    if m['base']!=BASE:raise RuntimeError('SOURCE_IDENTITY_DRIFT')
    for tool in ('git','python3','iverilog','vvp','riscv32-unknown-elf-gcc','riscv32-unknown-elf-objcopy','riscv32-unknown-elf-objdump','riscv32-unknown-elf-nm'):
        command([tool,'-V' if tool in ('iverilog','vvp') else '--version'],root/(tool+'.version.log'))
    b=repo/'verification/independent/p12a3_soc_vga'
    for lane,flag in [('normal',0),('fault',1)]:
        image={k:f'{lane}.{ext}' for k,ext in [('elf','elf'),('hex','hex'),('binary','bin'),('disassembly','dis'),('symbols','nm'),('sim','vvp')]}
        def execute(args,log):
            code=command([str(a) for a in args],root/log)
            if code: raise RuntimeError(f'BUILD_INCOMPLETE {log} exit={code}')
        execute(['riscv32-unknown-elf-gcc','-march=rv32i_zicsr','-mabi=ilp32','-nostdlib','-nostartfiles','-Wl,--no-relax','-T',repo/'firmware/bsp/linker.ld',f'-DFAULT_CASE={flag}',b/'firmware/p12a3_soc_vga_e2e.S','-o',root/image['elf']],lane+'.gcc.log')
        execute(['riscv32-unknown-elf-objcopy','--dump-section',f".imem={root/image['binary']}",root/image['elf']],lane+'.objcopy.log')
        execute(['riscv32-unknown-elf-objdump','-d',root/image['elf']],image['disassembly'])
        execute(['riscv32-unknown-elf-nm','-n',root/image['elf']],image['symbols'])
        binary=(root/image['binary']).read_bytes();assert len(binary)%4==0
        (root/image['hex']).write_text(''.join(f'{int.from_bytes(binary[n:n+4],"little"):08x}\n' for n in range(0,len(binary),4)))
        pc={s:int(a,16) for a,t,s in re.findall(r'^([0-9a-f]+)\s+(\w)\s+(\w+)$',(root/image['symbols']).read_text(),re.M)}
        for symbol in ('_start','fault_store','younger_sentinel','normal_terminal','trap_terminal'):assert symbol in pc
        image.update(pc=pc,words=len(binary)//4)
        includes=sorted(set(p.parent for p in list(repo.glob('rtl/core/v/**/*.v'))+list(repo.glob('rtl/core/vh/**/*.vh'))))
        args=['iverilog','-g2012','-s','tb_p12a3_soc_vga','-o',root/image['sim'],f'-Ptb_p12a3_soc_vga.IMEM_FILE="{root/image["hex"]}"',f'-Ptb_p12a3_soc_vga.FAULT_CASE={flag}',f'-Ptb_p12a3_soc_vga.FAULT_PC={pc["fault_store"]}',f'-Ptb_p12a3_soc_vga.YOUNGER_PC={pc["younger_sentinel"]}',f'-Ptb_p12a3_soc_vga.TERMINAL_PC={pc["trap_terminal" if flag else "normal_terminal"]}']
        for d in includes:args+=['-I',d]
        args += [f'-Ptb_p12a3_soc_vga.TRAP_PC={pc["trap_entry"]}',f'-Ptb_p12a3_soc_vga.START_INSTRUCTION={int.from_bytes(binary[:4],"little")}']
        args+=sources+sorted((b/'tb').glob('*.sv'))
        execute(args,lane+'.compile.log');m['images'][lane]=image;put(root/'manifest.json',m)
    cases=[('normal','normal','NONE',''),('fault','fault','NONE','')]+[(a,l,a,p) for a,(l,p) in adapters.items()]
    for name,lane,adapter,pid in cases:
        print('RUN',name,flush=True)
        raw=name+'.raw.log';code=command(['vvp',str(root/m['images'][lane]['sim']),f'+OBS_FAULT={adapter}'],root/raw,1200)
        text=(root/raw).read_text();c={'raw':raw,'exit':code,'image':m['images'][lane]['sim'],'pid':pid}
        if not pid:
            c['reach']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',text.split('G1_SUMMARY PASS')[-1])} if 'G1_SUMMARY PASS' in text else {}
        m['cases'][name]=c;put(root/'manifest.json',m)
        okay=(code==0 and 'G1_SUMMARY PASS' in text) if not pid else (code==1 and f'G1_FAILURE {pid} ' in text and f'G1_ADAPTER {adapter} ' in text)
        if not okay:raise RuntimeError(f'REQUIRED_GATE_UNAVAILABLE {name} exit={code}; STOP')
    m['source_after']=closure(repo)[1]
    m['artifacts']={str(p.relative_to(root)):sha(p) for p in root.iterdir() if p.is_file() and p.name!='manifest.json'}
    put(root/'manifest.json',m);guard(root);put(root/'guard.json',{'exit':0,'verdict':'PASS'})
    put(root/'result.json',{'run_set':mode,'target_verdict':'TARGETED_PASS' if mode=='targeted' else 'OWNER_G1_EXECUTION_PASS','guard_exit':0,'final_exit':0,'acceptance':'PENDING','owner_regression':'NOT_RUN_OWNER_PENDING' if mode=='targeted' else 'OWNER_G1_EXECUTED_REVIEW_PENDING'})
    print('LEAF PASS',flush=True)
    return 0

FIXTURE_PIDS={
 'raw':'G1C_GUARD_ARTIFACT','reach':'G1C_GUARD_REACH','image':'G1C_GUARD_IMAGE_IDENTITY',
 'source':'G1C_GUARD_SOURCE','records':'G1C_GUARD_CASE_VERDICT','lane':'G1C_GUARD_CASE_SET',
 'semantic_final':'G1C_GUARD_TX_DATA','image_binding':'G1C_GUARD_IMAGE_BINDING',
 'duplicate_final':'G1C_GUARD_TX_ID','orphan_commit':'G1C_GUARD_TX_ID',
 'mixed_commit':'G1C_GUARD_TX_COMMIT','stale_edge':'G1C_GUARD_STALE_EVENT',
 'elf_binary':'G1C_GUARD_ELF_BINARY','hex_image':'G1C_GUARD_HEX',
 'disasm_opcode':'G1C_GUARD_DISASSEMBLY','symbols_pc':'G1C_GUARD_SYMBOLS',
 'compile_argv':'G1C_GUARD_COMPILE_ARGV','run_argv':'G1C_GUARD_RUN_ARGV',
 'missing_wait':'G1C_GUARD_ERROR_SEQUENCE','dmem_mask':'G1C_GUARD_DMEM',
 'dmem_post':'G1C_GUARD_DMEM',
 'csr_altered':'G1C2_GUARD_CSR','csr_missing':'G1C2_GUARD_CSR',
 'csr_duplicate':'G1C2_GUARD_CSR','csr_balanced_shift':'G1C2_GUARD_CSR',
 'status_ready':'G1C2_GUARD_STATUS_REACH','status_fault_ready':'G1C2_GUARD_STATUS_REACH',
 'status_poll_only':'G1C2_GUARD_STATUS_REACH',
}
def replay(source,root,mutation):
    """Isolated copied evidence self-test. Never a new CPU simulation."""
    shutil.copytree(source,root)
    for name in ('guard.json','result.json'):
        if (root/name).exists():(root/name).rename(root/('original.'+name))
    m=json.loads((root/'manifest.json').read_text());target_exit=0
    put(root/'replay.json',{'original_run':str(source),'kind':'GUARD_FIXTURE_REPLAY_NOT_NEW_SIMULATION','mutation':mutation,'original_manifest_sha256':sha(source/'manifest.json'),'validator_source':closure(Path(m['repo']))[1],'validator_guard_sha256':sha(Path(__file__))})
    def alter(name,transform):
        p=root/name;old=p.read_text();new=transform(old);need(new!=old,'G1C_FIXTURE_NOT_ACTIVATED',mutation);p.write_text(new);m['artifacts'][name]=sha(p)
    if mutation=='raw':(root/m['cases']['normal']['raw']).rename(root/'normal.raw.preserved')
    elif mutation=='reach':del m['cases']['normal']['reach']['boot']
    elif mutation=='image':del m['images']['normal']['hex']
    elif mutation=='source':m['source_after'][next(iter(m['source_after']))]='0'*64
    elif mutation=='records':m['cases']['normal']['exit']=1
    elif mutation=='lane':del m['cases']['fault']
    elif mutation=='target':target_exit=m['cases']['NOOP']['exit']
    elif mutation=='semantic_final':alter('normal.raw.log',lambda t:re.sub(r'(G1_FINAL id=2[^\n]*?data=)12345678',r'\g<1>deadbeef',t,count=1))
    elif mutation=='image_binding':alter('normal.vvp',lambda t:t.replace(str(source/'normal.hex'),str(source/'fault.hex')))
    elif mutation=='duplicate_final':alter('normal.raw.log',lambda t:re.sub(r'^(G1_FINAL id=2[^\n]*\n)',r'\g<1>\g<1>',t,count=1,flags=re.M))
    elif mutation=='orphan_commit':alter('normal.raw.log',lambda t:re.sub(r'^(G1_COMMIT_POST[^\n]*\n)',lambda x:x[0]+re.sub(r'id=\d+','id=99',x[0]),t,count=1,flags=re.M))
    elif mutation=='mixed_commit':alter('normal.raw.log',lambda t:re.sub(r'(G1_COMMIT_POST[^\n]*actual=)12345678',r'\g<1>89abcdef',t,count=1))
    elif mutation=='stale_edge':alter('normal.raw.log',lambda t:re.sub(r'(G1_FINAL id=2[^\n]*?edge=)\d+',r'\g<1>1',t,count=1))
    elif mutation=='elf_binary':
        p=root/'normal.bin';b=bytearray(p.read_bytes());b[0]^=1;p.write_bytes(b);m['artifacts'][p.name]=sha(p)
    elif mutation=='hex_image':alter('normal.hex',lambda t:'00000013\n'+t.split('\n',1)[1])
    elif mutation=='disasm_opcode':alter('normal.dis',lambda t:re.sub(r'(^\s*0:\s+)[0-9a-f]{8}',r'\g<1>00000013',t,count=1,flags=re.M))
    elif mutation=='symbols_pc':alter('normal.nm',lambda t:re.sub(r'^00000070 (\w) fault_store$',r'00000074 \1 fault_store',t,count=1,flags=re.M))
    elif mutation=='compile_argv':alter('normal.compile.log.command.json',lambda t:t.replace('normal.hex','fault.hex'))
    elif mutation=='run_argv':alter('normal.raw.log.command.json',lambda t:t.replace('normal.vvp','fault.vvp'))
    elif mutation=='missing_wait':alter('fault.raw.log',lambda t:re.sub(r'^G1_GAP_PHASE[^\n]*stage=WAIT[^\n]*\n','',t,count=1,flags=re.M))
    elif mutation=='dmem_mask':alter('normal.raw.log',lambda t:re.sub(r'(G1_DMEM_PRE[^\n]*mask=)15',r'\g<1>7',t,count=1))
    elif mutation=='dmem_post':alter('normal.raw.log',lambda t:re.sub(r'(G1_DMEM_POST[^\n]*actual=)47314f4b',r'\g<1>deadbeef',t,count=1))
    elif mutation=='csr_altered':alter('fault.raw.log',lambda t:re.sub(r'^(G1_CSR_POST cause=)00000007 mepc=00000070',r'\g<1>00000006 mepc=00000074',t,flags=re.M))
    elif mutation=='csr_missing':alter('fault.raw.log',lambda t:re.sub(r'^G1_CSR_POST[^\n]*\n','',t,count=1,flags=re.M))
    elif mutation=='csr_duplicate':alter('fault.raw.log',lambda t:re.sub(r'^(G1_CSR_POST[^\n]*\n)',r'\g<1>\g<1>',t,count=1,flags=re.M))
    elif mutation=='csr_balanced_shift':
        def shift(t):
            record=re.search(r'^G1_CSR_POST[^\n]*\n',t,re.M)[0]
            t=t.replace(record,'',1)
            return re.sub(r'^(G1_RETIRE pc=0000009c[^\n]*\n)',lambda hit:hit[0]+record,t,count=1,flags=re.M)
        alter('fault.raw.log',shift)
    elif mutation in ('status_ready','status_fault_ready'):
        lane,i,count=('normal',5,1) if mutation=='status_ready' else ('fault',1,0)
        alter(lane+'.raw.log',lambda t:re.sub(r'(G1_FINAL id='+str(i)+r'[^\n]*rdata=)00000011',r'\g<1>00000001',t,count=1).replace('release=1 status='+str(count+1),'release=1 status='+str(count)))
        m['cases'][lane]['reach']['status']=count
    elif mutation=='status_poll_only':
        alter('normal.raw.log',lambda t:re.sub(r'(G1_FINAL id=1[^\n]*rdata=)00000011',r'\g<1>00000001',t,count=1).replace('release=1 status=2','release=1 status=1'))
        m['cases']['normal']['reach']['status']=1
    elif mutation in ('initial_poll_normal','initial_poll_fault'):
        # Synthetic legal source-loop observation-input control, not CPU evidence.
        # Add one not-ready iteration plus source-matching retry retirements,
        # shifting later clock witnesses coherently. Neither producer identity
        # nor the archived image/source is relabeled as a newly executed sim.
        lane=mutation.rsplit('_',1)[1]
        def poll(t):
            original=t.splitlines();addr=next(x for x in original if x.startswith('G1_ADDR id=1 '));final=next(x for x in original if x.startswith('G1_FINAL id=1 '))
            retire=[next(x for x in original if x.startswith('G1_RETIRE pc='+pc+' ')) for pc in ('00000014','00000018','0000001c')]
            def shift(line,delta,ids=False):
                if ids:line=re.sub(r'\bid=(\d+)',lambda h:'id='+str(int(h[1])+1),line)
                line=re.sub(r'\bedge=(\d+)',lambda h:'edge='+str(int(h[1])+delta),line)
                return re.sub(r'\btime=(\d+)',lambda h:'time='+str(int(h[1])+20000*delta),line)
            out=[]
            for line in original:
                if line.startswith('G1_FINAL id=1 '):line=line.replace('rdata=00000011','rdata=00000001')
                d=fields(line)
                if 'id' in d and int(d['id'])>=2:line=re.sub(r'\bid=(\d+)',lambda h:'id='+str(int(h[1])+1),line)
                if 'edge' in d and int(d['edge'])>=1000030:line=shift(line,7)
                if line.startswith('G1_SUMMARY PASS '):line=re.sub(r'\bfinals=(\d+)',lambda h:'finals='+str(int(h[1])+1),line)
                out.append(line)
                if line.startswith('G1_RETIRE pc=0000001c ') and num(fields(line),'edge')==1000029:
                    out.extend([shift(addr,7,True),shift(final,7,True)]+[shift(x,7) for x in retire])
            return '\n'.join(out)+'\n'
        alter(lane+'.raw.log',poll);m['cases'][lane]['reach']['finals']+=1
    elif mutation!='valid':raise ValueError(mutation)
    put(root/'manifest.json',m)
    guard_exit=None;guard_pid=None
    if target_exit==0:
        try:guard(root);guard_exit=0
        except GuardFailure as e:print('GUARD_REJECT',str(e));guard_exit=1;guard_pid=e.pid
        except Exception as e:print('GUARD_REJECT_UNCLASSIFIED',type(e).__name__,str(e));guard_exit=1;guard_pid='UNCLASSIFIED'
    final=0 if target_exit==0 and guard_exit==0 else 1
    put(root/'replay.result.json',{'target_exit':target_exit,'guard_exit':guard_exit,'guard_pid':guard_pid,'expected_guard_pid':FIXTURE_PIDS.get(mutation),'final_exit':final,'kind':'REPLAY_NOT_NEW_SIMULATION'})
    return final

if __name__=='__main__':
    try:
        if sys.argv[1]=='guard': code=guard(Path(sys.argv[2]))
        elif sys.argv[1]=='replay': code=replay(Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4])
        else: code=run(Path(sys.argv[2]),Path(sys.argv[3]))
    except Exception as e:
        print(type(e).__name__,str(e),file=sys.stderr);code=1
        if sys.argv[1]=='run' and Path(sys.argv[3]).is_dir():
            put(Path(sys.argv[3])/'result.json',{'target_verdict':'FAIL_OR_INCOMPLETE','guard_exit':1 if isinstance(e,GuardFailure) else None,'final_exit':1,'reason':str(e),'acceptance':'PENDING'})
    sys.exit(code)
