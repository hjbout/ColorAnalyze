# Fits the Luminance / Master / Balance behaviour of PhotoLab's Color Grading on top of the tint model (fit14.py).
import csv, numpy as np
M = np.array([[0.627452,0.329249,0.043299],[0.069109,0.919531,0.011360],[0.016398,0.088030,0.895572]])
d = np.load('model_final_inputs.npz'); xs, K, hs, D = d['xs'], d['K'], d['hs'], d['D']
def load(f):
    rows = list(csv.reader(open('exports/'+f+'.csv')))[1:]
    return np.array([[float(x) for x in r[2:5]] for r in rows])
def wide(lin): return lin @ M.T
def curve(r, x): return np.interp(x, xs, K[r])
base = wide(load('E0-baseline'))

# ---- HSL helpers
def enc(x):
    x=np.clip(x,0,1); return np.where(x<=0.0031308,12.92*x,1.055*np.power(x,1/2.4)-0.055)
def hsv(w):
    e=enc(w); hi=e.max(1); lo=e.min(1); c=hi-lo
    r,g,b=e[:,0],e[:,1],e[:,2]
    h=np.where(c<1e-9,0,np.where(hi==r,((g-b)/np.maximum(c,1e-9))%6,np.where(hi==g,2+(b-r)/np.maximum(c,1e-9),4+(r-g)/np.maximum(c,1e-9))))*60%360
    return h, np.where(hi>0,c/np.maximum(hi,1e-9),0), hi
SL=[('red',325.07,343.759,15.623,31.137),('orange',15.623,31.137,41.144,50.114),('yellow',41.144,50.114,54.533,63.109),
    ('green',54.533,63.109,145.702,171.415),('cyan',145.702,171.415,201.099,216.152),('blue',201.099,216.152,246.546,264.986),
    ('purple',246.546,264.986,275.526,294.798),('magenta',275.526,294.798,325.07,343.759)]
def memb(h,s):
    _,a,b,c,d=s; rel=lambda x:(x-a)%360
    t=rel(h); ie,os_,oe=rel(b),rel(c),rel(d)
    return np.where(t<=ie,t/ie,np.where(t<=os_,1,np.where(t<=oe,1-(t-os_)/(oe-os_),0)))
def sigma(h,vals):   # vals: dict channel->param
    return sum(memb(h,s)*vals.get(s[0],0) for s in SL)
def oklab(lin):
    m1=np.array([[0.4122214708,0.5363325363,0.0514459929],[0.2119034982,0.6806995451,0.1073969566],[0.0883024619,0.2817188376,0.6299787005]])
    l=np.cbrt(lin@m1.T); m2=np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
    return l@m2.T
