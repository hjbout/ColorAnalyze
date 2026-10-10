import numpy as np, csv
from scipy.optimize import least_squares
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308, 12.92*x, 1.055*np.power(x,1/2.4)-0.055)
base=load('E0-baseline')
E={k:load(v) for k,v in {'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100'}.items()}
u=np.array([-0.0021,-0.0530]); u=u/np.hypot(*u)
gg=np.array([enc(base[(0,c)][:3])[0] for c in range(17)])
profs={k:np.array([np.dot(E[k][(0,c)][4:]-base[(0,c)][4:],u) for c in range(17)]) for k in E}
G=lambda k,r,c: enc(base[(r,c)][:3])
data=[]
for k in E:
    for row in range(1,4):
        for col in range(17):
            d=E[k][(row,col)][4:]-base[(row,col)][4:]
            data.append((k,row,col,G(k,row,col),np.dot(d,u),d))
def resid(w, power=1.0):
    w=np.abs(w); w=w/w.sum(); out=[]
    for k,row,col,g,proj,d in data:
        v=(np.dot(w,g**power))**(1/power)
        out.append(np.interp(v,gg,profs[k])-proj)
    return np.array(out)
for power in [1.0,2.0,4.0,8.0]:
    best=None
    for start in [[1,1,1],[.2,.7,.1],[1,0,0],[0,0,1]]:
        s=least_squares(lambda w:resid(w,power),np.array(start,float)+0.01)
        if best is None or s.cost<best.cost: best=s
    w=np.abs(best.x); w/=w.sum()
    eff=np.sqrt(np.mean([d[0] for *_,d in [(0,0,0,0,0,0)]] or [0])) if False else None
    rms=np.sqrt(np.mean(best.fun**2)); effrms=np.sqrt(np.mean([p**2 for *_,p,_ in data]))
    print(f'power {power}: weights R,G,B = {w.round(3)}  rms err {rms:.4f}  (effect rms {effrms:.4f})')
