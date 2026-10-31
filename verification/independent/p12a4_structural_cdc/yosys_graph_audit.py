#!/usr/bin/env python3
"""Check named VGA invariants in Yosys proc JSON, not physical CDC signoff.

Inputs are actual elaborated connectivity; expected clocks/resets/mechanisms
come from the frozen VGA/reset contract and independent crossing inventory.
"""
import argparse
import hashlib
import json
from pathlib import Path


def check_graph(graph):
    m = graph['modules']['AHB_VRAM_DUAL_BUFFER']
    checks = []
    def bits(name):
        return m['netnames'][name]['bits']
    def check(cid, ok, detail):
        checks.append({'id': cid, 'passed': bool(ok), 'detail': detail})
    def qcell(name):
        matches = [(k, c) for k, c in m['cells'].items()
                   if c['type'] == '$adff' and c['connections'].get('Q') == bits(name)]
        if len(matches) != 1:
            return None, None
        return matches[0]
    chains = [
        ('C01', 'request_toggle_h', 'req_meta_p', 'req_sync_p', 'pclk_25', 'vga_reset_n'),
        ('C02', 'ack_toggle_p', 'ack_meta_h', 'ack_sync_h', 'HCLK', 'h_epoch_valid'),
        ('C03', 'pixel_ready_p', 'pixel_ready_h1', 'pixel_ready_h2', 'HCLK', 'h_epoch_valid'),
        ('C04', 'vga_vsync_sig', 'vsync_h1', 'vsync_h2', 'HCLK', 'HRESETn'),
        ('C05', 'vga_pll_locked', 'pll_lock_h1', 'pll_lock_h2', 'HCLK', 'HRESETn'),
    ]
    for cid, source, first, second, clk, rst in chains:
        key1, c1 = qcell(first)
        key2, c2 = qcell(second)
        ok = bool(c1 and c2)
        if ok:
            ok = c1['connections']['D'] == bits(source) and c2['connections']['D'] == bits(first)
            for c in [c1, c2]:
                ok &= c['connections']['CLK'] == bits(clk) and c['connections']['ARST'] == bits(rst)
                ok &= int(c['parameters']['ARST_POLARITY'], 2) == 0
                ok &= int(c['parameters']['ARST_VALUE'], 2) == 0
        check(cid + '_GRAPH_CHAIN', ok, {'first_cell': key1, 'second_cell': key2, 'clock': clk, 'reset': rst})
        consumers = [(k, p) for k, c in m['cells'].items() for p, direction in c['port_directions'].items()
                     if direction == 'input' and any(x in bits(first) for x in c['connections'][p])]
        output_use = any(set(bits(first)) & set(p['bits']) for p in m['ports'].values() if p['direction'] == 'output')
        check(cid + '_GRAPH_ISOLATION', consumers == [(key2, 'D')] and not output_use, consumers)
    routes = {}
    for inst, clk, out in [('u_vga_reset_sync', 'pclk_25', 'vga_reset_n'),
                           ('u_h_epoch_sync', 'HCLK', 'h_epoch_valid')]:
        c = m['cells'][inst]
        rm = graph['modules'][c['type']]
        ff = [x for x in rm['cells'].values() if x['type'] == '$adff']
        ok = c['connections']['clk'] == bits(clk) and c['connections']['reset_n'] == bits(out)
        ok &= len(ff) == 1 and int(ff[0]['parameters']['WIDTH'], 2) == 2
        if ff:
            q, d = ff[0]['connections']['Q'], ff[0]['connections']['D']
            ok &= d == ['1', q[0]] and rm['ports']['reset_n']['bits'] == [q[1]]
            ok &= int(ff[0]['parameters']['ARST_POLARITY'], 2) == 0
        check('RESET_GRAPH_' + inst, ok, c['connections'])
        routes[inst] = c['connections']
    for bank in [0, 1]:
        c = m['cells'][f'u_VRAM{bank}']
        check('C09_GRAPH_PORTS_' + str(bank), c['connections']['wrclock'] == bits('HCLK')
              and c['connections']['rdclock'] == bits('pclk_25')
              and c['connections']['data'] == bits('write_data')
              and c['connections']['rdaddress'] == bits('vram_read_addr'), c['connections'])
    raw_consumers = [{'cell': k, 'type': c['type'], 'port': p, 'src': c.get('attributes', {}).get('src')}
                     for k, c in m['cells'].items() for p, direction in c['port_directions'].items()
                     if direction == 'input' and any(x in bits('vga_pll_locked') for x in c['connections'][p])]
    check('C08_GRAPH_RAW_PRESENT', any(x['type'] == '$adff' and x['port'] == 'D' for x in raw_consumers)
          and any(x['type'] == '$logic_not' for x in raw_consumers)
          and any(x['type'] == '$logic_and' for x in raw_consumers), raw_consumers)
    return {'claim': 'NAMED_RTL_GRAPH_INVARIANTS_ONLY', 'checks': checks,
            'failed_ids': [x['id'] for x in checks if not x['passed']],
            'module_types': {n: sorted({c['type'] for c in mod['cells'].values()})
                             for n, mod in graph['modules'].items()}}


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('json', type=Path)
    args = p.parse_args()
    result = check_graph(json.loads(args.json.read_text()))
    result['input_sha256'] = hashlib.sha256(args.json.read_bytes()).hexdigest()
    print(json.dumps(result, indent=2))
    raise SystemExit(int(bool(result['failed_ids'])))
