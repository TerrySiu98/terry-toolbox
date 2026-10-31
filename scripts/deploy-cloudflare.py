#!/usr/bin/env python3
"""Deploy the production terry-toolbox Worker, with private backup and exact readback.

Normal updates preserve Worker settings, workers.dev and DNS. --bind is only for
an explicit initial custom-domain migration from the historical GitHub Pages site.
"""
import argparse
import datetime
import email.parser
import email.policy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
NAME = 'terry-toolbox'
HOST = 'sh.uw.cx'
BASE = 'https://api.cloudflare.com/client/v4'
MODULES = ('worker.mjs', 'router.mjs', 'toolbox.txt', 'welcome.txt')


def need(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def evidence_warning(message, error):
    try:
        print(message+str(error), file=sys.stderr)
    except OSError:
        pass  # A failed stderr sink must not interrupt DNS recovery either.


def read_file(path):
    need(path.is_file() and not path.is_symlink(), 'Missing or symlinked release file: '+str(path))
    return path.read_bytes()


def load_bundle():
    bundle = ROOT / 'dist' / 'worker'
    manifest = json.loads(read_file(bundle / 'manifest.json'))
    need(manifest.get('schema') == 1 and set(manifest.get('files', {})) == set(MODULES),
         'Rebuild the Worker bundle: manifest must hash all four modules')
    data = {name: read_file(bundle / name) for name in MODULES}
    for name, raw in data.items():
        need(manifest['files'][name] == {'sha256': digest(raw), 'bytes': len(raw)},
             'Bundle hash/size mismatch: '+name)
    need(manifest.get('sha256') == digest(data['toolbox.txt']), 'Manifest Bash hash mismatch')
    for module, source in [('toolbox.txt', 'docs/index.html'), ('welcome.txt', 'web/index.html'),
                           ('router.mjs', 'web/router.mjs')]:
        need(data[module] == read_file(ROOT / source), 'Stale bundle: '+module+' differs from '+source)
    expected = ("import script from './toolbox.txt';\nimport page from './welcome.txt';\n"
                "import { createHandler } from './router.mjs';\n"
                "export default { fetch: createHandler({ script, page, sha256: "
                + json.dumps(manifest['sha256']) + ", contentSecurityPolicy: "
                + json.dumps(manifest['content_security_policy']) + " }) };\n").encode()
    need(data['worker.mjs'] == expected, 'Worker entrypoint does not match manifest')
    return manifest, data


def parse_modules(response):
    content_type = response.headers.get('Content-Type', '')
    need(content_type.lower().startswith('multipart/'), 'Worker readback is not a complete multipart module bundle')
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
        b'Content-Type: '+content_type.encode('ascii')+b'\r\nMIME-Version: 1.0\r\n\r\n'+response.content)
    need(message.is_multipart() and not message.defects, 'Malformed Worker multipart response')
    modules = {}
    for part in message.iter_parts():
        name = part.get_param('name', header='content-disposition') or part.get_filename()
        need(name and name not in modules and not part.is_multipart() and not part.defects,
             'Missing/duplicate/malformed Worker module')
        modules[name] = part.get_payload(decode=True)
    need(modules and all(isinstance(x, bytes) for x in modules.values()), 'Worker module payload missing')
    # Some Cloudflare responses include a metadata part alongside source parts.
    metadata = modules.pop('metadata', None)
    if metadata is not None:
        need(json.loads(metadata).get('main_module') == 'worker.mjs', 'Worker main module mismatch')
    return modules


