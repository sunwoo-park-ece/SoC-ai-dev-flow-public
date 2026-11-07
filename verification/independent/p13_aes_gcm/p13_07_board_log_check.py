#!/usr/bin/env python3
"""Strict independent UART transcript guard. No printed PASS is trusted alone.

Identity is checked against the separately retained frozen image manifest.
Cryptographic comparison correctness requires the host/oracle and genuine-core
lanes too: serial text cannot independently prove hardware calculations.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

CASES = [
    ('E0','E',0,0,6),('D0','D',0,0,6),('E7','E',7,0,6),('D7','D',7,0,6),
    ('E16','E',16,0,6),('D16','D',16,0,6),('AUTH','D',16,5,0x9a),
    ('ARG17','D',17,1,0),('ARG65535','D',65535,1,0),('ZERO','M',0,0,0),
    ('CLEAR','M',0,0,0),('NEXT','E',16,0,6),('TIMEOUT0','D',16,3,0),
    ('TIMEOUT1','D',16,3,1),('RECOVERY','D',16,8,0),
    ('BUSY','X',0,0,0),('OVERFLOW','X',0,0,0)]


def require(value, reason):
    if not value:
        raise ValueError(reason)


def fields(line, kind, keys):
    parts=line.split(' ')
    require(parts[0]==kind and len(parts)==len(keys)+1, 'SCHEMA_'+kind)
    result={}
    for part,key in zip(parts[1:],keys):
        require(part.startswith(key+'=') and part.count('=')==1, 'FIELD_'+key)
        result[key]=part[len(key)+1:]
    return result


def check(raw, manifest):
    require(b'\x00' not in raw and all(c in (10,13) or 32<=c<=126 for c in raw), 'SERIAL_BYTES')
    lines=raw.decode('ascii').replace('\r\n','\n').splitlines()
    require(len(lines)==20 and raw.endswith(b'\n'), 'COVERAGE_OR_TRUNCATION')
    begin=fields(lines[0],'BEGIN',['app','schema','build','source','vector','count'])
    require(begin['app']=='P13H0' and begin['schema']=='1' and begin['count']=='11', 'BEGIN_SCHEMA')
    for key in ('build','source','vector'):
        require(re.fullmatch('[0-9a-f]{64}',begin[key]) is not None and
                begin[key]==manifest[key], 'IDENTITY_'+key)
    rows=[]
    for ordinal,(line,expected) in enumerate(zip(lines[1:18],CASES),1):
        r=fields(line,'CASE',['o','id','m','l','r','s','c','p','e','v'])
        for key,width in [('o',2),('l',8),('r',2),('s',8),('c',8),('p',2),('e',1)]:
            require(re.fullmatch('[0-9a-f]{'+str(width)+'}',r[key]) is not None,'HEX_'+key)
        ident,mode,length,rc,status=expected
        require(int(r['o'],16)==ordinal and r['id']==ident, 'CASE_ORDER')
        require(r['m']==mode and int(r['l'],16)==length, 'CASE_INPUT_'+ident)
        require(int(r['r'],16)==rc and int(r['s'],16)==status, 'CASE_STATUS_'+ident)
        require(int(r['c'],16)==status&0x1fc0, 'CAUSE_'+ident)
        require(int(r['p'],16)<=32,'POLL_BOUND_'+ident)
        if ordinal<=15:
            require(r['e']=='1' and r['v']=='P','COMPARISON_'+ident)
        else:
            require(r['e']=='0' and r['v']==('NT' if ident=='BUSY' else 'NR'), 'DEFERRED_'+ident)
        if ident in ('ARG17','ARG65535','CLEAR','TIMEOUT0','RECOVERY','BUSY','OVERFLOW'):
            require(r['p']=='00','NO_POLL_'+ident)
        if ident in ('E0','D0','E7','D7','E16','D16','NEXT','ZERO'):
            require(int(r['p'],16)>0,'MISSING_EXECUTION_'+ident)
        if ident=='TIMEOUT1':require(r['p']=='01','TIMEOUT_REACH')
        rows.append(r)
    require(lines[18]=='SUMMARY pass=0f fail=00 skip=00 nt=02','SUMMARY_COUNTS')
    require(lines[19]=='END complete=1','END_INCOMPLETE')
    return {'status':'PASS_BOUNDED','cases':rows,'mandatory':15,'not_testable':1,
            'not_run':1,'raw_sha256':hashlib.sha256(raw).hexdigest()}


def selftest(raw, manifest):
    check(raw,manifest)
    text=raw.decode('ascii').replace('\r\n','\n')
    tests={
      'truncate':text.rsplit('END',1)[0],
      'duplicate':text.replace('id=D0','id=E0',1),
      'order':text.replace('o=02','o=03',1),
      'identity':text.replace('build='+manifest['build'],'build='+'0'*64,1),
      'false_eq':text.replace('e=1','e=0',1),
      'sticky':text.replace('s=00000006','s=00000426',1),
      'fail':text.replace('v=P','v=F',1),
      'skip':text.replace('v=P','v=NT',1),
      'summary':text.replace('pass=0f','pass=10',1),
      'trailing':text+'EXTRA\n',
      'no_timeout':text.replace('r=03 s=00000001','r=00 s=00000006',1),
      'cause':text.replace('c=00000080','c=00000000',1)}
    results=[]
    for name,changed in tests.items():
        require(changed!=text,'SELFTEST_NOT_REACHED_'+name)
        try:check(changed.encode(),manifest)
        except ValueError as e:results.append({'fault':name,'injection_reached':True,'rejected':str(e)})
        else:raise ValueError('SELFTEST_SURVIVED_'+name)
    return results


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--log',required=True,type=Path)
    ap.add_argument('--manifest',required=True,type=Path)
    ap.add_argument('--selftest',action='store_true')
    args=ap.parse_args()
    try:
        raw=args.log.read_bytes(); manifest=json.loads(args.manifest.read_text())
        result=check(raw,manifest)
        if args.selftest:result['sensitivity']=selftest(raw,manifest)
        print(json.dumps(result));return 0
    except (ValueError,OSError,KeyError) as e:
        print(json.dumps({'status':'FAIL','reason':str(e)}));return 43


if __name__=='__main__':
    raise SystemExit(main())
