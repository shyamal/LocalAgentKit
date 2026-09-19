import re,sys,collections
def score(path):
    runs=[l for l in open(path) if l.startswith('P0| p09 goal=')]
    n=len(runs); c=collections.Counter(); cats=collections.Counter(); per=collections.defaultdict(int)
    for l in runs:
        g=re.search(r'goal=(\S+)',l).group(1)
        if 'called=false' in l:
            if 'error=none' in l: cats['no call: answered in text']+=1
            else:
                c['errors']+=1
                e=re.search(r'error=(\S+)',l).group(1)
                kind=('JSON parse failure' if 'ParsingError' in e else 'context overflow' if ('contextSize' in l or 'maximum allowed is 4,096' in l) else 'untyped GenerationError -1 (tokengeneration 10)' if 'GenerationError' in e else e[:60])
                cats['no call: '+kind]+=1
            continue
        c['called']+=1
        valid='schemaValid=true' in l; tool='toolCorrect=true' in l; args='argsCorrect=true' in l
        extra=int(re.search(r'extraCalls=(\d+)',l).group(1))
        c['valid']+=valid; c['tool']+=tool; c['args']+=args; c['followup']+= extra>0
        if valid and args: c['clean']+=1; per[g]+=1; cats['correct']+=1
        elif not valid: cats['schema-invalid call']+=1
        elif not tool: cats['wrong tool']+=1
        else:
            prob=re.search(r'problems=(.*)$',l).group(1)
            if 'not evaluable' in prob: cats['wrong args: calculator syntax']+=1
            elif 'due:not' in prob: cats['wrong args: optional due omitted']+=1
            elif 'off by' in prob: cats['wrong args: wrong date/time']+=1
            else: cats['wrong args: other (missing term/enum)']+=1
    pct=lambda k: f"{c[k]}/{n} = {100*c[k]/n:.0f}%"
    print(f"== {path.split('/')[-1]}  runs={n}")
    for k,lab in [('called','tool called'),('valid','schema-valid'),('tool','right tool'),('args','right tool + args'),('clean','first call fully correct'),('followup','runs with follow-up calls'),('errors','thrown errors')]:
        print(f"  {lab:28s} {pct(k)}")
    print('  outcome breakdown:'); [print(f"    {v:3d}  {k}") for k,v in cats.most_common()]
    return per
per={}
for p in sys.argv[1:]: per[p]=score(p)
goals=[f"st-{i:02d}" for i in range(1,21)]
print('per-goal first-call-correct (of 5):'); print('  goal   '+'  '.join(p.split('-')[-1][:3] for p in sys.argv[1:]))
for g in goals: print(f"  {g}  "+'    '.join(str(per[p].get(g,0)) for p in sys.argv[1:]))
