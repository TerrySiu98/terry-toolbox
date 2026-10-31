#!/usr/bin/env bash
# B10 two ORIGINAL container products; source-only, does not change Python WebSSH.
# Provenance: registry-1.docker.io raw manifests + Docker-Content-Digest verified
# 2026-10-31. The pins are immutable OCI indexes; explicitly select linux/amd64
# and verify native image/RepoDigests readback. The other index entries may be
# attestations or other platforms and do not imply arm64 support here.
# personal: github.com/jinhuaitao/WebSSH, OCI revision
# 1fda43b09371fa24b4faf4ffc968d10529439f3f. Native cookie login + 2FA exists;
# native config is seeded with local random credentials before first start.
# Upstream saveData uses data.json.tmp + rename: a single data.json bind mount
# is WRONG (EBUSY). Mount a private directory and use /data as working directory;
# original /app/webssh-app stays intact. 077 umask avoids upstream 0644 defaults.
# easynode: github.com/chaos-zhu/easynode; pinned app layer package version 3.8.4,
# app/db.js prints initial credentials, app/config/index.js stores DB + logs in
# /easynode/app/db. Retain them privately; never print Docker logs/inspect secrets.
# guacd is required by upstream guacamole-lite RDP service and has no host port.
# No package installation, hostnet, socket mount, watchtower or image mirrors.
# Loopback and bridge are not a firewall against host users/privileged routing.
# Pins are byte reproducibility, not signature verification or a security audit.

wsc_error() { printf 'B10: %s\n' "$*" >&2; return 1; }
wsc_docker() {
    # flock protects an inode, not its pathname. Re-prove the held descriptor
    # before every Docker mutation, also when a signal/failure invokes cleanup.
    case ${1-}:${2-} in
        pull:*|create:*|start:*|stop:*|rm:*|network:create|network:rm)
            [[ -n ${lockfd-} ]] && wsc_python lock-check "$branch" "$HOME" || return 1 ;;
    esac
    docker --host unix:///var/run/docker.sock "$@"
}

# Embedded stdlib helper keeps the distributed one-file toolbox source-only.
# No ledger is sourced as shell. Seal detects accidental/untrusted edits; a root
# adversary controlling this private directory and key is outside this boundary.
wsc_python() {
    python3 - "${lockfd-}" "$BASHPID" "$@" <<'PY'
import hashlib,hmac,json,os,pathlib,re,secrets,shutil,stat,sys
lockfd,lockpid,act,branch,home=sys.argv[1:6]; args=sys.argv[6:]
root=pathlib.Path(home)/'.local/share/terry-toolbox/webssh-containers'/branch
hexid=re.compile(r'^[0-9a-f]{64}$')
label='org.terry.toolbox.wsc.'
def fail(msg): raise ValueError(msg)
def secure(p,directory=False):
 s=p.lstat()
 if stat.S_ISLNK(s.st_mode) or s.st_uid!=os.geteuid():fail('外来属主/符号链接: '+str(p))
 if directory:
  if not stat.S_ISDIR(s.st_mode) or stat.S_IMODE(s.st_mode)!=0o700:fail('目录须为私有0700: '+str(p))
 elif not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or stat.S_IMODE(s.st_mode)!=0o600:fail('文件须为独立0600: '+str(p))
 return [s.st_dev,s.st_ino,stat.S_IMODE(s.st_mode),s.st_uid]
def paths():
 if not home.startswith('/') or any(c in home for c in ',\n\r\x00') or str(pathlib.Path(home))!=home:fail('HOME路径非规范或含Docker参数分隔符')
 if str(pathlib.Path(home).resolve())!=home:fail('HOME/父路径含符号链接')
 p=pathlib.Path(home)
 if not p.is_dir() or p.stat().st_uid!=os.geteuid():fail('HOME不是当前用户真实目录')
 for part in ('.local','share','terry-toolbox','webssh-containers',branch):
  p=p/part
  if p.is_symlink():fail('数据父路径含符号链接')
  if p.exists():
   s=p.stat()
   if not p.is_dir() or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)&0o022:fail('外来/可被他人写入的数据父目录')
def write_new(p,b):
 fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'wb') as f:f.write(b);f.flush();os.fsync(f.fileno())
def atomic(p,b):
 secure(root,True)
 if p.exists():secure(p)
 t=root/('.'+p.name+'.'+secrets.token_hex(12));write_new(t,b);os.replace(t,p)
def snapshot(p):
 s=p.lstat()
 if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)&0o022:fail('目录父inode/权限不安全')
 return [s.st_dev,s.st_ino,stat.S_IMODE(s.st_mode),s.st_uid]
