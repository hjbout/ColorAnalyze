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
X2R2020=np.array([[1.7166512,-0.3556708,-0.2533663],[-0.6666844,1.6164812,0.0157685],[0.0176399,-0.0427706,0.9421031]])
X2P3=np.array([[2.4934969,-0.9313836,-0.4027108],[-0.8294890,1.7626641,0.0236247],[0.0358458,-0.0761724,0.9568845]])
D65D50=np.array([[1.0478112,0.0228866,-0.0501270],[0.0295424,0.9904844,-0.0170491],[-0.0092345,0.0150436,0.7521316]])
X2PRO=np.array([[1.3459433,-0.2556075,-0.0511118],[-0.5445989,1.5081673,0.0205351],[0,0,1.2118128]])@D65D50
cands={'sRGB':np.eye(3),'P3':X2P3@S2X,'Rec2020':X2R2020@S2X,'ProPhoto':X2PRO@S2X}
for name,M in cands.items():
    # neutral check: M @ (1,1,1) should be (1,1,1)
    w=M@np.ones(3); M=M/w[:,None]          # normalise rows so that neutrals stay neutral
    Mi=np.linalg.inv(M)
    f=lambda x: (M@x)
    xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
    K={}
    for k,r in zip(['E1','E2','E3'],'smh'):
        K[r]=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])[:,2]
    ratios=[]
    for k,r in zip(['E1','E2','E3'],'smh'):
        d=np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)]); i=np.argmax(np.abs(d[:,2])); ratios.append(d[i]/d[i,2])
    n231=np.mean(ratios,axis=0)
    meas4=np.array([f(E['E4'][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
    sol=least_squares(lambda m:(sum(np.outer(K[r],m[3*i:3*i+3]) for i,r in enumerate('smh'))-meas4).ravel(),np.zeros(9)+0.1); m4=sol.x.reshape(3,3)
    dirs={'E1':[n231],'E2':[n231],'E3':[n231],'E4':[m4[0],m4[1],m4[2]]}
    rng={'E1':'s','E2':'m','E3':'h','E4':'smh'}
    out=[]
    for k in ['E1','E2','E3','E4']:
        errs=[];effs=[]
        for row in range(1,4):
            for col in range(17):
                b=f(base[(row,col)][:3]); target=f(E[k][(row,col)][:3])-b
                pred=sum(np.array([np.interp(b[i],xs,K[r])*dirs[k][j][i] for i in range(3)]) for j,r in enumerate(rng[k]))
                errs.append(pred-target); effs.append(target)
        errs=np.array(errs);effs=np.array(effs); out.append(np.sqrt(np.mean(errs**2))/np.sqrt(np.mean(effs**2)))
    print(f'{name:9s} rel err colored: E1 {out[0]:.0%} E2 {out[1]:.0%} E3 {out[2]:.0%} E4 {out[3]:.0%}')
