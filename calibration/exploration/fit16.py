import numpy as np, csv, colorsys
exec(open('fit15.py').read().split("patches=")[0])   # reuse loaders, bases, slices, shifts, membership
patches=[(r,c) for r in (1,2,3) for c in range(17)]
def lin2ok(c):
    l=0.4122214708*c[0]+0.5363325363*c[1]+0.0514459929*c[2]
    m=0.2119034982*c[0]+0.6806995451*c[1]+0.1073969566*c[2]
    s=0.0883024619*c[0]+0.2817188376*c[1]+0.6299787005*c[2]
    l,m,s=np.cbrt(max(l,0)),np.cbrt(max(m,0)),np.cbrt(max(s,0))
    return np.array([0.2104542553*l+0.7936177850*m-0.0040720468*s,1.9779984951*l-2.4285922050*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.8086757660*s])
B=bases['Rec2020']; Binv=np.linalg.inv(B)
def srgb_enc(x):
    x=np.clip(x,0,None); return np.where(x<=0.0031308,12.92*x,1.055*np.power(x,1/2.4)-0.055)
def srgb_dec(y):
    y=np.clip(y,0,None); return np.where(y<=0.04045,y/12.92,((y+0.055)/1.055)**2.4)
def variant(enc,dec,mode,gain=1.0):
    errs=[];eff=[]
    for p in patches:
        lin=base[p][:3]; w=enc(B@lin); h=hue(w)
        meas=lin2ok(hsl[p][:3]); orig=lin2ok(lin)
        if h is None: pred=orig
        else:
            d=pred_shift(h)*gain
            if mode=='hsv':
                hh,s,v=colorsys.rgb_to_hsv(*np.clip(w,0,1)); hh2=(hh*360+d)%360/360
                w2=np.array(colorsys.hsv_to_rgb(hh2,s,v))
            elif mode=='hsl':
                hh,l,s=colorsys.rgb_to_hls(*np.clip(w,0,1)); hh2=(hh*360+d)%360/360
                w2=np.array(colorsys.hls_to_rgb(hh2,l,s))
            pred=lin2ok(Binv@dec(w2))
        errs.append(np.linalg.norm(pred-meas)*100); eff.append(np.linalg.norm(orig-meas)*100)
    return np.mean(errs),np.max(errs),np.mean(eff)
for name,(enc,dec) in {'sRGB curve':(srgb_enc,srgb_dec),'gamma2.0':(lambda x:np.clip(x,0,None)**0.5,lambda y:np.clip(y,0,None)**2),'gamma2.2':(lambda x:np.clip(x,0,None)**(1/2.2),lambda y:np.clip(y,0,None)**2.2)}.items():
    for mode in ('hsv','hsl'):
        m,mx,e=variant(enc,dec,mode); print(f'{name:11s} {mode}: mean err {m:5.2f} max {mx:5.2f}  (effect mean {e:.2f})')
print('patch, rec2020 hue d, predicted shift (DxO deg), measured OKLab dHue, measured Rec2020-hue change, dChroma(OK), dL(OK)')
enc=lambda x:np.clip(x,0,None)**(1/2.2)
for p in patches[:34]:
    lin=base[p][:3]; w=enc(B@lin); h=hue(w)
    if h is None: continue
    w2=enc(B@hsl[p][:3]); h2=hue(w2)
    o1,o2=lin2ok(lin),lin2ok(hsl[p][:3])
    a1=np.degrees(np.arctan2(o1[2],o1[1])); a2=np.degrees(np.arctan2(o2[2],o2[1]))
    print(p, f'd={h:6.1f} pred={pred_shift(h):+6.1f} measOK={sdiff(a1,a2):+6.1f} measRec={sdiff(h,h2):+6.1f} dC={np.hypot(o2[1],o2[2])-np.hypot(o1[1],o1[2]):+.3f} dL={o2[0]-o1[0]:+.3f}')
print('--- with clipping to the sRGB gamut like the exported file')
def variant2(enc,dec,gain=1.0,keep='hsv'):
    errs=[];eff=[]
    for p in patches:
        lin=base[p][:3]; w=enc(B@lin); h=hue(w); meas=lin2ok(hsl[p][:3]); orig=lin2ok(lin)
        if h is None: pred=orig
        else:
            d=pred_shift(h)*gain
            hh,s,v=colorsys.rgb_to_hsv(*np.clip(w,0,1)); w2=np.array(colorsys.hsv_to_rgb((hh*360+d)%360/360,s,v))
            out=np.clip(Binv@dec(w2),0,1); pred=lin2ok(out)
        errs.append(np.linalg.norm(pred-meas)*100); eff.append(np.linalg.norm(orig-meas)*100)
    return np.mean(errs),np.max(errs),np.mean(eff)
