#!/usr/bin/env python3
"""B1 acceptance in an explicitly marked, disposable, booted Linux VM.

Phases: prepare -> external whole-VM reboot -> after-reboot -> restore.
No reboot is issued here. The test creates exactly two labeled containers,
uses an already-pulled immutable BusyBox image, and preserves all evidence.
"""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import signal
import stat
import subprocess
import sys
import time
import uuid


def need(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def protected(path, directory=False):
    path = pathlib.Path(path)
    need(path.is_absolute() and str(path) == os.path.normpath(str(path)), 'path must be normalized absolute')
    for part in reversed((path, *path.parents)):
        s = part.lstat()
        need(s.st_uid == 0 and not s.st_mode & 0o022 and not stat.S_ISLNK(s.st_mode), 'untrusted path: '+str(part))
        need(stat.S_ISDIR(s.st_mode) if part != path or directory else stat.S_ISREG(s.st_mode), 'wrong path type: '+str(part))
    return path


def snapshot(path):
    path = pathlib.Path(path)
    if not path.exists():
        need(not path.is_symlink(), 'configuration symlink refused')
        return {'exists': False}, b''
    protected(path)
    s = path.stat()
    need(s.st_nlink == 1 and s.st_size < 2*1024*1024, 'configuration is not a small single-link file')
    data = path.read_bytes()
    return {'exists': True, 'mode': stat.S_IMODE(s.st_mode), 'uid': s.st_uid, 'gid': s.st_gid, 'sha256': sha(data)}, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare','after-reboot','restore'))
    parser.add_argument('--disposable-marker', required=True, help='root-owned JSON: purpose=terry-toolbox-disposable-vm, machine_id=current /etc/machine-id')
    parser.add_argument('--evidence', required=True, help='new protected absolute evidence directory for prepare; same directory thereafter')
    parser.add_argument('--module', default=str(pathlib.Path(__file__).resolve().parents[1]/'modules/docker-ipv6.sh'))
    parser.add_argument('--image', help='already-pulled immutable busybox@sha256:... image; required for prepare')
    args = parser.parse_args()
    need(sys.platform == 'linux' and os.geteuid() == 0, 'Linux root required')
    need(pathlib.Path('/proc/1/comm').read_text().strip() == 'systemd', 'booted systemd VM required')
    marker = protected(args.disposable_marker)
    need(stat.S_IMODE(marker.stat().st_mode) == 0o600, 'marker must be root-owned 0600')
    machine = pathlib.Path('/etc/machine-id').read_text().strip()
    proof = json.loads(marker.read_text())
    need(proof == {'purpose':'terry-toolbox-disposable-vm','machine_id':machine}, 'explicit disposable VM marker does not match this machine')
    module = protected(args.module)
    source_hash = sha(module.read_bytes())
    harness_hash = sha(protected(pathlib.Path(__file__).resolve()).read_bytes())
    evidence = pathlib.Path(args.evidence)
    if args.phase == 'prepare':
        protected(evidence.parent, directory=True)
        evidence.mkdir(mode=0o700)
    protected(evidence, directory=True)
    need(stat.S_IMODE(evidence.stat().st_mode) == 0o700, 'evidence must be 0700')
    serial = len(list(evidence.glob('command-*.json')))

    def save(name, obj):
        p = evidence/name
        data = (json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2)+'\n').encode()
        temp = evidence/('.'+name+'.'+uuid.uuid4().hex)
        with temp.open('xb') as f:
            os.chmod(temp,0o600); f.write(data); f.flush(); os.fsync(f.fileno())
        temp.replace(p)

    def run(argv, input_data=None, check=True, timeout=90):
        nonlocal serial
        serial += 1
        p = subprocess.Popen(argv, stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        timed_out = False
        started = time.monotonic()
        try:
            out, err = p.communicate(input_data,timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True; os.killpg(p.pid,signal.SIGKILL); out,err = p.communicate()
        save('command-%04d.json'%serial, {'argv':argv,'rc':p.returncode,'seconds':round(time.monotonic()-started,3),
                                       'timeout':timed_out,'stdout':out,'stderr':err,'module_sha256':source_hash,
                                       'harness_sha256':harness_hash})
        need(not timed_out, 'command timed out; evidence preserved')
        if check:need(p.returncode == 0, 'command failed: '+argv[0]+'; inspect private evidence')
        return out.strip(), p.returncode

    def docker(*argv, check=True):
        need(not any(k.startswith('DOCKER_') for k in os.environ), 'clear DOCKER_* environment before native acceptance')
        return run(['docker','--host','unix:///var/run/docker.sock',*argv],check=check)

    def invoke(action):
        return run(['bash','-c','source "$1"; toolbox_docker_ipv6 "$2"','b1-native',str(module),action],
                   input_data='YES\nYES\n' if action != 'status' else '',timeout=600)

    def inspect_owned(item):
        out,_=docker('inspect',item['id'])
        data=json.loads(out)
        need(len(data)==1, 'owned container inspection is ambiguous')
        c=data[0]
        need(c['Id']==item['id'] and c['Name']=='/'+item['name'] and c['Image']==record['image_id']
             and c['Config']['Labels'].get('terry-toolbox.acceptance')==record['token']
             and c['HostConfig']['NetworkMode']=='bridge' and not c['Mounts']
             and c['HostConfig']['RestartPolicy']['Name']=='unless-stopped', 'container ownership/configuration changed')
        need(c['State']['Running'] is True, 'owned container is not running')
        addr=c['NetworkSettings']['Networks']['bridge']['GlobalIPv6Address']
        need(ipaddress.IPv6Address(addr) in ipaddress.IPv6Network(record['subnet']), 'owned container has no expected bridge IPv6')
        return c,addr

    def probe():
        server,addr=inspect_owned(record['containers'][0]); inspect_owned(record['containers'][1])
        expected=record['token']
        for attempt in range(10):
            out,rc=docker('exec',record['containers'][1]['id'],'wget','-qO-','http://['+addr+']:8080/probe',check=False)
            if rc==0 and out==expected:
                save('probe-'+args.phase+'.json',{'passed':True,'server_ipv6':addr,'nonce':expected,
                                                'client_id':record['containers'][1]['id'],'server_id':server['Id'],
                                                'module_sha256':source_hash,'boot_id':boot_id})
                return
            time.sleep(1)
        need(False,'IPv6 unique nonce readback failed; evidence and owned containers retained')

    boot_id=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    record_path=evidence/'native-record.json'
    if args.phase == 'prepare':
        need(args.image and re.fullmatch(r'(?:docker\.io/)?(?:library/)?busybox@sha256:[a-f0-9]{64}',args.image), 'prepare requires immutable BusyBox digest')
        need(not pathlib.Path('/var/lib/terry-toolbox-docker-ipv6').exists(), 'prior B1 evidence exists; do not adopt')
        need(docker('container','ls','--all','--quiet')[0]=='', 'disposable VM must have no existing containers')
        out,_=docker('image','inspect',args.image)
        image=json.loads(out)[0]
        need(re.fullmatch(r'sha256:[a-f0-9]{64}',image['Id']), 'image ID invalid')
        before,data=snapshot('/etc/docker/daemon.json')
        token='b1-'+uuid.uuid4().hex
        record={'schema':1,'phase':'prepared','machine_id':machine,'module_sha256':source_hash,
                'harness_sha256':harness_hash,
                'boot_before':boot_id,'original':before,'original_b64':base64.b64encode(data).decode(),
                'subnet':'fd00:1234::/64','token':token,'image':args.image,'image_id':image['Id'],'containers':[]}
        save('native-record.json',record)
        run(['systemctl','show','docker.service','docker.socket','--all','--no-pager',
             '--property=LoadState,ActiveState,SubState,MainPID,FragmentPath,DropInPaths,Job,UnitFileState'])
        run(['ss','-H','-xlpn'])
        docker('info','--format','{{json .}}'); docker('network','inspect','bridge')
        invoke('apply'); invoke('status')
        record['applied'],_=snapshot('/etc/docker/daemon.json')
        for role in ('server','client'):
            name='toolbox-b1-'+token[3:15]+'-'+role
            command=['sh','-c','mkdir -p /www; printf %s "$1" > /www/probe; exec httpd -f -p [::]:8080 -h /www','http',token] if role=='server' else ['sleep','86400']
            out,_=docker('run','-d','--name',name,'--label','terry-toolbox.acceptance='+token,
                         '--restart','unless-stopped','--network','bridge',args.image,*command)
            need(re.fullmatch(r'[a-f0-9]{64}',out), 'container ID invalid')
            record['containers'].append({'id':out,'name':name,'role':role}); save('native-record.json',record)
        record['phase']='applied'; save('native-record.json',record)
        probe(); print('prepare PASS; reboot this entire disposable VM, then run after-reboot')
    else:
        protected(record_path)
        record=json.loads(record_path.read_text())
        need(record['machine_id']==machine and record['module_sha256']==source_hash
             and record['harness_sha256']==harness_hash, 'machine/source/harness changed since prepare')
        need(record['phase'] in ('applied','reboot-verified'), 'native phase does not permit operation')
        need(snapshot('/etc/docker/daemon.json')[0]==record['applied'], 'B1 configuration changed since prepare')
        if args.phase=='after-reboot':
            need(boot_id!=record['boot_before'], 'whole-VM reboot has not occurred')
            invoke('status'); docker('network','inspect','bridge'); probe()
            record['boot_after']=boot_id;record['phase']='reboot-verified';save('native-record.json',record)
            print('after-reboot PASS; run restore to remove exact owned containers and restore original daemon config')
        else:
            need(record['phase']=='reboot-verified', 'after-reboot acceptance is required before restore')
            for item in record['containers']:
                inspect_owned(item)
                docker('stop','--time','10',item['id'])
                docker('rm',item['id'])
                need(docker('inspect',item['id'],check=False)[1]!=0, 'owned container removal not confirmed')
            invoke('restore'); invoke('status')
            docker('network','inspect','bridge')
            after,data=snapshot('/etc/docker/daemon.json')
            need(after==record['original'] and data==base64.b64decode(record['original_b64']), 'original config bytes/mode not restored')
            record['phase']='restored';record['restored_boot']=boot_id;save('native-record.json',record)
            print('restore PASS; exact original config restored, owned containers removed, evidence retained')


if __name__=='__main__':
    try:main()
    except (RuntimeError,OSError,ValueError,KeyError,TypeError) as exc:
        print('B1 native acceptance failed: '+str(exc),file=sys.stderr)
        sys.exit(1)
