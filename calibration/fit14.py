import numpy as np, csv, json
from scipy.optimize import least_squares
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
names={'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100','E4':'E4-combo','E5':'E5-combo2','E6':'E6-combo3','E7':'E7-sat-231'}
E={k:load(v) for k,v in names.items()}
S2X=np.array([[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]])
X2R=np.array([[1.7166512,-0.3556708,-0.2533663],[-0.6666844,1.6164812,0.0157685],[0.0176399,-0.0427706,0.9421031]])
M=X2R@S2X; M=M/(M@np.ones(3))[:,None]
f=lambda x: M@x
xs=np.array([f(base[(0,c)][:3])[0] for c in range(17)])
gray=lambda k: np.array([f(E[k][(0,c)][:3])-f(base[(0,c)][:3]) for c in range(17)])
K={r:gray(k)[:,2] for k,r in zip(['E1','E2','E3'],'smh')}
n231=np.mean([gray(k)[np.argmax(np.abs(gray(k)[:,2]))]/gray(k)[np.argmax(np.abs(gray(k)[:,2])),2] for k in ['E1','E2','E3']],axis=0)
# --- saturation linearity (E7): shadows 50, midtones 25, highlights 75, all hue 231
m7=gray('E7'); sat={'s':0.5,'m':0.25,'h':0.75}
for q in [0.8,0.9,1.0,1.1,1.2,1.5]:
    pred=sum(np.outer(sat[r]**q*K[r],n231) for r in 'smh')
    print(f'sat exponent {q}: gray rms error {np.sqrt(np.mean((pred-m7)**2)):.5f}  (effect rms {np.sqrt(np.mean(m7**2)):.5f})')
# --- directions per hue from the combo experiments
def fit_dirs(k, sats):
    meas=gray(k)
    sol=least_squares(lambda m:(sum(np.outer(sats[i]*K[r],m[3*i:3*i+3]) for i,r in enumerate('smh'))-meas).ravel(),np.zeros(9)+0.1)
    return sol.x.reshape(3,3), np.sqrt(np.mean(sol.fun**2))
dirs=[(231,n231)]
for k,hues,sats in [('E4',(36,312,104),(1,1,.5)),('E5',(0,160,270),(1,1,1)),('E6',(80,200,340),(1,1,1))]:
    m,rms=fit_dirs(k,sats)
    print(k,'gray fit rms',round(rms,5))
    for h,v in zip(hues,m): dirs.append((h,v))
hs=np.array([d[0] for d in dirs],float); D=np.array([d[1] for d in dirs])
order=np.argsort(hs); 
print('directions n(h) (Rec2020, blue(231)-normalised):')
for i in order: print(f'  {hs[i]:5.0f}  {D[i].round(3)}')
def design(hh,harm):
    cols=[np.ones_like(hh)] if False else []
    for k in range(1,harm+1):
        cols+= [np.cos(np.radians(k*hh)),np.sin(np.radians(k*hh))]
    return np.stack(cols,1)
for harm in (1,2,3):
    X=design(hs,harm); A=np.linalg.lstsq(X,D,rcond=None)[0]
    # leave-one-out
    loo=[]
    for i in range(len(hs)):
        idx=[j for j in range(len(hs)) if j!=i]
        Ai=np.linalg.lstsq(X[idx],D[idx],rcond=None)[0]; loo.append(np.sqrt(np.mean((X[i]@Ai-D[i])**2)))
    print(f'harmonics {harm}: fit rms {np.sqrt(np.mean((X@A-D)**2)):.4f}  leave-one-out rms {np.sqrt(np.mean(np.square(loo))):.4f}')
np.savez('model_final_inputs.npz',xs=xs,K=np.array([K['s'],K['m'],K['h']]),hs=hs,D=D,M=M)
