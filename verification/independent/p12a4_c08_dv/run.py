#!/usr/bin/env python3
"""Fresh external C08 runs; isolated faults never edit canonical production."""
import argparse, hashlib, json, re, subprocess, sys
from pathlib import Path

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--propagate',choices=['leaf','guard']);args=ap.parse_args()
    lane=Path(__file__).resolve().parent;repo=lane.parents[2];run=args.run.resolve()
    if run.exists() or repo==run or repo in run.parents: raise ValueError('fresh external run required')
    run.mkdir(parents=True)
    source=repo/'rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v'
    sources=[source,repo/'rtl/video/vram/HW_Cleaner.v',repo/'rtl/video/vga/VGA_SyncGen.v',repo/'rtl/soc/reset_release_sync.v',repo/'verification/models/memory/VRAM.sv',lane/'pll.sv',lane/'tb.sv']
    inputs=sources+[Path(__file__),lane/'proof_plan.md',repo/'spec/08_vga.md']
    def manifest(): return {str(p.relative_to(repo)):sha(p) for p in inputs}
    def save(n,v): (run/n).write_text(json.dumps(v,indent=2)+'\n')
    pre=manifest();save('source-pre.json',pre);records=[];results=[]
    def execute(name,argv):
        with (run/(name+'.log')).open('wb') as log:
            try: rc=subprocess.run(argv,stdout=log,stderr=subprocess.STDOUT,cwd=repo,timeout=180).returncode
            except subprocess.TimeoutExpired: rc=124
        raw=(run/(name+'.log')).read_text(errors='replace')
        records.append(dict(name=name,argv=argv,exit=rc,log_sha256=sha(run/(name+'.log')),timeout=180))
        save('commands.json',records);return rc,raw
    execute('iverilog-version',['iverilog','-V']);execute('vvp-version',['vvp','-V'])
    text=source.read_text()
    adapter=text.replace('wire diagnostic_cpu_we0 = !use_clear && vram0_we;',
        'wire diagnostic_cpu_we0 = (!use_clear && vram0_we) || (tb.injection == 2);').replace(
        'wire diagnostic_cpu_we1 = !use_clear && vram1_we;',
        'wire diagnostic_cpu_we1 = (!use_clear && vram1_we) || (tb.injection == 1);')
    assert adapter!=text
    discriminator=text.replace('wire diagnostic_cpu_we0 = !use_clear && vram0_we;',
        "wire fixture_pulse = tb.injection == 1 && ((tb.monitor == 4) ? !diagnostic_completion && !error_final : (tb.monitor == 5) ? 1'b1 : diagnostic_completion);\n    wire diagnostic_cpu_we0 = (!use_clear && vram0_we) || (fixture_pulse && tb.monitor == 6);").replace(
        'wire diagnostic_cpu_we1 = !use_clear && vram1_we;',
        'wire diagnostic_cpu_we1 = (!use_clear && vram1_we) || (fixture_pulse && tb.monitor != 6);').replace(
        '(write_addr != data_word_addr)', "((write_addr ^ ((tb.monitor == 2 && tb.injection == 1) ? 14'd1 : 14'd0)) != data_word_addr)").replace(
        '(write_data != HWDATA)', "((write_data ^ ((tb.monitor == 3 && tb.injection == 1) ? 32'd1 : 32'd0)) != HWDATA)").replace(
        '((HRESP == 2\'b00)', "((tb.monitor != 0 || HRESP == 2'b00)")
    variants={'production':text,'monitor_fixture':adapter,
        'discriminator':discriminator,
        'monitor_collision':adapter.replace('if (accepted_status_write && HWDATA[5])','if ((accepted_status_write || tb.injection != 0) && HWDATA[5])'),
        'error_no_wait':text.replace('assign HREADY = !(data_valid && effective_data_rejected) || error_final;', "assign HREADY = 1'b1;"),
        'false_error':text.replace('wire address_rejected = !address_supported ||','wire address_rejected = address_is_fb || !address_supported ||'),
        'port_bank':text.replace('wire cpu_target_bank = ~front_bank_h;', 'wire cpu_target_bank = front_bank_h;'),
        'port_address':text.replace('use_clear ? clear_addr : data_word_addr;', "use_clear ? clear_addr : data_word_addr + 14'd1;"),
        'port_missing':text.replace('(clear_we || accepted_fb_write);', '(clear_we);'),
        'reserved_nonzero':text.replace("{lock_loss_count, 10'h0, is_cdc_sticky,", "{lock_loss_count, 10'h1, is_cdc_sticky,"),
        'no_saturation':text.replace("if (lock_loss_count != 16'hffff)", "if (1'b1)"),
        'count_plus2':text.replace("lock_loss_count + 16'd1","lock_loss_count + 16'd2"),
        'sticky_omitted':adapter.replace("if (diagnostic_fault)\n                is_cdc_sticky <= 1'b1;","if (diagnostic_fault)\n                is_cdc_sticky <= 1'b0;")}
    tests=[('production',0,[],None),('saturation',2,[],None),('monitor_fixture',1,[],None),
           ('monitor_collision',1,[],None),('error_no_wait',0,[],'ERROR_SEQUENCE'),('false_error',0,[],'ERROR_UNEXPECTED'),('port_bank',0,[],'PORT_BANK'),('port_address',0,[],'PORT_ADDRESS'),('port_missing',0,[],'COMMAND_COUNT'),('reserved_nonzero',0,[],'RESERVED'),('no_saturation',2,[],'READ_COUNT'),('count_plus2',0,[],'READ_COUNT'),('sticky_omitted',1,[],'FAULT'),
           ('port_negative',0,['+BAD_PORT=1'],'PORT_DATA'),('read_negative',0,['+WRONG_READ=1'],'READ_COUNT')]
    tests += [(f'discriminator_{i}',1,[f'+MONITOR={i}'],None) for i in range(1,7)]
    if args.propagate:tests=[('port_negative' if args.propagate=='leaf' else 'production',0,['+BAD_PORT=1'] if args.propagate=='leaf' else [],None)]
    for name,mode,plus,expected in tests:
        variant='discriminator' if name.startswith('discriminator_') else name if name in variants else 'production'
        d=run/name;d.mkdir()
        if variant=='production': src=source
        else: src=d/'isolated_dut.v';src.write_text(variants[variant])
        ce,_=execute(name+'-compile',['iverilog','-g2012','-s','tb','-o',str(d/'test')]+[str(src)]+[str(p) for p in sources[1:]])
        rc,raw=execute(name,['vvp',str(d/'test'),f'+LANE={mode}']+plus) if ce==0 else (None,'')
        errors=[];ids=re.findall(r'FAIL_([A-Z_]+)',raw)
        if expected:
            if ce or rc!=1 or ids!=[expected] or 'SUMMARY C08' in raw:errors.append('SPECIFIC_REJECTION')
            if name=='port_negative' and 'ACTIVATE_PORT_DATA' not in raw:errors.append('INJECTION_REACH')
            if name=='read_negative' and 'ACTIVATE_READ_COUNT' not in raw:errors.append('INJECTION_REACH')
            if name=='sticky_omitted' and 'ACTIVATE_MONITOR_INPUT mode=1' not in raw:errors.append('INJECTION_REACH')
        else:
            if ce or rc!=0 or ids: errors.append('TARGET')
            summaries=re.findall(r'SUMMARY C08 checks=(\d+) transfers=(\d+) commands=(\d+) error_waits=(\d+) lane=(\d+)',raw)
            if len(summaries)!=1:errors.append('SUMMARY')
            rows=re.findall(r'^TX id=(\d+) ',raw,re.M)
            guard_raw=raw
            if args.propagate=='guard':
                guard_raw=re.sub(r'^TX .*\n','',raw,count=1,flags=re.M);(run/'guard-input.txt').write_text(guard_raw)
            grows=re.findall(r'^TX id=(\d+) ',guard_raw,re.M)
            if len(summaries)==1:
                n=int(summaries[0][1])
                if len(grows)!=n or [int(x) for x in grows]!=list(range(1,n+1)):errors.append('GUARD_TRACE')
                if int(summaries[0][0])<6 or n<3:errors.append('VACUITY')
                if mode!=2 and (int(summaries[0][2])!=5 or int(summaries[0][3])<5):errors.append('COVERAGE')
            if mode==2 and 'BIN SATURATION_REACHABLE episodes=65536' not in raw:errors.append('SATURATION')
        classification=('SELFTEST_EXPECTED_REJECTION' if expected else 'PASS') if not errors else 'FAIL'
        results.append(dict(name=name,source_sha256=sha(src),mutation_reached=(expected is not None and ce==0 and rc==1 and ids==[expected]),compile_exit=ce,target_exit=rc,guard_exit=int(bool(errors)),final_exit=int(bool(errors)),classification=classification,errors=errors,assertion_ids=ids,log_sha256=sha(run/(name+'.log')) if ce==0 else None))
        save('lanes.json',results)
    post=manifest();save('source-post.json',post)
    failed=pre!=post or any(x['final_exit'] for x in results)
    result=dict(classification='FAIL' if failed else 'PASS_BOUNDED_PORTABLE',source_hashes_unchanged=pre==post,lanes=results,final_exit=int(failed),production_rtl_sha256=sha(source))
    save('result.json',result)
    # Final independent readback verifies saved lane exits, raw logs and actual inputs.
    reread=json.loads((run/'result.json').read_text())
    assert reread==result and manifest()==post
    for x in results:
        if x['log_sha256']: assert sha(run/(x['name']+'.log'))==x['log_sha256']
    print(json.dumps(result));return int(failed)
if __name__=='__main__':sys.exit(main())
