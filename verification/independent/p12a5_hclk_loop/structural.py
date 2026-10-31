"""G3 structural audit on fresh actual flattened Yosys output, no edge cuts."""
import sys,json,collections,hashlib
from pathlib import Path
sys.setrecursionlimit(100000)
OUT=Path(__file__).parent
def check(path):
    j=json.loads(path.read_text());m=j['modules']['AMBA_SoC_TOP'];g=collections.defaultdict(set);black=[];seq=[]
    for n,c in m['cells'].items():
        typ=c['type']
        if typ in j['modules']:
            black.append({'instance':n,'type':typ,'attributes':j['modules'][typ].get('attributes',{})});continue
        if 'dff' in typ.lower() or 'latch' in typ.lower():seq.append(n);continue
        ins={b for p,v in c['connections'].items() if c['port_directions'][p]=='input' for b in v if isinstance(b,int)}
        outs={b for p,v in c['connections'].items() if c['port_directions'][p]=='output' for b in v if isinstance(b,int)}
        for b in ins:g[b].add(n)
        g[n].update(outs)
    def reach(starts,targets):
        parents={b:None for b in starts};q=collections.deque(starts)
        while q:
            a=q.popleft()
            if a in targets:
                path=[]
                while a is not None:path.append(a);a=parents[a]
                return path[::-1]
            for b in g.get(a,()):
                if b not in parents:parents[b]=a;q.append(b)
        return []
    nets=m['netnames'];bits=lambda n:set(b for b in nets[n]['bits'] if isinstance(b,int))
    index={};low={};active=set();stack=[];comps=[]
    def visit(v):
        index[v]=low[v]=len(index);active.add(v);stack.append(v)
        for w in g.get(v,()):
            if w not in index:visit(w);low[v]=min(low[v],low[w])
            elif w in active:low[v]=min(low[v],index[w])
        if low[v]==index[v]:
            c=[]
            while True:
                w=stack.pop();active.remove(w);c.append(w)
                if w==v:break
            if len(c)>1 or v in g.get(v,()):comps.append(c)
    for v in list(g):
        if v not in index:visit(v)
    paths={}
    for src in ['HRESP','HREADY','u_CPU.mem_fault_now']:
        for dst in ['HWDATA','u_CPU.CUSTOM_WRITE_MASK']:
            p=reach(bits(src),bits(dst));paths[src+' -> '+dst]={'reachable':bool(p),'witness':p}
    return {'input':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'graph_vertices_with_fanout':len(g),'edges':sum(map(len,g.values())),
      'scc_sizes':sorted([len(c) for c in comps],reverse=True),'response_paths':paths,'sequential_boundaries':len(seq),'blackboxes':black,
      'method':'Actual proc/flatten/opt_clean graph; every primitive input conservatively reaches each output; DFF/latch and declared blackbox interiors excluded. No removed edges or proposed dependencies.'}

out=Path(sys.argv[1]);graphs={n:check(out/(n+'.json')) for n in ('unoptimized','optimized')}
paths={k:v for g in graphs.values() for k,v in g['response_paths'].items() if v['reachable']}
assertion=None
if any('HWDATA' in k for k in paths):assertion='STRUCT_RESPONSE_DATA: '+str(list(paths))
elif paths:assertion='STRUCT_RESPONSE_MASK: '+str(list(paths))
elif any(g['scc_sizes'] for g in graphs.values()):assertion='STRUCT_SCC: remaining combinational SCC'
r={'status':'FAIL' if assertion else 'PASS','assertion':assertion,'graphs':graphs}
(out/'check.json').write_text(json.dumps(r,indent=2));print(json.dumps({'status':r['status'],'assertion':assertion,'SCC':{k:v['scc_sizes'] for k,v in graphs.items()}}));raise SystemExit(1 if assertion else 0)
