import numpy as np, csv
from scipy.optimize import least_squares
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
names={'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100','E4':'E4-combo'}
E={k:load(v) for k,v in names.items()}
lin=lambda d,r,c: d[(r,c)][:3]
Ylin=lambda x: 0.2126*x[0]+0.7152*x[1]+0.0722*x[2]
gray=np.array([lin(base,0,c) for c in range(17)])
yg=gray[:,0]                       # linear luminance of gray = value
# kappa_r on the gray ramp: B gain of the blue tint
kap={}
for k,r in zip(['E1','E2','E3'],'smh'):
    gains=np.array([(lin(E[k],0,c)-gray[c])/np.where(gray[c]>0,gray[c],1) for c in range(17)])
    kap[r]=gains[:,2]
n231=np.array([-0.42,-0.05,1.0])
def vars_(x,L):
    return {'Y':Ylin(x),'mean':x.mean(),'max':x.max(),'L3':L**3}
def kappa(r,var,x,L):
    # tabulate kappa over the same variable as measured on gray (Y of gray == value)
    return np.interp(vars_(x,L)[var],yg,kap[r])
for var in ['Y','mean','max','L3']:
    for k,r in zip(['E1','E2','E3'],'smh'):
        errs=[];effs=[]
        for row in range(1,4):
            for col in range(17):
                b=lin(base,row,col); L=base[(row,col)][3]; meas=lin(E[k],row,col)-b
                pred=b*kappa(r,var,b,L)*n231
                errs.append(pred-meas); effs.append(meas)
        errs=np.array(errs);effs=np.array(effs)
        print(var,k,'rms err',np.sqrt(np.mean(errs**2)).round(4),' rms effect',np.sqrt(np.mean(effs**2)).round(4))
