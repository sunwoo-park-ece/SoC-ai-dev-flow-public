#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the public checkout}"
python3 - "$repo_root" <<'PY'
import hashlib, json, os, shlex, subprocess, sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
source = Path(os.environ.get('SOC_HEALTH_TEST_SOURCE_ROOT', str(repo))).resolve()
run = Path(os.environ['RUN_ROOT']).resolve() / 'soc_health_observers'
for base in (repo, source):
    if run == base or base in run.parents:
        raise SystemExit('RUN_ROOT must be outside source checkouts')
run.mkdir(parents=True, exist_ok=False)  # never overwrite previous evidence
inputs = ['firmware/include/soc_health.h', 'firmware/services/soc_health.c',
          'firmware/services/soc_health_probes.c', 'firmware/services/soc_health_render.c', 'firmware/services/soc_health_providers.c',
          'firmware/include/soc_health_providers.h', 'firmware/include/soc_memory_map.h', 'firmware/include/soc_mmio.h',
          'firmware/drivers/timer.c', 'firmware/drivers/uart.c', 'firmware/drivers/gsensor.c',
          'firmware/drivers/adc.c', 'firmware/drivers/joystick_policy.c', 'firmware/drivers/vram.c',
          'firmware/include/timer.h', 'firmware/include/uart.h', 'firmware/include/gsensor.h',
          'firmware/include/adc.h', 'firmware/include/joystick_policy.h', 'firmware/include/vram.h',
          'verification/firmware/soc_health_observer_host.c', 'verification/firmware/soc_health_provider_host.c',
          'firmware/services/soc_health_board_io.c', 'firmware/include/soc_health_board_io.h',
          'firmware/drivers/gpio.c', 'firmware/drivers/sw.c', 'firmware/drivers/led.c', 'firmware/drivers/hex_display.c',
          'firmware/include/gpio.h', 'firmware/include/sw.h', 'firmware/include/led.h', 'firmware/include/hex_display.h',
          'firmware/services/soc_health_observers.c', 'firmware/include/soc_health_observers.h',
          'firmware/drivers/vga_text.c', 'firmware/include/vga_text.h', 'verification/firmware/soc_health_observer_reference.h', 'verification/firmware/soc_health_provider_mmio.h']
def manifest():
    return {p: hashlib.sha256((source / p).read_bytes()).hexdigest() for p in inputs}
result = dict(classification='INCOMPLETE', compile_exit=None, target_exit=None,
              guard_exit=None, final_exit=1, source_root=str(source))
try:
    before = manifest()
    result['source_pre'] = before
    command = shlex.split(os.environ.get('HOST_CC', 'gcc')) + [
        '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
        '-fsanitize=undefined', '-fno-sanitize-recover=all',
        '-I', str(source / 'firmware/include'), '-include',
        str(source / 'verification/firmware/soc_health_provider_mmio.h')]
    command += [str(source / p) for p in inputs if p.endswith('.c') and p != 'verification/firmware/soc_health_provider_host.c']
    command += ['-o', str(run / 'test')]
    result['compile_command'] = command
    with (run / 'compile.log').open('wb') as log:
        result['compile_exit'] = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=60).returncode
    if result['compile_exit'] != 0:
        result.update(classification='FAIL', final_exit=result['compile_exit'])
    else:
        with (run / 'target.log').open('wb') as log:
            result['target_exit'] = subprocess.run([str(run / 'test')], stdout=log, stderr=subprocess.STDOUT, timeout=30).returncode
        if result['target_exit'] != 0:
            result.update(classification='FAIL', final_exit=result['target_exit'])
        else:
            lines = (run / 'target.log').read_text().splitlines()
            expected = ['CASE ' + name + ' PASS' for name in (
                'timer_transactions', 'uart_framing_resync', 'gsensor_sequences',
                'adc_joy_coherence', 'vga_fresh_ownership', 'provider_fairness_snapshot', 'exact_formatter_bounds_states',
                'coherent_frame_uart_swap_immutability', 'observer_timeouts_abort_leases_backlog', 'qualified_sequence_snapshot_details',
                'real_observer_all_provider_fairness')] + ['SUMMARY: PASS SOC_HEALTH_S4B']
            after = manifest()
            result['source_post'] = after
            result['source_hashes_unchanged'] = before == after
            accepted = all(lines.count(line) == 1 for line in expected) and before == after
            result['guard_exit'] = 0 if accepted else 2
            (run / 'guard.log').write_text('PASS: all required asserted cases, unique summary and actual source hashes\n' if accepted
                                          else 'FAIL: missing/duplicate case, summary or changed source hashes\n')
            result.update(classification='PASS' if accepted else 'FAIL', final_exit=result['guard_exit'])
except Exception as exc:
    (run / 'runner_error.log').write_text(repr(exc) + '\n')
    result.update(classification='FAIL', final_exit=1)
try:
    post = manifest()
    result['source_post'] = post
    result['source_hashes_unchanged'] = result.get('source_pre') == post
    if not result['source_hashes_unchanged']:
        result.update(classification='FAIL', final_exit=result['final_exit'] or 2)
except Exception as exc:
    result.update(classification='FAIL', final_exit=result['final_exit'] or 1)
    result['source_post_error'] = repr(exc)
for name in ('compile.log', 'target.log', 'guard.log'):
    path = run / name
    if path.exists(): result[name + '_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
result['runner_sha256'] = hashlib.sha256((repo / 'scripts/wsl/soc_health_observer_test.sh').read_bytes()).hexdigest()
(run / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
(run / 'result.md').write_text('# SOC_HEALTH_S4B Host Result\n\n' + result['classification'] +
                            '\n\ncompile/target/guard/final exits: ' +
                            '/'.join(str(result[k]) for k in ('compile_exit','target_exit','guard_exit','final_exit')) + '\n')
(run / 'exit_code.txt').write_text(str(result['final_exit']) + '\n')
print('SOC_HEALTH_S4B ' + result['classification'] + ': ' + str(run))
sys.exit(result['final_exit'])
PY
