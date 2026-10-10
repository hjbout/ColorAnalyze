import numpy as np, csv
def load(name):
    rows=list(csv.DictReader(open(f'exports/{name}.csv')))
    return {(int(r['row']),int(r['col'])): np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')]) for r in rows}
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308, 12.92*x, 1.055*np.power(x,1/2.4)-0.055)
base=load('E0-baseline')
def grayrows(name):
    e=load(name)
    out=[]
    for c in range(17):
        b=base[(0,c)]; x=e[(0,c)]
        out.append((c, b[3], enc(b[:3]), enc(x[:3]), x[3:]-b[3:]))
    return out
for name in ['E1-shadows-231-100','E2-midtones-231-100','E3-highlights-231-100']:
    print(name)
    for c,L,g0,g1,d in grayrows(name):
        dg=(g1-g0)*255
        print(f"  gray {c*16:3d} L={L:.3f} dGamma255 R{dg[0]:+6.1f} G{dg[1]:+6.1f} B{dg[2]:+6.1f}  dOK L{d[0]:+.4f} a{d[1]:+.4f} b{d[2]:+.4f}")
