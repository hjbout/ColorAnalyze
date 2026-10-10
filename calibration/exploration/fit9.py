import numpy as np, csv
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308, 12.92*x, 1.055*np.power(x,1/2.4)-0.055)
def dec(y):
    y=np.clip(y,0,1); return np.where(y<=0.04045, y/12.92, ((y+0.055)/1.055)**2.4)
base=load('E0-baseline')
E={k:load(v) for k,v in {'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100'}.items()}
space={'gamma':(enc,dec),'linear':(lambda x:x,lambda x:x)}
for sname,(f,finv) in space.items():
    print('space',sname)
    for k in ['E1','E2','E3']:
        xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
        curves=[np.array([f(E[k][(0,c)][:3])[i]-f(base[(0,c)][:3])[i] for c in range(17)]) for i in range(3)]   # delta of channel i at gray level x
        errs=[];effs=[]
        for row in range(1,4):
            for col in range(17):
                b=f(base[(row,col)][:3]); meas=f(E[k][(row,col)][:3])-b
                pred=np.array([np.interp(b[i],xs,curves[i]) for i in range(3)])
                errs.append(pred-meas); effs.append(meas)
        errs=np.array(errs);effs=np.array(effs)
        sc=255 if sname=='gamma' else 1
        print('  ',k,'rms err',np.sqrt(np.mean(errs**2)).round(4),' rms effect',np.sqrt(np.mean(effs**2)).round(4),' (per-channel curve model)')
