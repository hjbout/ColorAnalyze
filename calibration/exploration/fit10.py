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
def run(p, verbose=False):
    f=lambda x: np.power(np.clip(x,0,None),p)
    xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
    K={}; n231=None
    for k,r in zip(['E1','E2','E3'],'smh'):
        d=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])   # 17x3
        K[r]=d[:,2]
    # direction of blue: weighted ratio at the largest |B| per range
    ratios=[]
    for k,r in zip(['E1','E2','E3'],'smh'):
        d=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
        i=np.argmax(np.abs(d[:,2])); ratios.append(d[i]/d[i,2])
    n231=np.mean(ratios,axis=0)
    # E4: fit three direction vectors on the gray ramp
    meas=np.array([f(E['E4'][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
    def model(m): return sum(np.outer(K[r],m[3*i:3*i+3]) for i,r in enumerate('smh'))
    sol=least_squares(lambda m:(model(m)-meas).ravel(),np.zeros(9)+0.1)
    m=sol.x.reshape(3,3); m[2]/=0.5
    gray_rms=np.sqrt(np.mean(sol.fun**2))
    # harmonic model of the directions
    hs=np.array([231,36,312,104.0]); D=np.vstack([n231,m])
    X=np.stack([np.cos(np.radians(hs)),np.sin(np.radians(hs))],1); A=np.linalg.lstsq(X,D,rcond=None)[0]
    harm_rms=np.sqrt(np.mean((X@A-D)**2))
    # colored patches: per-channel curves K_r(x_c) * n_c
    def predict(settings, b):
        out=np.zeros(3)
        for r,(hue,sat) in settings.items():
            t=np.radians(hue); v=np.array([np.cos(t),np.sin(t)])@A
            t0=np.radians(231); v=v/(np.array([np.cos(t0),np.sin(t0)])@A)[2]
            out+= (sat/100)*np.array([np.interp(b[i],xs,K[r])*v[i] for i in range(3)])
        return out
    exps={'E1':{'s':(231,100)},'E2':{'m':(231,100)},'E3':{'h':(231,100)},'E4':{'s':(36,100),'m':(312,100),'h':(104,50)}}
    res={}
    for k,settings in exps.items():
        errs=[];effs=[]
        for row in range(1,4):
            for col in range(17):
                b=f(base[(row,col)][:3]); meas_c=f(E[k][(row,col)][:3])-b
                errs.append(predict(settings,b)-meas_c); effs.append(meas_c)
        errs=np.array(errs);effs=np.array(effs); res[k]=np.sqrt(np.mean(errs**2))/np.sqrt(np.mean(effs**2))
    return gray_rms, harm_rms, res, n231, A
for p in [0.4545,0.7,1.0,1.3,1.6,2.0]:
    g,h,res,n231,A=run(p)
    print(f'p={p}: gray fit rms {g:.4f}, harmonic rms {h:.3f}, relative error on colored patches: '+' '.join(f'{k} {v:.0%}' for k,v in res.items()))

print('--- E4 with directly fitted directions (no harmonic model), linear space')
p=1.0
f=lambda x: np.power(np.clip(x,0,None),p)
xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
K={}
for k,r in zip(['E1','E2','E3'],'smh'):
    K[r]=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])[:,2]
meas=np.array([f(E['E4'][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
def model(m): return sum(np.outer(K[r],m[3*i:3*i+3]) for i,r in enumerate('smh'))
sol=least_squares(lambda m:(model(m)-meas).ravel(),np.zeros(9)+0.1); m=sol.x.reshape(3,3)
print('fitted directions (s=36,m=312,h=104@50%):\n',m.round(3))
errs=[];effs=[]
for row in range(1,4):
    for col in range(17):
        b=f(base[(row,col)][:3]); mc=f(E['E4'][(row,col)][:3])-b
        pred=sum(np.array([np.interp(b[i],xs,K[r])*m[j][i] for i in range(3)]) for j,r in enumerate('smh'))
        errs.append(pred-mc); effs.append(mc)
errs=np.array(errs);effs=np.array(effs)
print('E4 colored: rel err',(np.sqrt(np.mean(errs**2))/np.sqrt(np.mean(effs**2))).round(2))
for row in (1,2,3):
    sl=slice((row-1)*17,row*17)
    print(' row',row,'rel err',(np.sqrt(np.mean(errs[sl]**2))/np.sqrt(np.mean(effs[sl]**2))).round(2))
