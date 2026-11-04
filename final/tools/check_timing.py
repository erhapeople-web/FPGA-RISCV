"""Fail on any reported setup/hold/recovery/removal endpoint violation."""
import argparse
import json
from pathlib import Path
import re

ap=argparse.ArgumentParser()
ap.add_argument('report',type=Path)
ap.add_argument('--out',type=Path,required=True)
ap.add_argument('--clock',default='cpu_clk')
a=ap.parse_args()
text=a.report.read_text(encoding='utf-8',errors='replace')
rows=[]
section=None
for line in text.splitlines():
    m=re.match(r'(Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\((Slow|Fast) Corner\):',line.strip())
    if m:
        section=m.groups()
        continue
    if 'Summary(' in line and not m:
        section=None
    if section:
        if section[0]=='Minimum Pulse Width':
            pulse=re.fullmatch(r'\s*(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*',line)
            if pulse:
                clock,slack,total,failed,endpoints=pulse.groups()
                rows.append({'check':section[0],'corner':section[1],'launch':clock,'capture':clock,
                             'slack_ns':float(slack),'total_negative_slack_ns':float(total),
                             'failed_endpoints':int(failed),'endpoints':int(endpoints)})
            continue
        m=re.fullmatch(r'\s*(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*',line)
        if m:
            source,dest,slack,total,failed,endpoints=m.groups()
            rows.append({'check':section[0],'corner':section[1],'launch':source,'capture':dest,
                         'slack_ns':float(slack),'total_negative_slack_ns':float(total),
                         'failed_endpoints':int(failed),'endpoints':int(endpoints)})
assert rows, 'No timing summary rows parsed'
for corner in ['Slow','Fast']:
    for check in ['Setup','Hold']:
        assert any(r['corner']==corner and r['check']==check and r['launch']==r['capture']==a.clock for r in rows), (corner,check)
    assert any(r['corner']==corner and r['check']=='Minimum Pulse Width' for r in rows),corner
failed=[r for r in rows if r['failed_endpoints'] or r['slack_ns']<0]
cpu=[r for r in rows if r['launch']==r['capture']==a.clock]
setup=min(r['slack_ns'] for r in cpu if r['check']=='Setup')
hold=min(r['slack_ns'] for r in cpu if r['check']=='Hold')
result={'passed':not failed,'report':str(a.report.resolve()),'scope':'routed static timing summaries only; no physical board or thermal claim',
        'cpu_setup_ns':setup,'cpu_hold_ns':hold,'cpu_margin_goal_met':setup>=0.3 and hold>=0.05,
        'failed_groups':failed,'groups':rows}
a.out.write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps({k:result[k] for k in ['passed','cpu_setup_ns','cpu_hold_ns','cpu_margin_goal_met','failed_groups']},indent=2))
raise SystemExit(0 if result['passed'] else 1)
