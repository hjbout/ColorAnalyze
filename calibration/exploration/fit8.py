import numpy as np, csv
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
E={k:load(v) for k,v in {'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100'}.items()}
Lg=np.array([base[(0,c)][3] for c in range(17)])
u=np.array([-0.0021,-0.0530]); u=u/np.hypot(*u)   # direction of the blue tint in OKLab (a,b)
print('rows: row,col | L, chroma, hueangle | measured projection on tint dir, ortho comp | gray profile at same L | ratio')
for k,rows in [('E2',(1,2,3))]:
    prof=np.array([np.dot(E[k][(0,c)][4:]-base[(0,c)][4:],u) for c in range(17)])
    for row in rows:
        for col in range(17):
            b=base[(row,col)]; d=E[k][(row,col)][4:]-b[4:]
            proj=np.dot(d,u); ortho=d[0]*(-u[1])+d[1]*u[0]
            pg=np.interp(b[3],Lg,prof)
            ang=np.degrees(np.arctan2(b[5],b[4]))%360
            print(f'{row},{col:2d} | L={b[3]:.3f} C={np.hypot(b[4],b[5]):.3f} h={ang:5.1f} | proj {proj:+.4f} ortho {ortho:+.4f} | gray {pg:+.4f} | ratio {proj/pg if abs(pg)>1e-4 else float("nan"):.2f}')
