#!/usr/bin/env python3
"""Selected existing-IP composition; all outputs in a fresh external run root.

Uses real mixed-language AES for CPU smoke/KAT. No structural stub can satisfy
these lanes. Existing component suites keep their historical directed scope.
See verification/selected_ip/README.md for contracts and negative-control lanes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run-root', required=True, type=Path)
    ap.add_argument('--only', choices=['all', 'smoke'], default='all')
    ap.add_argument('--fault', choices=['signature', 'error', 'child', 'guard'])
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()
    run = args.run_root.resolve()
    if run == REPO or REPO in run.parents:
        ap.error('run root must be outside checkout')
    run.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, RUN_ROOT=str(run), PYTHONDONTWRITEBYTECODE='1',
               TMPDIR=str(run))
    result = {'verdict': 'INCOMPLETE', 'target_exit': None, 'guard_exit': None,
              'final_exit': 1, 'fault': args.fault, 'suites': {}, 'commands': []}
    before = {}

    def save(name, value):
        (run / name).write_text(json.dumps(value, indent=2) + '\n')

    def launch(argv, name, cwd=REPO, timeout=180):
        argv = [str(a) for a in argv]
        with (run / (name + '.stdout')).open('wb') as out, \
             (run / (name + '.stderr')).open('wb') as err:
            try:
                rc = subprocess.run(argv, cwd=cwd, env=env, stdout=out,
                                    stderr=err, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                rc = 124
            except OSError as exc:
                err.write(str(exc).encode()); rc = 127
        result['commands'].append({'argv': argv, 'cwd': str(cwd), 'name': name,
                                   'timeout_s': timeout, 'exit': rc})
        save('commands.json', result['commands'])
        return rc, (run / (name + '.stdout')).read_text(errors='replace')

    def must(argv, name, **kw):
        rc, out = launch(argv, name, **kw)
        if rc:
            result['target_exit'] = rc
            raise RuntimeError('CHILD_FAILURE ' + name)
        return out

    def require(ok, why):
        if not ok:
            raise RuntimeError(why)

    def fw_build(manifest):
        out = run / 'firmware'; out.mkdir()
        cc = os.environ.get('CC', 'riscv32-unknown-elf-gcc')
        flags = ['-march=rv32i', '-mabi=ilp32', '-mstrict-align',
                 '-msmall-data-limit=0', '-O2', '-ffreestanding', '-fno-builtin',
                 '-ffunction-sections', '-fdata-sections', '-fno-pic', '-fno-pie',
                 '-Ifirmware/include', '-Wall', '-Wextra']
        objects = []
        for i, src in enumerate(manifest['firmware']):
            obj = out / (str(i) + '.o'); objects.append(obj)
            must([cc, *flags, '-c', src, '-o', obj], 'fw_compile_' + str(i))
        elf = out / 'smoke.elf'
        must([cc, *flags, '-nostartfiles', '-nostdlib', '-Wl,--gc-sections',
              '-T', manifest['linker'], '-Wl,-Map,' + str(out / 'smoke.map'),
              *objects, '-o', elf], 'fw_link')
        symbols = {}
        for line in must(['riscv32-unknown-elf-nm', '-n', elf], 'fw_symbols').splitlines():
            fields = line.split()
            if len(fields) == 3:
                symbols[fields[2]] = int(fields[0], 16)
        for section, name, depth in [('.imem', 'imem', 4096), ('.dmem_init', 'dmem', 8192)]:
            binary = out / (name + '.bin')
            must(['riscv32-unknown-elf-objcopy', '-O', 'binary', '-j', section,
                  elf, binary], 'fw_' + name)
            payload = binary.read_bytes()
            require(len(payload) <= depth * 4, 'FW_IMAGE_OVERFLOW')
            payload += bytes((-len(payload)) % 4)
            words = [int.from_bytes(payload[i:i+4], 'little') for i in range(0, len(payload), 4)]
            fill = 0x13 if name == 'imem' else 0
            words += [fill] * (depth - len(words))
            (out / (name + '.hex')).write_text(''.join('%08x\n' % w for w in words))
        save('fw_symbols.json', symbols)
        return symbols

    try:
        os.chdir(REPO)
        manifest = json.loads((REPO / 'verification/selected_ip/sources.json').read_text())
        # Resolve only explicit files. There is no legacy-top or peripheral glob.
        paths = set(sum((manifest[k] for k in ('verilog', 'vhdl', 'headers', 'firmware')), []))
        paths.add(manifest['linker'])
        for folder in ['verification/selected_ip', 'firmware/include']:
            paths.update(str(p.relative_to(REPO)) for p in (REPO / folder).rglob('*') if p.is_file())
        paths.update(['scripts/wsl/selected_ip_test.py', 'scripts/wsl/p06b_timer_test.sh',
                      'verification/directed/timer/tb_p06b_timer.sv',
                      'verification/firmware/p06b_timer_host.c', 'verification/firmware/p06b_timer_mmio.h',
                      'verification/directed/uart/tb_p07b_uart_direct.sv',
                      'verification/firmware/p07b_uart_host.c', 'verification/firmware/p07b_uart_mmio.h',
                      'verification/firmware/p13_03_aes_host.c', 'verification/firmware/p13_03_aes_mmio.h',
                      'verification/firmware/p04_boardio_mmio.h',
                      'verification/independent/p13_aes_gcm/p13_04_oracle_vectors.py',
                      'verification/independent/p13_aes_gcm/tb_p13_04_apb.sv',
                      'verification/independent/p13_aes_gcm/p13_04_contract_scoreboard.sv'])
        for path in paths:
            require((REPO / path).is_file(), 'MISSING_SOURCE ' + path)
        before = {p: digest(REPO / p) for p in sorted(paths)}
        save('source.before.json', before)
        save('identity.json', {
            'head': must(['git', 'rev-parse', 'HEAD'], 'head').strip(),
            'branch': must(['git', 'branch', '--show-current'], 'branch').strip(),
            'status': must(['git', 'status', '--porcelain=v1', '--untracked-files=all'], 'status'),
            'source_manifest_sha256': digest(REPO / 'verification/selected_ip/sources.json')})
        (run / 'tracked.diff').write_text(must(['git', 'diff', '--binary'], 'diff'))
        for tool, option in [('iverilog', '-V'), ('verilator', '--version'),
                             ('gcc', '--version'), ('riscv32-unknown-elf-gcc', '--version'),
                             ('vsim', '-version')]:
            must([tool, option], 'version_' + tool)
        symbols = fw_build(manifest)
        # Compile/link the actual VHDL core in a fresh library outside Git.
        must(['vlib', run / 'work'], 'vlib')
        must(['vcom', '-2008', '-work', run / 'work', *manifest['vhdl']], 'vcom')
        sv = manifest['verilog'] + ['verification/selected_ip/tb_selected_soc.sv',
                                   'verification/independent/p13_aes_gcm/tb_p13_04_apb.sv',
                                   'verification/independent/p13_aes_gcm/p13_04_contract_scoreboard.sv']
        must(['vlog', '-sv', '-work', run / 'work', *sv], 'vlog')
        do = 'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'
        command = ['vsim', '-c', '-lib', run / 'work', 'tb_selected_soc',
                   '-gIMEM_FILE=' + str(run / 'firmware/imem.hex'),
                   '-gDMEM_FILE=' + str(run / 'firmware/dmem.hex'),
                   '+sig_addr=%x' % symbols['signature'],
                   '+scratch_addr=%x' % symbols['scratch'],
                   '+fault_pc=%x' % symbols['selected_fault'], '-do', do]
        if args.fault in ('signature', 'error'):
            command.append('+inject_' + args.fault)
        text = must(command, 'cpu_smoke', cwd=run)
        require('SUMMARY_PASS SELECTED_CPU_SMOKE' in text and 'ASSERT_FAIL' not in text,
                'CPU_SMOKE_SEMANTIC_REJECTION')
        result['suites']['cpu_selected_real_aes_elaboration'] = 'PASS_BOUNDED'
        if args.only == 'all':
            # Timer's existing directed suite includes controlled near-terminal
            # state; retain historical scope, not independent natural progress.
            text = must(['bash', 'scripts/wsl/p06b_timer_test.sh', 'selected_timer'], 'timer')
            require('SUMMARY: PASS P06B' in text, 'TIMER_SEMANTIC_REJECTION')
            result['suites']['timer'] = 'PASS_DIRECTED'
            must(['iverilog', '-g2012', '-s', 'tb_p07b_uart_direct', '-o', run / 'uart.vvp',
                  'rtl/peripherals/APB_UART_RT.v', 'rtl/peripherals/APB_UART_LORA_RT.v',
                  'verification/directed/uart/tb_p07b_uart_direct.sv'], 'uart_compile')
            text = must(['vvp', run / 'uart.vvp'], 'uart_direct')
            require('SUMMARY: PASS' in text and 'FAIL' not in text, 'UART_SEMANTIC_REJECTION')
            result['suites']['uart_digital'] = 'PASS_DIRECTED'
            for name, sources, include, marker in [
                ('gpio', ['firmware/drivers/gpio.c', 'verification/selected_ip/gpio_host.c'],
                 'verification/firmware/p04_boardio_mmio.h', 'SUMMARY_PASS GPIO_HOST'),
                ('uart', ['firmware/drivers/uart.c', 'firmware/drivers/lora_uart.c',
                          'verification/firmware/p07b_uart_host.c'],
                 'verification/firmware/p07b_uart_mmio.h', 'SUMMARY: PASS')]:
                must(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1',
                      '-Ifirmware/include', '-include', include, *sources,
                      '-o', run / (name + '_host')], name + '_host_compile')
                text = must([run / (name + '_host')], name + '_host')
                require(marker in text, name.upper() + '_HOST_REJECTION')
                result['suites'][name + '_host'] = 'PASS'
            must(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1',
                  '-Ifirmware/include', '-include', 'verification/firmware/p13_03_aes_mmio.h',
                  'firmware/drivers/aes_gcm.c', 'verification/firmware/p13_03_aes_host.c',
                  '-o', run / 'aes_host'], 'aes_host_compile')
            for group, sub in [(1, 0), (2, 0), (3, 0), (4, 0), (4, 1), (5, 0), (6, 0), (5, 1)]:
                text = must([run / 'aes_host', group, sub], 'aes_host_%s_%s' % (group, sub))
                require(text.endswith('CASE_PASS\n') and 'ASSERT_FAIL' not in text, 'AES_HOST_REJECTION')
            result['suites']['aes_trusted_host_sample'] = 'PASS_BOUNDED_8_CASES'
            must([sys.executable, '-B', 'verification/independent/p13_aes_gcm/p13_04_oracle_vectors.py',
                  '--emit', run], 'oracle')
            text = must(['vsim', '-c', '-lib', run / 'work', 'tb_p13_04_apb',
                         '+vectors=' + str(run / 'vectors.txt'), '-do', do], 'actual_aes', cwd=run)
            require('SUMMARY_PASS' in text and 'ASSERT_FAIL' not in text, 'ACTUAL_AES_REJECTION')
            result['suites']['actual_aes_contract_vectors'] = 'PASS_BOUNDED_D08_NOT_PROVEN'
            # Focused lint: structural stub is only a lint boundary, never KAT.
            must(['verilator', '--lint-only', '--sv', '--timing', '--relative-includes',
                  '-Wno-fatal', '--top-module', 'selected_soc', *manifest['verilog'],
                  'verification/models/aes/top_aes_gcm_structural_stub.sv'], 'lint')
            result['suites']['lint_structural_only'] = 'PASS_WITH_WARNINGS'
            must(['iverilog', '-g2012', '-grelative-include', '-s', 'tb_load_extender',
                  '-o', run / 'load.vvp', 'rtl/core/v/mem_stage/LoadExtender.v',
                  'verification/selected_ip/tb_load_extender.sv'], 'load_compile')
            text = must(['vvp', run / 'load.vvp'], 'load_extender')
            require('SUMMARY_PASS LOAD_EXTENDER checks=262144' in text,
                    'LOAD_EXTENDER_SEMANTIC_REJECTION')
            result['suites']['load_extender'] = 'PASS_262144_BINARY_INPUT_CASES'
        if args.fault == 'child':
            must([sys.executable, '-c', 'import sys; print("INJECTION_REACHED CHILD_EXIT"); sys.exit(37)'], 'child_fault')
        if args.selftest:
            if args.only == 'all':
                rc, out = launch([run / 'gpio_host', 'inject'], 'gpio_observation_fault')
                err = (run / 'gpio_observation_fault.stderr').read_text()
                require(rc != 0 and 'INJECTION_REACHED GPIO_DIRECTION_READ' in out
                        and 'dir==0x1237' in err, 'GPIO_NEGATIVE_NOT_DETECTED')
                rc, text = launch(['vvp', run / 'load.vvp', '+inject_load'], 'load_observation_fault')
                require(rc != 0 and 'INJECTION_REACHED LOAD_OBSERVATION' in text
                        and 'ASSERT_FAIL LOAD_EXTEND' in text, 'LOAD_NEGATIVE_NOT_DETECTED')
            for fault, evidence in [('signature', 'ASSERT_FAIL CPU_SIGNATURE'),
                                    ('error', 'ASSERT_FAIL ERROR_PHASE'),
                                    ('child', 'INJECTION_REACHED CHILD_EXIT'),
                                    ('guard', 'GUARD_SOURCE_MISMATCH')]:
                child = run / ('negative_' + fault)
                rc, outer_text = launch([sys.executable, '-B', __file__, '--run-root', child,
                                '--only', 'smoke', '--fault', fault], 'negative_' + fault, timeout=240)
                child_result = json.loads((child / 'result.json').read_text())
                logs = outer_text + ''.join(p.read_text(errors='replace') for p in child.glob('*.stdout'))
                logs += (child / 'result.json').read_text()
                require(rc != 0 and child_result['verdict'] == 'FAIL' and evidence in logs,
                        'NEGATIVE_CONTROL_NOT_PROPAGATED ' + fault)
                require('INJECTION_REACHED' in logs, 'NEGATIVE_CONTROL_NOT_REACHED ' + fault)
            result['selftest'] = ('SIX_EXPECTED_REJECTIONS' if args.only == 'all'
                                  else 'FOUR_EXPECTED_REJECTIONS')
        result['target_exit'] = 0
        after = {p: digest(REPO / p) for p in before}
        save('source.after.json', after)
        recorded = json.loads((run / 'source.before.json').read_text())
        if args.fault == 'guard':
            print('INJECTION_REACHED GUARD_SOURCE', flush=True)
            recorded[next(iter(recorded))] = '0' * 64
            save('source.before.json', recorded)
        require(recorded == after, 'GUARD_SOURCE_MISMATCH')
        result['guard_exit'] = 0
        result['verdict'] = 'PASS_BOUNDED'
        result['final_exit'] = 0
    except Exception as exc:
        result['reason'] = str(exc)
        result['verdict'] = 'FAIL'
        if result['target_exit'] == 0:
            result['guard_exit'] = 1
        result['final_exit'] = result['target_exit'] or 1
    finally:
        # No self-referential result hash. Keep original child stdout separate.
        save('artifacts.json', {str(p.relative_to(run)): digest(p)
                               for p in sorted(run.rglob('*')) if p.is_file()
                               and p.name not in ('artifacts.json', 'result.json')})
        save('result.json', result)
    print(json.dumps({'verdict': result['verdict'], 'final_exit': result['final_exit'],
                      'reason': result.get('reason'), 'run': str(run)}))
    return result['final_exit']


if __name__ == '__main__':
    sys.exit(main())
