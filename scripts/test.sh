#!/usr/bin/env bash
# Run Linux regression commands serially, recording timeouts and supervising complete descendant trees.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/scratch-root.sh"
toolbox_test_scratch
exec python3 "$root/tests/regression-runner.py" "$@"
