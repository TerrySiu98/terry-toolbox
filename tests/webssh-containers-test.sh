#!/usr/bin/env bash
# Docker/socket/available-memory boundaries are mocked; real filesystem/ledger checks.
set -euo pipefail
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/wsc-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/mock" "$work/home"
real_python=$(command -v python3)
# The Docker daemon is synthetic; host RAM contention is also an unrelated
# fixture fact. Keep filesystem/ledger code real while providing deterministic
# /proc/meminfo to the embedded helper only (never a product env override).
cat > "$work/bin/python3" <<'PY'
#!/usr/bin/env python3-real
import pathlib,sys
code=sys.stdin.read() if len(sys.argv)>1 and sys.argv[1]=='-' else None
if code is not None:
 if "label='org.terry.toolbox.wsc.'" in code:
  original=pathlib.Path.read_text
  def fixture_read(p,*a,**k):
   return 'MemAvailable: 2097152 kB\n' if str(p)=='/proc/meminfo' else original(p,*a,**k)
  pathlib.Path.read_text=fixture_read
 sys.argv=['-',*sys.argv[2:]]
 exec(compile(code,'<wsc-helper>','exec'))
else:
 import os
 os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
PY
ln -s "$real_python" "$work/bin/python3-real"
chmod +x "$work/bin/python3"
cp "$base/tests/webssh-containers-mock.py" "$work/bin/docker"
chmod +x "$work/bin/docker"
ln -s docker "$work/bin/ss"
export PATH="$work/bin:$PATH" WSC_MOCK="$work/mock" HOME="$work/home"
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
# Before module exists, RED is an explicit missing public behavior, not source/import failure.
if [[ -f $base/modules/webssh-containers.sh ]]; then source "$base/modules/webssh-containers.sh"; fi
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
declare -F toolbox_webssh_container >/dev/null || fail 'B10 personal/easynode public lifecycle implementation missing'
reset_case() {
  rm -rf -- "$HOME/.local" "${WSC_MOCK:?}"/*
  unset MOCK_CONTEXT MOCK_ENDPOINT MOCK_VERSION MOCK_OFFLINE MOCK_ARCH MOCK_PORT MOCK_SS_FAIL MOCK_NAME MOCK_LIST_FAIL MOCK_PULL_FAIL MOCK_IMAGE_INSPECT MOCK_NETWORK_FAIL MOCK_NETWORK_READ_FAIL MOCK_CREATE_FAIL MOCK_START_FAIL MOCK_STOP_FAIL MOCK_READ_FAIL MOCK_RUNNING_READBACK MOCK_TAMPER MOCK_PEER MOCK_SIGNAL MOCK_RM_FAIL MOCK_NETWORK_RM_FAIL MOCK_POST_RM_LIST_FAIL MOCK_MEM MOCK_SECURITY MOCK_IMAGE_ARCH MOCK_IMAGE_DIGEST MOCK_STOP_ROLE MOCK_LOG_DELAY MOCK_REPLACE_LOCK
}
reject() { if toolbox_webssh_container "$@" >"$work/output" 2>&1; then fail "accepted $*"; fi; }
no_mutation() {
  python3 - "$WSC_MOCK" <<'PY'
import pathlib,json,sys
r=pathlib.Path(sys.argv[1]);p=r/'calls.jsonl'
for c in map(json.loads,p.read_text().splitlines() if p.exists() else []):
 a=c[1:];a=a[2:] if a[:1]==['--host'] else a
 assert a[:1] not in (['pull'],['create'],['start'],['stop'],['rm']),c
 assert a[:2] not in (['network','create'],['network','rm']),c
PY
  [[ ! -e $HOME/.local ]] || fail 'cancel/preflight wrote data'
}
for input in $'no\n' $'YES\nno\n' 'YES' $'YES\nYES'; do
 reset_case; reject personal install 8080 <<<"" # blank is rejected
 printf '%s' "$input" | reject personal install 8080
 no_mutation
done
reset_case; reject personal install </dev/null; no_mutation
for p in 0 00080 65536 8e3 evil; do
 reset_case; reject personal install "$p" <<< $'YES\nYES'; no_mutation
done
reset_case; export MOCK_NAME=terry-webssh-easynode-guacd
reject easynode install <<< $'YES\nYES'; no_mutation
for v in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION; do
 reset_case; export "$v="; reject personal install 8080 <<< $'YES\nYES'; unset "$v"; no_mutation
 [[ ! -e $WSC_MOCK/calls.jsonl ]] || fail 'Docker env override reached CLI'
done
for pair in MOCK_CONTEXT=remote MOCK_ENDPOINT=tcp://remote:2375 MOCK_VERSION=27.9.0 MOCK_VERSION=28.0.0-rc1 MOCK_VERSION=invalid MOCK_ARCH=aarch64 MOCK_OFFLINE=1 MOCK_SS_FAIL=1 MOCK_PORT=8080 MOCK_NAME=terry-webssh-personal MOCK_LIST_FAIL=1 MOCK_MEM=100 MOCK_SECURITY=name=rootless MOCK_SECURITY=name=userns; do
 reset_case; export "${pair?}"; reject personal install 8080 <<< $'YES\nYES'; no_mutation
done
for branch in personal easynode; do
 reset_case
 toolbox_webssh_container "$branch" install <<< $'YES\nYES' >"$work/output" 2>&1 || { printf '%s\n' "$(< "$work/output")"; fail "install $branch"; }
 data="$HOME/.local/share/terry-toolbox/webssh-containers/$branch"
 [[ -f $data/ledger.json && -f $data/ledger.mac ]] || fail 'ledger absent'
 toolbox_webssh_container "$branch" status >"$work/status" || fail 'status'
 python3 - "$WSC_MOCK" "$data" "$branch" "$work/output" <<'PY'
import pathlib,json,sys,stat
r,d,b,o=map(pathlib.Path,sys.argv[1:]);s=json.loads((r/'state.json').read_text());assert len(s['containers'])==(1 if str(b)=='personal' else 2)
calls=[c[3:] if c[1:2]==['--host'] else c[1:] for c in map(json.loads,(r/'calls.jsonl').read_text().splitlines())]
for call in calls:
 if call[:1] in (['pull'],['create']):assert call[1:3]==['--platform','linux/amd64'],call
for c in s['containers'].values():
 assert c['Config']['Image'].count('@sha256:')==1
 assert not c['HostConfig']['Privileged'];assert c['HostConfig']['NetworkMode'] in s['networks']
 for p in c['HostConfig']['PortBindings'].values():assert all(x['HostIp']=='127.0.0.1' for x in p)
 assert all('docker.sock' not in m['Source'] for m in c['Mounts'])
 if 'guacd' in c['Name']:assert not c['HostConfig']['PortBindings']
for f in ['ledger.json','ledger.mac','seal.key']:
 assert stat.S_IMODE((d/f).stat().st_mode)==0o600
assert stat.S_IMODE((d/'credentials.txt').stat().st_mode)==0o600
credentials=(d/'credentials.txt').read_text()
for line in credentials.splitlines():assert line.split('=',1)[1] not in o.read_text()
assert 'private-fixture-password' not in o.read_text()
if str(b)=='personal':
 creds=(d/'credentials.txt').read_text();assert creds not in o.read_text();assert stat.S_IMODE((d/'credentials.txt').stat().st_mode)==0o600
 assert (d/'data'/'data.json').is_file()
 assert any(m['Destination']=='/data' for c in s['containers'].values() for m in c['Mounts'])
PY
 printf 'keep' > "$data/sentinel"
 reject "$branch" uninstall <<< $'YES\nno'
 toolbox_webssh_container "$branch" uninstall <<< $'yes\nYeS' >"$work/remove" 2>&1 || fail "uninstall $branch"
 [[ $(< "$data/sentinel") == keep ]] || fail 'database deleted'
 python3 - "$WSC_MOCK/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]));assert not s['containers'];assert not s['networks']
PY
 reject "$branch" install <<< $'YES\nYES' # retained state not silently reused
 done
printf 'PASS: B10 cancellation/preflight/install/status/uninstall\n'
# Stateful failure rollback, real SIGTERM, and destructive gates.
count_state() {
 python3 - "$WSC_MOCK" "${1?}" "${2?}" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])/'state.json';s=json.loads(p.read_text()) if p.exists() else {'containers':{},'networks':{}}
assert len(s['containers'])==int(sys.argv[2]),s
assert len(s['networks'])==int(sys.argv[3]),s
PY
}
for pair in MOCK_PULL_FAIL=1 MOCK_IMAGE_INSPECT=1 MOCK_IMAGE_ARCH=arm64 MOCK_IMAGE_DIGEST=1 MOCK_NETWORK_FAIL=1 MOCK_CREATE_FAIL=before MOCK_CREATE_FAIL=after MOCK_START_FAIL=personal; do
 printf 'CHECK: %s\n' "$pair"
 reset_case; export "${pair?}"
 reject personal install <<< $'YES\nYES'
 [[ -f $HOME/.local/share/terry-toolbox/webssh-containers/personal/data/data.json ]] || fail "failure erased data $pair"
 if [[ $pair == MOCK_CREATE_FAIL=before ]]; then count_state 0 1; else count_state 0 0; fi
 done
reset_case; export MOCK_START_FAIL=easynode
reject easynode install <<< $'YES\nYES'; count_state 0 0
reset_case; export MOCK_START_FAIL=easynode MOCK_STOP_FAIL=1
reject easynode install <<< $'YES\nYES'; count_state 2 1
reset_case; export MOCK_START_FAIL=personal MOCK_RUNNING_READBACK=1
reject personal install <<< $'YES\nYES'; count_state 1 1
wsc_signal_case() {
 # Keep the same nested caller shape as other rejected lifecycle operations.
 # Under Bash errexit, a failing diagnostic in TERM must not unwind the claim.
 if toolbox_webssh_container personal install <<< $'YES\nYES' >"$work/output" 2>&1; then
  fail 'SIGTERM installation succeeded'
 else
  signal_rc=$?
 fi
 [[ $signal_rc == 130 ]] || { cat "$work/output" >&2; fail "SIGTERM lost explicit exit status: $signal_rc"; }
 [[ $(< "$work/output") != *'unbound variable'* ]] || fail 'SIGTERM EXIT lost its local transaction state'
}
for stop_fail in 0 1; do
 printf 'CHECK: SIGTERM stop_fail=%s\n' "$stop_fail"
 reset_case; export MOCK_SIGNAL=1
 [[ $stop_fail == 0 ]] || export MOCK_STOP_FAIL=1
 wsc_signal_case
 [[ -f $HOME/.local/share/terry-toolbox/webssh-containers/personal/credentials.txt ]] || fail 'signal deleted secrets'
 if [[ $stop_fail == 0 ]]; then count_state 0 0; else count_state 1 1; fi
 done
for pair in MOCK_STOP_FAIL=1 MOCK_RUNNING_READBACK=1 MOCK_READ_FAIL=1 MOCK_NETWORK_READ_FAIL=1 MOCK_TAMPER=1 MOCK_TAMPER=mount MOCK_TAMPER=image MOCK_TAMPER=network MOCK_TAMPER=port MOCK_PEER=1 MOCK_RM_FAIL=1; do
 printf 'CHECK: uninstall %s\n' "$pair"
 reset_case
 toolbox_webssh_container personal install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'gate fixture install'
 export "${pair?}"
 reject personal uninstall <<< $'YES\nYES'; count_state 1 1
 done
# Ledger edit / data directory replacement are not permission to adopt resources.
for tamper in ledger data parent credentials lock; do
 printf 'CHECK: tamper %s\n' "$tamper"
 reset_case; toolbox_webssh_container personal install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'tamper fixture install'
 data=$HOME/.local/share/terry-toolbox/webssh-containers/personal
 if [[ $tamper == ledger ]]; then printf 'tamper' >> "$data/ledger.json"
 elif [[ $tamper == data ]]; then mv "$data/data" "$data/data-old"; mkdir -m700 "$data/data"
 elif [[ $tamper == parent ]]; then mv "$HOME/.local/share/terry-toolbox" "$HOME/.local/share/toolbox-old"; mkdir -m700 "$HOME/.local/share/terry-toolbox"; mv "$HOME/.local/share/toolbox-old/webssh-containers" "$HOME/.local/share/terry-toolbox/"
 elif [[ $tamper == credentials ]]; then printf 'tamper' >> "$data/credentials.txt"
 else mv "$data/lock" "$data/lock-old"; install -m600 /dev/null "$data/lock"; fi
 reject personal uninstall <<< $'YES\nYES'; count_state 1 1
 done
reset_case; toolbox_webssh_container easynode install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'partial uninstall fixture'
# App removed, second guacd stop fails; first removed ID recorded, remaining retained.
export MOCK_STOP_ROLE=guacd
reject easynode uninstall <<< $'YES\nYES'; count_state 1 1
unset MOCK_STOP_ROLE
toolbox_webssh_container easynode uninstall <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'resume partial container uninstall'; count_state 0 0
reset_case; toolbox_webssh_container easynode install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'partial network fixture'
export MOCK_NETWORK_RM_FAIL=1
reject easynode uninstall <<< $'YES\nYES'; count_state 0 1
unset MOCK_NETWORK_RM_FAIL
toolbox_webssh_container easynode uninstall <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'resume partial network uninstall'; count_state 0 0
reset_case; toolbox_webssh_container personal install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'rm readback fixture'
export MOCK_POST_RM_LIST_FAIL=1
reject personal uninstall <<< $'YES\nYES'; count_state 0 1
# Read-only status is exact: no new app files and no Docker mutations.
reset_case; toolbox_webssh_container personal install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'readonly fixture'
python3 - "$HOME" "$work/before.json" <<'PY'
import pathlib,json,sys,hashlib
r=pathlib.Path(sys.argv[1]);json.dump({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in r.rglob('*') if p.is_file()},open(sys.argv[2],'w'))
PY
: > "$WSC_MOCK/calls.jsonl"
toolbox_webssh_container personal status >"$work/output" 2>&1 || fail 'readonly status'
python3 - "$HOME" "$work/before.json" "$WSC_MOCK/calls.jsonl" <<'PY'
import pathlib,json,sys,hashlib
r=pathlib.Path(sys.argv[1]);assert {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in r.rglob('*') if p.is_file()}==json.load(open(sys.argv[2]))
for c in map(json.loads,pathlib.Path(sys.argv[3]).read_text().splitlines()):
 a=c[1:];a=a[2:] if a[:1]==['--host'] else a
 assert a[:1] not in (['pull'],['create'],['start'],['stop'],['rm'],['logs'])
 assert a[:2] not in (['network','create'],['network','rm'])
PY
# Exercise native startup delay and the fd/pathname lock race with real files.
reset_case; export MOCK_LOG_DELAY=1
toolbox_webssh_container easynode install <<< $'YES\nYES' >"$work/output" 2>&1 || fail 'delayed native credentials'
[[ -f $HOME/.local/share/terry-toolbox/webssh-containers/easynode/credentials.txt ]] || fail 'delayed credentials absent'
reset_case; export MOCK_REPLACE_LOCK=1
reject personal install <<< $'YES\nYES'
count_state 0 1
python3 - "$WSC_MOCK/calls.jsonl" <<'PY'
import json,sys
calls=[c[3:] if c[1:2]==['--host'] else c[1:] for c in map(json.loads,open(sys.argv[1]))]
assert not any(c[:1] in (['create'],['start'],['stop'],['rm']) for c in calls)
assert not any(c[:2]==['network','rm'] for c in calls)
PY
printf 'PASS: B10 failure/signal/tamper/unknown/stop-readback/data-retention/readonly regressions\n'
