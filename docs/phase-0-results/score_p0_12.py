"""Summarises a P0-12 log: per profile, the exhaustion rate and what happened to facts that
were in context (recalled) versus trimmed out (abstained / hallucinated)."""
import re, sys, collections

for path in sys.argv[1:]:
    rows = [l for l in open(path) if l.startswith('P0| p12 profile=')]
    per = collections.defaultdict(collections.Counter)
    tokens = {}
    for l in rows:
        p = re.search(r'profile=(\S+)', l).group(1)
        outcome = re.search(r'outcome=(\S+)', l).group(1)
        per[p][outcome] += 1
        tokens[p] = max(tokens.get(p, 0), int(re.search(r'tokens=(\d+)', l).group(1)))
    print(f"== {path.split('/')[-1]}: {len(rows)} runs")
    print(f"   {'profile':8s} {'tokens':>6s} {'exhausted':>10s} {'untyped err':>12s} "
          f"{'recall (in context)':>20s} {'kept out: abstain/halluc':>26s}")
    for p in ['light', 'typical', 'heavy', 'stress']:
        c = per.get(p)
        if not c:
            continue
        exh = sum(v for k, v in c.items() if k.startswith('exceeded'))
        oth = sum(v for k, v in c.items() if k.startswith('otherError'))
        rec = c['recalled']
        miss = c['missed'] + c['missed:toolDetour']
        avail = rec + miss
        abst, hall, leak = c['abstained'], c['hallucinated'], c['leaked']
        n = sum(c.values())
        print(f"   {p:8s} {tokens[p]:6d} {exh:4d}/{n:<5d} {oth:12d} "
              f"{rec:>10d}/{avail:<9d} {abst:>12d}/{hall:<13d}" + (f"  leaked={leak}" if leak else ""))