for name,(enc,dec) in {'sRGB curve':(srgb_enc,srgb_dec),'gamma2.2':(lambda x:np.clip(x,0,None)**(1/2.2),lambda y:np.clip(y,0,None)**2.2)}.items():
    for gain in (0.9,1.0,1.1):
        m,mx,e=variant2(enc,dec,gain); print(f'{name:11s} gain {gain}: mean err {m:5.2f} max {mx:5.2f} (effect {e:.2f})')
print('--- variant: keep OKLab lightness and chroma, rotate the OKLab hue by the angle of the pure Rec2020 hues')
def ok2lin(lab):
    l_=lab[0]+0.3963377774*lab[1]+0.2158037573*lab[2]; m_=lab[0]-0.1055613458*lab[1]-0.0638541728*lab[2]; s_=lab[0]-0.0894841775*lab[1]-1.2914855480*lab[2]
    l,m,s=l_**3,m_**3,s_**3
    return np.array([4.0767416621*l-3.3077115913*m+0.2309699292*s,-1.2684380046*l+2.6097574011*m-0.3413193965*s,-0.0041960863*l-0.7034186147*m+1.7076147010*s])
def pure_angle(hdeg,dec):
    w=np.array(colorsys.hsv_to_rgb((hdeg%360)/360,1,1)); lin=Binv@dec(w); o=lin2ok(lin); return np.degrees(np.arctan2(o[2],o[1]))
dec22=lambda y:np.clip(y,0,None)**2.2; enc22=lambda x:np.clip(x,0,None)**(1/2.2)
def variant3(gain=1.0):
    errs=[];eff=[]
    for p in patches:
        lin=base[p][:3]; w=enc22(B@lin); h=hue(w); meas=lin2ok(hsl[p][:3]); orig=lin2ok(lin)
        if h is None: pred=orig
        else:
            d=pred_shift(h)*gain
            rot=np.radians(sdiff(pure_angle(h,dec22),pure_angle(h+d,dec22)))
            a,b=orig[1],orig[2]; pred_lab=np.array([orig[0],a*np.cos(rot)-b*np.sin(rot),a*np.sin(rot)+b*np.cos(rot)])
            pred=lin2ok(np.clip(ok2lin(pred_lab),0,1))
        errs.append(np.linalg.norm(pred-meas)*100); eff.append(np.linalg.norm(orig-meas)*100)
    return np.mean(errs),np.max(errs),np.mean(eff)
for g in (0.9,1.0): print('gain',g,variant3(g))
print('--- worst patches of the HSV-in-Rec2020 model (gamma 2.2, clipped)')
rows=[]
for p in patches:
    lin=base[p][:3]; w=enc22(B@lin); h=hue(w); meas=lin2ok(hsl[p][:3]); orig=lin2ok(lin)
    if h is None: continue
    d=pred_shift(h); hh,s,v=colorsys.rgb_to_hsv(*np.clip(w,0,1)); w2=np.array(colorsys.hsv_to_rgb((hh*360+d)%360/360,s,v))
    pred=lin2ok(np.clip(Binv@dec22(w2),0,1))
    rows.append((np.linalg.norm(pred-meas)*100,p,h,d,orig,meas,pred))
for e,p,h,d,orig,meas,pred in sorted(rows,key=lambda r:-r[0])[:10]:
    print(f'{e:5.2f} {p} d={h:6.1f} shift={d:+5.1f}  orig L {orig[0]:.3f} C {np.hypot(orig[1],orig[2]):.3f} | meas L {meas[0]:.3f} C {np.hypot(meas[1],meas[2]):.3f} ang {np.degrees(np.arctan2(meas[2],meas[1])):6.1f} | pred L {pred[0]:.3f} C {np.hypot(pred[1],pred[2]):.3f} ang {np.degrees(np.arctan2(pred[2],pred[1])):6.1f}')
print('--- variant 4: HSV rotation in Rec2020 gamma, then put the original OKLab lightness back')
def variant4(lkeep=1.0,gain=1.0):
    errs=[];eff=[]
    for p in patches:
        lin=base[p][:3]; w=enc22(B@lin); h=hue(w); meas=lin2ok(hsl[p][:3]); orig=lin2ok(lin)
        if h is None: pred=orig
        else:
            d=pred_shift(h)*gain; hh,s,v=colorsys.rgb_to_hsv(*np.clip(w,0,1)); w2=np.array(colorsys.hsv_to_rgb((hh*360+d)%360/360,s,v))
            rot=lin2ok(Binv@dec22(w2)); lab=np.array([rot[0]+(orig[0]-rot[0])*lkeep,rot[1],rot[2]])
            pred=lin2ok(np.clip(ok2lin(lab),0,1))
        errs.append(np.linalg.norm(pred-meas)*100); eff.append(np.linalg.norm(orig-meas)*100)
    return np.mean(errs),np.max(errs)
for lk in (0.0,0.5,0.8,1.0):
    print('lightness kept',lk,variant4(lk))
