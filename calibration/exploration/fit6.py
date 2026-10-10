import numpy as np, csv
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
E={k:load(v) for k,v in {'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100'}.items()}
print('gray ramp, linear-light relative gain per channel: (X_after/X_before - 1), blue tint sat100')
for k in ['E1','E2','E3']:
    print(k)
    for c in range(1,16):
        b=base[(0,c)][:3]; x=E[k][(0,c)][:3]
        gain=x/b-1
        if abs(gain).max()>0.004:
            print(f'  v={c*16:3d} lin={b[0]:.4f} gain R{gain[0]:+.3f} G{gain[1]:+.3f} B{gain[2]:+.3f}   ratio R/B {gain[0]/gain[2]:+.2f} G/B {gain[1]/gain[2]:+.2f}')
