import numpy as np, csv
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308, 12.92*x, 1.055*np.power(x,1/2.4)-0.055)
base=load('E0-baseline')
names={'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100','E4':'E4-combo'}
exp={k:load(v) for k,v in names.items()}
g=lambda d,r,c: enc(d[(r,c)][:3])
vg=np.array([g(base,0,c)[0] for c in range(17)])
prof={}
for k,r in zip(['E1','E2','E3'],'smh'):
    prof[r]=np.array([g(exp[k],0,c)-g(base,0,c) for c in range(17)])[:,2]
m=np.array([[-0.477,-0.058,1.0],[0.634,-0.178,-0.897],[1.29,-0.721,0.497],[-0.837,0.601,-0.842]]); h=np.array([231,36,312,104.0])
X=np.stack([np.cos(np.radians(h)),np.sin(np.radians(h))],1); A=np.linalg.lstsq(X,m,rcond=None)[0]
def direction(hue):
    t=np.radians(hue); v=np.array([np.cos(t),np.sin(t)])@A
    t0=np.radians(231); b231=(np.array([np.cos(t0),np.sin(t0)])@A)[2]
    return v/b231
print('A (3x2):\n',A.round(3))
def luma(c): return 0.2126*c[0]+0.7152*c[1]+0.0722*c[2]
def predict(settings, rgb_enc, variable):
    out=np.zeros(3)
    x={'luma':luma(rgb_enc),'mean':rgb_enc.mean(),'max':rgb_enc.max()}[variable]
    for r,(hue,sat) in settings.items():
        out+= (sat/100)*np.interp(x,vg,prof[r])*direction(hue)
    return out
exps={'E1':{'s':(231,100)},'E2':{'m':(231,100)},'E3':{'h':(231,100)},'E4':{'s':(36,100),'m':(312,100),'h':(104,50)}}
for variable in ['luma','mean','max']:
    for k,settings in exps.items():
        errs=[]; eff=[]
        for row in range(1,4):
            for col in range(17):
                b=g(base,row,col); meas=g(exp[k],row,col)-b
                errs.append((predict(settings,b,variable)-meas)*255); eff.append(meas*255)
        errs=np.array(errs); eff=np.array(eff)
        print(variable,k,'rms err',np.sqrt(np.mean(errs**2)).round(2),' max',np.abs(errs).max().round(1),' mean |effect|',np.abs(eff).mean().round(1))
