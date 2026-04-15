#!/usr/bin/env python3
"""AI triage for azure-analyzer."""
import argparse,asyncio,json,os,sys
try:
    from copilot import CopilotClient
except ImportError:
    print('ERROR: pip install github-copilot-sdk',file=sys.stderr);sys.exit(1)
SYSTEM_PROMPT="You are an Azure security expert. Triage findings: priority(1=fix first), risk, remediation, related. JSON array only."
DEFAULT_MODEL='gpt-4.1'
FALLBACK=['claude-sonnet-4','gpt-5-mini']
BATCH=12
RETRIES=3
def load(p):
    with open(p,'r',encoding='utf-8') as f: d=json.load(f)
    return d.get('Findings',d) if isinstance(d,dict) else d
def batch(findings):
    s=sorted(findings,key=lambda f:{'High':0,'Medium':1,'Low':2,'Info':3}.get(f.get('Severity','Info'),3))
    return [s[i:i+BATCH] for i in range(0,len(s),BATCH)]
async def triage_batch(client,b,idx,total):
    prompt=f'Triage {len(b)} findings:\\n{json.dumps([{k:f.get(k,"") for k in ("Id","Source","Category","Title","Severity","Detail","Remediation","ResourceId")} for f in b],indent=2)}'
    ids={f.get('Id') for f in b}
    for model in [DEFAULT_MODEL]+FALLBACK:
        for attempt in range(RETRIES):
            try:
                print(f'  Batch {idx+1}/{total}: {model} attempt {attempt+1}',file=sys.stderr)
                r=client.create_session(model=model,system_message=SYSTEM_PROMPT).send(prompt)
                t=r.strip()
                if t.startswith('$$$'+'$$$'): t='\\n'.join(l for l in t.split('\\n') if not l.strip().startswith('$$$'+'$$$')).strip()
                e=json.loads(t)
                return {x['Id']:x for x in e if x.get('Id') in ids}
            except Exception as ex: print(f'    {ex}',file=sys.stderr)
            await asyncio.sleep(2.0*(2**attempt))
    return {}
async def run(inp,out):
    findings=load(inp);nc=[f for f in findings if not f.get('Compliant',True)]
    if not nc: write(findings,{},out);return
    print(f'Triaging {len(nc)} findings',file=sys.stderr)
    batches=batch(nc);client=CopilotClient();enrichments={}
    for i,b in enumerate(batches): enrichments.update(await triage_batch(client,b,i,len(batches)))
    write(findings,enrichments,out);print(f'Done: {len(enrichments)}/{len(nc)} enriched',file=sys.stderr)
def write(findings,enrichments,path):
    out=[]
    for f in findings:
        e=dict(f);fid=f.get('Id','')
        if fid in enrichments: ai=enrichments[fid];e.update(AiPriority=ai.get('AiPriority'),AiRiskContext=ai.get('AiRiskContext',''),AiRemediation=ai.get('AiRemediation',''),AiRelatedFindings=ai.get('AiRelatedFindings',[]))
        else: e.update(AiPriority=None,AiRiskContext='',AiRemediation='',AiRelatedFindings=[])
        out.append(e)
    out.sort(key=lambda x:(x['AiPriority'] is None,x['AiPriority'] or 9999))
    os.makedirs(os.path.dirname(path) or '.',exist_ok=True)
    with open(path,'w',encoding='utf-8') as f: json.dump(out,f,indent=2,ensure_ascii=False)
def main():
    p=argparse.ArgumentParser();p.add_argument('--input',default='output/results.json');p.add_argument('--output',default='output/triage.json')
    a=p.parse_args()
    if not os.path.isfile(a.input): print(f'ERROR: {a.input} not found',file=sys.stderr);sys.exit(1)
    tk=os.environ.get('COPILOT_GITHUB_TOKEN') or os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not tk: print('ERROR: No token',file=sys.stderr);sys.exit(1)
    if tk.startswith('ghs_'): print('ERROR: ghs_ unsupported',file=sys.stderr);sys.exit(1)
    try: asyncio.run(run(a.input,a.output))
    except Exception as e: print(f'ERROR: {e}',file=sys.stderr);sys.exit(1)
if __name__=='__main__': main()
