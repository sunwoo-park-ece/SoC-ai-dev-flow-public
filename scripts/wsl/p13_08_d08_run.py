import hashlib, json, os, pathlib as P, re, subprocess as S, sys, time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
p=P.Path(__file__).resolve().parents[2]
mode=sys.argv[1] if len(sys.argv)==2 else ''
if mode not in ('smoke','owner-long'):
 raise SystemExit('usage: p13_08_d08_run.py {smoke|owner-long}')
r=P.Path(os.environ['RUN_ROOT']).resolve()
if r.parent != p.parents[1]/'runs/p13_aes_phase08':
 raise SystemExit('RUN_ROOT must name a new Phase08 run directory')
r.mkdir()
t=P.Path(os.environ['MODELSIM_BIN']).resolve()
env=dict(os.environ,TMPDIR=str(r),PYTHONDONTWRITEBYTECODE='1',GIT_OPTIONAL_LOCKS='0')
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
def save(n,o):(r/n).write_text(json.dumps(o,indent=2,sort_keys=True)+'\n')
def src():
 names=S.check_output(['git','-C',p,'ls-files'],env=env,text=True).splitlines()
 return {n:sha(p/n) for n in names}
def launch(n,a,wanted=0):
 a=list(map(str,a));start=time.monotonic()
 with (r/(n+'.stdout')).open('wb') as out,(r/(n+'.stderr')).open('wb') as err:
  try:
   rc=S.run(a,cwd=r,env=env,stdout=out,stderr=err,timeout=(int(os.environ.get('D08_TIMEOUT_SECONDS','86400')) if n=='icb_owner' else 120)).returncode
  except S.TimeoutExpired:
   rc=124
 with (r/'commands.jsonl').open('a') as f:f.write(json.dumps(dict(name=n,argv=a,exit=rc,expected=wanted,seconds=time.monotonic()-start))+'\n')
 if rc!=wanted:raise RuntimeError(f'{n} exit {rc}, expected {wanted}')
 return (r/(n+'.stdout')).read_text(errors='replace')
def check(v,n):
 if not v:raise RuntimeError(n)
def simulate(n,lib,top,args=(),wanted=0):
 do=f'onerror {{quit -code 2}}; onbreak {{quit -code 1}}; run -all; if {{[examine -radix unsigned /{top}/completed] != 1}} {{quit -code 1}}; quit -code 0'
 return launch(n,[t/'vsim','-c','-onfinish','stop','-l',r/(n+'.transcript'),'-wlf',r/(n+'.wlf'),'-lib',lib,top,'-do',do,*args],wanted)
before=src();save('source.before.json',before)
base='2e706e690c4dd8ed6f951c7bb5f587109463b074'
production=('rtl', 'firmware', 'fpga', 'scripts/wsl/source_list.py',
            'verification/independent/p13_aes_gcm',
            'verification/directed/p13_aes_rtl/tb_p13_02_apb.sv',
            'verification/directed/p13_aes_rtl/p13_02_contract_checker.sv',
            'verification/directed/p13_aes_rtl/fixtures')
def pin_inputs():
 S.run(['git','-C',p,'diff','--exit-code',base,'--',*production],check=True)
 extra=S.check_output(['git','-C',p,'ls-files','--others','--exclude-standard','--',*production],text=True)
 check(not extra,'UNTRACKED_PRODUCTION_INPUT')

