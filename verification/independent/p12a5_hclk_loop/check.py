"""Instruction-derived oracle vs pre-edge physical and architectural observations."""
import json,sys,collections
from pathlib import Path
from oracle import interpret
class Failure(Exception):pass
def require(ok,code,detail):
    if not ok:raise Failure(code+': '+str(detail))
def check(out):
    expected=json.loads((out/'expected.json').read_text());events=collections.defaultdict(dict);dump={};summary=None;loss=0;loss_cycles=[]
    require(expected==interpret(json.loads((out/'program.json').read_text())),'ORACLE_IDENTITY','serialized expected differs from independent interpreter')
    for line in (out/'trace.txt').read_text().splitlines():
        a=line.split();tag=a[0]
        if tag=='D':dump[int(a[1])]=int(a[2],16);continue
        if tag=='S':summary=a[1:];continue
        if tag=='L':loss+=1;loss_cycles.append(int(a[1]));continue
        try:vals=[int(v,16) for v in a[2:]]
        except ValueError:raise Failure('KNOWN_OBSERVATION: '+line)
        c=int(a[1]);events[c].setdefault(tag,[]).append(vals)
    require(summary is not None,'COVERAGE_COMPLETE','no final snapshot')
    owner=None;request_i=retire_i=physical=clear_i=fb_i=uart_i=waits=errors=faults=0;trap_actual=[];normal_csr=[];epoch_drop=False;epoch_recovered=False
    uart_expected=[t for t in expected['bus'] if t['addr']==0x40060000 and t['write'] and t['okay']]
    clear_allowed=False;error_first=False;held=None;edge_counts=collections.Counter();address_kinds=[]
    for cycle,rows in sorted(events.items()):
        require('B' in rows and 'W' in rows and 'V' in rows,'COVERAGE_COMPLETE',cycle)
        addr,wr,ht,size,data,mask,ready,resp,rdata=rows['B'][0]
        wen,wa,wd,be=rows['W'][0]
        wantwrite=bool(owner and owner['dmem'] and owner['write'] and owner['okay'])
        require(wen==int(wantwrite),'WRITE_OWNER',dict(cycle=cycle,wen=wen,owner=owner,ready=ready,resp=resp,addr=hex(addr),mask=mask))
        if wantwrite:
            require(wa==(owner['addr']-0x10000000)//4,'WRITE_ADDRESS',(cycle,wa,owner))
            require(be==owner['mask'],'WRITE_LANES',(cycle,be,owner))
            require(wd==owner['payload'],'WRITE_DATA',(cycle,hex(wd),owner))
            physical+=1;edge_counts[owner['pc']]+=1
        if owner and owner['write']:
            require(data==owner['payload'] and mask==owner['mask'],'PAYLOAD_STABLE',(cycle,hex(data),mask,owner))
        if owner:
            require(resp==0 or not owner['okay'],'RESPONSE_CONTRACT',(cycle,owner,resp))
            if resp==1:
                if ready:
                    require(error_first,'RESPONSE_CONTRACT','missing first ERROR')
                    require(not(ht&2),'ERROR_FINAL_CANCEL',(cycle,addr,ht))
                    errors+=1
                else:error_first=True
            if ready:require((resp==0)==owner['okay'],'RESPONSE_CONTRACT',(cycle,owner,resp))
            if held is not None:
                require((data,mask)==held,'PAYLOAD_STABLE',(cycle,held,data,mask))
            held=(data,mask) if not ready and owner['write'] else None
        if 'F' in rows:
            require(owner is not None and not owner['okay'] and ready and resp==1,'FAULT_FINAL',(cycle,owner));faults+=1
        for pa,pwr,pdata,pready,pslverr in rows.get('P',[]):
            require(owner is not None and 0x40000000<=owner['addr']<0x40100000,'APB_ACCEPT',(cycle,pa,owner))
            require(pa==owner['addr'] and pwr==owner['write'],'APB_ACCEPT',(cycle,pa,pwr,owner))
            if pwr:require(pdata==owner['data'],'APB_ACCEPT',(cycle,hex(pdata),owner))
            if not pready:waits+=1
        for udata,ubaud in rows.get('U',[]):
            require(uart_i<len(uart_expected),'UART_POLICY','extra TX')
            require(udata==uart_expected[uart_i]['data'] and ubaud==217,'UART_POLICY',(cycle,udata,ubaud));uart_i+=1
        vw0,vw1,va,vd,lock,epoch,domain,front=rows['V'][0]
        require(front==0 and not vw0,'VGA_PHYSICAL',(cycle,front,vw0))
        require(not(vw0 or vw1) or lock and epoch and domain,'VGA_PHYSICAL',(cycle,lock,epoch,domain))
        if loss_cycles and cycle>=loss_cycles[0] and not epoch:epoch_drop=True
        if epoch_drop and epoch and domain:epoch_recovered=True
        vwrite=bool(owner and owner['okay'] and owner['write'] and 0x20000000<=owner['addr']<=0x200095ff and ready)
        if vwrite:
            require(vw1==1 and va==(owner['addr']-0x20000000)//4 and vd==owner['data'],'VGA_PHYSICAL',(cycle,va,vd,owner));fb_i+=1
        elif vw1:
            require(clear_allowed and clear_i<9600 and va==clear_i and vd==0,'VGA_PHYSICAL',(cycle,clear_i,va,vd));clear_i+=1
        if owner and ready and owner['okay'] and owner['write'] and owner['addr']==0x20010004 and owner['data']&2:clear_allowed=True
        for pc,insn,gpr,rd,value in rows.get('R',[]):
            if pc==expected['terminal']:
                require(retire_i==len(expected['retire']) and insn==0x6f,'RETIRE_ORDER',(cycle,pc,retire_i));continue
            require(retire_i<len(expected['retire']),'RETIRE_ORDER',(cycle,pc))
            e=expected['retire'][retire_i]
            require((pc,insn)==(e['pc'],e['insn']),'RETIRE_ORDER',(cycle,pc,hex(insn),e))
            if e['rd'] and e['value'] is not None:
                require(gpr and rd==e['rd'] and value==e['value'],'GPR_RESULT',(cycle,pc,rd,hex(value),e))
            else:require(not gpr or rd==0,'GPR_RESULT',(cycle,pc,rd))
            retire_i+=1
        for csr,value in rows.get('T',[]):
            if csr in (0x341,0x342):trap_actual.append((csr,value))
        normal_csr.extend(rows.get('C',[]))
        if ready:
            owner=None;held=None;error_first=False
            if ht&2 and resp==0:
                require(request_i<len(expected['bus']),'REQUEST_ORDER',(cycle,hex(addr)))
                owner=expected['bus'][request_i]
                require((addr,bool(wr),1<<size)==(owner['addr'],owner['write'],owner['size']),'REQUEST_ORDER',(cycle,hex(addr),wr,size,owner))
                address_kinds.append('DMEM' if owner['dmem'] else 'APB' if owner['addr']>>28==4 else 'VGA' if owner['addr']>>28==2 else 'DEFAULT');request_i+=1
    require(retire_i==len(expected['retire']) and request_i==len(expected['bus']) and owner is None,'COVERAGE_COMPLETE',(retire_i,len(expected['retire']),request_i,len(expected['bus']),owner))
    wantphysical=[t for t in expected['bus'] if t['dmem'] and t['write'] and t['okay']]
    require(physical==len(wantphysical) and all(edge_counts[t['pc']]==1 for t in wantphysical),'WRITE_EXACTLY_ONCE',(physical,edge_counts))
    require(dump=={i:int.from_bytes(bytes(expected['memory'][i*4:i*4+4]),'little') for i in range(32)},'RAM_IMAGE',dump)
    wanttrap=[item for t in expected['traps'] for item in [(0x341,t['pc']),(0x342,t['cause'])]]
    require(trap_actual==wanttrap,'TRAP_CAUSE_PC',(trap_actual,wanttrap))
    require(normal_csr==expected['normal_csr'],'CSR_EFFECT',(normal_csr,expected['normal_csr']))
    require(errors==faults==sum(not t['okay'] for t in expected['bus']),'FAULT_FINAL',(errors,faults))
    require(uart_i==2 and waits>1000,'UART_POLICY',(uart_i,waits))
    expected_fb=sum(t['okay'] and t['write'] and 0x20000000<=t['addr']<=0x200095ff for t in expected['bus'])
    require(loss==1 and epoch_drop and epoch_recovered and clear_i==9600 and fb_i==expected_fb,'COVERAGE_COMPLETE',(loss,epoch_drop,epoch_recovered,clear_i,fb_i))
    kinds={'DMEM','APB','VGA','DEFAULT'}
    require({(a,b) for a,b in zip(address_kinds,address_kinds[1:]) if a!=b}=={(a,b) for a in kinds for b in kinds if a!=b},'CROSS_SLAVE_COVERAGE',address_kinds)
    reset_cycles,center,enable,baud,mcause,busy,done=[int(v,16) if i else int(v) for i,v in enumerate(summary)]
    require(reset_cycles>=1000000 and center==1234 and enable==0 and baud==217 and not busy and done,'PERIPHERAL_STATE',summary)
    return {'retired':retire_i,'requests':request_i,'physical_writes':physical,'traps':len(expected['traps']),'bus_errors':errors,'uart_wait_cycles':waits,'uart_transmits':uart_i,'vga_fb_writes':fb_i,'vga_clear_writes':clear_i,'pll_losses':loss,'epoch_recovered':epoch_recovered,'reset_cycles':reset_cycles,'cross_slave_transitions':sorted(set(zip(address_kinds,address_kinds[1:])))}
if __name__=='__main__':
    out=Path(sys.argv[1]);result={'status':'INCOMPLETE'}
    try:result={'status':'PASS','coverage':check(out)};code=0
    except (Failure,FileNotFoundError,ValueError,KeyError) as e:result={'status':'FAIL','assertion':str(e)};code=1
    (out/'check.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));raise SystemExit(code)
