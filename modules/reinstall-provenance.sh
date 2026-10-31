#!/usr/bin/env bash
# Source-only provenance. Pin updates require human review of upstream and this diff.
_TOOLBOX_REINSTALL_COMMIT=54fae2067557b3c0ca49e7c9ce03bca63c793f8c
_TOOLBOX_REINSTALL_RAW_SHA=3ca358bf065ebd3ecb2f727e152a4b4fb9b154398abc1b9a5fe0b599f1027d7a
_TOOLBOX_REINSTALL_DERIVED_SHA=fc056ad5498bd019201d20ca19d1ebfe1d9d7cb05028cd4cb5a0352e9566518d
# README at this commit, lines 705..719, documents pinning confhome* to commit_id.
# Reviewed derivation: both active origins use SAME immutable GitHub commit;
# remove upstream curl --insecure from download and URL probe (two exact
# occurrences), use HTTPS for Alpine boot images and Debian driver packages
# injected into the initrd. No installer rewritten.
# trans.sh + initrd-network.sh are downloaded through that origin; extra_confhome
# propagates it into initrd/runtime. Distribution images/packages remain mutable.
_toolbox_reinstall_derive() {
    python3 - "$1" "$2" "$_TOOLBOX_REINSTALL_COMMIT" "$_TOOLBOX_REINSTALL_RAW_SHA" "$_TOOLBOX_REINSTALL_DERIVED_SHA" <<'PY'
import hashlib, os, sys
src, dst, commit, raw_sha, derived_sha = sys.argv[1:]
b = open(src, 'rb').read()
if hashlib.sha256(b).hexdigest() != raw_sha:
    sys.exit('上游原始 SHA256 不匹配；未执行。')
edits = [
 (b'confhome=https://raw.githubusercontent.com/bin456789/reinstall/main\n',
  ('confhome=https://raw.githubusercontent.com/bin456789/reinstall/'+commit+'\n').encode()),
 (b'confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/main\n',
  ('confhome_cn=https://raw.githubusercontent.com/bin456789/reinstall/'+commit+'\n').encode()),
 (b'command curl --insecure --connect-timeout 10 -f "$@"',
  b'command curl --connect-timeout 10 -f "$@"'),
 (b'command curl --insecure --connect-timeout 10 -Lfr 0-1048575 "$url"',
  b'command curl --connect-timeout 10 -Lfr 0-1048575 "$url"'),
 (b'mirror=http://mirror.nju.edu.cn/alpine/v$releasever',
  b'mirror=https://mirror.nju.edu.cn/alpine/v$releasever'),
 (b'mirror=http://dl-cdn.alpinelinux.org/alpine/v$releasever',
  b'mirror=https://dl-cdn.alpinelinux.org/alpine/v$releasever'),
 (b'local url=http://$mirror/dists/$nextos_codename/main/binary-$basearch_alt/Packages.gz',
  b'local url=https://$mirror/dists/$nextos_codename/main/binary-$basearch_alt/Packages.gz'),
 (b'local url=http://$mirror/dists/$nextos_codename/main/debian-installer/binary-$basearch_alt/Packages.gz',
  b'local url=https://$mirror/dists/$nextos_codename/main/debian-installer/binary-$basearch_alt/Packages.gz'),
 (b'curl -Lo $tmp/tmp.deb http://$mirror/"$deb_path"',
  b'curl -Lo $tmp/tmp.deb https://$mirror/"$deb_path"'),
 (b'is_in_china && mirror=http://mirror.nju.edu.cn/alpine || mirror=https://dl-cdn.alpinelinux.org/alpine',
  b'is_in_china && mirror=https://mirror.nju.edu.cn/alpine || mirror=https://dl-cdn.alpinelinux.org/alpine')]
for old, new in edits:
    if b.count(old) != 1: sys.exit('pin patch 前置条件不匹配；需要显式 review。')
    b = b.replace(old, new)
if hashlib.sha256(b).hexdigest() != derived_sha:
    sys.exit('派生 SHA256 不匹配；未执行。')
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'wb') as f: f.write(b)
PY
}
_toolbox_reinstall_download() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location \
        --connect-timeout 15 --max-time 120 --output "$2" \
        "https://raw.githubusercontent.com/bin456789/reinstall/$_TOOLBOX_REINSTALL_COMMIT/$1"
}
_toolbox_reinstall_fetch() {
    local dir=$1 name digest actual
    _toolbox_reinstall_download reinstall.sh "$dir/upstream.raw" || return
    _toolbox_reinstall_derive "$dir/upstream.raw" "$dir/reinstall.sh" || return
    # These executable helpers are checked AGAIN from unpacked initrd before a
    # plan is declared prepared. Other repo resources inherit the same commit.
    for name in trans.sh initrd-network.sh; do
        case $name in
            trans.sh) digest=d8f34529c0a706b17d67965b99a107f8299a30d5303744a20f0fb96556365bf7;;
            initrd-network.sh) digest=78fd74716b236d0e41e4f5c4034d45db8bcc47fba2d53c4a19a0d21ef60510bc;;
        esac
        _toolbox_reinstall_download "$name" "$dir/$name" || return
        actual=$(sha256sum "$dir/$name") || return
        [[ ${actual%% *} == "$digest" ]] || { printf 'runtime helper SHA256 不匹配：%s\n' "$name" >&2; return 1; }
    done
    bash -n "$dir/reinstall.sh" || return
    _toolbox_reinstall_expected_trans "$dir" || return
}
_toolbox_reinstall_expected_trans() {
    local dir=$1
    # Reuse the exact upstream Debian initrd transformation, statically extracted
    # only after raw SHA validation. Execute its sed/insert functions on PRIVATE
    # fixture files; never source or enter the full installer to discover them.
    python3 - "$dir" "$_TOOLBOX_REINSTALL_RAW_SHA" <<'PY' || return
import hashlib,os,sys
p,sha=sys.argv[1:];b=open(p+'/upstream.raw','rb').read()
if hashlib.sha256(b).hexdigest()!=sha:sys.exit('raw hash changed before trans derivation')
s=b.decode().splitlines(True)
fragment=''.join(s[358:392])+''.join(s[4182:4209])
# Reviewed source boundaries: insert_into_file + only Debian trans modifications.
if not fragment.startswith('insert_into_file() {') or not fragment.endswith('        $initrd_dir/trans.sh\n'):sys.exit('upstream fragment boundaries changed')
os.mkdir(p+'/trans-derive',0o700)
with open(p+'/trans-derive/trans.sh','xb') as f:f.write(open(p+'/trans.sh','rb').read())
with open(p+'/trans-transform.sh','x') as f:
 f.write('initrd_dir="$1"\nnextos_distro=debian\nnextos_releasever=13\nreplace=\'\\\\n: #\'\n'+fragment)
PY
    bash "$dir/trans-transform.sh" "$dir/trans-derive" || return
    mv "$dir/trans-derive/trans.sh" "$dir/expected-debian-trans.sh" || return
    rmdir "$dir/trans-derive" || return
    rm "$dir/trans-transform.sh" || return
}
