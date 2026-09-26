#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${RUN_ROOT:?Set RUN_ROOT outside the checkout}"
python3 - "$root" <<'PY'
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys
from concurrent.futures import ThreadPoolExecutor
repo=Path(sys.argv[1]).resolve();run=Path(os.environ['RUN_ROOT']).resolve()/'soc_health_board_io_negative'
if run==repo or repo in run.parents:raise SystemExit('RUN_ROOT must be outside checkout')
run.mkdir(parents=True,exist_ok=False)
provider='firmware/services/soc_health_board_io.c';driver='firmware/drivers/hex_display.c'
mutations=[
 ('gpio_output_as_sense',provider,'sense = (gpio_read() >> 1) & 1u;','sense = gpio_read_output() & 1u;'),
 ('gpio_partial_generation',provider,'if (++b->gpio_index == 4u)','if (++b->gpio_index == 1u)'),
 ('mixed_sw_generation',provider,'if (b->pending) return;','if (0) return;'),
 ('led_compare_bypass',provider,'if (b->led_readback != b->sw_value)','if (0)'),
 ('sw_unmasked_getter','firmware/drivers/sw.c','& 0x3ffu',''),
 ('raw_groups_swapped',provider,'group == 1u && i >= 3u','group == 1u && i < 3u'),
 ('raw_polarity_inverted',provider,'raw = (~on) & 0x7fu','raw = on & 0x7fu'),
 ('raw_digit_order',provider,'(i & 1u)','!(i & 1u)'),
 ('raw_bad_stride',provider,'(i * 7u)','(i * 8u)'),
 ('decoder_bad_repeat',provider,'<< 12','<< 8'),
 ('ctrl_disable_bypass',provider,'hex_display_enable(0);','hex_display_enable(1);'),
 ('ctrl_direct_owner_bypass',provider,'hex_display_enable(0);','mmio_write32(HEX_DISPLAY_BASE + HEX_CTRL, 0u);'),
 ('ctrl_shadow_corruption',driver,'return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_LOW) & 0x001fffffu;','hex_ctrl_shadow = 0u; return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_LOW) & 0x001fffffu;'),
 ('getter_wrong_offset',driver,'return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_HIGH) & 0x001fffffu;','return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_LOW) & 0x001fffffu;'),
 ('getter_missing_mask',driver,'return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_LOW) & 0x001fffffu;','return mmio_read32(HEX_DISPLAY_BASE + HEX_RAW_LOW);'),
 ('hex_compare_bypass',provider,'if (fault) failure','if (0) failure'),
]
def fixture(name):
 p=run/name/'source';p.mkdir(parents=True)
 shutil.copytree(repo/'firmware',p/'firmware')
 shutil.copytree(repo/'verification/firmware',p/'verification/firmware')
 (p/'rtl/peripherals').mkdir(parents=True)
 for n in ('APB_GPIO.v','APB_SW.v','APB_LED.v','APB_HEX_display.v'):shutil.copy2(repo/'rtl/peripherals'/n,p/'rtl/peripherals'/n)
 (p/'verification/directed/firmware').mkdir(parents=True)
 for n in ('soc_health_board_io_top.sv','soc_health_board_io_rtl.cpp'):shutil.copy2(repo/'verification/directed/firmware'/n,p/'verification/directed/firmware'/n)
 return p
