import numpy as np, csv
def load(name):
    d={}
    for r in csv.DictReader(open(f'exports/{name}.csv')):
        d[(int(r['row']),int(r['col']))]=np.array([float(r[k]) for k in ('lr','lg','lb','L','a','b')])
    return d
base=load('E0-baseline')
names={'E1':'E1-shadows-231-100','E2':'E2-midtones-231-100','E3':'E3-highlights-231-100'}
exp={k:load(v) for k,v in names.items()}
Lg=np.array([base[(0,c)][3] for c in range(17)])
for k in ['E1','E2','E3']:
    prof_ab=np.array([exp[k][(0,c)][4:]-base[(0,c)][4:] for c in range(17)])   # gray (a,b) delta by L
    rows=[]
    for row in range(1,4):
        for col in range(17):
            b=base[(row,col)]; meas=exp[k][(row,col)][4:]-b[4:]
            pred=np.array([np.interp(b[3],Lg,prof_ab[:,0]),np.interp(b[3],Lg,prof_ab[:,1])])
            rows.append((row,col,b[3],np.hypot(b[4],b[5]),meas,pred))
    err=np.array([r[4]-r[5] for r in rows]); eff=np.array([r[4] for r in rows])
    print(k,'OKLab additive model: rms err',np.sqrt(np.mean(err**2)).round(4),' rms effect',np.sqrt(np.mean(eff**2)).round(4))
    # show a few
    for r in rows[:0]: pass
    # per row
    for row in (1,2,3):
        sel=[i for i,r in enumerate(rows) if r[0]==row]
        print('   row',row,'rms err',np.sqrt(np.mean(err[sel]**2)).round(4),' rms effect',np.sqrt(np.mean(eff[sel]**2)).round(4))
# detail for E2 row 1: measured vs predicted along hues
k='E2'; Lg=np.array([base[(0,c)][3] for c in range(17)]); prof_ab=np.array([exp[k][(0,c)][4:]-base[(0,c)][4:] for c in range(17)])
print('E2 row1: col, base L, base chroma, measured (da,db), predicted (da,db)')
for col in range(17):
    b=base[(1,col)]; meas=exp[k][(1,col)][4:]-b[4:]
    pred=np.array([np.interp(b[3],Lg,prof_ab[:,0]),np.interp(b[3],Lg,prof_ab[:,1])])
    print(col,round(b[3],3),round(np.hypot(b[4],b[5]),3),meas.round(4),pred.round(4))