def body(d):return json.dumps(d,sort_keys=True,separators=(',',':')).encode()
def seal(d):
 k=(root/'seal.key').read_bytes();b=body(d)
 atomic(root/'ledger.json',b);atomic(root/'ledger.mac',hmac.digest(k,b,'sha256').hex().encode())
def load():
 paths();secure(root,True)
 for n in ('seal.key','ledger.json','ledger.mac','lock'):secure(root/n)
 b=(root/'ledger.json').read_bytes();k=(root/'seal.key').read_bytes()
 if len(k)!=32 or not hmac.compare_digest((root/'ledger.mac').read_text(),hmac.digest(k,b,'sha256').hex()):fail('ownership ledger封印损坏，保留全部资源')
 d=json.loads(b)
 if d.get('schema')!=1 or d.get('branch')!=branch or d.get('home')!=home or not hexid.fullmatch(d.get('token','')):fail('ownership ledger内容无效')
 for p,s in d['paths'].items():
  if snapshot(pathlib.Path(p))!=s:fail('目录inode/权限/属主已改变，拒绝接管')
 for p,rec in d['files'].items():
  f=pathlib.Path(p)
  if secure(f)!=rec['stat'] or hashlib.sha256(f.read_bytes()).hexdigest()!=rec['hash']:fail('私有凭据/lock inode或内容已改变')
 if lockfd:
  if not lockfd.isdecimal() or not lockpid.isdecimal():fail('持有锁描述符无效')
  held=os.stat('/proc/'+lockpid+'/fd/'+lockfd)
  expected=d['files'][str(root/'lock')]['stat']
  if [held.st_dev,held.st_ino,stat.S_IMODE(held.st_mode),held.st_uid]!=expected:fail('持有锁fd与ledger inode不同，拒绝变更')
 return d
def read_one(file):
 j=json.loads(pathlib.Path(file).read_text())
 if not isinstance(j,list) or len(j)!=1:fail('Docker返回不完整inspect')
 return j[0]
def critical(c):
 # Engine 29 reports OomKillDisable null after start but false at create inspect;
 # normalize this boolean so the snapshot compare is not a false ownership change.
 hc=dict(c['HostConfig']); hc['OomKillDisable']=bool(hc.get('OomKillDisable'))
 return {'Id':c['Id'],'Name':c['Name'],'Image':c['Image'],'Config':c['Config'],'HostConfig':hc,'Mounts':c['Mounts']}
def network(n):return {k:n[k] for k in ('Id','Name','Driver','Scope','Internal','Attachable','Ingress','Options','Labels')}
def owned_net(d,n):
 if network(n)!=d['network']['critical']:fail('network ID/labels/driver已改变')
 peers=set(n.get('Containers',{}));known={c['id'] for c in d['containers'] if not c.get('removed')}
 if peers-known:fail('独立bridge有未知外来容器，拒绝停止/删除')
def validate_intent(d,c,role,ref,iid):
 if not hexid.fullmatch(c.get('Id','')):fail('container ID无效')
 expected_name='terry-webssh-'+branch+('' if role=='app' else '-guacd')
 cfg=c['Config'];hc=c['HostConfig'];labels=cfg.get('Labels',{})
 if c['Name']!='/'+expected_name or cfg['Image']!=ref or c['Image']!=iid or labels.get(label+'token')!=d['token'] or labels.get(label+'branch')!=branch or labels.get(label+'role')!=role:fail('create readback ownership/image不匹配')
 if hc['NetworkMode']!=d['network']['id'] or hc.get('Privileged') or hc.get('CapAdd') or hc.get('CapDrop')!=['ALL'] or hc.get('SecurityOpt')!=['no-new-privileges'] or not hc.get('ReadonlyRootfs') or hc.get('Binds') or hc.get('RestartPolicy',{}).get('Name')!='unless-stopped':fail('create readback权限/网络不匹配')
 target='8080/tcp' if branch=='personal' else '8082/tcp'
 ports={} if role=='guacd' else {target:[{'HostIp':'127.0.0.1','HostPort':str(d['port'])}]}
 if (hc.get('PortBindings') or {})!=ports:fail('create readback端口暴露不匹配')
 expected=[] if role=='guacd' else [(str(root/'data'),'/data' if branch=='personal' else '/easynode/app/db',True)]
 actual=sorted((m['Source'],m['Destination'],m['RW']) for m in c['Mounts'] if m['Type']=='bind')
 if actual!=expected or any(m['Type'] not in ('bind','tmpfs') for m in c['Mounts']):fail('create readback挂载不匹配')
 if role=='app':
  expected_cmd=['-c','umask 077; exec /app/webssh-app'] if branch=='personal' else ['-c','umask 077; exec node ./index.js']
  expected_cwd='/data' if branch=='personal' else '/easynode'
  if cfg.get('Entrypoint')!=['/bin/sh'] or cfg.get('Cmd')!=expected_cmd or cfg.get('WorkingDir')!=expected_cwd:fail('create readback启动命令不匹配')
 if branch=='personal' and cfg.get('User')!='0:0':fail('personal数据属主不匹配')
