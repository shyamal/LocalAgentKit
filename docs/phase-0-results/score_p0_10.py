"""Summarises a P0-10 log: completion, and for each failed run the first reason it failed."""
import json, re, sys, collections
suite = json.load(open(sys.argv[1]))
steps = {g['id']: {s['id']: s for s in g['steps']} for g in suite['goals']}
for path in sys.argv[2:]:
    runs = [l for l in open(path) if l.startswith('P0| p10 goal=')]
    done = sum('completed=true' in l for l in runs)
    reasons = collections.Counter()
    for l in runs:
        if 'completed=true' in l: continue
        g = re.search(r'goal=(\S+)', l).group(1)
        trace = re.search(r'trace=(.*)$', l).group(1)
        called = {c.split('{')[0].strip() for c in trace.split(' > ') if c}
        if 'ending=error' in l: reasons['framework error ended the run'] += 1
        elif re.search(r'forbidden=\S', l): reasons['conditional: did the forbidden action'] += 1
        elif (u := re.search(r'firstUnmatched=(\S+)', l).group(1)) != '-':
            st = steps[g][u]
            grounded = any('groundedIn' in m for m in st.get('arguments', {}).values())
            if st['tool'] not in called: reasons['skipped a required step'] += 1
            elif grounded: reasons["called it, but didn't use earlier tool output (grounding)"] += 1
            else: reasons['called it with wrong arguments (dates, terms)'] += 1
        elif re.search(r'overConfirmed=\S', l): reasons['extra side-effect / sensitive calls'] += 1
        elif 'ending=maxIterations' in l: reasons['hit maxIterations'] += 1
        else: reasons['other'] += 1
    print(f"== {path.split('/')[-1]}: completed {done}/{len(runs)} = {100*done/len(runs):.0f}%")
    for k, v in reasons.most_common(): print(f"   {v:3d}  {k}")
