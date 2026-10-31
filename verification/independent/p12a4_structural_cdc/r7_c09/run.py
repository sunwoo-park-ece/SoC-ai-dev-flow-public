#!/usr/bin/env python3
"""Bounded R7 lane; no Git/vendor executable and no production mutation."""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', required=True, type=Path)
    ap.add_argument('--failure-propagation', action='store_true')
    ap.add_argument('--guard-drop-pixel', action='store_true',
                    help='isolated observation-input selftest; preserve actual stdout')
    args = ap.parse_args()
    lane = Path(__file__).resolve().parent
    repo = lane.parents[3]
    run = args.run.resolve()
    if run.exists() or run == repo or repo in run.parents:
        raise RuntimeError('fresh external run required')
    dut = repo/'rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v'
    if sha(dut) != 'a63442f93f4566349d37bd480a7803d32f219b95c93860743071cd07d3e22bf1':
        raise RuntimeError('R7 candidate identity mismatch')
    run.mkdir(parents=True)
    sources = [dut, repo/'rtl/video/vram/HW_Cleaner.v', repo/'rtl/video/vga/VGA_SyncGen.v',
               repo/'rtl/soc/reset_release_sync.v', repo/'verification/models/clock/vga_pll.sv',
               repo/'verification/models/memory/VRAM.sv',
               repo/'verification/independent/p12a2_vga_cdc/tb/ahb_vga_bfm.sv', lane/'tb_c09.sv']
    inputs = sources + [Path(__file__).resolve(), lane/'proof_plan.md',
                        repo/'spec/08_vga.md', repo/'spec/06_reset_clock.md']
    def identity():
        return {str(p.relative_to(repo)): sha(p) for p in inputs}
    pre = identity()
    def save(name, value):
        (run/name).write_text(json.dumps(value, indent=2)+'\n')
    save('source-pre.json', pre)
    records = []
    def execute(name, argv):
        with (run/(name+'.stdout')).open('wb') as out, (run/(name+'.stderr')).open('wb') as err:
            try:
                rc = subprocess.run(argv, cwd=repo, stdout=out, stderr=err, timeout=150).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        records.append({'name': name, 'argv': argv, 'cwd': str(repo), 'exit': rc,
                        'timeout_seconds': 150})
        save('commands.json', records)
        raw = (run/(name+'.stdout')).read_text(errors='replace') + (run/(name+'.stderr')).read_text(errors='replace')
        return rc, raw
    execute('iverilog-version', ['iverilog', '-V'])
    execute('vvp-version', ['vvp', '-V'])
    compile_exit, _ = execute('compile', ['iverilog', '-g2012', '-s', 'tb_c09', '-o',
                                         str(run/'test.vvp')] + [str(p) for p in sources])
    cases = [('full', 0, 3, 'NONE'), ('pll', 1, 7, 'NONE'), ('stopped', 2, 0, 'NONE'),
             ('wrong_bank', 0, 3, 'WRONG_BANK'), ('pixel_delay', 0, 3, 'PIXEL_DELAY')]
    if args.failure_propagation:
        cases = [('propagation', 0, 3, 'WRONG_BANK')]
    elif args.guard_drop_pixel:
        cases = [('guard_drop', 0, 3, 'NONE')]
    results = []
    failed = compile_exit != 0
    for name, mode, phase, fault in cases if not failed else []:
        rc, raw = execute(name, ['vvp', '-i', str(run/'test.vvp'), f'+MODE={mode}',
                                f'+PHASE={phase}', '+FAULT='+fault])
        if args.guard_drop_pixel:
            raw, count = re.subn(r'^\[PIXEL\].*\n', '', raw, count=1, flags=re.M)
            (run/'guard-input-fixture.txt').write_text(raw)
            save('guard-injection.json', {'layer':'isolated checker observation input',
                 'removed_pixel_records':count, 'raw_target_stdout_unchanged':True})
            if count != 1:
                raise RuntimeError('guard fault did not reach a pixel record')
        ids = re.findall(r'FAIL_C09_[A-Z_]+', raw)
        errors = []
        coverage = {}
        negative = fault != 'NONE' and not args.failure_propagation
        if negative:
            if rc != 1 or ids != ['FAIL_C09_PIXEL'] or '[FAULT_ACTIVATED]' not in raw or 'C09_TARGET_PASS' in raw:
                errors.append('SENSITIVITY_SPECIFIC_REJECTION')
            classification = 'SELFTEST_EXPECTED_REJECTION' if not errors else 'FAIL'
        else:
            if rc != 0 or ids or raw.count('C09_TARGET_PASS') != 1:
                errors.append('TARGET_SEMANTIC_FAILURE')
            summaries = re.findall(r'\[C09_SUMMARY\] (.*)', raw)
            if len(summaries) != 1:
                errors.append('REQUIRED_SUMMARY')
            else:
                coverage = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', summaries[0])}
                wanted = dict(mode=mode, firsts=4, pixels=256, isolation=64, commits=3,
                              requests=3, writes=6, stop_checks=20 if mode==2 else 0)
                if any(coverage.get(k) != v for k, v in wanted.items()):
                    errors.append('COVERAGE_VALUES')
            rows = re.findall(r'\[PIXEL\] n=(\d+) x=(\d+) y=0 bank=(\d+) word=(\d+) bit=(\d+) expected=([0-9a-f]+) actual=([0-9a-f]+)', raw)
            # Independent second-level coordinate/bit computation, fixed stimulus
            # values are cross-checked against the accepted-write ledger first.
            patterns = [(0x96a53c69,0x5a5ac3c3), (0x96a53c69,0x5a5ac3c3),
                        (0x695ac396,0xa5a53c3c), (0xc35a9695,0x3ca5696a)]
            ledger = re.findall(r'\[WRITE_ORACLE\] bank=(\d+) word=(\d+) data=([0-9a-f]+)',raw)
            expected_ledger = [(1,0,0x96a53c69),(1,1,0x5a5ac3c3),(0,0,0x695ac396),
                               (0,1,0xa5a53c3c),(1,0,0xc35a9695),(1,1,0x3ca5696a)]
            if [(int(a),int(b),int(c,16)) for a,b,c in ledger] != expected_ledger:
                errors.append('ACCEPTED_WRITE_IDENTITY')
            if len(rows) != 256:
                errors.append('PIXEL_TRACE_COUNT')
            for index, row in enumerate(rows):
                n,x,bank,word,bit = map(int,row[:5])
                if (n,x) != (index//64+1,index%64) or not 1<=n<=4:
                    errors.append('PIXEL_TRACE_COORDINATE'); break
                expected_bank = 0 if n==3 else 1
                value = 0xfff if (patterns[n-1][x//32] >> (x%32)) & 1 else 0
                if (bank,word,bit) != (expected_bank,x//32,x%32) or int(row[5],16)!=value or int(row[6],16)!=value:
                    errors.append('PIXEL_TRACE_ORACLE'); break
            if raw.count('[FIRST_PIXEL]') != 4 or raw.count('[FRAME_HANDOFF]') != 3:
                errors.append('FIRST_PIXEL_HANDOFF_TRACE')
            if mode==2 and ('[CLOCK_STOP]' not in raw or '[CLOCK_RESTART] checks=20' not in raw):
                errors.append('STOP_RESTART_REACH')
            classification = 'PASS_DIGITAL_TARGETED' if not errors else 'FAIL'
        results.append({'name': name, 'target_exit': rc, 'guard_exit': int(bool(errors)),
                        'classification': classification, 'errors': errors, 'coverage': coverage,
                        'failure_ids': ids})
        if errors:
            failed = True
            break  # preserve production failure; do not broaden/repair
    post = identity()
    save('source-post.json', post)
    if pre != post:
        failed = True
    result = {'run_id':run.name, 'timestamp_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'source_commit':'86882aa22220de0a8b3c97f67a13bc285036bd6e',
              'source_candidate_sha256':sha(dut), 'compile_exit':compile_exit, 'lanes':results,
              'source_unchanged':pre==post, 'final_exit':int(failed),
              'classification':'FAIL' if failed else 'PASS_DIGITAL_TARGETED',
              'claim_limit':'Portable digital model; no fitted/physical RAM or C08 qualification'}
    save('result.json', result)
    (run/'final_exit.txt').write_text(str(int(failed))+'\n')
    save('artifact-hashes.json', {p.name:sha(p) for p in run.iterdir() if p.is_file()})
    print(json.dumps(result,indent=2), flush=True)
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