def execute(name,p,rtl=False,compiler=None):
 out=run/name/'evidence';env=dict(os.environ,RUN_ROOT=str(out),SOC_HEALTH_TEST_SOURCE_ROOT=str(p))
 if compiler:env['HOST_CC']=str(compiler)
 script='soc_health_board_io_rtl_test.sh' if rtl else 'soc_health_board_io_test.sh'
 with (run/name/'parent.log').open('wb') as log:
  rc=subprocess.run(['bash',str(repo/'scripts/wsl'/script)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300).returncode
 result=json.loads((out/('soc_health_board_io_rtl' if rtl else 'soc_health_board_io')/'result.json').read_text())
 leaf=result['target_exit'];guard=result['guard_exit']
 okay=rc!=0 and result['classification']=='FAIL' and result['final_exit']==rc
 tags={'gpio_output_as_sense':'GPIO_SENSE_REJECT','gpio_partial_generation':'NO_PARTIAL_GPIO',
       'mixed_sw_generation':'CAPTURE_RETAINED','led_compare_bypass':'LED_MISMATCH_FAIL',
       'sw_unmasked_getter':'DIRECT_SW_MASK','raw_groups_swapped':'HEX_DIGIT_EXTERNAL_ORACLE',
       'raw_polarity_inverted':'HEX_DIGIT_EXTERNAL_ORACLE','raw_digit_order':'HEX_DIGIT_EXTERNAL_ORACLE',
       'raw_bad_stride':'GENERATION_CONSUMED','decoder_bad_repeat':'HEX_DECODE_NIBBLE',
       'ctrl_disable_bypass':'HEX_STAYS_DISABLED','ctrl_direct_owner_bypass':'HEX_STAYS_DISABLED','ctrl_shadow_corruption':'GETTER_SHADOW_PRESERVED',
       'getter_wrong_offset':'RAW_HIGH_OFFSET_MASK','getter_missing_mask':'RAW_LOW_OFFSET_MASK',
       'hex_compare_bypass':'HEX_MISMATCH_FAIL','rtl_bad_stride':'HEX_SEGMENT_ORACLE'}
 if name in tags:
  target=(out/('soc_health_board_io_rtl' if rtl else 'soc_health_board_io')/'target.log').read_text()
  okay=okay and result['compile_exit']==0 and leaf==1 and 'ASSERT '+tags[name] in target
 elif name=='compile_failure':okay=okay and result['compile_exit']==1 and leaf is None
 elif name=='guard_failure':okay=okay and leaf==0 and guard==2 and rc==2
 row=dict(name=name,parent_exit=rc,compile_exit=result['compile_exit'],leaf_exit=leaf,guard_exit=guard,classification=result['classification'],rejected=okay)
 (run/name/'verdict.json').write_text(json.dumps(row,indent=2)+'\n');return row
def mutant(m):
 name,file,old,new=m;p=fixture(name);f=p/file;s=f.read_text()
 if old not in s:raise RuntimeError('mutation anchor absent: '+name)
 f.write_text(s.replace(old,new,1));(run/name/'mutation.json').write_text(json.dumps(dict(file=file,old=old,new=new,sha256=hashlib.sha256(f.read_bytes()).hexdigest()),indent=2)+'\n')
 return execute(name,p)
rows=[]
with ThreadPoolExecutor(max_workers=3) as pool:
 for row in pool.map(mutant,mutations):rows.append(row);print(row,flush=True)
# Real RTL segment/output checker must reject packing even when register readback
# and the provider's own expected command agree with the erroneous packing.
p=fixture('rtl_bad_stride');f=p/provider;f.write_text(f.read_text().replace('(i * 7u)','(i * 6u)',1));rows.append(execute('rtl_bad_stride',p,rtl=True));print(rows[-1],flush=True)
p=fixture('compile_failure');rows.append(execute('compile_failure',p,compiler='/bin/false'));print(rows[-1],flush=True)
# Successful synthetic target with an incomplete set of asserted markers tests
# guard->parent propagation separately from real leaf failures above.
p=fixture('guard_failure');fake=run/'guard_failure'/'fake_cc.py'
fake.write_text('''#!/usr/bin/env python3
import pathlib,sys
p=pathlib.Path(sys.argv[sys.argv.index('-o')+1])
p.write_text("#!/bin/sh\\necho 'SUMMARY: PASS SOC_HEALTH_S4A'\\nexit 0\\n")
p.chmod(0o755)
''');fake.chmod(0o755);rows.append(execute('guard_failure',p,compiler=fake));print(rows[-1],flush=True)
ok=all(r['rejected'] for r in rows)
(run/'result.json').write_text(json.dumps(dict(classification='PASS' if ok else 'FAIL',cases=rows,final_exit=0 if ok else 1),indent=2)+'\n')
(run/'result.md').write_text('# S4-A isolated negative fixtures\n\n'+('PASS' if ok else 'FAIL')+'\n\n'+ '\n'.join(r['name']+': '+str(r) for r in rows)+'\n')
(run/'exit_code.txt').write_text('0\n' if ok else '1\n')
sys.exit(0 if ok else 1)
PY
