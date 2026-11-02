# Works out the dates a repeat rule falls on by testing every day one at a time, as a check on
# TasksCore's evaluator, which works period by period. Reads a JSON list of cases
# ({"name", "rule", "start": "yyyy-MM-dd", "n"}) and prints them with their "expected" dates:
#
#   python3 scripts/repeat-oracle.py cases.json
import calendar, datetime as dt, sys, json
CODES = ["MO","TU","WE","TH","FR","SA","SU"]  # python weekday order

def parse(rule):
    r = {"FREQ":None,"INTERVAL":1,"BYDAY":[],"BYMONTHDAY":[],"BYMONTH":[],"BYSETPOS":[],"WKST":"MO","COUNT":None,"UNTIL":None}
    for part in rule.split(";"):
        k,v = part.split("=")
        if k in ("INTERVAL","COUNT"): r[k]=int(v)
        elif k in ("BYMONTHDAY","BYMONTH","BYSETPOS"): r[k]=[int(x) for x in v.split(",")]
        elif k=="BYDAY":
            out=[]
            for x in v.split(","):
                out.append((int(x[:-2]) if x[:-2] else None, CODES.index(x[-2:])))
            r[k]=out
        elif k=="UNTIL": r[k]=dt.date(int(v[:4]),int(v[4:6]),int(v[6:8]))
        else: r[k]=v
    return r

def dim(y,m): return calendar.monthrange(y,m)[1]

def period_key(r, d, s):
    f=r["FREQ"]
    if f=="DAILY": return (d-s).days
    if f=="WEEKLY":
        wk=CODES.index(r["WKST"])
        ws=lambda x: x-dt.timedelta(days=(x.weekday()-wk)%7)
        return (ws(d)-ws(s)).days//7
    if f=="MONTHLY": return (d.year-s.year)*12+d.month-s.month
    return d.year-s.year

def base(r, d, s):
    f=r["FREQ"]
    if r["BYMONTH"] and d.month not in r["BYMONTH"]: return False
    if f=="YEARLY" and not r["BYMONTH"] and not r["BYMONTHDAY"] and not r["BYDAY"]:
        return d.month==s.month and d.day==s.day
    if r["BYMONTHDAY"]:
        n=dim(d.year,d.month)
        if not any((x if x>0 else n+1+x)==d.day for x in r["BYMONTHDAY"]): return False
    if r["BYDAY"]:
        ok=False
        for (o,w) in r["BYDAY"]:
            if d.weekday()!=w: continue
            if o is None: ok=True; break
            if f=="YEARLY" and not r["BYMONTH"]:
                first=dt.date(d.year,1,1); last=dt.date(d.year,12,31)
            else:
                first=dt.date(d.year,d.month,1); last=dt.date(d.year,d.month,dim(d.year,d.month))
            pos=(d-first).days//7+1; neg=-((last-d).days//7+1)
            if o==pos or o==neg: ok=True; break
        if not ok: return False
    if not r["BYMONTHDAY"] and not r["BYDAY"]:
        if f=="WEEKLY": return d.weekday()==s.weekday()
        if f in ("MONTHLY","YEARLY"): return d.day==s.day
    return True

def occurrences(rule, start, n, horizon_years=60):
    r=parse(rule); s=start; out=[]
    d=s; end=dt.date(s.year+horizon_years,12,31)
    # group candidate days by period, then apply BYSETPOS
    cur=None; bucket=[]
    def flush(bucket):
        if r["BYSETPOS"]:
            sel=set()
            for p in r["BYSETPOS"]:
                i=p-1 if p>0 else len(bucket)+p
                if 0<=i<len(bucket): sel.add(bucket[i])
            bucket=sorted(sel)
        return [x for x in bucket if x>=s]
    # periods may begin before start: start scanning from the period's beginning
    scan=dt.date(s.year,1,1)-dt.timedelta(days=7)
    d=scan
    while d<=end and len(out)<n:
        k=period_key(r,d,s)
        if k!=cur:
            out+=flush(bucket); bucket=[]; cur=k
        if k>=0 and k%r["INTERVAL"]==0 and base(r,d,s): bucket.append(d)
        d+=dt.timedelta(days=1)
    out+=flush(bucket)
    out=sorted(out)
    if r["UNTIL"]: out=[x for x in out if x<=r["UNTIL"]]
    if r["COUNT"]: out=out[:r["COUNT"]]
    return out[:n]

if __name__=="__main__":
    cases=json.load(open(sys.argv[1]))
    res=[]
    for c in cases:
        y,m,dd=map(int,c["start"].split("-"))
        occ=occurrences(c["rule"], dt.date(y,m,dd), c["n"])
        res.append({**c,"expected":[x.isoformat() for x in occ]})
    json.dump(res,sys.stdout,indent=1)
