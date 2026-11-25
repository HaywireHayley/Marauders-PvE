# python summarise.py bridge/recoil_test.txt : per gun and round, the climb of the view shot by shot (degrees, up is positive).
import sys, re, collections
path = sys.argv[1]
cfg = {}; rpm = {}; F = collections.defaultdict(list); SP = collections.defaultdict(list); skipped = []
for line in open(path, encoding='utf8', errors='replace'):
    p = [x.strip() for x in line.rstrip('\n').split(' | ')]
    if p[0] == 'CFG':
        cfg[p[1]] = p[3]; rpm[p[1]] = float(p[2].split()[1])
    elif p[0] == 'F' and len(p) >= 9:
        F[(p[1], p[2])].append(dict(t=float(p[3]), pitch=float(p[4]), yaw=float(p[5]), ads=p[6], shots=int(p[7])))
    elif p[0] == 'S' and len(p) >= 7:
        SP[(p[1], p[2])].append(float(p[6]))
    elif p[0] == 'GUN' and 'skipped' in line:
        skipped.append(p[1] + ' ' + p[2])
def cfgv(g, k):
    m = re.search(r'\b' + k + r'=(\S+)', cfg.get(g, ''))
    return m.group(1) if m else '?'
guns = []
for (g, ph) in F:
    if g not in guns: guns.append(g)
for ph in ('ads free', 'hip free'):
    print(f'\n{ph.upper()}: view after each shot (pitch degrees from eye level, yaw in brackets)')
    print('gun | cfg V / V ADS | rpm | shot 1 | shot 2 | shot 3 | shot 4 | shot 5 | climb per shot | ads flag')
    for g in guns:
        r = F.get((g, ph), [])
        if not r: continue
        cells = []; last = None
        for k in range(1, 6):
            rows = [x for x in r if x['shots'] == k]
            if rows:
                last = rows[-1]; cells.append(f"{last['pitch']:.2f} ({last['yaw']:.2f})")
            else: cells.append('-')
        per = f"{last['pitch'] / max(1, last['shots']):.3f}" if last else '-'
        flag = collections.Counter(x['ads'] for x in r).most_common(1)[0][0]
        print(' | '.join([g, f"{cfgv(g, 'VerticalRecoil')} / {cfgv(g, 'VerticalRecoilADS')}", f"{rpm.get(g, 0):.0f}"] + cells + [per, flag]))
if skipped: print('\nskipped:', ', '.join(skipped))

print('\nBLOOM: how far each shot strayed from where the view pointed (degrees), shot by shot. Rising = the spread grows as you fire.')
print('gun | cfg spread start / per shot / max | part | shot 1 | shot 2 | shot 3 | shot 4 | shot 5 | holes')
for g in guns:
    for ph in ('ads free', 'hip free'):
        r = SP.get((g, ph), [])
        cells = [f'{x:.2f}' for x in r[:5]] + ['-'] * (5 - len(r[:5]))
        print(' | '.join([g, f"{cfgv(g, 'WeaponSpread')} / {cfgv(g, 'FiringSpreadIncrement')} / {cfgv(g, 'FiringSpreadMax')}", ph] + cells + [str(len(r))]))