try:
 paths()
 if act=='preflight':
  if root.exists() or root.is_symlink():fail('已有安装/失败数据，拒绝自动复用；保留并手工备份检查')
  avail=None
  for line in pathlib.Path('/proc/meminfo').read_text().splitlines():
   if line.startswith('MemAvailable:'):avail=int(line.split()[1])*1024
  if avail is None or avail<512*1024**2 or shutil.disk_usage(home).free<1024**3:fail('需要至少512MiB可用内存和1GiB可用磁盘')
 elif act=='port':
  port=int(args[0]);text=pathlib.Path(args[1]).read_text()
  for line in text.splitlines():
   fields=line.split()
   if len(fields)<5 or fields[0]!='LISTEN':fail('socket输出无法解析，不视为空闲')
   ep=fields[3]
   if ':' not in ep:fail('socket端点未知')
   if ep.rsplit(':',1)[1]==str(port):fail('端口已占用: '+str(port))
 elif act=='daemon':
  j=json.loads(pathlib.Path(args[0]).read_text())
  if j.get('OSType')!='linux' or j.get('Architecture') not in ('amd64','x86_64'):fail('固定镜像仅支持linux/amd64')
  if int(j.get('MemTotal',0))<512*1024**2:fail('Docker可用内存不足512MiB')
  if any('rootless' in x or 'userns' in x for x in j.get('SecurityOptions',[])):fail('当前固定数据权限仅支持rootful且无userns-remap的本机Engine')
 elif act=='image':
  j=read_one(args[0]);ref=args[1]
  if j.get('Os')!='linux' or j.get('Architecture')!='amd64' or ref not in j.get('RepoDigests',[]) or not re.fullmatch('sha256:[0-9a-f]{64}',j.get('Id','')):fail('image digest/arch inspect不匹配')
  print(j['Id'])
 elif act=='init':
  if root.exists() or root.is_symlink():fail('数据路径已存在，拒绝覆盖')
  p=pathlib.Path(home)
  for part in ('.local','share','terry-toolbox','webssh-containers'):
   p=p/part
   if not p.exists():p.mkdir(mode=0o700)
  paths();root.mkdir(mode=0o700);(root/'data').mkdir(mode=0o700)
  for n in ('seal.key','lock'):write_new(root/n,secrets.token_bytes(32) if n=='seal.key' else b'')
  token=secrets.token_hex(32)
  anchors=[];p=root/'data'
  while True:
   anchors.append(p)
   if p==pathlib.Path(home):break
   p=p.parent
  d={'schema':1,'branch':branch,'home':home,'token':token,'port':int(args[0]),'paths':{str(p):snapshot(p) for p in anchors},'files':{},'containers':[],'network':None,'phase':'created'}
  if branch=='personal':
   user='webssh-admin';pwd=secrets.token_urlsafe(32)
   write_new(root/'credentials.txt',('username='+user+'\npassword='+pwd+'\n').encode())
   # EXACT upstream Database.Config schema; pre-initialize native form login.
   write_new(root/'data'/'data.json',json.dumps({'config':{'is_setup':True,'admin_user':user,'admin_pass':pwd},'sessions':{}}).encode())
  for n in ('seal.key','lock')+(('credentials.txt',) if branch=='personal' else ()):
   p=root/n;d['files'][str(p)]={'stat':secure(p),'hash':hashlib.sha256(p.read_bytes()).hexdigest()}
  seal(d);print(token)
 elif act=='load':
  d=load();print(d['port']);print(d['token'])
 elif act=='lock-check':
  if not lockfd:fail('生命周期独占锁未持有')
  load()
 elif act=='credentials-record':
  d=load()
  if branch!='easynode':fail('仅Easynode需要读取原生初始化凭据')
  text=pathlib.Path(args[0]).read_text()
  users=re.findall(r'用户名:\s*([A-Za-z0-9_-]+)',text)
  passwords=re.findall(r'密码:\s*([A-Za-z0-9_-]+)',text)
  if not users or not passwords:sys.exit(2) # native DB/RSA initialization is still pending
  if len(set(users))!=1 or len(set(passwords))!=1:fail('初始化凭据不唯一，保留私有日志供检查')
  p=root/'credentials.txt'
  write_new(p,('username='+users[0]+'\npassword='+passwords[0]+'\n').encode())
  d['files'][str(p)]={'stat':secure(p),'hash':hashlib.sha256(p.read_bytes()).hexdigest()};seal(d)
 elif act=='net-record':
  d=load();n=read_one(args[0]);nid=args[1]
  if not hexid.fullmatch(nid) or n.get('Id')!=nid or n.get('Name')!='terry-webssh-'+branch+'-'+d['token'] or n.get('Driver')!='bridge' or n.get('Scope')!='local' or n.get('Internal') or n.get('Ingress') or n.get('Attachable') or n.get('Options') or n.get('Containers') or n.get('Labels')!={label+'branch':branch,label+'token':d['token']}:fail('network创建读回不匹配，网络/数据保留')
  d['network']={'id':nid,'critical':network(n),'removed':False};seal(d)
 elif act=='container-record':
  d=load();c=read_one(args[0]);cid=args[1];role,ref,iid=args[2:5]
  if c['Id']!=cid:fail('cidfile/container inspect不同')
  validate_intent(d,c,role,ref,iid)
  d['containers'].append({'id':cid,'role':role,'critical':critical(c),'attempted':False,'removed':False});seal(d)
  d['unknown_create']=False;seal(d)
 elif act=='plan':
  d=load()
  if d.get('unknown_create'):fail('create未绑定immutable ID，状态未知；拒绝接管/停止/删除网络')
  if d['network'] and not d['network']['removed']:print('N '+d['network']['id'])
  for c in reversed(d['containers']):
   if not c['removed']:print('C '+c['id'])
 elif act=='verify-net':
  d=load();owned_net(d,read_one(args[0]))
  if len(args)>1 and read_one(args[0]).get('Containers'):fail('network仍有容器连接')
 elif act in ('verify-container','stopped','running'):
  d=load();c=read_one(args[0]);saved=next((x for x in d['containers'] if x['id']==args[1] and not x['removed']),None)
  if saved is None or critical(c)!=saved['critical']:fail('container immutable ID/image/labels/mounts配置已改变')
  state=c['State']
  if act=='stopped' and (state.get('Running') is not False or state.get('Restarting') is not False or state.get('Paused') is not False or state.get('Pid')!=0 or state.get('Status') not in ('exited','created','dead')):fail('stop读回非明确停止状态，保留')
  if act=='running' and (state.get('Running') is not True or state.get('Restarting') or state.get('Paused') or state.get('Dead')):fail('容器未稳定运行')
  if act=='verify-container':print(saved['role']+': '+str(state.get('Status','unknown')))
 elif act in ('attempt','removed','net-removed','ready','create-pending'):
  d=load()
  if act=='create-pending':d['unknown_create']=True
  elif act=='ready':d['phase']='running'
  elif act=='net-removed':d['network']['removed']=True;d['phase']='removed'
  else:
   c=next(x for x in d['containers'] if x['id']==args[0]);c['attempted' if act=='attempt' else 'removed']=True
  seal(d)
 else:fail('未知helper操作')
