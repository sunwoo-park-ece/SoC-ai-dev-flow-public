#!/usr/bin/env python3
"""Bounded G2 build, semantic raw checker, integrity guard and parent runner.

Copied observation-input counterexamples are checker self-tests, not new DUT
simulations. No import produces cache files. Every output stays in RUN_ROOT.
"""
import hashlib, importlib.util, json, os, re, shutil, struct, subprocess, sys, time
from pathlib import Path
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
BASE='8c3a4d6948e3061ff48021b81a6a3eec708f7788'
LANES=['P0','P1','P2','P3','P4']
class Failure(Exception):
    def __init__(self,pid,detail): self.pid=pid;super().__init__(pid+' '+str(detail))
def need(v,pid,detail):
    if not v: raise Failure(pid,detail)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v): p.write_text(json.dumps(v,indent=2)+'\n')
def read(p): return json.loads(p.read_text())
def g1():
    s=importlib.util.spec_from_file_location('g1_reused',REPO/'verification/independent/p12a3_soc_vga/p12a3_evidence_guard.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def source():
    sources,closure=g1().closure(REPO)
    closure.update({str(p.relative_to(REPO)):sha(p) for p in HERE.rglob('*') if p.is_file()})
    return sources,closure
def command(args,out,budget=1200):
    args=[str(a) for a in args];started=time.time_ns()
    with out.open('w') as f:
        try: code=subprocess.run(args,stdout=f,stderr=subprocess.STDOUT,timeout=budget,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')).returncode
        except subprocess.TimeoutExpired: code=124
    put(Path(str(out)+'.command.json'),dict(argv=args,budget_seconds=budget,started_ns=started,finished_ns=time.time_ns(),exit=code))
    return code
def fields(line): return dict(re.findall(r'(\w+)=([^\s]+)',line))
def records(raw,kind): return [fields(x) for x in raw.splitlines() if x.startswith(kind+' ')]
def n(d,k,base=10):
    need(k in d,'G2_RAW','missing '+k)
    return int(d[k],base)
def timing_guard(raw):
    samples=records(raw,'G2_TIMING_SAMPLE')
    need(samples,'G2_TIMING','missing settled timing observations')
    for d in samples:
        edge=n(d,'edge');count=max(0,(edge-1000011)//2)
        ex=count%800;ey=(count//800)%525
        need(n(d,'expected_x')==ex and n(d,'expected_y')==ey and n(d,'actual_x')==ex and n(d,'actual_y')==ey,'G2_TIMING','external-history coordinate '+str(d))
        need(n(d,'time_ps')==(edge*20-10)*1000+2,'G2_TIMING','sample phase')
    need('G2_FAILURE G2_TIMING ' not in raw,'G2_TIMING','target comparator rejection')
    return 0
def semantic(root,lane):
    m=read(root/'manifest.json');case=m['cases'][lane];raw=(root/case['raw']).read_text();i=int(lane[1])
    need('G2_FAILURE' not in raw and raw.count('G2_SUMMARY PASS ')==1,'G2_TARGET',lane)
    summary=records(raw,'G2_SUMMARY')[0];need(n(summary,'lane')==i,'G2_CASE_SET',lane)
    if i==0:timing_guard(raw)
    binary,symbols=g1().read_elf(root/m['images'][lane]['elf'])
    img=records(raw,'G2_IMAGE');need(len(img)==1 and n(img[0],'lane')==i and img[0].get('path')==str(Path(m['run_root'])/m['images'][lane]['hex']) and n(img[0],'start',16)==int.from_bytes(binary[:4],'little') and n(img[0],'fault_pc',16)==symbols['fault_store'],'G2_IDENTITY','image observation / stale run')
    releases=records(raw,'G2_RESET_RELEASE')
    need(len(releases)==(2 if i==3 else 1) and all(n(x,'qualified')==1000000 for x in releases),'G2_RECOVERY','reset qualification')
    need(n(releases[0],'edge')==1000008,'G2_RECOVERY','first natural qualification edge')
    if i==3:
        assertions=records(raw,'G2_RESET_ASSERT');need(len(assertions)==1 and n(releases[1],'edge')-n(assertions[0],'edge')>=1000000,'G2_RECOVERY','reboot qualification')
    finals=records(raw,'G2_FINAL')
    for f in finals:
        a=n(f,'addr',16);expected=2 if 0x20000000<=a<0x20020000 else (1 if 0x10000000<=a<0x10008000 else (3 if a>>20==0x400 else 0))
        need(n(f,'route')==expected,'G2_BUS','route '+str(f))
    cmds=records(raw,'G2_COMMAND');expected_cmds={0:[1,2,3],1:[3],2:[3],3:[1,1],4:[3,1]}[i]
    need([n(c,'command') for c in cmds]==expected_cmds,'G2_CAUSALITY','accepted command sequence')
    need(len({(n(c,'epoch'),n(c,'op')) for c in cmds})==len(cmds),'G2_CAUSALITY','duplicate commands')
    request=records(raw,'G2_REQUEST');commit=records(raw,'G2_EXPECT_COMMIT');ack=records(raw,'G2_ACK');owner=records(raw,'G2_OWNER');done=records(raw,'G2_DONE');clear=records(raw,'G2_CLEAR');writes=records(raw,'G2_CPU_WRITE')
    cancel=records(raw,'G2_CANCEL');expected_cancel=1 if i in (3,4) else 0
    command_keys={(n(c,'epoch'),n(c,'op')) for c in cmds}
    need(all((n(e,'epoch'),n(e,'op')) in command_keys for e in request+commit+ack+owner+done+clear),'G2_CAUSALITY','orphan operation event')
    need(len(cancel)==expected_cancel,'G2_RECOVERY','cancellation count')
    canceled={(n(c,'epoch'),n(cmds[0],'op')) for c in cancel}
    def key(c): return n(c,'epoch'),n(c,'op')
    for c in cmds:
        k=key(c);typ=n(c,'command');r=[x for x in request if key(x)==k];co=[x for x in commit if key(x)==k];a=[x for x in ack if key(x)==k];o=[x for x in owner if key(x)==k];d=[x for x in done if key(x)==k];cw=[x for x in clear if key(x)==k]
        need(len(r)==int(bool(typ&1)),'G2_CAUSALITY','request uniqueness')
        if k in canceled:
            need(not d,'G2_RECOVERY','canceled DONE')
            if i==3:need(not co and not a and not o and not cw,'G2_RECOVERY','precommit stale effects')
            else:need(len(co)==len(a)==len(o)==1 and 0<len(cw)<9600,'G2_PLL','postcommit canceled clear interval')
        else:
            need(len(d)==1,'G2_COMPLETION','unique first DONE')
            if typ&1:need(len(co)==len(a)==len(o)==1,'G2_CAUSALITY','commit ACK owner uniqueness')
            else:need(not co and not a and not o,'G2_CAUSALITY','clear-only ownership event')
        if co:
            need(n(co[0],'edge')>n(c,'edge') and n(co[0],'front')==1-n(c,'front'),'G2_CAUSALITY','natural commit bank')
            wraps=records(raw,'G2_WRAP');need(any(n(w,'epoch')==k[0] and n(w,'edge')==n(co[0],'edge') for w in wraps),'G2_CAUSALITY','no natural wrap')
        if a:need(co and n(a[0],'edge')>=n(co[0],'edge'),'G2_CAUSALITY','early ACK')
        if o:need(a and n(o[0],'edge')>n(a[0],'edge') and n(o[0],'front')==n(co[0],'front'),'G2_CAUSALITY','H ownership causality')
        if typ&2:
            target=n(c,'front') if typ&1 else 1-n(c,'front')
            need(all(n(w,'bank')==target for w in cw),'G2_BANK','clear target immutable')
            need([n(w,'addr') for w in cw]==list(range(len(cw))) and all(n(w,'data',16)==0 for w in cw),'G2_COMPLETION','clear ordered physical words')
            if k not in canceled:need(len(cw)==9600 and n(d[0],'edge')>n(cw[-1],'edge') and n(d[0],'clear')==9600,'G2_COMPLETION','word9599 before DONE')
            if o and cw:need(n(cw[0],'edge')>n(o[0],'edge'),'G2_CAUSALITY','clear before H ownership')
        elif d:need(o and n(d[0],'edge')==n(o[0],'edge'),'G2_COMPLETION','swap first DONE ownership')
    # Construct expected memory solely from accepted external CPU writes and
    # normative clear events. Actual bank/word fields are checked, not truth.
    memory=[[0]*9600,[0]*9600];front_by_epoch={0:0};hfront_by_epoch={0:0};active=None;word_index=0;rounds=0;known_words=0
    pixels=0;coords=set();w1c_masks=set();last_edge=-1
    for line in raw.splitlines():
        if not line.startswith('G2_'):continue
        kind=line.split(' ',1)[0];d=fields(line)
        if 'edge' in d:
            need(n(d,'edge')>=last_edge,'G2_RAW','nonmonotonic event');last_edge=n(d,'edge')
        ep=n(d,'epoch') if 'epoch' in d else 0
        if kind=='G2_COMMAND':active=(ep,n(d,'op'),n(d,'command'),n(d,'front'))
        elif kind=='G2_EXPECT_COMMIT':front_by_epoch[ep]=1-front_by_epoch.get(ep,0)
        elif kind=='G2_OWNER':hfront_by_epoch[ep]=front_by_epoch.get(ep,0)
        elif kind=='G2_RESET_ASSERT':front_by_epoch[ep]=hfront_by_epoch[ep]=0;rounds=0;word_index=0;active=None
        elif kind=='G2_PLL_BIND':front_by_epoch[1]=hfront_by_epoch[1]=0;active=None
        elif kind=='G2_CPU_WRITE':
            a=n(d,'addr');bank=1-hfront_by_epoch.get(ep,0);value=n(d,'data',16)
            need(n(d,'bank')==bank and a==word_index and value==(a^(0x80000001 if rounds==0 else 0x55aa55aa)),'G2_BANK','CPU accepted pattern/bank')
            memory[bank][a]=value;word_index+=1;known_words+=1
            if word_index==9600:word_index=0;rounds+=1
        elif kind=='G2_CLEAR':memory[n(d,'bank')][n(d,'addr')]=0
        elif kind=='G2_PIXEL':
            x=n(d,'x');y=n(d,'y');f=front_by_epoch.get(ep,0);v=memory[f][y*20+x//32]
            need(n(d,'front')==f and n(d,'rgb',16)==(0xfff if (v>>(x%32))&1 else 0),'G2_PIXEL','tagged pixel '+str(d));coords.add((x,y));pixels+=1
        elif kind=='G2_W1C':
            before=n(d,'before');after=n(d,'after');mask=n(d,'mask');w1c_masks.add(mask)
            # Directed W1C edges deliberately do not coincide with completions.
            need(after&10==(before&10)&~mask,'G2_W1C','selected DONE/ABORT or unselected preservation')
            need(after&20==before&20,'G2_W1C','live fields changed')
            if mask&1:need(after&1==0,'G2_W1C','VSYNC clear')
        elif kind=='G2_DMEM':need(n(d,'we')==1 and n(d,'mask')==15 and n(d,'word')==(n(d,'addr',16)-0x10000000)//4,'G2_DMEM','physical diagnostic')
    need(known_words==9600*({0:2,1:1,2:1,3:2,4:2}[i]),'G2_IMAGE','full CPU source pattern extent')
    if i in (0,3,4):need({(0,0),(31,0),(32,0),(639,0),(0,479),(639,479)}<=coords,'G2_PIXEL','all boundary coordinates')
    if i==0:
        need({1,2,8,10}<=w1c_masks and n(summary,'apb_wait')>0 and records(raw,'G2_APB_WAIT'),'G2_W1C','operation-time W1C/APB coverage')
    if i in (1,2):
        errs=records(raw,'G2_ERROR');need(len(errs)==2 and [n(e,'ready') for e in errs]==[0,1] and all(n(e,'resp')==1 and n(e,'pc',16)==symbols['fault_store'] and n(e,'we')==0 for e in errs) and n(errs[1],'edge')==n(errs[0],'edge')+1,'G2_FAULT','two-cycle precise busy ERROR')
        diagnostics=records(raw,'G2_DMEM')
        need([n(d,'data',16) for d in diagnostics if n(d,'addr',16)==0x10000004]==[7] and [n(d,'data',16) for d in diagnostics if n(d,'addr',16)==0x10000008]==[symbols['fault_store']],'G2_FAULT','cause and ELF PC diagnostic')
    if i==4:
        inj=records(raw,'G2_PLL_INJECT');bind=records(raw,'G2_PLL_BIND');low=records(raw,'G2_LOCK_LOW');ab=records(raw,'G2_ABORT')
        need(len(inj)==len(bind)==len(ab)==1 and low,'G2_PLL','loss reach')
        need(n(inj[0],'clear')>0 and n(inj[0],'clear')<9600 and n(inj[0],'edge')>n(inj[0],'commit_edge'),'G2_PLL','phase')
        need(all(n(d,'hreset')==1 and n(d,'we')==0 for d in bind+low) and all(n(bind[0],k)==0 for k in ('model_lock','raw_lock','preset','hepoch')),'G2_PLL','connected raw-lock gating')
        need(n(ab[0],'done')==0 and n(summary,'canceled')==1 and n(summary,'aborts')==1 and n(summary,'boots')==1,'G2_RECOVERY','same CPU fresh epoch')
    return summary

CRITICAL_SYMBOLS=('_start','fault_store','younger_sentinel','trap_entry','normal_terminal','trap_terminal')
C2_PRODUCER_MANIFEST='068156664ccf7df6d8583440f81da999f5dad775681a57a44edefb7379dfdf85'
C2_PRODUCER_SOURCE='49994e84e4ecdd91f2c4214eba220a8a415c50d3ad899d285020d59cf944408e'
def elf_symbol_records(path):
    # The existing independent parser first validates ELF32/RISC-V/IMEM.
    g1().read_elf(path)
    b=path.read_bytes();h=struct.unpack_from('<HHIIIIIHHHHHH',b,16)
    sections=[struct.unpack_from('<IIIIIIIIII',b,h[5]+i*h[10]) for i in range(h[11])]
    rows=[]
    for q in sections:
        if q[1]!=2:continue  # SHT_SYMTAB
        need(q[9]==16 and q[6]<len(sections),'G2_IDENTITY','typed symtab layout')
        st=sections[q[6]];need(st[4]+st[5]<=len(b) and q[4]+q[5]<=len(b),'G2_IDENTITY','typed symbol payload')
        strings=b[st[4]:st[4]+st[5]]
        for off in range(q[4],q[4]+q[5],16):
            name,value,size,info,other,index=struct.unpack_from('<IIIBBH',b,off)
            if not name or not index:continue
            need(name<len(strings),'G2_IDENTITY','symbol string offset')
            name=strings[name:].split(b'\0',1)[0].decode('ascii')
            rows.append(dict(name=name,value=value,type=info&15,bind=info>>4,section=index))
    return rows
def special_symbol(row):
    return row['type']==4 or (row['type']==0 and re.fullmatch(r'\$(?:x(?:rv\S*)?|d)(?:\.\d+)?',row['name']) is not None)
def symbol_binding(root,im,symbols):
    rows=elf_symbol_records(root/im['elf']);ordinary={}
    # ELF mapping symbols can repeat at several code regions; nm may hide
    # them and STT_FILE entirely. Never exempt ordinary/critical symbols.
    for row in rows:
        if special_symbol(row):continue
        need(row['name'] not in ordinary,'G2_IDENTITY','duplicate ordinary ELF symbol')
        ordinary[row['name']]=row['value']
    declarations=re.findall(r'^\.global (.+)$',(HERE/'firmware.S').read_text(),re.M)
    declared={x.strip() for line in declarations for x in line.split(',')}
    need(set(CRITICAL_SYMBOLS)<=declared,'G2_IDENTITY','critical source declarations')
    need(im['symbols']==symbols,'G2_IDENTITY','producer symbol metadata versus independent ELF')
    parsed={}
    for line in (root/im['nm']).read_text().splitlines():
        hit=re.fullmatch(r'([0-9a-fA-F]+)\s+([A-Za-z?])\s+(\S+)',line)
        need(hit is not None,'G2_IDENTITY','malformed nm record')
        address,kind,name=hit.groups();value=int(address,16)
        matches=[row for row in rows if row['name']==name and row['value']==value]
        need(matches,'G2_IDENTITY','nm address/name versus ELF '+name)
        if all(special_symbol(row) for row in matches):continue
        need(name not in parsed,'G2_IDENTITY','duplicate ordinary nm symbol '+name)
        parsed[name]=value
    for name in CRITICAL_SYMBOLS:
        definitions=[row for row in rows if row['name']==name]
        need(len(definitions)==1 and definitions[0]['bind']==1 and definitions[0]['type'] in (0,2),'G2_IDENTITY','critical ELF definition '+name)
        need(name in parsed and name in ordinary and parsed[name]==ordinary[name]==symbols[name]==im['symbols'][name],'G2_IDENTITY','critical symbol missing/address '+name)
    need(parsed==ordinary,'G2_IDENTITY','ordinary nm inventory versus typed ELF')

def source_identity(root,m):
    live=source()[1]
    if (root/'replay-context.json').exists():
        replay_identity(root,m,live);return
    context=root/'validator-context.json'
    if not context.exists():
        need(m['base']==BASE and m['source_before']==m['source_after']==live,'G2_IDENTITY','actual source closure');return
    # Only the explicitly pinned C2 producer is eligible for this separation.
    # Historical producer maps remain unchanged; the validator has its own map.
    need(root.name.startswith('P12A3-G2C2-') and root.parent==REPO.parents[1]/'runs','G2_IDENTITY','C2 validation scope')
    c=read(context);origin=Path(c['origin'])
    need(c['kind']=='ORIGINAL_PRODUCER_NEW_VALIDATOR_SELFTEST' and c['validator_source']==live,'G2_IDENTITY','validator identity')
    need(origin.resolve()!=root.resolve() and str(origin)==m['run_root'],'G2_IDENTITY','producer origin path')
    need(c['origin_manifest_sha256']==C2_PRODUCER_MANIFEST and sha(origin/'manifest.json')==C2_PRODUCER_MANIFEST,'G2_IDENTITY','pinned original producer manifest')
    original=read(origin/'manifest.json')
    digest=hashlib.sha256(json.dumps(original['source_before'],sort_keys=True,separators=(',',':')).encode()).hexdigest()
    need(digest==C2_PRODUCER_SOURCE and original['source_before']==original['source_after'],'G2_IDENTITY','pinned producer source')
    need(m['base']==BASE and m['source_before']==m['source_after']==original['source_before'],'G2_IDENTITY','producer maps rewritten')
    delta={k for k in set(live)|set(original['source_before']) if live.get(k)!=original['source_before'].get(k)}
    need(delta=={'verification/independent/p12a3_soc_vga_g2/evidence.py'},'G2_IDENTITY','out-of-scope producer/validator source delta')
    for name,h in original['artifacts'].items():need(sha(origin/name)==h,'G2_IDENTITY','original producer artifact altered')
    need(read(origin/'result.json')['guard_exit']==1 and (origin/'guard.log').read_text().strip()=='G2_REJECT G2_IDENTITY ELF/symbol binding','G2_IDENTITY','historical guard failure')
    need({k:v for k,v in m.items() if k!='artifacts'}=={k:v for k,v in original.items() if k!='artifacts'},'G2_IDENTITY','producer metadata changed')
    mutation=c['mutation'];allowed=set()
    if mutation=='extra_symbols' or mutation.startswith(('missing:','wrong:')):allowed={'P0.nm'}
    elif mutation=='image':allowed={'P0.hex'}
    need(set(m['artifacts'])==set(original['artifacts']),'G2_IDENTITY','producer artifact inventory')
    changed={name for name in m['artifacts'] if m['artifacts'][name]!=original['artifacts'][name]}
    need(changed==allowed,'G2_IDENTITY','copied self-test artifact delta')
    need(c['copied_origin_sha256']==original['artifacts'],'G2_IDENTITY','copy lineage')

def integrity(root,required=None):
    m=read(root/'manifest.json');source_identity(root,m)
    if required is not None:need(set(m['cases'])==set(required),'G2_CASE_SET','omitted/mismatched lanes')
    required_names=set()
    for lane,c in m['cases'].items():
        im=m['images'][lane];required_names.update(im[k] for k in ('elf','bin','hex','nm','dis','sim'))
        required_names.update([c['raw'],c['raw']+'.command.json',lane+'.gcc.log.command.json',lane+'.compile.log.command.json'])
    need(required_names<=m['artifacts'].keys(),'G2_IDENTITY','omitted required artifact binding')
    for name,h in m['artifacts'].items():
        need(isinstance(name,str) and Path(name).name==name,'G2_IDENTITY','nonlocal artifact')
        p=root/name;need(p.is_file() and not p.is_symlink() and sha(p)==h,'G2_IDENTITY',name)
    for lane in m['cases']:
        im=m['images'][lane];binary,symbols=g1().read_elf(root/im['elf'])
        need(binary==(root/im['bin']).read_bytes(),'G2_IDENTITY','ELF binary')
        words=[int(x,16) for x in (root/im['hex']).read_text().splitlines()]
        need(words==[int.from_bytes(binary[i:i+4],'little') for i in range(0,len(binary),4)],'G2_IDENTITY','checksum-consistent IMEM corruption')
        symbol_binding(root,im,symbols)
        gcc=read(root/(lane+'.gcc.log.command.json'))
        need(gcc['argv']==['riscv32-unknown-elf-gcc','-march=rv32i_zicsr','-mabi=ilp32','-nostdlib','-nostartfiles','-Wl,--no-relax','-T',str(REPO/'firmware/bsp/linker.ld'),f'-DLANE={int(lane[1])}',str(HERE/'firmware.S'),'-o',str(Path(m['run_root'])/im['elf'])] and gcc['exit']==0,'G2_IDENTITY','source/image compiler argv')
        sim=(root/im['sim']).read_text();origin=Path(m['run_root'])
        need(str(origin/im['hex']) in sim,'G2_IDENTITY','static elaboration image')
        params=re.findall(r'\.param/str "INIT_FILE"[^\n]*, "([^"\n]*)";',sim)
        need(str(origin/im['hex']) in params,'G2_IDENTITY','actual IMEM binding')
        c=m['cases'][lane];cmd=read(root/(c['raw']+'.command.json'))
        need(cmd['argv']==['vvp',str(origin/im['sim'])] and cmd['exit']==c['simulator_exit']==0,'G2_IDENTITY','sim command/exit')
        need(c['checker_exit']==0,'G2_TARGET','leaf semantic status')
        semantic(root,lane)
    return 0
def artifacts(root):return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file() and p.name not in ('manifest.json','result.json','guard.log','guard.log.command.json')}
def fresh(root):
    need(root.name.startswith('P12A3-G2-resume-') and root.parent==REPO.parents[1]/'runs','G2_SCOPE','fresh authorized root')
    root.mkdir(exist_ok=False)
def run(root,lanes):
    need(lanes==LANES or lanes in [[l] for l in LANES],'G2_CASE_SET','exact approved full order or single lane')
    fresh(root);sources,before=source()
    need(subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()==BASE,'G2_IDENTITY','HEAD')
    need(subprocess.check_output(['git','diff','--name-only'],cwd=REPO,text=True)=='','G2_IDENTITY','tracked changes')
    m=dict(base=BASE,repo=str(REPO),run_root=str(root),source_before=before,source_after={},images={},cases={},artifacts={})
    put(root/'manifest.json',m)
    for tool in ('iverilog','vvp','riscv32-unknown-elf-gcc','riscv32-unknown-elf-objcopy','riscv32-unknown-elf-nm','riscv32-unknown-elf-objdump','python3'):
        command([tool,'-V' if tool in ('iverilog','vvp') else '--version'],root/(tool+'.version.log'),30)
    for lane in lanes:
        i=int(lane[1]);im={k:lane+'.'+v for k,v in [('elf','elf'),('bin','bin'),('hex','hex'),('nm','nm'),('dis','dis'),('sim','vvp')]}
        def build(args,name):need(command(args,root/name,120)==0,'G2_BUILD',name)
        build(['riscv32-unknown-elf-gcc','-march=rv32i_zicsr','-mabi=ilp32','-nostdlib','-nostartfiles','-Wl,--no-relax','-T',REPO/'firmware/bsp/linker.ld',f'-DLANE={i}',HERE/'firmware.S','-o',root/im['elf']],lane+'.gcc.log')
        build(['riscv32-unknown-elf-objcopy','--dump-section',f'.imem={root/im["bin"]}',root/im['elf']],lane+'.objcopy.log')
        build(['riscv32-unknown-elf-nm','-n',root/im['elf']],im['nm']);build(['riscv32-unknown-elf-objdump','-d',root/im['elf']],im['dis'])
        binary,symbols=g1().read_elf(root/im['elf']);im['symbols']=symbols
        (root/im['hex']).write_text(''.join(f'{int.from_bytes(binary[n:n+4],"little"):08x}\n' for n in range(0,len(binary),4)))
        args=['iverilog','-g2012','-s','tb_g2','-o',root/im['sim'],f'-Ptb_g2.IMEM_FILE="{root/im["hex"]}"',f'-Ptb_g2.LANE={i}',f'-Ptb_g2.FAULT_PC={symbols["fault_store"]}',f'-Ptb_g2.YOUNGER_PC={symbols["younger_sentinel"]}',f'-Ptb_g2.TRAP_PC={symbols["trap_entry"]}',f'-Ptb_g2.START_WORD={int.from_bytes(binary[:4],"little")}']
        for p in sorted({p.parent for p in list(REPO.glob('rtl/core/v/**/*.v'))+list(REPO.glob('rtl/core/vh/**/*.vh'))}):args+=['-I',p]
        args+=sources+[REPO/'verification/independent/p12a3_soc_vga/tb/p12a3_soc_vga_ref.sv',HERE/'tb_g2.sv']
        build(args,lane+'.compile.log');m['images'][lane]=im
        print('RUN',lane,flush=True)
        sim_exit=command(['vvp',root/im['sim']],root/(lane+'.raw.log'),1800)
        m['cases'][lane]=dict(raw=lane+'.raw.log',simulator_exit=sim_exit,checker_exit=None)
        put(root/'manifest.json',m)
        if sim_exit:
            m['source_after']=source()[1];m['artifacts']=artifacts(root);put(root/'manifest.json',m)
            put(root/'result.json',dict(verdict='STOP_REQUIRED_LANE_FAILED',lane=lane,simulator_exit=sim_exit,final_exit=1));return 1
        leaf=command([sys.executable,'-B',HERE/'evidence.py','check',root,lane],root/(lane+'.checker.log'),60)
        m['cases'][lane]['checker_exit']=leaf
        if leaf:
            m['source_after']=source()[1];m['artifacts']=artifacts(root);put(root/'manifest.json',m)
            put(root/'result.json',dict(verdict='STOP_MISSING_SEMANTANTIC_EVIDENCE',lane=lane,simulator_exit=0,checker_exit=leaf,final_exit=1));return 1
        put(root/'manifest.json',m)
    m['source_after']=source()[1];m['artifacts']=artifacts(root);put(root/'manifest.json',m)
    guard_exit=command([sys.executable,'-B',HERE/'evidence.py','guard',root,','.join(lanes)],root/'guard.log',120)
    put(root/'result.json',dict(verdict='FUNCTIONAL_LANES_PASS_SENSITIVITY_PENDING' if guard_exit==0 and lanes==LANES else ('PARTIAL_TARGETED_PASS' if guard_exit==0 else 'STOP_GUARD_FAILED'),lanes=lanes,guard_exit=guard_exit,final_exit=int(guard_exit!=0),acceptance='PENDING_CONTROL_REVIEW'))
    return int(guard_exit!=0)

def timing_negative(origin,root):
    """Same source-bound P0; only local passive comparator input is changed.
    Real vvp leaf and independent raw timing guard both fail; parent returns1.
    This is checker sensitivity, never a Production semantic mutant kill.
    """
    fresh(root);m=read(origin/'manifest.json')
    need(m['source_before']==m['source_after']==source()[1],'G2_IDENTITY','current origin source')
    need(m['cases'].get('P0',{}).get('simulator_exit')==0,'G2_TARGET','passing timing control required')
    put(root/'source-before.json',source()[1])
    leaf=command(['vvp',origin/m['images']['P0']['sim'],'+TIMING_FAULT'],root/'timing.raw.log',1800)
    guard_exit=command([sys.executable,'-B',HERE/'evidence.py','timing-check',root/'timing.raw.log'],root/'timing.guard.log',60)
    raw=(root/'timing.raw.log').read_text();acts=records(raw,'G2_TIMING_ADAPTER')
    need(len(acts)==1 and n(acts[0],'after_x')==n(acts[0],'before_x')+1 and n(acts[0],'expected_x')==n(acts[0],'before_x'),'G2_TIMING_REACH','adapter isolation/activation')
    need(leaf==1 and guard_exit==1 and 'G2_FAILURE G2_TIMING ' in raw and 'G2_REJECT G2_TIMING ' in (root/'timing.guard.log').read_text(),'G2_TIMING_REACH','specific semantic rejection')
    after=source()[1];put(root/'source-after.json',after)
    need(read(root/'source-before.json')==after,'G2_IDENTITY','negative source unchanged')
    put(root/'artifact-hashes.json',artifacts(root))
    put(root/'result.json',dict(kind='ISOLATED_OBSERVATION_INPUT_SELFTEST',classification='SELFTEST_EXPECTED_REJECTION',expected_pid='G2_TIMING',simulator_exit=leaf,guard_exit=guard_exit,final_exit=1,origin=str(origin)))
    return 1

# Copied observation/input self-tests. PIDs are actual semantic checker labels.
# No fixture reaches the Production instance, original archive or oracle.
FIXTURES={
 'valid':('P0',None),'route':('P0','G2_BUS'),
 'request_duplicate':('P0','G2_CAUSALITY'),'ack_early':('P0','G2_CAUSALITY'),
 'orphan_ack':('P0','G2_CAUSALITY'),'clear_bank':('P0','G2_BANK'),
 'clear_last_missing':('P0','G2_COMPLETION'),'clear_address':('P0','G2_COMPLETION'),
 'done_early':('P0','G2_COMPLETION'),'w1c':('P0','G2_W1C'),
 'pixel':('P0','G2_PIXEL'),'timing':('P0','G2_TIMING'),
 'dmem':('P0','G2_DMEM'),'fault_response':('P1','G2_FAULT'),
 'fault_cause':('P1','G2_FAULT'),'reset_stale_done':('P3','G2_RECOVERY'),
 'pll_write_gate':('P4','G2_PLL'),'abort_done':('P4','G2_RECOVERY'),
 'source':('P0','G2_IDENTITY'),'image':('P0','G2_IDENTITY'),
 'stale':('P0','G2_IDENTITY'),'omitted':('P0','G2_CASE_SET'),
 'truncated':('P0','G2_TARGET'),'unbound':('P0','G2_IDENTITY')}
# Immutable producer pins; R23 is a validator self-test, not new simulation.
REPLAY_PINS={
 'P0':('P12A3-G2-resume-P0-01','068156664ccf7df6d8583440f81da999f5dad775681a57a44edefb7379dfdf85','49994e84e4ecdd91f2c4214eba220a8a415c50d3ad899d285020d59cf944408e'),
 'P1':('P12A3-G2-resume-R21-P1-01','b401f8e6c46c31d235a8d64c3fb138e932eebb23cc265a62a1be274d7a92d70f','e4a01a5843ed1133f1c23171d90a1f824a59f3a37055a5033f925f3bb6284fc1'),
 'P2':('P12A3-G2-resume-R21-P2-01','2dd47487fd4453a1f2083a9dcb36bd2a0c3d9b6dbad5680f19017bfd39716a2d','e4a01a5843ed1133f1c23171d90a1f824a59f3a37055a5033f925f3bb6284fc1'),
 'P3':('P12A3-G2-resume-R21-P3-01','22163351751ea9b5e5398af61c13b2b7a1c5a664a5954576fc7213f936e5bdff','e4a01a5843ed1133f1c23171d90a1f824a59f3a37055a5033f925f3bb6284fc1'),
 'P4':('P12A3-G2-resume-G2C3-P4-01','bc46c9e4e516e8e60f4e4334b7d4ca3c055a81c4265909c02680bcededdb07a6','3ee28f908bc1fee93c75e91138ff611c3c9337722460d2352680f460d2a0b963')}
FIXTURES.update({**{'valid_'+l:(l,None) for l in LANES},
 'front_write':('P0','G2_BANK'),'fault_wait':('P1','G2_FAULT'),
 'recovery_missing_pixel':('P4','G2_PIXEL'),'symbol_missing':('P0','G2_IDENTITY'),
 'validator_identity':('P0','G2_IDENTITY'),'unrelated_artifact':('P0','G2_IDENTITY')})
def producer(lane):
    name,mhash,digest=REPLAY_PINS[lane];origin=REPO.parents[1]/'runs'/name
    need(sha(origin/'manifest.json')==mhash,'G2_IDENTITY','pinned replay producer manifest')
    m=read(origin/'manifest.json')
    need(m['run_root']==str(origin) and m['base']==BASE and set(m['cases'])=={lane},'G2_IDENTITY','producer case/path')
    need(m['source_before']==m['source_after'] and hashlib.sha256(json.dumps(m['source_before'],sort_keys=True,separators=(',',':')).encode()).hexdigest()==digest,'G2_IDENTITY','producer source digest')
    for name,h in m['artifacts'].items():
        need(Path(name).name==name and (origin/name).is_file() and not (origin/name).is_symlink() and sha(origin/name)==h,'G2_IDENTITY','immutable producer artifact '+name)
    need(m['cases'][lane]['simulator_exit']==m['cases'][lane]['checker_exit']==0,'G2_IDENTITY','producer semantic/sim status')
    result=read(origin/'result.json')
    if lane=='P0':
        need(result['guard_exit']==result['final_exit']==1 and (origin/'guard.log').read_text().strip()=='G2_REJECT G2_IDENTITY ELF/symbol binding','G2_IDENTITY','P0 historical guard1')
        c2=REPO.parents[1]/'runs'/'P12A3-G2C2-valid-01'
        pins={'validator-context.json':'1b6dfe5dc46809db4eda47c29f586cb317c7c994ad1b6e0f9843a806fbf7bf53','validation.result.json':'b2cf33edc8c8dbeee7a797e0dc4346e1be4ca74124e12c7774f027e3664a8e59','producer.result.json':'9d9291f6ebc14809c5eaafa7fe4c6b85aaad93910c523c16887efca2ea65be22','producer.guard.log':'8fd56d645502354befd8f290bc04f5697e772ad2f01b1b49dc8fa7f9e9150846'}
        need(sha(c2/'manifest.json')==mhash,'G2_IDENTITY','C2 copied producer manifest')
        for n,h in pins.items():need(sha(c2/n)==h,'G2_IDENTITY','pinned C2 validation record '+n)
        for n,h in m['artifacts'].items():need(sha(c2/n)==h,'G2_IDENTITY','C2 copied artifact '+n)
    else:need(result['guard_exit']==result['final_exit']==0,'G2_IDENTITY','historical passing producer result')
    live=source()[1];delta={k for k in set(live)|set(m['source_before']) if live.get(k)!=m['source_before'].get(k)}
    need(delta<= {'verification/independent/p12a3_soc_vga_g2/evidence.py','verification/independent/p12a3_soc_vga_g2/tb_g2.sv'} and live['verification/independent/p12a3_soc_vga_g2/tb_g2.sv']=='a6ac2d0461a5550803c9d6d235542efc2413bed4d12e15b584f9cfa8ef515238','G2_IDENTITY','bounded validator/producer delta')
    return origin,m

def replay_payload(origin,mutation):
    lane,pid=FIXTURES[mutation];m=read(origin/'manifest.json');rawname=m['cases'][lane]['raw'];raw=(origin/rawname).read_text();payload={}
    activation={'kind':'COPIED_OBSERVATION_INPUT','mutation':mutation,'origin':str(origin),'origin_manifest_sha256':sha(origin/'manifest.json'),'origin_raw_sha256':sha(origin/rawname)}
    def change(kind,key,value,predicate=lambda d:True):
        nonlocal raw
        lines=raw.splitlines();indices=[i for i,x in enumerate(lines) if x.startswith(kind+' ') and predicate(fields(x))]
        need(indices,'G2_FIXTURE_REACH',kind);i=indices[0];old=lines[i]
        lines[i]=re.sub(r'\b'+key+r'=\S+',key+'='+str(value),old,count=1)
        need(lines[i]!=old,'G2_FIXTURE_REACH','no change');activation.update(before=old,after=lines[i]);raw='\n'.join(lines)+'\n'
    if mutation=='route':change('G2_FINAL','route',0,lambda d:n(d,'route')==2)
    elif mutation=='request_duplicate':
        line=next(x for x in raw.splitlines() if x.startswith('G2_REQUEST '));raw=raw.replace(line,line+'\n'+line,1);activation.update(before=line,after=line+' [duplicated]')
    elif mutation=='ack_early':change('G2_ACK','edge',n(records(raw,'G2_EXPECT_COMMIT')[0],'edge')-1)
    elif mutation=='orphan_ack':change('G2_ACK','op',999999)
    elif mutation=='clear_bank':change('G2_CLEAR','bank',1-n(records(raw,'G2_CLEAR')[0],'bank'))
    elif mutation=='clear_last_missing':
        line=next(x for x in raw.splitlines() if x.startswith('G2_CLEAR ') and n(fields(x),'addr')==9599);raw=raw.replace(line+'\n','',1);activation.update(before=line,after='[removed]')
    elif mutation=='clear_address':change('G2_CLEAR','addr',8,lambda d:n(d,'addr')==7)
    elif mutation=='done_early':change('G2_DONE','edge',n(records(raw,'G2_OWNER')[0],'edge')-1)
    elif mutation=='w1c':change('G2_W1C','after',n(next(d for d in records(raw,'G2_W1C') if n(d,'mask')==2),'after')|2,lambda d:n(d,'mask')==2)
    elif mutation=='pixel':change('G2_PIXEL','rgb','000' if n(records(raw,'G2_PIXEL')[0],'rgb',16) else 'fff')
    elif mutation=='timing':change('G2_TIMING_SAMPLE','actual_x',33,lambda d:n(d,'actual_x')==32)
    elif mutation=='dmem':change('G2_DMEM','mask',7)
    elif mutation=='fault_response':change('G2_ERROR','resp',0,lambda d:n(d,'ready')==1)
    elif mutation=='fault_cause':change('G2_DMEM','data','00000008',lambda d:n(d,'addr',16)==0x10000004)
    elif mutation=='reset_stale_done':
        c=records(raw,'G2_COMMAND')[0];reset=next(x for x in raw.splitlines() if x.startswith('G2_RESET_ASSERT '));insert=f"G2_DONE epoch={c['epoch']} edge={n(fields(reset),'edge')} op={c['op']} clear=0 front=0"
        raw=raw.replace(reset,reset+'\n'+insert,1);activation.update(before='[no canceled DONE]',after=insert)
    elif mutation=='pll_write_gate':change('G2_LOCK_LOW','we','01')
    elif mutation=='abort_done':change('G2_ABORT','done',1)
    elif mutation=='source':
        key='verification/independent/p12a3_soc_vga_g2/evidence.py';old=m['source_before'][key];m['source_before'][key]=m['source_after'][key]='0'*64;activation.update(before=old,after='0'*64)
    elif mutation=='image':
        name=m['images'][lane]['hex'];old=(origin/name).read_text();payload[name]=(f'{int(old.splitlines()[0],16)^1:08x}\n'+'\n'.join(old.splitlines()[1:])+'\n').encode();activation.update(before=old.splitlines()[0],after=payload[name].decode().splitlines()[0])
    elif mutation=='stale':change('G2_IMAGE','path','stale-origin/P0.hex')
    elif mutation=='omitted':m['cases']={};activation.update(before=lane,after='[omitted]')
    elif mutation=='truncated':
        line=next(x for x in raw.splitlines() if x.startswith('G2_SUMMARY '));raw=raw.replace(line+'\n','',1);activation.update(before=line,after='[truncated summary]')
    elif mutation=='unbound':m['artifacts'].pop(rawname);activation.update(before='bound raw checksum',after='[binding omitted]')
    elif mutation=='front_write':change('G2_CPU_WRITE','bank',1-n(records(raw,'G2_CPU_WRITE')[0],'bank'))
    elif mutation=='fault_wait':change('G2_ERROR','ready',1,lambda d:n(d,'ready')==0)
    elif mutation=='recovery_missing_pixel':
        line=next(x for x in raw.splitlines() if x.startswith('G2_PIXEL ') and fields(x).get('epoch')=='1' and fields(x).get('x')=='639' and fields(x).get('y')=='479')
        raw=raw.replace(line+'\n','',1);activation.update(before=line,after='[removed recovery bottom-right]')
    elif mutation=='symbol_missing':
        name=m['images'][lane]['nm'];text=(origin/name).read_text();line=next(x for x in text.splitlines() if x.split()[-1]=='fault_store');payload[name]=text.replace(line+'\n','',1).encode();activation.update(before=line,after='[removed critical symbol]')
    elif mutation=='unrelated_artifact':
        name=lane+'.compile.log';payload[name]=(origin/name).read_bytes()+b'UNRELATED-CHECKSUM-CONSISTENT-TAMPER\n';activation.update(before=sha(origin/name),after=hashlib.sha256(payload[name]).hexdigest())
    elif mutation=='validator_identity':activation.update(before='actual validator map',after='counterfeit validator map')

    payload[rawname]=raw.encode()
    for name,data in payload.items():
        if name in m['artifacts']:m['artifacts'][name]=hashlib.sha256(data).hexdigest()
    return m,payload,activation

def replay_identity(root,m,live):
    need(root.name.startswith('P12A3-G2-resume-R23-') and root.parent==REPO.parents[1]/'runs' and not (root/'validator-context.json').exists(),'G2_IDENTITY','R23 explicit replay scope')
    c=read(root/'replay-context.json');mutation=c['mutation']
    need(c['kind']=='R23_IMMUTABLE_PRODUCER_SEPARATE_VALIDATOR' and c['validator_source']==live and mutation in FIXTURES,'G2_IDENTITY','R23 validator identity/fixture')
    lane,pid=FIXTURES[mutation];origin,original=producer(lane)
    need(c['origin']==str(origin) and c['origin_manifest_sha256']==sha(origin/'manifest.json') and c['producer_source']==original['source_before'] and c['original_artifacts']==original['artifacts'],'G2_IDENTITY','R23 producer context')
    need(m['source_before']==m['source_after']==original['source_before'],'G2_IDENTITY','counterfeit producer map')
    need(read(root/'producer.result.json')==read(origin/'result.json'),'G2_IDENTITY','copied original producer result')
    if lane=='P0':
        c2=REPO.parents[1]/'runs'/'P12A3-G2C2-valid-01'
        need(c['c2_validation_record_sha256']==sha(c2/'validation.result.json') and read(root/'c2.validation.result.json')==read(c2/'validation.result.json') and read(root/'c2.validator-context.json')==read(c2/'validator-context.json'),'G2_IDENTITY','separate C2 validator lineage')
    expected,payload,activation=replay_payload(origin,mutation)
    allowed={original['cases'][lane]['raw']}
    if mutation=='image':allowed.add(original['images'][lane]['hex'])
    if mutation=='symbol_missing':allowed.add(original['images'][lane]['nm'])
    changed={name for name,data in payload.items() if hashlib.sha256(data).hexdigest()!=original['artifacts'][name]}
    need(changed<=allowed,'G2_IDENTITY','unrelated artifact mutation forbidden')
    need(m==expected and read(root/'activation.json')==activation and c['expected_pid']==pid,'G2_IDENTITY','undeclared manifest or activation delta')
    for name,h in original['artifacts'].items():
        expected_bytes=payload.get(name)
        need((root/name).is_file() and not (root/name).is_symlink() and ( (root/name).read_bytes()==expected_bytes if expected_bytes is not None else sha(root/name)==h),'G2_IDENTITY','undeclared copied artifact delta '+name)
    # Omitted binding is an intentional guard-input fault; normal integrity must
    # still reject it after this exact single-fixture lineage validation.

def replay(origin,root,mutation):
    need(mutation in FIXTURES,'G2_CASE_SET','fixture selection')
    lane,pid=FIXTURES[mutation];pinned,original=producer(lane)
    allowed=[pinned]
    if lane=='P0':allowed.append(REPO.parents[1]/'runs'/'P12A3-G2C2-valid-01')
    need(origin in allowed,'G2_IDENTITY','replay origin selection')
    semantic(pinned,lane)  # Real passing base; not a same-source historical guard.
    need(root.name.startswith('P12A3-G2-resume-R23-'),'G2_SCOPE','R23 replay root');fresh(root)
    for name in original['artifacts']:shutil.copy2(pinned/name,root/name)
    shutil.copy2(pinned/'result.json',root/'producer.result.json')
    validator_before=source()[1]
    context=dict(kind='R23_IMMUTABLE_PRODUCER_SEPARATE_VALIDATOR',mutation=mutation,origin=str(pinned),origin_manifest_sha256=sha(pinned/'manifest.json'),producer_source=original['source_before'],original_artifacts=original['artifacts'],validator_source=validator_before,expected_pid=pid)
    if lane=='P0':
        c2=REPO.parents[1]/'runs'/'P12A3-G2C2-valid-01';context['c2_validation_record_sha256']=sha(c2/'validation.result.json')
        shutil.copy2(c2/'validation.result.json',root/'c2.validation.result.json');shutil.copy2(c2/'validator-context.json',root/'c2.validator-context.json')
    m,payload,activation=replay_payload(pinned,mutation)
    for name,data in payload.items():(root/name).write_bytes(data)
    if mutation=='validator_identity':context['validator_source']=dict(context['validator_source']);context['validator_source']['verification/independent/p12a3_soc_vga_g2/evidence.py']='0'*64
    put(root/'manifest.json',m);put(root/'activation.json',activation);put(root/'replay-context.json',context)
    identity_fault=mutation in ('source','image','omitted','unbound','symbol_missing','validator_identity','unrelated_artifact')
    args=[sys.executable,'-B',HERE/'evidence.py','guard' if identity_fault else 'check',root,lane]
    leaf=command(args,root/'fixture.leaf.log',120)
    guard_exit=command([sys.executable,'-B',HERE/'evidence.py','guard',root,lane],root/'fixture.guard.log',120)
    expected=int(pid is not None)
    need(leaf==guard_exit==expected,'G2_SENSITIVITY_FAILURE','expected exits '+mutation)
    if pid:need('G2_REJECT '+pid+' ' in (root/'fixture.leaf.log').read_text() and 'G2_REJECT '+pid+' ' in (root/'fixture.guard.log').read_text(),'G2_SENSITIVITY_FAILURE','wrong PID '+mutation)
    need(source()[1]==validator_before,'G2_IDENTITY','fixture changed source')
    put(root/'result.json',dict(kind='COPIED_EVIDENCE_NOT_NEW_SIMULATION',mutation=mutation,pid=pid,target_checker_exit=leaf,guard_exit=guard_exit,final_exit=guard_exit,classification='SELFTEST_EXPECTED_REJECTION' if pid else 'VALID_REPLAY_CONTROL',producer_source=original['source_before'],validator_source=source()[1]))
    return guard_exit

def c2_replay(origin,root,mutation):
    need(root.name.startswith('P12A3-G2C2-') and root.parent==REPO.parents[1]/'runs','G2_SCOPE','C2 root')
    need(mutation in ('valid','extra_symbols','image','validator_identity','producer_map','no_context') or mutation in ['missing:'+s for s in CRITICAL_SYMBOLS]+['wrong:'+s for s in CRITICAL_SYMBOLS],'G2_CASE_SET','C2 control selection')
    need(sha(origin/'manifest.json')==C2_PRODUCER_MANIFEST,'G2_IDENTITY','C2 original producer')
    root.mkdir(exist_ok=False)
    original=read(origin/'manifest.json');before=source()[1]
    for p in origin.iterdir():
        if p.is_file():shutil.copy2(p,root/p.name)
    need(all(sha(root/n)==h for n,h in original['artifacts'].items()),'G2_IDENTITY','byte-equivalent copy')
    (root/'result.json').rename(root/'producer.result.json')
    (root/'guard.log').rename(root/'producer.guard.log')
    m=read(root/'manifest.json')
    context=dict(kind='ORIGINAL_PRODUCER_NEW_VALIDATOR_SELFTEST',origin=str(origin),origin_manifest_sha256=sha(origin/'manifest.json'),validator_source=before,copied_origin_sha256=original['artifacts'],mutation=mutation)
    activation=dict(mutation=mutation,origin=str(origin),copy_initially_byte_identical=True)
    if mutation.startswith(('missing:','wrong:')):
        name=mutation.split(':',1)[1];p=root/'P0.nm';lines=p.read_text().splitlines();hits=[i for i,x in enumerate(lines) if x.split()[-1]==name]
        need(len(hits)==1,'G2_FIXTURE_REACH','critical nm activation');i=hits[0];old=lines[i]
        if mutation.startswith('missing:'):lines.pop(i);new='[removed]'
        else:parts=old.split();parts[0]=f'{int(parts[0],16)+4:08x}';new=' '.join(parts);lines[i]=new
        p.write_text('\n'.join(lines)+'\n');m['artifacts'][p.name]=sha(p);activation.update(before=old,after=new)
    elif mutation=='extra_symbols':
        rows=elf_symbol_records(root/'P0.elf');special=[row for row in rows if special_symbol(row)]
        need(special,'G2_FIXTURE_REACH','actual special ELF symbols')
        p=root/'P0.nm';extra=''.join(f"{row['value']:08x} {'a' if row['type']==4 else 't'} {row['name']}\n" for row in special)
        p.write_text(p.read_text()+extra);m['artifacts'][p.name]=sha(p);activation.update(before='default nm hides mapping/file symbols',after=extra,kind='SYNTHETIC_OPTIONAL_NM_REPRESENTATION_NOT_NEW_TOOL_EXECUTION')
    elif mutation=='image':
        p=root/'P0.hex';lines=p.read_text().splitlines();old=lines[0];lines[0]=f'{int(old,16)^1:08x}';p.write_text('\n'.join(lines)+'\n');m['artifacts'][p.name]=sha(p);activation.update(before=old,after=lines[0])
    elif mutation=='validator_identity':
        key='verification/independent/p12a3_soc_vga_g2/evidence.py';context['validator_source']=dict(before);context['validator_source'][key]='0'*64;activation.update(before=before[key],after='0'*64)
    elif mutation=='producer_map':
        key='verification/independent/p12a3_soc_vga_g2/evidence.py';m['source_before']=dict(m['source_before']);m['source_after']=dict(m['source_after']);m['source_before'][key]=m['source_after'][key]=before[key];activation.update(before=original['source_before'][key],after=before[key])
    elif mutation=='no_context':activation.update(before='explicit C2 lineage',after='[omitted context]')
    put(root/'manifest.json',m)
    if mutation!='no_context':put(root/'validator-context.json',context)
    put(root/'activation.json',activation)
    code=command([sys.executable,'-B',HERE/'evidence.py','guard',root,'P0'],root/'validator.guard.log',120)
    expected=0 if mutation in ('valid','extra_symbols') else 1
    need(code==expected,'G2C2_CONTROL_FAILURE',mutation+' exit='+str(code))
    if expected:need('G2_REJECT G2_IDENTITY ' in (root/'validator.guard.log').read_text(),'G2C2_CONTROL_FAILURE','wrong PID')
    after=source()[1];need(before==after,'G2_IDENTITY','validator changed during control')
    put(root/'validator-source-after.json',after)
    put(root/'validation.result.json',dict(kind='VALIDATOR_SELFTEST_NOT_NEW_DUT_SIMULATION',mutation=mutation,producer_simulator_exit=original['cases']['P0']['simulator_exit'],producer_checker_exit=original['cases']['P0']['checker_exit'],producer_historical_guard_exit=read(origin/'result.json')['guard_exit'],new_validator_exit=code,final_exit=code,classification='VALID_P0_REVALIDATION' if expected==0 else 'SELFTEST_EXPECTED_REJECTION',pid='G2_IDENTITY' if expected else None,origin_manifest_sha256=sha(origin/'manifest.json'),copied_manifest_sha256=sha(root/'manifest.json'),validator_source_sha256=hashlib.sha256(json.dumps(after,sort_keys=True,separators=(',',':')).encode()).hexdigest()))
    return code

if __name__=='__main__':
    try:
        mode=sys.argv[1];root=Path(sys.argv[2]).resolve()
        if mode=='run':code=run(root,sys.argv[3].split(',') if len(sys.argv)>3 else LANES)
        elif mode=='check':semantic(root,sys.argv[3]);print('G2_CHECK PASS',sys.argv[3]);code=0
        elif mode=='guard':code=integrity(root,sys.argv[3].split(','));print('G2_GUARD PASS')
        elif mode=='timing-check':code=timing_guard(root.read_text());print('G2_TIMING_GUARD PASS')
        elif mode=='timing-negative':code=timing_negative(Path(sys.argv[3]).resolve(),root)
        elif mode=='replay':code=replay(Path(sys.argv[3]).resolve(),root,sys.argv[4])
        elif mode=='c2-replay':code=c2_replay(Path(sys.argv[3]).resolve(),root,sys.argv[4])
        else:raise ValueError(mode)
    except Exception as e:
        print('G2_REJECT',str(e),flush=True);code=1
    sys.exit(code)
