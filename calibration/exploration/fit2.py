import numpy as np, csv
from scipy.optimize import least_squares
def load(name):
    rows=list(csv.DictReader(open(f'exports/{name}.csv')))
    d={}
    for r in rows:
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308, 12.92*x, 1.055*np.power(x,1/2.4)-0.055)
base=load('E0-baseline')
exp={n:load(n) for n in ['E1-shadows-231-100','E2-midtones-231-100','E3-highlights-231-100','E4-combo']}
def gamma_delta(name, row, col):
    b=enc(base[(row,col)][:3]); x=enc(exp[name][(row,col)][:3]); return x-b
# profiles on the gray ramp: B-channel delta of blue tint (gamma units, 0..1)
v=np.array([base[(0,c)][:3] for c in range(17)]); vg=enc(v)[:,0]    # gamma gray level
L=np.array([base[(0,c)][3] for c in range(17)])
prof={}
for n,r in zip(['E1-shadows-231-100','E2-midtones-231-100','E3-highlights-231-100'],'smh'):
    prof[r]=np.array([gamma_delta(n,0,c) for c in range(17)])          # 17x3
ref={r: prof[r][np.argmax(prof[r][:,2])] for r in 'smh'}
for r in 'smh':
    d=ref[r]/ref[r][2]
    print(r,'peak at gray',vg[np.argmax(prof[r][:,2])]*255,'B',ref[r][2]*255,'direction R,G per B',d[0].round(3),d[1].round(3))
# direction constancy across levels
for r in 'smh':
    ratios=prof[r][:,:2]/np.where(prof[r][:,2:3]>0.002,prof[r][:,2:3],np.nan)
    print(r,'R/B',np.nanmin(ratios[:,0]).round(3),np.nanmax(ratios[:,0]).round(3),' G/B',np.nanmin(ratios[:,1]).round(3),np.nanmax(ratios[:,1]).round(3))
# E4: fit three unknown 3-vectors m(36), m(312), m(104)*0.5-factor
Bprof={r: prof[r][:,2] for r in 'smh'}
def model(m, name='E4-combo'):
    # m: 9 numbers: m_s, m_m, m_h (each 3, B-normalized so that blue = (-.48,-.06,1))
    out=np.zeros((17,3))
    for k,r in enumerate('smh'):
        out+=np.outer(Bprof[r], m[3*k:3*k+3])
    return out
meas=np.array([gamma_delta('E4-combo',0,c) for c in range(17)])
def resid(m): return (model(m)-meas).ravel()*255
sol=least_squares(resid,np.array([0.1,0.1,0.1]*3))
print('residual rms (255 scale):',np.sqrt(np.mean(sol.fun**2)).round(3))
for k,(r,h,s) in enumerate(zip('smh',[36,312,104],[1,1,0.5])):
    print(f'm({h}) with sat {s}:',sol.x[3*k:3*k+3].round(3),' per sat100:',(sol.x[3*k:3*k+3]/s).round(3))
np.save('m_fit.npy',sol.x)
