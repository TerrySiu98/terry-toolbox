#!/usr/bin/env bash
# Real PTY/redirection checks; service/package boundaries stay isolated.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scratch-root.sh"
toolbox_test_scratch
exec python3 "$(dirname -- "${BASH_SOURCE[0]}")/hy2-password-pty.py"
