#!/usr/bin/env python3
"""Publish a self-contained Worker. Optionally move only sh.uw.cx off GitHub Pages."""
import argparse
import json
import os
from pathlib import Path
import requests

ROOT = Path(__file__).resolve().parents[1]
NAME = 'terry-toolbox'
HOST = 'sh.uw.cx'
BASE = 'https://api.cloudflare.com/client/v4'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--credentials', type=Path, default=None)
    parser.add_argument('--bind', action='store_true', help='Attach sh.uw.cx after preview verification')
    parser.add_argument('--backup-dir', type=Path, default=None)
    args = parser.parse_args()
    if args.credentials:
        cfg = json.loads(args.credentials.read_text())
        account, token = cfg['account_id'], cfg['api_token']
    else:
        account, token = os.environ['CLOUDFLARE_ACCOUNT_ID'], os.environ['CLOUDFLARE_API_TOKEN']
    session = requests.Session()
    session.headers['Authorization'] = 'Bearer ' + token

    def api(method, path, **kwargs):
        r = session.request(method, BASE + path, timeout=60, **kwargs)
        d = r.json()
        if not d.get('success'):
            raise RuntimeError(f'Cloudflare {r.status_code}: {d.get("errors")}')
        return d['result']

    bundle = ROOT / 'dist' / 'worker'
    manifest = json.loads((bundle / 'manifest.json').read_text())
    files = {'metadata': (None, json.dumps({
        'main_module': 'worker.mjs', 'compatibility_date': '2026-10-01',
        'bindings': [], 'logpush': False,
        'annotations': {'workers/message': 'Terry Toolbox: browser landing page and audited Bash artifact'},
    }), 'application/json')}
    for file in ['worker.mjs', 'router.mjs', 'toolbox.txt', 'welcome.txt']:
        files[file] = (file, (bundle / file).read_bytes(), 'application/javascript+module' if file.endswith('.mjs') else 'text/plain')
    result = api('PUT', f'/accounts/{account}/workers/scripts/{NAME}', files=files)
    print('Worker uploaded:', result.get('id', NAME))
    # Read back the exact deployed target, not just the upload response.
    r = session.get(BASE + f'/accounts/{account}/workers/scripts/{NAME}', timeout=60)
    r.raise_for_status()
    if manifest['sha256'].encode() not in r.content or (bundle / 'toolbox.txt').read_bytes() not in r.content:
        raise RuntimeError('Worker readback does not contain the expected shell bytes/hash')
    print('Worker readback: shell bytes and hash verified')
    api('POST', f'/accounts/{account}/workers/scripts/{NAME}/subdomain', json={'enabled': True, 'previews_enabled': False})
    state = api('GET', f'/accounts/{account}/workers/scripts/{NAME}/subdomain')
    if not state['enabled']:
        raise RuntimeError('workers.dev endpoint is not enabled')
    subdomain = api('GET', f'/accounts/{account}/workers/subdomain')['subdomain']
    preview = f'https://{NAME}.{subdomain}.workers.dev'
    print('Preview:', preview)
    if not args.bind:
        return
    # Live preview must return both variants before changing any DNS record.
    cli = requests.get(preview + '/', headers={'User-Agent': 'curl/8.0', 'Accept': '*/*'}, timeout=60)
    cli.raise_for_status()
    if cli.content != (bundle / 'toolbox.txt').read_bytes():
        raise RuntimeError('Preview script does not match release')
    browser = requests.get(preview + '/', headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'text/html'}, timeout=60)
    browser.raise_for_status()
    if browser.content != (bundle / 'welcome.txt').read_bytes():
        raise RuntimeError('Preview welcome page does not match release')
    zone = api('GET', '/zones?name=uw.cx')[0]['id']
    domains = api('GET', f'/accounts/{account}/workers/domains')
    existing = [d for d in domains if d['hostname'] == HOST]
    if existing:
        if existing[0]['service'] != NAME:
            raise RuntimeError('Hostname already belongs to another Worker')
        print('Custom domain already bound:', existing[0]['id'])
        return
    records = api('GET', f'/zones/{zone}/dns_records?name={HOST}')
    if records and (len(records) != 1 or records[0]['type'] != 'CNAME' or records[0]['content'] != 'terrysiu98.github.io'):
        raise RuntimeError('DNS ownership baseline changed; refusing cutover')
    if records and args.backup_dir is None:
        raise RuntimeError('--backup-dir required before replacing existing DNS')
    if records:
        args.backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        backup = args.backup_dir / 'dns-before.json'
        if not backup.exists():
            backup.write_text(json.dumps(records, indent=2) + '\n')
            backup.chmod(0o600)
    try:
        for record in records:
            api('DELETE', f'/zones/{zone}/dns_records/{record["id"]}')
        domain = api('PUT', f'/accounts/{account}/workers/domains', json={
            'hostname': HOST, 'service': NAME, 'enabled': True, 'previews_enabled': False,
            'zone_id': zone, 'zone_name': 'uw.cx',
        })
    except Exception:
        current = api('GET', f'/zones/{zone}/dns_records?name={HOST}')
        if not current:
            for record in records:
                payload = {k: record[k] for k in ['type', 'name', 'content', 'ttl', 'proxied']}
                payload['comment'] = record.get('comment') or ''
                api('POST', f'/zones/{zone}/dns_records', json=payload)
        raise
    check = api('GET', f'/accounts/{account}/workers/domains/{domain["id"]}')
    if check['hostname'] != HOST or check['service'] != NAME or not check['enabled']:
        raise RuntimeError('Custom domain readback mismatch')
    print('Custom domain readback verified:', HOST, '->', NAME, 'id=' + domain['id'])


if __name__ == '__main__':
    main()
