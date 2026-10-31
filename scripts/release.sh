#!/usr/bin/env bash
# Build the Bash artifact consumed by the production Cloudflare Worker bundle.
# docs/ also retains the historical GitHub Pages artifact.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/docs/index.html
mkdir -p -- "$root/docs"
[[ ! -L $out && ( ! -e $out || -f $out ) ]] || { printf 'Untrusted release target: %s\n' "$out" >&2; exit 1; }
stage=$(mktemp -d "$root/docs/.toolbox-release.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
bash "$root/scripts/build.sh" "$stage/index.html"
bash -n "$stage/index.html"
# No source is executed during release. Validate bytes and atomically replace
# only after the complete new artifact has been built on this filesystem.
python3 - "$stage/index.html" "$out" <<'PY'
import hashlib, os, pathlib, sys
candidate, target = map(pathlib.Path, sys.argv[1:])
data = candidate.read_bytes()
if not data.startswith(b'#!/usr/bin/env bash\n') or not data.endswith(b'\n'):
    raise SystemExit('Invalid standalone Bash artifact; old release retained')
with candidate.open('rb') as f:
    os.fsync(f.fileno())
os.replace(candidate, target)
directory = os.open(target.parent, os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
print('Worker Bash artifact:', target)
print('sha256 ', hashlib.sha256(data).hexdigest())
print('bytes  ', len(data))
PY
