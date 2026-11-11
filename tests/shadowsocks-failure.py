#!/usr/bin/env python3
"""Exercise failing start on isolated guest; identity-checked rollback expected."""
import os,subprocess,sys,tempfile
from pathlib import Path
backend=sys.argv[1];module='/root/ss-test/modules/shadowsocks.sh';unit=Path('/etc/init.d/terry-toolbox-shadowsocks' if backend=='alpine' else '/etc/systemd/system/terry-toolbox-shadowsocks.service');etc=Path('/etc/terry-toolbox-shadowsocks');binary=Path('/usr/local/bin/terry-toolbox-shadowsocks')
assert not unit.exists() and not etc.exists() and not binary.exists()
with tempfile.TemporaryDirectory(prefix='ssx-start-fault-',dir='/root') as d:
 command='rc-service' if backend=='alpine' else 'systemctl'; real='/sbin/rc-service' if backend=='alpine' else '/usr/bin/systemctl'
 wrapper=Path(d)/command;trace=Path(d)/'trace';wrapper.write_text('#!/bin/sh\ncase " $* " in *" start "*) printf reached > '+str(trace)+'; exit 51;; esac\nexec '+real+' "$@"\n');wrapper.chmod(0o755)
 env=os.environ.copy();env['PATH']=d+':'+env.get('PATH','')
 r=subprocess.run(['bash',module,backend,'install','127.0.0.1','38388'],input='YES\nYES\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=180)
 assert r.returncode!=0 and trace.exists()
 if backend=='alpine':
  assert unit.exists() and etc.exists() and binary.exists(), 'ambiguous start must retain resources'
  cleanup=subprocess.run(['bash',module,backend,'uninstall'],input='YES\nYES\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
  assert cleanup.returncode==0 and not unit.exists() and not etc.exists() and not binary.exists()
  print('injected start failure retained uncertain resources; explicit verified uninstall PASS')
 else:
  assert not unit.exists() and not etc.exists() and not binary.exists(), 'failed-start rollback did not complete'
  print('injected service start failure reached and rolled back PASS')
