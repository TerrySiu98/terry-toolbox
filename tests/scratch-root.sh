#!/usr/bin/env bash
# Shared fixture root, checked before tests replace Python/system boundaries.
toolbox_test_scratch() {
    local selected
    selected=$(python3 - "${TOOLBOX_TEST_TMPDIR:-${TMPDIR:-/root/.cache/terry-toolbox-tests}}" <<'PY'
import os, stat, sys
p=sys.argv[1]
if not p.startswith('/') or any(x in ('', '.', '..') for x in p.split('/')[1:]):
    raise SystemExit('test scratch must be a normalized absolute path')
fd=os.open('/', os.O_RDONLY | os.O_DIRECTORY)
try:
    for part in p.split('/')[1:]:
        s=os.fstat(fd)
        if s.st_uid not in (0, os.geteuid()) or s.st_mode & 0o022:
            raise SystemExit('test scratch has a foreign/writable ancestor')
        try: os.mkdir(part, 0o700, dir_fd=fd)
        except FileExistsError: pass
        child=os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        os.close(fd); fd=child
    s=os.fstat(fd)
    if s.st_uid != os.geteuid() or s.st_mode & 0o077:
        raise SystemExit('test scratch must be private and owned by the test user')
finally:
    os.close(fd)
print(p)
PY
    ) || return 1
    export TMPDIR="$selected" TOOLBOX_TEST_TMPDIR="$selected"
}
