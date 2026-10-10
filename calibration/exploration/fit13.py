import numpy as np, csv
from scipy.optimize import least_squares
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
E={k:load(v) for k,v in {'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100','E4':'E4-combo'}.items()}
S2X=np.array([[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]])
X2R=np.array([[1.7166512,-0.3556708,-0.2533663],[-0.6666844,1.6164812,0.0157685],[0.0176399,-0.0427706,0.9421031]])
M=X2R@S2X; M=M/(M@np.ones(3))[:,None]
print('sRGB->Rec2020 matrix (rows normalised):\n',M.round(4))
f=lambda x: M@x
xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
K={}
for k,r in zip(['E1','E2','E3'],'smh'):
    K[r]=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])[:,2]
ratios=[]
for k,r in zip(['E1','E2','E3'],'smh'):
    d=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)]); i=np.argmax(np.abs(d[:,2])); ratios.append(d[i]/d[i,2])
print('n(231) per range:',np.array(ratios).round(3))
n231=np.mean(ratios,axis=0)
meas4=np.array([f(E['E4'][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
sol=least_squares(lambda m:(sum(np.outer(K[r],m[3*i:3*i+3]) for i,r in enumerate('smh'))-meas4).ravel(),np.zeros(9)+0.1); m4=sol.x.reshape(3,3); m4[2]/=0.5
print('gray rms of E4 fit',np.sqrt(np.mean(sol.fun**2)).round(5))
D=np.vstack([n231,m4]); hs=np.array([231,36,312,104.0])
print('directions in Rec2020 (blue-normalised):'); 
for h,d in zip(hs,D): print(' hue',h,d.round(3),' sum',d.sum().round(3),' luma(2020)',(0.2627*d[0]+0.6780*d[1]+0.0593*d[2]).round(3))
X=np.stack([np.cos(np.radians(hs)),np.sin(np.radians(hs))],1); A=np.linalg.lstsq(X,D,rcond=None)[0]
print('harmonic fit residual rms',np.sqrt(np.mean((X@A-D)**2)).round(4)); print('A:\n',A.round(3))
print('K peaks (B gain amplitude in 2020 space):',{r:(K[r].max().round(4),xs[np.argmax(K[r])].round(3)) for r in K})
np.savez('model2020.npz',xs=xs,Ks=np.array([K['s'],K['m'],K['h']]),A=A,M=M,n231=n231,D=D,hs=hs)
