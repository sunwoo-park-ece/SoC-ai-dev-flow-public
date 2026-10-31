"""Independent program/byte-addressed architectural oracle; no DUT data inputs."""
import json
from pathlib import Path
MASK=0xffffffff
def generate(out):
    ops={}; pc=0
    def emit(kind,**kw):
        nonlocal pc
        d=dict(kind=kind,**kw)
        if kind=='lui': code=kw['imm']<<12|kw['rd']<<7|0x37
        elif kind=='addi':code=(kw['imm']&4095)<<20|kw['rs']<<15|kw['rd']<<7|0x13
        elif kind=='load':code=(kw['off']&4095)<<20|kw['rs']<<15|kw['f3']<<12|kw['rd']<<7|3
        elif kind=='store':
            i=kw['off']&4095;code=(i>>5)<<25|kw['rs2']<<20|kw['rs']<<15|kw['f3']<<12|(i&31)<<7|0x23
        elif kind=='csr':code=kw['csr']<<20|kw['rs']<<15|kw['f3']<<12|kw['rd']<<7|0x73
        elif kind=='mret':code=0x30200073
        elif kind=='end':code=0x0000006f
        else:raise ValueError(kind)
        d['insn']=code;ops[pc]=d;pc+=4
    def li(rd,val):
        val&=MASK;hi=(val+2048)>>12;lo=val-(hi<<12)
        if hi:emit('lui',rd=rd,imm=hi&0xfffff);emit('addi',rd=rd,rs=rd,imm=lo)
        else:emit('addi',rd=rd,rs=0,imm=lo)
    def st(rs,off,f3=2):emit('store',rs=rs,rs2=2,off=off,f3=f3)
    def ld(rd,rs,off,f3=2):emit('load',rd=rd,rs=rs,off=off,f3=f3)
    def fault(kind,rs,off,f3=2):
        emit('addi',rd=25,rs=25,imm=1) # older WB must survive
        if kind=='store':st(rs,off,f3)
        else:ld(20,rs,off,f3)
        st(1,64) # younger address must never be accepted on final ERROR
        emit('addi',rd=26,rs=0,imm=66) # younger architectural effect must be killed
    li(29,4096);emit('csr',csr=0x305,rd=0,rs=29,f3=1)
    for rd,val in [(1,0x10000000),(11,0x40050000),(12,0x40060000),(13,0x20000000),(14,0x20010000),(15,0x50000000),(20,0x55)]:li(rd,val)
    for _ in range(64):emit('addi',rd=0,rs=0,imm=0) # natural VGA epoch qualification
    li(2,0x89abcdef);st(1,0)
    for off in range(4):
        li(2,0x80+off);st(1,off,0);ld(3,1,off,0);ld(4,1,off,4);ld(5,1,0)
    for off,val in [(0,0x8001),(2,0xfedc)]:
        li(2,val);st(1,off,1);ld(6,1,off,1);ld(7,1,off,5);ld(8,1,0)
    li(2,0x12345678);st(1,4);st(1,8);st(1,12);st(1,0,0);st(1,2,1);ld(9,1,0)
    for kind,off,f3 in [('store',1,1),('store',3,1),('store',1,2),('store',2,2),('store',3,2),('load',1,1),('load',1,2)]:fault(kind,1,off,f3)
    li(2,1234);st(11,0x40);ld(10,11,0x40)
    li(2,0);st(11,12)
    li(2,9);fault('store',11,12) # reserved bit + ENABLE: illegal acceptance would be observable
    fault('store',15,0);fault('load',15,0)
    li(2,65535);st(12,12);ld(16,12,12)
    li(2,217);st(12,12);li(2,216);st(12,12);ld(16,12,12)
    li(2,0);st(12,12);ld(16,12,12)
    li(2,0xa5);st(12,0);li(2,0x5a);st(12,0);st(1,20);ld(17,1,20)
    li(2,0x12345678);st(13,0)
    fault('load',13,0);fault('store',13,0,0);fault('load',14,4)
    fault('store',13,4) # external PLL model lock loss between address and commit
    for _ in range(64):emit('addi',rd=0,rs=0,imm=0)
    # Close every directed pair among DMEM, APB, VGA and default/error owners.
    ld(10,11,0x40);st(13,8);ld(10,11,0x40)
    fault('load',15,0);st(13,12);fault('store',15,0)
    st(1,28);fault('load',15,0);ld(16,12,12)
    li(2,0);st(14,4);li(2,2);st(14,4) # legal NOP control and real clear
    fault('store',13,0) # busy rejection while cleaner runs naturally
    li(2,0x76543210);st(1,24);ld(18,1,24)
    terminal=pc;emit('end')
    pc=4096
    emit('csr',csr=0x341,rd=30,rs=0,f3=2);emit('addi',rd=30,rs=30,imm=12)
    emit('csr',csr=0x341,rd=0,rs=30,f3=1);emit('csr',csr=0x342,rd=31,rs=0,f3=2);emit('mret')
    image=[0x13]*(max(ops)//4+1)
    for p,d in ops.items():image[p//4]=d['insn']
    (out/'program.hex').write_text(''.join(f'{i:08x}\n' for i in image))
    spec={'ops':ops,'terminal':terminal,'pll_loss_address':0x20000004};(out/'program.json').write_text(json.dumps(spec,indent=2))
    return interpret(spec)
def interpret(spec):
    ops={int(k):v for k,v in spec['ops'].items()};regs=[0]*32;mem=bytearray(128);csr={0x305:0,0x341:0,0x342:0};pc=0
    retires=[];bus=[];traps=[];normal_csr=[];adc_center=2048;adc_enable=0;baud=434;clearing=False
    while pc!=spec['terminal']:
        op=ops[pc];k=op['kind'];rd=op.get('rd',0);value=None;nextpc=pc+4;cause=0
        if k=='lui':value=op['imm']<<12
        elif k=='addi':value=regs[op['rs']]+op['imm']
        elif k=='csr':
            value=csr.get(op['csr'],0)
            if op['f3']==1:
                csr[op['csr']]=regs[op['rs']];normal_csr.append([op['csr'],regs[op['rs']]])
        elif k=='mret':nextpc=csr[0x341]
        elif k in ('store','load'):
            write=k=='store';f3=op['f3'];size=1<<(f3&3);addr=(regs[op['rs']]+op['off'])&MASK;data=regs[op.get('rs2',0)]
            if addr%size:cause=6 if write else 4
            else:
                dmem=0x10000000<=addr<0x10008000
                adc=addr==0x40050040 or addr==0x4005000c
                uart=addr in (0x40060000,0x4006000c)
                fb=0x20000000<=addr<=0x200095ff
                control=addr==0x20010004
                okay=dmem or size==4 and (adc and (not write or addr!=0x4005000c or data<8) or uart or control and write or fb and write and addr!=0x20000004 and not clearing)
                cause=0 if okay else (7 if write else 5)
                lane=sum(1<<b for b in range(addr%4,addr%4+size))
                payload=int.from_bytes((data&((1<<(8*size))-1)).to_bytes(size,'little')*(4//size),'little')
                tx={'pc':pc,'addr':addr,'write':write,'size':size,'data':data,'mask':lane if write else 0,'payload':payload if write else 0,'okay':okay,'dmem':dmem}
                bus.append(tx)
                if okay:
                    if dmem:
                        off=addr-0x10000000
                        if write:mem[off:off+size]=(data&((1<<(8*size))-1)).to_bytes(size,'little')
                        else:value=int.from_bytes(mem[off:off+size],'little',signed=f3<4)
                    elif adc:
                        if write:
                            if addr==0x40050040:adc_center=data&4095
                            else:adc_enable=data&1
                        else:value=adc_center if addr==0x40050040 else adc_enable
                    elif uart:
                        if addr==0x4006000c:
                            if write and data&65535>=217:baud=data&65535
                            elif not write:value=baud
                    elif control and data&2:clearing=True
        else:raise ValueError(op)
        if cause:
            csr[0x341]=pc;csr[0x342]=cause;traps.append({'pc':pc,'cause':cause});pc=csr[0x305];continue
        if value is not None:regs[rd]=value&MASK
        regs[0]=0
        retires.append({'pc':pc,'insn':op['insn'],'rd':rd,'value':(value&MASK) if value is not None else None})
        pc=nextpc
        assert len(retires)<2000
    return {'retire':retires,'bus':bus,'traps':traps,'normal_csr':normal_csr,'memory':list(mem),'terminal':spec['terminal'],'adc_center':adc_center,'adc_enable':adc_enable,'baud':baud}
