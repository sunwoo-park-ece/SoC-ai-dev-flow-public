#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the checkout}"
python3 - "$root" <<'PY'
from pathlib import Path
import hashlib,json,os,subprocess,sys,shlex,time
repo=Path(sys.argv[1]).resolve();source=Path(os.environ.get('SOC_HEALTH_TEST_SOURCE_ROOT',str(repo))).resolve()
run=Path(os.environ['RUN_ROOT']).resolve()/'soc_health_observer_rtl'
for base in (repo,source):
    if run==base or base in run.parents: raise SystemExit('RUN_ROOT must be outside source checkout')
run.mkdir(parents=True,exist_ok=False)
cfiles=['firmware/services/soc_health.c','firmware/services/soc_health_providers.c','firmware/services/soc_health_observers.c']+[
 'firmware/drivers/'+n+'.c' for n in ('timer','uart','gsensor','adc','joystick_policy','vram','vga_text')]
rtl=['rtl/peripherals/APB_TIMER.v','rtl/peripherals/APB_UART_RT.v','rtl/peripherals/APB_UART_LORA_RT.v',
 'rtl/peripherals/gsensor/APB_GSENSOR_MB.v','rtl/peripherals/gsensor/spi_ee_config.v',
 'rtl/peripherals/APB_ADC_Controller.v','rtl/peripherals/Joystick_Policy.v',
 'rtl/video/vram/pre_fetch_AHB_VRAM_DUAL_BUFFER.v','rtl/video/vram/HW_Cleaner.v',
 'rtl/video/vga/VGA_SyncGen.v','rtl/soc/reset_release_sync.v',
 'verification/models/clock/vga_pll.sv','verification/models/memory/VRAM.sv',
 'verification/directed/firmware/soc_health_observer_top.sv']
cpp='verification/directed/firmware/soc_health_observer_rtl.cpp';mmio='verification/firmware/soc_health_provider_mmio.h'
inputs=cfiles+rtl+[cpp,mmio,'verification/firmware/soc_health_observer_reference.h']+[str(p.relative_to(source)) for p in sorted((source/'firmware/include').glob('*.h'))]
def manifest():return {p:hashlib.sha256((source/p).read_bytes()).hexdigest() for p in inputs}
r=dict(classification='INCOMPLETE',compile_exit=None,target_exit=None,guard_exit=None,final_exit=1,commands=[],source_root=str(source))
def command(args,log,timeout):
    r['commands'].append(args)
    return subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=timeout).returncode
try:
    r['source_pre']=manifest();r['started_epoch']=time.time()
    with (run/'compile.log').open('wb') as log:
        objects=[];rc=0
        for i,f in enumerate(cfiles):
            obj=run/(str(i)+'.o');objects.append(str(obj))
            rc=command(shlex.split(os.environ.get('HOST_CC','gcc'))+['-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-I',str(source/'firmware/include'),'-include',str(source/mmio),'-c',str(source/f),'-o',str(obj)],log,60)
            if rc:break
        if not rc:rc=command(['ar','rcs',str(run/'providers.a')]+objects,log,30)
        if not rc:
            rc=command(['verilator','--cc','--exe','--build','-j','2','-Wno-fatal','--top-module','soc_health_observer_top','--Mdir',str(run/'obj'),'-CFLAGS','-I'+str(source/'firmware/include')+' -I'+str(source/'verification/firmware'),'-LDFLAGS',str(run/'providers.a')]+[str(source/p) for p in rtl]+[str(source/cpp)],log,180)
        r['compile_exit']=rc
    if rc:r.update(classification='FAIL',final_exit=rc)
    else:
        with (run/'target.log').open('wb') as log:r['target_exit']=subprocess.run([str(run/'obj/Vsoc_health_observer_top'),str(run/'frame.pbm')],stdout=log,stderr=subprocess.STDOUT,timeout=90).returncode
        if r['target_exit']:r.update(classification='FAIL',final_exit=r['target_exit'])
        else:
            lines=(run/'target.log').read_text().splitlines()
            expected=['CASE '+c+' PASS' for c in ('real_timer_driver_provider','simulated_uart_serial_loopback','real_gsensor_snapshot_driver_provider','real_adc_hold_joy_driver_provider','real_vga_swap_driver_provider','real_dashboard_raster_serial_same_snapshot')]+['SUMMARY: PASS SOC_HEALTH_S4B_RTL']
            frame=(run/'frame.pbm').read_bytes() if (run/'frame.pbm').exists() else b''
            okay=all(lines.count(l)==1 for l in expected) and r['source_pre']==manifest() and frame.startswith(b'P4\n640 480\n') and len(frame)==38411
            r['frame_sha256']=hashlib.sha256(frame).hexdigest()
            r['guard_exit']=0 if okay else 2
            (run/'guard.log').write_text('PASS asserted integration cases and unchanged sources\n' if okay else 'FAIL missing/duplicate asserted cases or changed sources\n')
            r.update(classification='PASS' if okay else 'FAIL',final_exit=r['guard_exit'])
except Exception as exc:
    (run/'runner_error.log').write_text(repr(exc)+'\n');r.update(classification='FAIL',final_exit=1)
try:
    r['source_post']=manifest();r['source_hashes_unchanged']=r.get('source_pre')==r['source_post']
    if not r['source_hashes_unchanged']:r.update(classification='FAIL',final_exit=r['final_exit'] or 2)
except Exception as exc:r.update(classification='FAIL',final_exit=r['final_exit'] or 1,source_post_error=repr(exc))
for name in ('compile.log','target.log','guard.log'):
    if (run/name).exists():r[name+'_sha256']=hashlib.sha256((run/name).read_bytes()).hexdigest()
r['runner_sha256']=hashlib.sha256((repo/'scripts/wsl/soc_health_observer_rtl_test.sh').read_bytes()).hexdigest()
(run/'result.json').write_text(json.dumps(r,indent=2)+'\n')
(run/'result.md').write_text('# S4-B Real RTL Provider Integration\n\n'+r['classification']+'\n\ncompile/target/guard/final: '+' / '.join(str(r[k]) for k in ('compile_exit','target_exit','guard_exit','final_exit'))+'\n')
(run/'exit_code.txt').write_text(str(r['final_exit'])+'\n');print('SOC_HEALTH_S4B_RTL',r['classification'],str(run));sys.exit(r['final_exit'])
PY
