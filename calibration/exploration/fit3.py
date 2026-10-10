import numpy as np
m=np.array([[-0.477,-0.058,1.0],[0.634,-0.178,-0.897],[1.29,-0.721,0.497],[-0.837,0.601,-0.842]])
h=np.array([231,36,312,104.0])
def design(theta):
    t=np.radians(theta); return np.stack([np.cos(t),np.sin(t)],axis=1)
for name,theta in [('DxO hue as angle',h)]:
    X=design(theta)
    A,res,rk,sv=np.linalg.lstsq(X,m,rcond=None)
    pred=X@A
    print(name,'rms residual',np.sqrt(np.mean((pred-m)**2)).round(3)); print(np.round(pred-m,3))
# add 2nd harmonic
X2=np.concatenate([design(h),design(2*h)],axis=1)
A2=np.linalg.lstsq(X2,m,rcond=None)[0]; print('2 harmonics (exact fit, 4 params per channel):',np.sqrt(np.mean((X2@A2-m)**2)).round(4))
# sums of components per hue
print('sum of components',m.sum(axis=1).round(3))