(r/'plan.txt').write_text("""Independent D08 oracle: all-ones low 32 bits are required for genuine overflow. Start/reset reload 1 and upper 96-bit IV is separate, at most one increment/PCLK and ECB busy can only slow it. From 1 to FFFFFFFF needs 4,294,967,294 increments in one uninterrupted epoch, plus registered overflow observation. At 50MHz absolute lower bound ~85.9 s of hardware clock, not simulator wall time. One-block legal traffic normally stops on terminal, invalid LEN never starts, BUSY commands cannot extend payload, system reset/zeroize do not preserve a counter epoch. ST_WAIT_RESULT has no unconditional architectural upper bound if core progress fails, so bounded tests cannot prove universal unreachability.
Actual lane: unmodified 14 VHDL+wrapper, P04 68 KATs and existing legal external BUSY/abort/recovery controls, all-ones externally supplied IV AESGCM KAT, long idle, passive pin observation. Expected no overflow within sample and no stale status/outputs after reset. Report measured epoch bound, never as universal proof.
Isolated lane: existing P02 wrapper fixture in separate library (no VHDL DUT here), externally scheduled fixture callbacks + concurrent overflow/success and late callback. Contract status 0x11a, TAG_OK 0, output registers clear, bounded reset and next independent operation admitted. Valid fixture control then observation-only mutation toggles TAG_OK in sampled terminal status, assertion OVERFLOW_TERMINAL and target 1; parent guard confirms reach, exact failure and exit. Never claim actual core overflow from fixture.
""")
try:
 pin_inputs()
 save('source_identity.json',dict(head=S.check_output(['git','-C',p,'rev-parse','HEAD'],text=True).strip(),
     status=S.check_output(['git','--no-optional-locks','-C',p,'status','--porcelain=v1','-uall'],text=True)))
 launch('ghdl_version',['ghdl','--version'])
 core=p/'rtl/peripherals/aes_gcm/pipe0'
 icb_tb=p/'verification/directed/p13_aes_rtl/p13_08_d08_icb_tb.vhd'
 save('new_inputs.json',{str(f.relative_to(p)):sha(f) for f in (icb_tb,P.Path(__file__).resolve())})
 flags=['--std=08','-fsynopsys']
 launch('icb_analyze',['ghdl','-a',*flags,core/'aes_pkg.vhd',core/'gcm_pkg.vhd',core/'aes_icb.vhd',icb_tb])
 launch('icb_elaborate',['ghdl','-e',*flags,'p13_08_d08_icb_tb'])
 icb=['ghdl','-r',*flags,'p13_08_d08_icb_tb']
 check('ICB_NOT_REACHED edge=000000040' in launch('icb_smoke',icb),'ICB_SMOKE_RECEIPT')
 neg=launch('icb_negative',icb+['-gnegative=true'],1)
 check('INJECTION_REACHED ICB_EARLY_OVERFLOW' in neg and 'ICB_OVERFLOW_EDGE' in neg,'ICB_NEGATIVE_RECEIPT')
 a=p/'verification/independent/p13_aes_gcm'
 b=p/'verification/directed/p13_aes_rtl'
 rtl=p/'rtl/peripherals/aes_gcm/pipe0/apb_aes_gcm_ip.v'
 launch('oracle',[sys.executable,'-B',a/'p13_04_oracle_vectors.py','--check',a/'p13_04_vectors.json','--emit',r])
 grouped=launch('source_list',[sys.executable,'-B',p/'scripts/wsl/source_list.py','OPEN_SIM_MIXED_MODELSIM','--group'])
 vhdl=[s for g,s in (l.split('\t') for l in grouped.splitlines()) if g=='aes_vhdl_dependency_order']
 check(len(vhdl)==14,'VHDL_IDENTITY')
 launch('sim_version',[t/'vsim','-version'])
 raw=(a/'tb_p13_04_apb.sv').read_text()
 needle='  // Passive observations only.'
 check(raw.count(needle)==1,'TB_ANCHOR')
 extra='''  integer epoch_start=-1, epochs_started=0, epochs_closed=0, max_window=0;
  always @(posedge PCLK) begin
    if(PRESETn && dut.core_icb_overflow===1'b1) $fatal(1,"UNEXPECTED_ACTUAL_OVERFLOW");
    if (!PRESETn || dut.core_soft_reset_reg || dut.core_icb_stop_reg) begin
      if(epoch_start>=0) begin
        if(cycle-epoch_start>max_window) max_window=cycle-epoch_start;
        epochs_closed=epochs_closed+1;
        epoch_start=-1;
      end
    end else if(dut.core_icb_start_reg) begin
      if(epoch_start>=0) $fatal(1,"ICB_RESTART_WITHOUT_BOUNDARY");
      epoch_start=cycle;
      epochs_started=epochs_started+1;
    end
  end
'''
 raw=raw.replace(needle,extra+needle)
 key=bytes(range(16));iv=bytes([255])*12;data=bytes(range(16,32))
 ct=AESGCM(key).encrypt(iv,data,b'\xa5\x5a'+iv+b'\0\x10')
 s=f"""    key=128'h{key.hex()}; iv=96'h{iv.hex()}; n=16;
    pt=128'h{data.hex()}; ct=128'h{ct[:16].hex()}; tag=128'h{ct[16:].hex()};
    program_case(n,pt,tag);start_crypto(0);crypto_compare(0,6);
    $display("MAX_IV_PASS");
    repeat(4096) @(negedge PCLK);
    expect_reg("LONG_IDLE_NO_OVERFLOW",'h10,6);
    score.require_true("ICB_EPOCH_CLOSURE",epochs_started==epochs_closed && epochs_started>68 && epoch_start<0);
    $display("D08_WINDOW started=%0d closed=%0d max_pclk=%0d idle_pclk=4096",epochs_started,epochs_closed,max_window);
"""
 needle='    $display("CASE_NOT_RUN DV04-10 NATURAL_32BIT_ICB_OVERFLOW");'
 check(raw.count(needle)==1,'TB_END_ANCHOR')
 tb=r/'observed_apb.sv';tb.write_text(raw.replace(needle,s+needle))
 actual=r/'actual_work';launch('actual_lib',[t/'vlib',actual])
 launch('actual_vhdl',[t/'vcom','-2008','-work',actual,*vhdl])
 launch('actual_sv',[t/'vlog','-sv','-work',actual,rtl,a/'p13_04_contract_scoreboard.sv',tb])
 log=simulate('actual',actual,'tb_p13_04_apb',['+vectors='+str(r/'vectors.txt')])
 check('top_aes_gcm(arch_top_aes_gcm)' in log and len(re.findall(r'^# CRYPTO_CASE ',log,re.M))==68 and 'MAX_IV_PASS' in log and 'CASE_PASS DV04-08' in log and 'CASE_NOT_RUN DV04-10' in log and 'SUMMARY_PASS cases=68' in log,'ACTUAL_WITNESSES')
 m=re.search(r'D08_WINDOW started=(\d+) closed=(\d+) max_pclk=(\d+) idle_pclk=4096',log)
 check(m and int(m[1])==int(m[2]) and 0<int(m[3])<4096,'EPOCH_COVERAGE')
 fixture=r/'fixture_work';launch('fixture_lib',[t/'vlib',fixture])
 launch('fixture_sv',[t/'vlog','-sv','-work',fixture,'+define+P13_FIXTURE',b/'fixtures/top_aes_gcm_control_fixture.sv',rtl,b/'p13_02_contract_checker.sv',b/'tb_p13_02_apb.sv'])
 ctl=simulate('fixture_control',fixture,'tb_p13_02_apb',['+fault=0'])
 neg=simulate('fixture_negative',fixture,'tb_p13_02_apb',['+fault=3'],1)
 check(ctl.count('FIXTURE_REACH overflow=1 data=1 tag=1 reset=0')==2 and ctl.count('ASSERT_PASS OVERFLOW_TERMINAL')==2 and ctl.count('ASSERT_PASS OVERFLOW_READMISSION')==2 and 'CASE_PASS RTL-09' in ctl,'FIXTURE_CONTROL_SEMANTICS')
 check('FIXTURE_REACH overflow=1 data=1 tag=1 reset=0' in neg and 'ASSERT_FAIL OVERFLOW_TERMINAL expected=0000011a observed=0000011e' in neg and 'SUMMARY_PASS' not in neg,'FIXTURE_NEGATIVE_SEMANTICS')
 standalone='NOT_RUN'
 final=0
 if mode=='owner-long':
  try:
   log=launch('icb_owner',icb+['-gcycles=1'])
  except RuntimeError as exc:
   if str(exc)!='icb_owner exit 124, expected 0':
    raise
   standalone='INCONCLUSIVE_TIMEOUT'
   final=124
  else:
   check('ICB_ENTITY_OVERFLOW_REACHED edge=0FFFFFFFF' in log,'ICB_OWNER_EDGE_MISSING')
   standalone='OVERFLOW_REACHED_STANDALONE_ONLY'
 for n,h in json.loads((r/'new_inputs.json').read_text()).items():
  check(sha(p/n)==h,'DV_INPUT_DRIFT')
 pin_inputs()
 after=src();save('source.after.json',after);check(before==after,'SOURCE_DRIFT')
 save('result.json',dict(status='D08_NOT_PROVEN',standalone=standalone,mode=mode,promotion='BLOCK_FOR_PROMOTION',actual_overflow='NOT_RUN',actual_cases=68,extra_max_iv=1,observed_epoch_count=int(m[1]),observed_max_pclk=int(m[3]),actual_exit=0,fixture_control_exit=0,fixture_negative_exit=1,guard_exit=0,final_exit=final,raw={k:sha(r/(k+'.stdout')) for k in ('actual','fixture_control','fixture_negative')}))
except BaseException as e:
 save('result.json',dict(status='BLOCK',final_exit=1,reason=str(e)));raise
finally:
 save('manifest.json',{str(f.relative_to(r)):sha(f) for f in sorted(r.rglob('*')) if f.is_file() and f.name!='manifest.json'})

sys.exit(final)
