import numpy as np, csv, itertools
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline'); hsl=load('E9-hsl')
S2X=np.array([[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]])
X2R=np.array([[1.7166512,-0.3556708,-0.2533663],[-0.6666844,1.6164812,0.0157685],[0.0176399,-0.0427706,0.9421031]])
X2P3=np.array([[2.4934969,-0.9313836,-0.4027108],[-0.8294890,1.7626641,0.0236247],[0.0358458,-0.0761724,0.9568845]])
D65D50=np.array([[1.0478112,0.0228866,-0.0501270],[0.0295424,0.9904844,-0.0170491],[-0.0092345,0.0150436,0.7521316]])
X2PRO=np.array([[1.3459433,-0.2556075,-0.0511118],[-0.5445989,1.5081673,0.0205351],[0,0,1.2118128]])@D65D50
bases={'sRGB':np.eye(3),'P3':X2P3@S2X,'Rec2020':X2R@S2X,'ProPhoto':X2PRO@S2X}
encs={'linear':lambda x:np.clip(x,0,None),'gamma2.2':lambda x:np.clip(x,0,None)**(1/2.2),'sqrt':lambda x:np.clip(x,0,None)**0.5,'cbrt':lambda x:np.clip(x,0,None)**(1/3)}
def hue(rgb):
    r,g,b=rgb; mx=max(rgb); mn=min(rgb); c=mx-mn
    if c<1e-6: return None
    if mx==r: h=((g-b)/c)%6
    elif mx==g: h=(b-r)/c+2
    else: h=(r-g)/c+4
    return h*60
def sdiff(a,b): return (b-a+180)%360-180
slices=[('red',325.07,343.759,15.623,31.137),('orange',15.623,31.137,41.144,50.114),('yellow',41.144,50.114,54.533,63.109),('green',54.533,63.109,145.702,171.415),('cyan',145.702,171.415,201.099,216.152),('blue',201.099,216.152,246.546,264.986),('purple',246.546,264.986,275.526,294.798),('magenta',275.526,294.798,325.07,343.759)]
shifts={'red':25.5866,'orange':0,'yellow':0,'green':28.5536,'cyan':-19.2093,'blue':27.1425,'purple':0,'magenta':-27.1258}
def membership(s,h):
    name,fs,fe,os_,oe=s
    rel=lambda x:(x-fs)%360
    t=rel(h); ie=rel(fe); osr=rel(os_); oer=rel(oe)
    if t<=ie: return 1.0 if ie==0 else t/ie
    if t<=osr: return 1.0
    if t<=oer: return 0.0 if oer==osr else 1-(t-osr)/(oer-osr)
    return 0.0
def pred_shift(h): return sum(membership(s,h)*shifts[s[0]] for s in slices)
patches=[(r,c) for r in (1,2,3) for c in range(17)]
for bname,B in bases.items():
    for ename,E in encs.items():
        errs=[]
        for p in patches:
            b=E(B@base[p][:3]); a=E(B@hsl[p][:3])
            hb,ha=hue(b),hue(a)
            if hb is None or ha is None: continue
            errs.append(sdiff(hb,ha)-pred_shift(hb))
        errs=np.array(errs); print(f'{bname:9s} {ename:9s} rms err {np.sqrt(np.mean(errs**2)):6.2f}  median |err| {np.median(np.abs(errs)):5.2f}')
print('--- Rec2020, exponent scan')
def srgb_enc(x):
    x=np.clip(x,0,None); return np.where(x<=0.0031308,12.92*x,1.055*np.power(x,1/2.4)-0.055)
res=[]
B=bases['Rec2020']
for name,E in [(f'x^(1/{e})',(lambda e:(lambda x:np.clip(x,0,None)**(1/e)))(e)) for e in [1.6,1.8,2.0,2.2,2.4,2.6,3.0]]+[('sRGB curve',srgb_enc)]:
    errs=[]
    for p in patches:
        b=E(B@base[p][:3]); a=E(B@hsl[p][:3]); hb,ha=hue(b),hue(a)
        if hb is None or ha is None: continue
        errs.append(sdiff(hb,ha)-pred_shift(hb))
    errs=np.array(errs); print(f'{name:12s} rms {np.sqrt(np.mean(errs**2)):5.2f} median |err| {np.median(np.abs(errs)):5.2f} max {np.abs(errs).max():5.1f}')