class Evidence:
    def __init__(self, requested):
        if requested:
            need(str(requested.expanduser().absolute()) == os.path.normpath(str(requested.expanduser().absolute())),
                 'Backup path must be normalized (no parent traversal)')
        parent = requested.expanduser().absolute().parent if requested else Path.home()
        # The leaf is always new, owner-only, and outside the source repository.
        # Sticky system tmp parents are allowed; all symlink parents are refused.
        for part in reversed((parent, *parent.parents)):
            s = part.lstat()
            need(stat.S_ISDIR(s.st_mode) and not stat.S_ISLNK(s.st_mode), 'Backup parent is not a directory: '+str(part))
            need(s.st_uid in (0, os.getuid()) and (not s.st_mode & 0o022 or s.st_uid == 0 and s.st_mode & stat.S_ISVTX),
                 'Backup parent is writable by another user: '+str(part))
        if requested:
            self.path = requested.expanduser().absolute()
            need(os.path.commonpath((str(self.path), str(ROOT))) != str(ROOT), 'Backup must be outside the source repository')
            self.path.mkdir(mode=0o700)
        else:
            self.path = Path(tempfile.mkdtemp(prefix='.terry-toolbox-deploy-', dir=parent))
        need(stat.S_IMODE(self.path.stat().st_mode) == 0o700, 'Backup directory must be private 0700')
        self.files = {}

    def write(self, name, raw):
        with (self.path / name).open('xb') as f:
            os.chmod(f.name, 0o600)
            f.write(raw); f.flush(); os.fsync(f.fileno())
        self.files[name] = {'sha256': digest(raw), 'bytes': len(raw)}

    def json(self, name, value):
        self.write(name, (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)+'\n').encode())

    def response(self, name, response):
        self.write(name+'.body', response.content)
        self.json(name+'.json', {'url': response.url, 'status': response.status_code, 'headers': dict(response.headers)})

    def checkpoint(self, name, **details):
        self.json(name, {'files': dict(self.files), **details})
        fd = os.open(self.path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def main(argv=None, session_factory=None, sleeper=time.sleep):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path)
    parser.add_argument('--bind', action='store_true', help='Explicitly migrate sh.uw.cx from its historical Pages CNAME if needed')
    parser.add_argument('--backup-dir', type=Path, help='New private directory outside the repository (default: a new directory under your home)')
    args = parser.parse_args(argv)
    manifest, modules = load_bundle()  # All local integrity checks precede network access.
    if args.credentials:
        cfg = json.loads(read_file(args.credentials))
        account, token = cfg['account_id'], cfg['api_token']
    else:
        account, token = os.environ['CLOUDFLARE_ACCOUNT_ID'], os.environ['CLOUDFLARE_API_TOKEN']
    need(re.fullmatch(r'[a-fA-F0-9]{32}', account) and isinstance(token, str) and token.strip(), 'Invalid Cloudflare credentials')
    if session_factory is None:
        import requests
        session_factory = requests.Session
    evidence = Evidence(args.backup_dir)
    session, public = session_factory(), session_factory()
    session.headers['Authorization'] = 'Bearer '+token
    # Separate public session: never forward the API credential to the site.
    print('Production Worker:', NAME, 'at https://'+HOST, flush=True)
    print('Private deployment backup:', evidence.path, flush=True)
    script_path = f'/accounts/{account}/workers/scripts/{NAME}'
    domain_path = f'/accounts/{account}/workers/domains'
    sequence = 0
    changed = False

    def request(method, path, **kwargs):
        return session.request(method, BASE+path, timeout=60, allow_redirects=False, **kwargs)

    def api(method, path, *, best_effort_evidence=False, **kwargs):
        nonlocal sequence
        response = request(method, path, **kwargs)
        sequence += 1
        try:
            evidence.response('api-%03d'%sequence, response)
        except OSError as error:
            if not best_effort_evidence:
                raise
            evidence_warning('Cannot save DNS recovery response; continuing recovery: ', error)
        need(response.status_code == 200, 'Cloudflare API returned HTTP '+str(response.status_code)+' for '+method+' '+path)
        value = response.json()
        need(value.get('success') is True, 'Cloudflare API rejected '+method+' '+path+'; inspect private evidence')
        return value['result']

    def content(label, optional=False):
        response = request('GET', script_path, headers={'Accept': 'multipart/form-data'})
        evidence.response(label, response)
        if optional and response.status_code == 404:
            return None
        need(response.status_code == 200, 'Cannot snapshot/read back production Worker content')
        return parse_modules(response)

    def domains(*, best_effort_evidence=False):
        result = api('GET', domain_path, best_effort_evidence=best_effort_evidence)
        need(isinstance(result, list), 'Domain list response is invalid')
        matches = [d for d in result if d.get('hostname') == HOST]
        need(len(matches) <= 1, 'Ambiguous custom-domain ownership')
        if matches:
            d = matches[0]
            need(d.get('service') == NAME and d.get('environment', 'production') == 'production'
                 and d.get('enabled', True) is True, 'Custom domain belongs to another Worker/environment or is disabled')
        return matches

    def public_read(label, origin, expected=None, cache_bust=False, require_ok=True):
        rows = [('cli-root', '/', 'curl/8.0', '*/*', 'toolbox.txt'),
                ('browser-root', '/', 'Mozilla/5.0', 'text/html', 'welcome.txt'),
                ('toolbox', '/toolbox.sh', 'curl/8.0', '*/*', 'toolbox.txt'),
                ('sha256', '/sha256', 'curl/8.0', '*/*', None)]
        matched = True
        for name, path, ua, accept, source in rows:
            if cache_bust:
                path += '?toolbox_verify='+uuid.uuid4().hex
            response = public.request('GET', origin+path, timeout=60, allow_redirects=False,
                                      headers={'User-Agent': ua, 'Accept': accept, 'Cache-Control': 'no-cache'})
            evidence.response(label+'-'+name, response)
            if require_ok:
                need(response.status_code == 200, 'Public endpoint returned HTTP '+str(response.status_code)+': '+name)
            if expected:
                raw = expected[source] if source else (manifest['sha256']+'  toolbox.sh\n').encode()
                media = 'text/html' if source == 'welcome.txt' else 'text/plain'
                matched = matched and response.status_code == 200 and response.content == raw
                matched = matched and response.headers.get('Content-Type', '').lower().startswith(media)
        return matched

    def verify_public(origin, prefix):
        for attempt in range(8):
            # Check the actual public URLs too: a fresh query can bypass a
            # stale or incorrectly varied cached root response.
            actual = public_read(prefix+'-%02d'%attempt, origin, modules, require_ok=False)
            fresh = public_read(prefix+'-%02d-fresh'%attempt, origin, modules, cache_bust=True, require_ok=False)
            if actual and fresh:
                return
            if attempt < 7:
                sleeper(10)
        raise RuntimeError('Production public readback failed for '+origin+'; uploaded bytes may already be live; inspect private evidence')

    try:
        old_modules = content('worker-before', optional=args.bind)
        old_settings = api('GET', script_path+'/settings') if old_modules is not None else None
        old_subdomain = api('GET', script_path+'/subdomain') if old_modules is not None else None
        bound = domains()
        need(bound or args.bind, 'Custom domain is not bound; ordinary deployment cannot migrate DNS')
        need(old_modules is not None or not bound, 'Bound Worker has no readable original content')
        public_read('public-before', 'https://'+HOST, require_ok=bool(bound))
        zone, records = None, []
        if args.bind and not bound:
            zones = api('GET', '/zones?name=uw.cx')
            need(len(zones) == 1, 'Expected exactly one uw.cx zone')
            zone = zones[0]['id']
            records = api('GET', f'/zones/{zone}/dns_records?name={HOST}')
            need(not records or len(records) == 1 and records[0].get('type') == 'CNAME'
                 and records[0].get('name') == HOST and records[0].get('content') == 'terrysiu98.github.io',
                 'DNS ownership baseline changed; refusing migration')
            evidence.json('dns-before.json', records)
        evidence.json('release-manifest.json', manifest)
        for name, raw in modules.items():
            evidence.write('release-'+name, raw)
        evidence.checkpoint('backup-complete.json', production_worker=NAME, hostname=HOST,
                            old_settings=old_settings, old_subdomain=old_subdomain, domain=bound,
                            utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        # Recheck the remote target immediately before writing. Multipart
        # boundaries may vary, so compare decoded module bytes instead.
        need(content('worker-preupload', optional=old_modules is None) == old_modules,
             'Production Worker changed during backup; refusing overwrite')
        if old_modules is not None:
            need(api('GET', script_path+'/settings') == old_settings and
                 api('GET', script_path+'/subdomain') == old_subdomain, 'Worker settings changed during backup')
        need(domains() == bound, 'Domain binding changed during backup')
        metadata = {'main_module': 'worker.mjs'}
        if old_modules is None:
            metadata.update(compatibility_date='2026-10-01', bindings=[], logpush=False)
        files = {'metadata': (None, json.dumps(metadata), 'application/json')}
        files.update({name: (name, raw, 'application/javascript+module' if name.endswith('.mjs') else 'text/plain')
                      for name, raw in modules.items()})
        print('Uploading verified bytes to the production Worker.', flush=True)
        changed = True
        # Cloudflare /content replaces source while preserving configuration.
        # https://github.com/cloudflare/cloudflare-python/blob/main/src/cloudflare/resources/workers/scripts/content.py
        api('PUT', script_path+('/content' if old_modules is not None else ''), files=files)
        need(content('worker-after') == modules, 'Uploaded Worker module names/bytes differ from release')
        if old_settings is not None:
            need(api('GET', script_path+'/settings') == old_settings, 'Worker settings changed during content deployment')
            need(api('GET', script_path+'/subdomain') == old_subdomain, 'workers.dev settings changed during content deployment')
        if args.bind and not bound:
            state = api('GET', script_path+'/subdomain')
            if state.get('enabled') is not True:
                api('POST', script_path+'/subdomain', json={'enabled': True, 'previews_enabled': state.get('previews_enabled', False)})
                need(api('GET', script_path+'/subdomain').get('enabled') is True, 'workers.dev activation failed')
            account_subdomain = api('GET', f'/accounts/{account}/workers/subdomain')['subdomain']
            need(re.fullmatch(r'[a-zA-Z0-9-]+', account_subdomain), 'Invalid workers.dev subdomain')
            verify_public(f'https://{NAME}.{account_subdomain}.workers.dev', 'workers-dev-production')
            need(domains() == [] and api('GET', f'/zones/{zone}/dns_records?name={HOST}') == records,
                 'DNS/domain changed before explicit migration')
            attempted_deletions = []
            try:
                for record in records:
                    # A DELETE may take effect even when its response is lost or
                    # saving the response fails. Track intent before sending it.
                    attempted_deletions.append(record)
                    api('DELETE', f'/zones/{zone}/dns_records/{record["id"]}')
                domain = api('PUT', domain_path, json={'hostname': HOST, 'service': NAME,
                             'enabled': True, 'previews_enabled': False, 'zone_id': zone, 'zone_name': 'uw.cx'})
                check = api('GET', domain_path+'/'+domain['id'])
                need(check.get('hostname') == HOST and check.get('service') == NAME and check.get('enabled', True),
                     'Custom-domain migration readback mismatch')
                need(check.get('environment', 'production') == 'production', 'Custom domain is not bound to production')
            except Exception:
                # Read back an ambiguous DELETE before restoring its exact
                # baseline. New bindings/records always win. Evidence I/O must
                # not prevent recovery; HTTP/API validation still fails closed.
                if attempted_deletions and not domains(best_effort_evidence=True):
                    current = api('GET', f'/zones/{zone}/dns_records?name={HOST}', best_effort_evidence=True)
                    need(isinstance(current, list), 'DNS recovery readback is not a record list')
                    if not current:
                        payloads = [{k: record[k] for k in
                            ('type', 'name', 'content', 'ttl', 'proxied', 'comment') if k in record}
                            for record in attempted_deletions]
                        for payload in payloads:
                            api('POST', f'/zones/{zone}/dns_records', json=payload, best_effort_evidence=True)
                        restored = api('GET', f'/zones/{zone}/dns_records?name={HOST}', best_effort_evidence=True)
                        need(isinstance(restored, list) and len(restored) == len(payloads) and
                             all(all(record.get(k) == value for k, value in payload.items())
                                 for record, payload in zip(restored, payloads)), 'DNS recovery readback mismatch')
                raise
        else:
            need(domains() == bound, 'Production domain binding changed during upload')
        need(domains(), 'Production custom domain is not bound after deployment')
        verify_public('https://'+HOST, 'public-after')
        evidence.checkpoint('deployment-verified.json', sha256=manifest['sha256'], production_worker=NAME,
                            hostname=HOST, utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        print('Production deployment verified: exact modules, CLI root, browser root, /toolbox.sh and /sha256.')
        print('Bash SHA-256:', manifest['sha256'])
        return evidence.path
    except Exception as exc:
        try:
            evidence.checkpoint('deployment-failed.json', upload_attempted=changed, reason=str(exc))
        except OSError as error:
            evidence_warning('Cannot save deployment failure checkpoint: ', error)
        raise
    finally:
        session.close(); public.close()


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, ImportError) as error:
        print('Deployment failed: '+str(error), file=sys.stderr)
        sys.exit(1)
