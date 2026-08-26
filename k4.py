import json,glob,os
K=4.0; WIN=10; TOL=0.20
def median(xs):
    s=sorted(xs); return s[len(s)//2] if s else 0
def cnt(p):
    d=json.load(open(p,encoding='utf-8'))
    rr=d['rrValues']; sa=d['rrStartAbs']; ea=d['rrEndAbs']; rec=d['rrRecovered']
    pts=[(rr[i],sa[i],ea[i]) for i in range(len(rr)) if not rec[i]]
    n=len(pts); f=0
    for i in range(1,n-2):
        if pts[i][1]!=pts[i-1][2] or pts[i+1][1]!=pts[i][2] or pts[i+2][1]!=pts[i+1][2]: continue
        lo=max(0,i-WIN//2); hi=min(n,lo+WIN)
        m=median([pts[j][0] for j in range(lo,hi)])
        if m<=0: continue
        dabs=[abs(pts[j][0]-pts[j-1][0]) for j in range(lo+1,hi) if pts[j][1]==pts[j-1][2]]
        if len(dabs)<3: continue
        dmed=median(dabs); thr=dmed+K*median([abs(x-dmed) for x in dabs])
        d1=pts[i][0]-pts[i-1][0]; d2=pts[i+1][0]-pts[i][0]
        if d1<-thr and d2>thr and abs(pts[i-1][0]-m)<=TOL*m and abs(pts[i+2][0]-m)<=TOL*m: f+=1
    return f,n
SNAP='C:/Users/AQUIVIO/Desktop/max30102_snapshots'
for f in ['snap_2026-07-20_141725_1784528245833.json','snap_2026-07-20_144200_1784529720015.json','snap_2026-07-20_131406_1784524446506.json']:
    p=os.path.join(SNAP,f)
    if os.path.exists(p):
        c,n=cnt(p); print(f'{f[:28]}  k=4 → {c} 顆 / {n} 拍')
