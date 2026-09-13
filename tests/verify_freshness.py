"""Opt-in compositor/pixel regression; uses only disposable windows on WS 90.

Requires Pillow and grim. Do not interact with the desktop or change Hyprland
settings during this test; cleanup reloads configuration to remove its rule.
"""
import json,subprocess,time,sys
from pathlib import Path
from PIL import Image
if __name__ != '__main__' or sys.argv[1:] != ['--run']:
 raise SystemExit('Usage: python tests/verify_freshness.py --run (briefly switches desktops)')
config=Path(__file__).resolve().parents[1]
fixture_path=Path(__file__).resolve().parent/'capture-fixture'
p=['quickshell','ipc','-p',str(config),'call','overview']
f=['quickshell','ipc','-p',str(fixture_path),'call','fixture']
def run(*args): return subprocess.run(list(args),check=True,capture_output=True,text=True)
def j(c): return json.loads(run('hyprctl','-j',c).stdout)
def state(): return json.loads(run(*p,'status').stdout)
def focus(ws): run('hyprctl','dispatch',f'hl.dsp.focus({{ workspace = "{ws}" }})')
def card(s): return next(w for w in s['windows'] if w['address']==fixture['address'].removeprefix('0x'))
def frame():
 end=time.monotonic()+4
 while time.monotonic()<end:
  s=state()
  if s['visible'] and len(s['windows'])==4 and all(w['thumbnail'] for w in s['windows']) and not s['preparing']:
   time.sleep(.15);return state()
  time.sleep(.025)
 raise RuntimeError(state())
def pixel(s,name):
 zone=next(z for z in s['zones'] if z['kind']=='window' and z['address']==fixture['address'].removeprefix('0x'))
 path=f'/tmp/overview-fixture-{name}.png';run('grim','-s','1',path)
 with Image.open(path) as im: color=im.getpixel((round(zone['x']+zone['width']*.25),round(zone['y']+zone['height']*.25)))
 Path(path).unlink();return color
before=j('clients');original=j('activeworkspace')['id'];active=j('activewindow').get('address')
assert 90 not in [w['id'] for w in j('workspaces')]
assert not state()['visible']
run('quickshell','-p',str(fixture_path),'--no-duplicate','--daemonize')
try:
 run('hyprctl','eval','hl.workspace_rule({ workspace = "90", layout = "scrolling" })')
 focus(90);run(*f,'openFixture')
 fs=json.loads(run(*f,'status').stdout);print('Fixture:',fs,flush=True)
 end=time.monotonic()+2;fixture=None
 while time.monotonic()<end:
  fixture=next((w for w in j('clients') if w['pid']==fs['pid'] and w['title'].startswith('OVERVIEW CACHE FIXTURE')),None)
  if fixture:break
  time.sleep(.05)
 assert fixture, j('clients')
 assert fixture['workspace']['id']==90,fixture
 if fixture['floating']:
  run('hyprctl','dispatch',f'hl.dsp.window.float({{ window = "address:{fixture["address"]}", action = "toggle" }})')
 run('hyprctl','eval','hl.workspace_rule({ workspace = "90", layout = "scrolling" })')
 print('Test layout:',j('activeworkspace')['tiledLayout'],'floating:',next(w for w in j('clients') if w['address']==fixture['address'])['floating'],flush=True)
 assert j('activeworkspace')['tiledLayout']=='scrolling'
 time.sleep(.3)
 run(*p,'openOverview');old=frame();a=pixel(old,'before');print('Tab A pixel:',a,'generation:',card(old)['generation'],flush=True)
 assert a[1]>a[0]*1.4 and a[1]>a[2]*1.3
 run(*p,'close');time.sleep(.1)
 run(*f,'change')
 members=[w for w in j('clients') if w['pid']==fs['pid']]
 target=next(w for w in members if w['address']==fixture['address'])
 peer=max((w for w in members if w['address']!=fixture['address']),key=lambda w: abs(w['at'][0]-target['at'][0]))
 run('hyprctl','dispatch',f'hl.dsp.focus({{ window = "address:{peer["address"]}" }})');time.sleep(.3)
 offscreen=next(w for w in j('clients') if w['address']==fixture['address'])
 monitor=next(m for m in j('monitors') if m['id']==offscreen['monitor'])
 right=monitor['x']+monitor['width']/monitor['scale']
 assert offscreen['at'][0]>right or offscreen['at'][0]+offscreen['size'][0]<monitor['x'], offscreen
 cached=card(state())
 print('After tab change offscreen:',cached,flush=True)
 if cached['generation']==card(old)['generation']: assert not cached['thumbnail'], 'Old tab must be invalidated'
 run(*p,'openOverview');new=frame();b=pixel(new,'after');print('Tab B pixel:',b,'generation:',card(new)['generation'],'primed:',new['primed'],flush=True)
 assert b[2]>b[0]*1.4 and b[2]>b[1]*1.3, 'Expected BLUE new tab, not GREEN cached tab'
 actual=next(w for w in j('clients') if w['address']==fixture['address'])
 assert actual['at']==offscreen['at'],(actual['at'],offscreen['at'])
 print('PASS: new pixels, not just metadata; covered viewport restored',flush=True)
finally:
 run(*p,'close')
 for _ in range(100):
  if not state()['visible']:break
  time.sleep(.025)
 run(*f,'close');time.sleep(.15);focus(original)
 if active and any(w['address']==active for w in j('clients')):
  run('hyprctl','dispatch',f'hl.dsp.focus({{ window = "address:{active}" }})')
 run('hyprctl','reload')
 print('Config errors:',run('hyprctl','configerrors').stdout.strip())
 after={w['address']:w for w in j('clients')}
 assert all(after[w['address']]['workspace']==w['workspace'] for w in before if w['address'] in after)
 print('User window desktop memberships unchanged')
