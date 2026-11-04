import numpy as np, sys
def load(n):
    d=open(f'{n}.f32','rb').read()
    w,h=np.frombuffer(d[:8],np.int32); a=np.frombuffer(d[8:],np.float32).reshape(h,w,3).astype(float)
    return a
M=np.array([[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]])
def uv(rgb):
    X,Y,Z=M@rgb; d=X+15*Y+3*Z; return np.array([4*X/d,6*Y/d])
def locus(T):
    u=(0.860117757+1.54118254e-4*T+1.28641212e-7*T*T)/(1+8.42420235e-4*T+7.08145163e-7*T*T)
    v=(0.317398726+4.22806245e-5*T+4.20481691e-8*T*T)/(1-2.89741816e-5*T+1.61456053e-7*T*T)
    return np.array([u,v])
def cct(p):
    Ts=np.arange(1500,15000,5.0); L=np.array([locus(t) for t in Ts]); i=np.argmin(((L-p)**2).sum(1))
    off=p-L[i]; tang=locus(Ts[i]*1.001)-locus(Ts[i]*0.999)
    side=tang[0]*off[1]-tang[1]*off[0]
    return Ts[i],(1 if side<0 else -1)*np.hypot(*off)
base=load('T5694')
for n in sys.argv[1:]:
    a=load(n)
    m=(base.mean(2)>0.03)&(base.mean(2)<0.6)&(base.min(2)>0.005)&(a.min(2)>0.005)
    r=a[m]/base[m]            # per-pixel gains
    g=np.median(r,0); g=g/g[1]
    # shift of D65-white (equal RGB) through the gains
    w0=np.ones(3); w1=1/g   # correcting: an object grey under gains g appears at g; so the white balance point moved by 1/g
    t0,d0=cct(uv(w0)); t1,d1=cct(uv(g))
    mir=1e6/t1-1e6/t0
    print(n,'gains',np.round(g,4),'spread',np.round(r.std(0)/np.abs(r.mean(0)),3),'dmired(of grey)',round(mir,1),'dDuv*3000',round((d1-d0)*3000,1))