except (ValueError,OSError,KeyError,TypeError,StopIteration,json.JSONDecodeError) as e:
 print('B10: '+str(e),file=sys.stderr);sys.exit(1)
PY
}

wsc_local_gate() {
    local context endpoint version major
    if [[ -v DOCKER_HOST || -v DOCKER_CONTEXT || -v DOCKER_TLS_VERIFY || -v DOCKER_CERT_PATH || -v DOCKER_API_VERSION ]]; then
        wsc_error '请清除Docker连接环境覆盖；拒绝remote/歧义daemon。'; return 1
    fi
    if ! context=$(docker context show) || [[ $context != default ]] ||
       ! endpoint=$(docker context inspect default --format '{{.Endpoints.docker.Host}}') || [[ $endpoint != unix:///var/run/docker.sock ]]; then
        wsc_error '仅接受default context本机Unix socket；需确认不是远程socket代理。'; return 1
    fi
    if ! version=$(wsc_docker version --format '{{.Server.Version}}') || [[ ! $version =~ ^([0-9]+)\.[0-9]+\.[0-9]+(\+[a-zA-Z0-9.+_-]+)?$ ]]; then
        wsc_error '无法确认稳定版Engine；拒绝prerelease/未知版本。'; return 1
    fi
    major=${BASH_REMATCH[1]}
    if (( ${#major} > 3 || 10#$major < 28 )); then wsc_error '需要Docker Engine >=28以避免旧版loopback泄露。'; return 1; fi
    wsc_docker info --format '{{json .}}' > "$probe" 2>/dev/null && wsc_python daemon "$branch" "$HOME" "$probe" || return 1
}
wsc_confirm() {
    local answer n
    for n in 1 2; do
        printf '确认 %s/2，输入 YES（其他/EOF取消）: ' "$n" >&2
        if ! IFS= read -r answer || [[ ${answer^^} != YES ]]; then wsc_error '已取消。'; return 1; fi
    done
}
wsc_port_gate() {
    if ! ss -H -ltn > "$probe" 2>/dev/null || ! wsc_python port "$branch" "$HOME" "$port" "$probe"; then
        wsc_error '端口占用/状态未知。'; return 1
    fi
}
wsc_name_gate() {
    local text
    if ! text=$(wsc_docker container ls -a --format '{{.Names}}'); then wsc_error '容器名称检查失败。'; return 1; fi
    # Real CLI emits names; fixtures may emit JSON to exercise robust parsing.
    if ! python3 -c 'import sys,json
names=[]
for l in sys.stdin.read().splitlines():
 try:names.append(json.loads(l)["Names"])
 except json.JSONDecodeError:names.append(l)
assert not any(n in names for n in sys.argv[1:])' "terry-webssh-$branch" "terry-webssh-$branch-guacd" <<< "$text" 2>/dev/null; then
        wsc_error '同名容器已存在，不接管、不覆盖。'; return 1
    fi
}
wsc_inspect() { wsc_docker container inspect "$1" > "$probe" 2>/dev/null; }
wsc_net_inspect() { wsc_docker network inspect "$1" > "$probe" 2>/dev/null; }
wsc_resources_verify() {
    local type id plan
    plan=$(wsc_python plan "$branch" "$HOME") || return 1
    while read -r type id; do
        [[ -n $type ]] || continue
        if [[ $type == N ]]; then wsc_net_inspect "$id" && wsc_python verify-net "$branch" "$HOME" "$probe" || return 1
        else wsc_inspect "$id" && wsc_python verify-container "$branch" "$HOME" "$probe" "$id" >/dev/null || return 1; fi
    done <<< "$plan"
}
wsc_absent() {
    local kind=$1 id=$2 text
    # Successful complete listing, NOT failed inspect, proves exact ID is absent.
    if [[ $kind == container ]]; then
        text=$(wsc_docker container ls -a --no-trunc --format '{{.ID}}') || return 1
    else
        text=$(wsc_docker network ls --no-trunc --format '{{.ID}}') || return 1
    fi
    python3 -c 'import sys,json
ids=[]
for l in sys.stdin.read().splitlines():
 try:ids.append(json.loads(l)["ID"])
 except json.JSONDecodeError:ids.append(l)
assert sys.argv[1] not in ids' "$id" <<< "$text" 2>/dev/null
}
wsc_cleanup() {
    local type id plan
    if (( ! cleanup_allowed )); then wsc_error 'create结果未绑定immutable ID；不清理可能有未知容器的网络，全部保留。'; return 1; fi
    # Never perform even owned cleanup after daemon connection ambiguity appears.
    wsc_local_gate || { wsc_error 'cleanup本机daemon门禁失败，全部资源保留。'; return 1; }
    # All ownership/unknown-peer gates precede any stop, including signal cleanup.
    wsc_resources_verify || { wsc_error 'ownership/读回未知；容器、网络和数据全部保留。'; return 1; }
    plan=$(wsc_python plan "$branch" "$HOME") || return 1
    while read -r type id; do
        [[ $type == C ]] || continue
        wsc_inspect "$id" && wsc_python verify-container "$branch" "$HOME" "$probe" "$id" >/dev/null || return 1
        # Always require successful stop after any potentially attempted start.
        if ! wsc_docker stop --time 20 "$id" >> "$log" 2>&1; then wsc_error 'stop失败，保留容器/网络/数据。'; return 1; fi
        if ! wsc_inspect "$id" || ! wsc_python stopped "$branch" "$HOME" "$probe" "$id" || ! wsc_port_gate; then
            wsc_error 'stop读回/端口未明确停止；保留。'; return 1
        fi
        wsc_resources_verify || return 1
        if ! wsc_docker rm "$id" >> "$log" 2>&1 || ! wsc_absent container "$id" || ! wsc_python removed "$branch" "$HOME" "$id"; then
            wsc_error 'rm/不存在读回失败，保留ledger供检查。'; return 1
        fi
    done <<< "$plan"
    while read -r type id; do
        [[ $type == N ]] || continue
        wsc_net_inspect "$id" && wsc_python verify-net "$branch" "$HOME" "$probe" empty || return 1
        if ! wsc_docker network rm "$id" >> "$log" 2>&1 || ! wsc_absent network "$id" || ! wsc_python net-removed "$branch" "$HOME"; then
            wsc_error 'network删除/读回失败；保留ledger。'; return 1
        fi
    done <<< "$plan"
}
wsc_create_start() {
    local role=$1 image=$2 iid=$3 name cidfile cid out rc n native_log
    shift 3
    name="terry-webssh-$branch"; [[ $role == app ]] || name+=-guacd
    cidfile=$data/$role.cid
    # Parent directory is exclusive private; never look up/adopt by name on failure.
    cleanup_allowed=0
    wsc_python create-pending "$branch" "$HOME" || return 1
    out=$(wsc_docker create --platform linux/amd64 --name "$name" --cidfile "$cidfile" --network "$network" \
        --label "org.terry.toolbox.wsc.branch=$branch" --label "org.terry.toolbox.wsc.token=$token" --label "org.terry.toolbox.wsc.role=$role" \
        --restart unless-stopped --read-only --cap-drop ALL --security-opt no-new-privileges \
        --log-driver local --log-opt max-size=10m --log-opt max-file=3 "$@" "$image" "${command_args[@]}" 2>> "$log"); rc=$?
    if [[ ! -f $cidfile || -L $cidfile || ! -O $cidfile ]]; then wsc_error 'create未得到私有cidfile；不按名称接管，数据/网络保留。'; return 1; fi
    IFS= read -r cid < "$cidfile" || [[ -n $cid ]] || return 1
    if [[ ! $cid =~ ^[a-f0-9]{64}$ || ( -n $out && $out != "$cid" ) ]]; then wsc_error 'create ID未知；不接管。'; return 1; fi
    wsc_inspect "$cid" && wsc_python container-record "$branch" "$HOME" "$probe" "$cid" "$role" "$image" "$iid" || return 1
    cleanup_allowed=1
    (( rc == 0 )) || { wsc_error 'create部分失败；已记录的owned容器可卸载，数据保留。'; return 1; }
    wsc_python attempt "$branch" "$HOME" "$cid" || return 1
    if ! wsc_docker start "$cid" >> "$log" 2>&1; then wsc_error 'start失败；执行owned停止/读回门禁，数据保留。'; return 1; fi
    wsc_inspect "$cid" && wsc_python running "$branch" "$HOME" "$probe" "$cid" || return 1
    if [[ $role == app && $branch == easynode ]]; then
        native_log=$(mktemp "$data/native-init.XXXXXXXX.log") || return 1
        # The app starts before native RSA/key DB initialization finishes. Wait
        # for its original credentials, keeping every log byte in private files.
        for ((n=0; n<60; n++)); do
            wsc_resources_verify && wsc_inspect "$cid" && wsc_python running "$branch" "$HOME" "$probe" "$cid" || return 1
            wsc_docker logs "$cid" > "$native_log" 2>&1 || { wsc_error '初始化日志读取失败；容器状态已记录。'; return 1; }
            if wsc_python credentials-record "$branch" "$HOME" "$native_log"; then rc=0; else rc=$?; fi
            (( rc != 0 )) || return 0
            (( rc == 2 )) || return 1
            sleep 1
        done
        wsc_error '60秒内未取得原生初始化凭据；停止仅owned资源，数据/日志保留。'; return 1
    fi
}

toolbox_webssh_container() (
    # No caller secret tracing. Do not export any credentials or pass them in argv.
    set +x
    umask 077
    # shellcheck disable=SC2034 # EXIT trap reads transaction flags.
    local branch=${1-} action=${2-} port=${3-} data probe log token network netout plan type id app_image guacd_image app_iid guacd_iid lockfd initialized=0 install_ok=0 cleanup_allowed=1
    local -a command_args=()
    [[ ( $branch == personal || $branch == easynode ) && ( $action == install || $action == status || $action == uninstall ) && $# -ge 2 && $# -le 3 ]] || { wsc_error '用法: toolbox_webssh_container personal|easynode install [port] | status | uninstall'; return 2; }
    [[ $action == install || $# == 2 ]] || { wsc_error 'status/uninstall不接受端口参数。'; return 2; }
    [[ -n ${HOME-} ]] || { wsc_error 'HOME未设置。'; return 1; }
    (( EUID == 0 )) || { wsc_error '要求root以匹配上游root应用和私有0700数据；不自动提权。'; return 1; }
    for id in docker python3 ss flock mktemp; do command -v "$id" >/dev/null 2>&1 || { wsc_error "缺少依赖$id；不会自动安装。"; return 1; }; done
    # Read-only probes are ephemeral, not application state; cleans on exit.
    probe=$(mktemp "${TMPDIR:-/tmp}/b10-probe.XXXXXXXX") || { wsc_error '无法创建私有临时probe（请设置TMPDIR）。'; return 1; }
    trap 'rm -f -- "$probe"' EXIT
    wsc_local_gate || return 1
    data=$HOME/.local/share/terry-toolbox/webssh-containers/$branch
    if [[ $action != install ]]; then
        if [[ ! -e $data && ! -L $data ]]; then
            wsc_name_gate || return 1
            printf 'B10 %s: 未安装（无ownership ledger）；未接管任何资源。\n' "$branch"; return 0
        fi
        plan=$(wsc_python load "$branch" "$HOME") || return 1
        port=${plan%%$'\n'*}; token=${plan#*$'\n'}
        exec {lockfd}< "$data/lock" || return 1
        if [[ $action == status ]]; then flock -sn "$lockfd" || { wsc_error '生命周期操作进行中。'; return 1; }; else flock -xn "$lockfd" || { wsc_error '生命周期操作进行中。'; return 1; }; fi
        wsc_resources_verify || return 1
        if [[ $action == status ]]; then
            printf 'B10 %s（仅本机 http://127.0.0.1:%s；状态不验证endpoint）\n' "$branch" "$port"
            plan=$(wsc_python plan "$branch" "$HOME") || return 1
            while read -r type id; do [[ $type != C ]] || { wsc_inspect "$id" && wsc_python verify-container "$branch" "$HOME" "$probe" "$id" || return 1; }; done <<< "$plan"
            printf '持久数据/私有凭据保留于: %s\n' "$data"; return 0
        fi
        printf '卸载 %s：停止并删除仅ledger绑定的container IDs/network ID；不删除数据库、凭据、日志或镜像。\n数据保留: %s\n' "$branch" "$data"
        wsc_confirm && wsc_local_gate && wsc_resources_verify || return 1
        # Never follow/overwrite an existing log leaf. Exclusive new private log.
        log=$(mktemp "$data/uninstall.XXXXXXXX.log") || return 1
        wsc_cleanup || return 1
        printf '已卸载owned容器/网络；所有数据库、凭据、日志保留: %s\n' "$data"; return 0
    fi
    port=${port:-8080}; [[ $branch != easynode || $# == 3 ]] || port=8082
    if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$port > 65535 )); then wsc_error '端口须为1–65535十进制，无前导零。'; return 1; fi
    wsc_python preflight "$branch" "$HOME" && wsc_name_gate && wsc_port_gate || return 1
    app_image='jhtone/webssh@sha256:06b2b6191f73a8c1545147593df4fd6ad58a6abbbddb8403c45f4dacbfc5e4df'
    [[ $branch != easynode ]] || app_image='chaoszhu/easynode@sha256:cc3cf7ae9f3f7f5b2650bf7d99bef12cd91f53d69ab53f491e636d23bbf50a8f'
    guacd_image='guacamole/guacd@sha256:8974eaa9ba32f713daf311e7cc8cd7e4cdfba1edea39eed75524e78ef4b08f4f'
    printf 'B10 %s：原上游镜像 %s\n仅linux/amd64，Engine>=28；新建私有0700数据、0600ledger/凭据/日志。\n仅发布127.0.0.1:%s，创建独立bridge；不改防火墙、不启用hostnet/socket/watchtower/mirror。\n失败run/uninstall保留全部数据；已有路径不复用。\n请确认default Unix socket是真正本机，不是远程代理。bridge不隔离宿主用户/特权路由/接入的其他容器。\n' "$branch" "$app_image" "$port"
    if [[ $branch == personal ]]; then
        printf '个人版已有原生login/2FA；随机本地管理员将写入原生config，路径credentials.txt；密码不会回显/进入argv。原程序存明文SSH凭据和管理员密码，且不校验SSH host key，必须保护/备份数据。\n'
    else
        printf '必要guacd: %s（内部4822，不发布宿主端口）。原生随机账号密码写入私有credentials.txt和初始化日志；首次登录立即更换并开启MFA。仅HTTP本机/SSH隧道，外部必须TLS。\n' "$guacd_image"
    fi
    wsc_confirm || return 1
    wsc_local_gate && wsc_python preflight "$branch" "$HOME" && wsc_name_gate && wsc_port_gate || return 1
    token=$(wsc_python init "$branch" "$HOME" "$port") || return 1
    # shellcheck disable=SC2034 # EXIT trap uses this flag.
    initialized=1
    exec {lockfd}< "$data/lock" && flock -xn "$lockfd" || return 1
    log=$(mktemp "$data/install.XXXXXXXX.log") || return 1
    # Failure/signal rollback only touches resources validated against THIS claim.
    trap 'trap - INT TERM; wsc_error "收到信号；停止/读回仅owned资源，保留所有数据。"; exit 130' INT TERM
    trap 'rc=$?; trap - EXIT INT TERM; if (( initialized && ! install_ok )); then wsc_cleanup || :; printf "数据/凭据/私有日志保留: %s\n" "$data" >&2; fi; rm -f -- "$probe"; exit "$rc"' EXIT
    # Pull before creating bridge/containers, no mutable fallback or automatic dependency install.
    if ! wsc_docker pull --platform linux/amd64 "$app_image" >> "$log" 2>&1 || ! wsc_docker image inspect "$app_image" > "$probe" 2>> "$log" || ! app_iid=$(wsc_python image "$branch" "$HOME" "$probe" "$app_image"); then wsc_error '固定镜像拉取/arch/digest读回失败；未换产品。'; return 1; fi
    if [[ $branch == easynode ]]; then
        if ! wsc_docker pull --platform linux/amd64 "$guacd_image" >> "$log" 2>&1 || ! wsc_docker image inspect "$guacd_image" > "$probe" 2>> "$log" || ! guacd_iid=$(wsc_python image "$branch" "$HOME" "$probe" "$guacd_image"); then wsc_error 'guacd固定镜像拉取/读回失败。'; return 1; fi
    fi
    # Recheck after potentially slow pulls to reject context/name/port races.
    wsc_local_gate && wsc_name_gate && wsc_port_gate || return 1
    if ! netout=$(wsc_docker network create --driver bridge --label "org.terry.toolbox.wsc.branch=$branch" --label "org.terry.toolbox.wsc.token=$token" "terry-webssh-$branch-$token" 2>> "$log"); then wsc_error 'network创建失败；不查名称接管。'; return 1; fi
    network=$netout
    [[ $network =~ ^[a-f0-9]{64}$ ]] && wsc_net_inspect "$network" && wsc_python net-record "$branch" "$HOME" "$probe" "$network" || return 1
    if [[ $branch == easynode ]]; then
        command_args=()
        wsc_create_start guacd "$guacd_image" "$guacd_iid" --tmpfs /tmp:rw,noexec,nosuid,size=64m || return 1
        command_args=(-c 'umask 077; exec node ./index.js')
        wsc_create_start app "$app_image" "$app_iid" --user 0:0 --entrypoint /bin/sh --workdir /easynode \
            --mount "type=bind,src=$data/data,dst=/easynode/app/db" --tmpfs /tmp:rw,noexec,nosuid,size=64m \
            --tmpfs /easynode/app/socket/sftp-cache:rw,noexec,nosuid,size=64m \
            --env TZ=Asia/Shanghai --env DEBUG=false --env ENABLE_HTTPS=0 --env COOKIE_SECURE=false --env HTTP_PORT=8082 \
            --env "GUACD_HOST=terry-webssh-easynode-guacd" --env GUACD_PORT=4822 --publish "127.0.0.1:$port:8082" || return 1
    else
        command_args=(-c 'umask 077; exec /app/webssh-app')
        wsc_create_start app "$app_image" "$app_iid" --user 0:0 --entrypoint /bin/sh --workdir /data \
            --mount "type=bind,src=$data/data,dst=/data" --tmpfs /tmp:rw,noexec,nosuid,size=64m \
            --env WEBSSH_GH_PROXY= --publish "127.0.0.1:$port:8080" || return 1
    fi
    wsc_resources_verify && wsc_python ready "$branch" "$HOME" || return 1
    # shellcheck disable=SC2034 # EXIT trap uses this flag.
    install_ok=1
    printf 'Docker已接受并读回运行状态：http://127.0.0.1:%s；endpoint、实际登录/SSH/SFTP仍须VM验收。\n数据/凭据: %s\n私有启动日志: %s\n' "$port" "$data" "$log"
    [[ $branch != personal ]] || printf '原生登录随机凭据仅见: %s/credentials.txt；首次登录立即修改并开启2FA。\n' "$data"
    [[ $branch != easynode ]] || printf '原生随机登录凭据仅见: %s/credentials.txt；初始化日志保存在同一私有目录。\n' "$data"
)
