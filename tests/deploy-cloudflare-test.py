#!/usr/bin/env python3
"""Offline production-deploy and atomic-release regression; no Cloudflare access."""
import contextlib
import copy
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), REPO/'scripts'/(name+'.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def multipart(modules, duplicate=False):
    boundary = 'fixture-boundary'
    raw = b''
    pairs = list(modules.items())
    if duplicate:
        pairs.append(pairs[0])
    for name, content in pairs:
        raw += ('--'+boundary+'\r\nContent-Disposition: form-data; name="'+name+'"; filename="'+name+'"\r\n'
                'Content-Type: '+('application/javascript+module' if name.endswith('.mjs') else 'text/plain')+'\r\n\r\n').encode()
        raw += content+b'\r\n'
    return raw+('--'+boundary+'--\r\n').encode(), 'multipart/form-data; boundary='+boundary


class Response:
    def __init__(self, url, raw=b'', status=200, content_type='application/json'):
        self.url, self.content, self.status_code = url, raw, status
        self.headers = {'Content-Type': content_type, 'CF-Ray': 'fixture'}

    def json(self):
        return json.loads(self.content)


class Cloud:
    def __init__(self, deploy, backup):
        self.deploy, self.backup = deploy, backup
        self.calls = []
        self.original = {'worker.mjs': b'export default old_worker;\n', 'old.txt': b'old contents\x00\r\n'}
        self.modules = copy.deepcopy(self.original)
        self.settings = {'bindings': [], 'compatibility_date': '2026-10-01', 'logpush': False,
                         'observability': {'enabled': False}, 'limits': {'cpu_ms': 50}}
        self.subdomain = {'enabled': False, 'previews_enabled': False}
        self.binding = [{'hostname': deploy.HOST, 'service': deploy.NAME, 'environment': 'production', 'id': 'bound'}]
        self.records = [{'id': 'legacy', 'name': deploy.HOST, 'type': 'CNAME', 'content': 'terrysiu98.github.io',
                         'ttl': 1, 'proxied': True, 'comment': 'original'}]
        self.uploaded = False
        self.sessions = []
        self.fail_backup = self.race = self.tamper = self.public_bad = self.migration_fail = None
        self.script_reads = 0
        self.public_after = 0
        self.stale_rounds = 0

    def session(self):
        cloud = self

        class Session:
            def __init__(self):
                self.headers = {}
                self.closed = False

            def request(self, method, url, **kwargs):
                return cloud.request(self, method, url, **kwargs)

            def close(self):
                self.closed = True

        session = Session()
        self.sessions.append(session)
        return session

    def request(self, session, method, url, **kwargs):
        assert kwargs['allow_redirects'] is False
        assert kwargs['timeout'] == 60
        self.calls.append((method, url, copy.deepcopy(kwargs)))
        if not url.startswith(self.deploy.BASE):
            assert 'Authorization' not in session.headers, 'API credential sent to public site'
            path = urlsplit(url).path
            name = 'browser-root' if kwargs['headers']['Accept'] == 'text/html' else 'cli-root' if path == '/' else path
            if not self.uploaded:
                return Response(url, b'original public '+name.encode(), 503 if self.fail_backup == 'public' else 200,
                                'text/html' if name == 'browser-root' else 'text/plain')
            self.public_after += 1
            if name == 'browser-root':
                body = self.modules['welcome.txt']; media = 'text/html; charset=utf-8'
            elif path == '/sha256':
                body = (hashlib.sha256(self.modules['toolbox.txt']).hexdigest()+'  toolbox.sh\n').encode(); media = 'text/plain'
            else:
                body = self.modules['toolbox.txt']; media = 'text/plain; charset=utf-8'
            if self.public_bad == name or self.public_after <= self.stale_rounds*8 or self.public_bad == 'cached-only' and not urlsplit(url).query:
                body = b'stale or wrong endpoint'
            return Response(url, body, content_type=media)
        assert session.headers['Authorization'] == 'Bearer fixture-token'
        path = url[len(self.deploy.BASE):]
        script = '/accounts/'+'a'*32+'/workers/scripts/'+self.deploy.NAME
        domain = '/accounts/'+'a'*32+'/workers/domains'

        def result(value, status=200):
            return Response(url, json.dumps({'success': status == 200, 'result': value}).encode(), status)

        if method != 'GET':
            assert (self.backup/'backup-complete.json').is_file(), 'Production write before complete backup'
            for p in self.backup.iterdir():
                assert stat.S_IMODE(p.stat().st_mode) == 0o600
            assert stat.S_IMODE(self.backup.stat().st_mode) == 0o700
        if path == script and method == 'GET':
            self.script_reads += 1
            if self.fail_backup == 'content':
                return result(None, 500)
            if self.modules is None:
                return result(None, 404)
            data = copy.deepcopy(self.modules)
            if self.race == 'content' and self.script_reads > 1 and not self.uploaded:
                data['old.txt'] = b'concurrent deployment'
            if self.uploaded and self.tamper == 'bytes':
                data['welcome.txt'] += b' extra'
            if self.uploaded and self.tamper == 'names':
                data['extra.txt'] = b'unexpected module'
            raw, media = multipart(data, duplicate=self.tamper == 'duplicate' and self.uploaded)
            return Response(url, raw, content_type=media)
        if path == script+'/settings' and method == 'GET':
            if self.fail_backup == 'settings':
                return result(None, 403)
            data = copy.deepcopy(self.settings)
            if self.race == 'settings' and self.script_reads > 1 and not self.uploaded:
                data['logpush'] = True
            if self.uploaded and self.tamper == 'settings':
                data['limits'] = {'cpu_ms': 10}
            return result(data)
        if path == script+'/subdomain':
            if method == 'POST':
                self.subdomain = kwargs['json']
            return result(self.subdomain)
        if path == '/accounts/'+'a'*32+'/workers/subdomain':
            return result({'subdomain': 'fixture-account'})
        if path == domain:
            if method == 'PUT':
                if self.migration_fail:
                    return result(None, 500)
                self.binding = [{'id': 'new', **kwargs['json'], 'environment': 'production'}]
                return result(self.binding[0])
            return result(self.binding)
        if path == domain+'/new':
            return result(self.binding[0])
        if path == '/zones?name=uw.cx':
            return result([{'id': 'zone'}])
        if path == '/zones/zone/dns_records?name='+self.deploy.HOST:
            return result(self.records)
        if path == '/zones/zone/dns_records/legacy' and method == 'DELETE':
            self.records = []
            return result({'id': 'legacy'})
        if path == '/zones/zone/dns_records' and method == 'POST':
            self.records = [{'id': 'restored', **kwargs['json']}]
            return result(self.records[0])
        if method == 'PUT' and path in (script, script+'/content'):
            metadata = json.loads(kwargs['files']['metadata'][1])
            if self.modules is not None:
                assert path.endswith('/content') and metadata == {'main_module': 'worker.mjs'}
            else:
                assert path == script and metadata['bindings'] == []
            self.modules = {name: value[1] for name, value in kwargs['files'].items() if name != 'metadata'}
            self.uploaded = True
            return result({'id': self.deploy.NAME})
        raise AssertionError((method, url, kwargs))


class DeployTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='toolbox-deploy-test-')
        self.base = Path(self.temp.name).resolve()
        self.root = self.base/'source'
        for name in ('docs', 'web', 'dist'):
            (self.root/name).mkdir(parents=True)
        (self.root/'docs/index.html').write_bytes(b'#!/usr/bin/env bash\nprintf "candidate"\n')
        (self.root/'web/index.html').write_text('<title>Terry Toolbox</title>\n<style>body{color:red}</style>\n<script>void 0;</script>\n')
        shutil.copyfile(REPO/'web/router.mjs', self.root/'web/router.mjs')
        builder = load_script('build-worker'); builder.ROOT = self.root; builder.OUT = self.root/'dist/worker'
        with contextlib.redirect_stdout(io.StringIO()):
            builder.main()
        self.deploy = load_script('deploy-cloudflare'); self.deploy.ROOT = self.root
        self.backup = self.base/'private-backup'
        self.cloud = Cloud(self.deploy, self.backup)
        self.environment = patch.dict(os.environ, CLOUDFLARE_ACCOUNT_ID='a'*32, CLOUDFLARE_API_TOKEN='fixture-token')
        self.environment.start()

    def tearDown(self):
        self.environment.stop(); self.temp.cleanup()

    def run_deploy(self, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.deploy.main(['--backup-dir', str(self.backup), *args], self.cloud.session, sleeper=lambda _: None)

    def no_writes(self):
        self.assertFalse([c for c in self.cloud.calls if c[0] != 'GET'])

    def test_production_backup_and_exact_readback(self):
        self.run_deploy()
        self.assertTrue((self.backup/'deployment-verified.json').exists())
        response = Response('backup', (self.backup/'worker-before.body').read_bytes(),
                            content_type=json.loads((self.backup/'worker-before.json').read_text())['headers']['Content-Type'])
        self.assertEqual(self.deploy.parse_modules(response), self.cloud.original)
        public = sorted(p.name for p in self.backup.glob('public-before-*.body'))
        self.assertEqual(len(public), 4)
        writes = [(m, u) for m, u, _ in self.cloud.calls if m != 'GET']
        self.assertEqual(len(writes), 1); self.assertEqual(writes[0][0], 'PUT'); self.assertTrue(writes[0][1].endswith('/content'))
        self.assertFalse(self.cloud.subdomain['enabled'])
        self.assertTrue(all(s.closed for s in self.cloud.sessions))

    def test_each_bundle_module_hash_is_checked_before_network(self):
        for name in self.deploy.MODULES:
            with self.subTest(name=name):
                p = self.root/'dist/worker'/name; before = p.read_bytes(); p.write_bytes(before+b'tampered')
                with self.assertRaisesRegex(RuntimeError, 'hash/size mismatch'):
                    self.run_deploy()
                p.write_bytes(before)
                self.assertEqual(self.cloud.calls, [])

    def test_stale_release_refused(self):
        (self.root/'docs/index.html').write_bytes(b'#!/usr/bin/env bash\necho newer\n')
        with self.assertRaisesRegex(RuntimeError, 'Stale bundle'):
            self.run_deploy()
        self.assertEqual(self.cloud.calls, [])

    def test_existing_backup_is_never_overwritten(self):
        self.backup.mkdir(); (self.backup/'keep').write_text('owned by user')
        with self.assertRaises(FileExistsError):
            self.run_deploy()
        self.assertEqual((self.backup/'keep').read_text(), 'owned by user'); self.no_writes()

    def test_backup_in_repo_refused(self):
        self.backup = self.root/'private'; self.cloud.backup = self.backup
        with self.assertRaisesRegex(RuntimeError, 'outside the source'):
            self.run_deploy()
        self.no_writes()

    def test_backup_symlink_parent_and_traversal_refused(self):
        (self.base/'linked').symlink_to(self.base, target_is_directory=True)
        for target in (self.base/'linked/private', self.base/'source/../private'):
            with self.subTest(target=target):
                self.backup = target; self.cloud.backup = target
                with self.assertRaises(RuntimeError):
                    self.run_deploy()
                self.no_writes()

    def test_incomplete_backup_prevents_upload(self):
        for failure in ('content', 'settings', 'public'):
            with self.subTest(failure=failure):
                self.cloud.fail_backup = failure
                with self.assertRaises(RuntimeError):
                    self.run_deploy()
                self.no_writes(); shutil.rmtree(self.backup)
                self.cloud = Cloud(self.deploy, self.backup)

    def test_remote_races_prevent_upload(self):
        for race in ('content', 'settings'):
            with self.subTest(race=race):
                self.cloud.race = race
                with self.assertRaisesRegex(RuntimeError, 'changed during backup'):
                    self.run_deploy()
                self.no_writes(); shutil.rmtree(self.backup)
                self.cloud = Cloud(self.deploy, self.backup)

    def test_missing_or_foreign_binding_refused(self):
        for binding in ([], [{'hostname': self.deploy.HOST, 'service': 'foreign', 'id': 'x'}]):
            self.cloud.binding = binding
            with self.assertRaises(RuntimeError):
                self.run_deploy()
            self.no_writes(); shutil.rmtree(self.backup)
            self.cloud = Cloud(self.deploy, self.backup)

    def test_exact_uploaded_module_set_bytes_and_settings(self):
        for attack in ('bytes', 'names', 'duplicate', 'settings'):
            with self.subTest(attack=attack):
                self.cloud.tamper = attack
                with self.assertRaises(RuntimeError):
                    self.run_deploy()
                self.assertTrue(self.cloud.uploaded)
                self.assertFalse((self.backup/'deployment-verified.json').exists())
                self.assertTrue(json.loads((self.backup/'deployment-failed.json').read_text())['upload_attempted'])
                shutil.rmtree(self.backup); self.cloud = Cloud(self.deploy, self.backup)

    def test_every_public_variant_must_match(self):
        for endpoint in ('cli-root', 'browser-root', '/toolbox.sh', '/sha256'):
            with self.subTest(endpoint=endpoint):
                self.cloud.public_bad = endpoint
                with self.assertRaisesRegex(RuntimeError, 'public readback failed'):
                    self.run_deploy()
                self.assertEqual(self.cloud.public_after, 64)
                self.assertFalse((self.backup/'deployment-verified.json').exists())
                shutil.rmtree(self.backup); self.cloud = Cloud(self.deploy, self.backup)

    def test_public_eventual_consistency_retries(self):
        self.cloud.stale_rounds = 2; self.run_deploy()
        self.assertEqual(self.cloud.public_after, 24)
        for method, url, _ in self.cloud.calls:
            if '?toolbox_verify=' in url:
                self.assertTrue(url.startswith('https://'+self.deploy.HOST))

    def test_bind_existing_domain_does_not_touch_dns_or_workers_dev(self):
        self.run_deploy('--bind')
        self.assertEqual(len([c for c in self.cloud.calls if c[0] != 'GET']), 1)

    def test_cache_bypass_alone_cannot_hide_stale_public_urls(self):
        self.cloud.public_bad = 'cached-only'
        with self.assertRaisesRegex(RuntimeError, 'public readback failed'):
            self.run_deploy()
        self.assertFalse((self.backup/'deployment-verified.json').exists())

    def test_explicit_legacy_binding_migration(self):
        self.cloud.binding = []; self.run_deploy('--bind')
        self.assertTrue((self.backup/'dns-before.json').exists())
        self.assertEqual(self.cloud.binding[0]['service'], self.deploy.NAME)
        writes = [(m, u) for m, u, _ in self.cloud.calls if m != 'GET']
        self.assertEqual([x[0] for x in writes], ['PUT', 'POST', 'DELETE', 'PUT'])
        self.assertTrue(self.cloud.subdomain['enabled'])
        self.assertEqual(self.cloud.public_after, 16)

    def test_explicit_initial_worker_and_binding(self):
        self.cloud.modules = None; self.cloud.binding = []; self.run_deploy('--bind')
        self.assertTrue(self.cloud.uploaded)
        self.assertTrue((self.backup/'deployment-verified.json').exists())

    def test_failed_migration_restores_only_deleted_legacy_dns(self):
        self.cloud.binding = []; self.cloud.migration_fail = True
        before = copy.deepcopy(self.cloud.records[0])
        with self.assertRaises(RuntimeError):
            self.run_deploy('--bind')
        self.assertEqual({k: v for k, v in self.cloud.records[0].items() if k != 'id'},
                         {k: v for k, v in before.items() if k != 'id'})
        self.assertFalse((self.backup/'deployment-verified.json').exists())

    def test_lost_delete_response_restores_verified_legacy_dns(self):
        self.cloud.binding = []
        before = copy.deepcopy(self.cloud.records[0])
        original = self.cloud.request

        def lose_response(session, method, url, **kwargs):
            response = original(session, method, url, **kwargs)
            if method == 'DELETE':
                raise OSError('lost DELETE response after server applied it')
            return response

        with patch.object(self.cloud, 'request', side_effect=lose_response):
            with self.assertRaisesRegex(OSError, 'lost DELETE response'):
                self.run_deploy('--bind')
        self.assertEqual({k: v for k, v in self.cloud.records[0].items() if k != 'id'},
                         {k: v for k, v in before.items() if k != 'id'})
        self.assertEqual(self.cloud.calls[-1][:2], ('GET', self.deploy.BASE+'/zones/zone/dns_records?name='+self.deploy.HOST))
        self.assertFalse((self.backup/'deployment-verified.json').exists())

    def test_delete_not_applied_does_not_duplicate_original_record(self):
        self.cloud.binding = []
        before = copy.deepcopy(self.cloud.records)
        original = self.cloud.request

        def fail_before_delete(session, method, url, **kwargs):
            if method == 'DELETE':
                raise OSError('DELETE not applied')
            return original(session, method, url, **kwargs)

        with patch.object(self.cloud, 'request', side_effect=fail_before_delete):
            with self.assertRaisesRegex(OSError, 'DELETE not applied'):
                self.run_deploy('--bind')
        self.assertEqual(self.cloud.records, before)
        self.assertFalse([c for c in self.cloud.calls if c[0] == 'POST' and c[1].endswith('/dns_records')])

    def test_delete_evidence_disk_full_does_not_prevent_dns_recovery(self):
        self.cloud.binding = []
        before = copy.deepcopy(self.cloud.records[0])
        original_response = self.deploy.Evidence.response
        original_checkpoint = self.deploy.Evidence.checkpoint
        full = [False]

        def disk_full_response(evidence, name, response):
            if response.url.endswith('/dns_records/legacy') or full[0]:
                full[0] = True
                raise OSError(errno.ENOSPC, 'fixture disk full after DELETE')
            return original_response(evidence, name, response)

        def disk_full_checkpoint(evidence, name, **details):
            if full[0]:
                raise OSError(errno.ENOSPC, 'fixture disk full during checkpoint')
            return original_checkpoint(evidence, name, **details)

        errors = io.StringIO()
        with patch.object(self.deploy.Evidence, 'response', disk_full_response), \
             patch.object(self.deploy.Evidence, 'checkpoint', disk_full_checkpoint), \
             contextlib.redirect_stderr(errors):
            with self.assertRaisesRegex(OSError, 'fixture disk full after DELETE'):
                self.run_deploy('--bind')
        self.assertEqual({k: v for k, v in self.cloud.records[0].items() if k != 'id'},
                         {k: v for k, v in before.items() if k != 'id'})
        self.assertEqual(self.cloud.calls[-1][0], 'GET')
        self.assertIn('continuing recovery', errors.getvalue())
        self.assertIn('Cannot save deployment failure checkpoint', errors.getvalue())
        self.assertFalse((self.backup/'deployment-verified.json').exists())

    def test_closed_stderr_does_not_prevent_dns_recovery(self):
        self.cloud.binding = []
        before = copy.deepcopy(self.cloud.records[0])
        original = self.deploy.Evidence.response
        broken = [False]

        class ClosedStderr:
            def write(self, value):
                raise OSError(errno.ENOSPC, 'stderr is also unavailable')

            def flush(self):
                pass

        def disk_full_response(evidence, name, response):
            if response.url.endswith('/dns_records/legacy') or broken[0]:
                broken[0] = True
                raise OSError(errno.ENOSPC, 'fixture evidence storage full')
            return original(evidence, name, response)

        with patch.object(self.deploy.Evidence, 'response', disk_full_response), \
             contextlib.redirect_stderr(ClosedStderr()):
            with self.assertRaisesRegex(OSError, 'fixture evidence storage full'):
                self.run_deploy('--bind')
        self.assertEqual({k: v for k, v in self.cloud.records[0].items() if k != 'id'},
                         {k: v for k, v in before.items() if k != 'id'})

    def test_ambiguous_delete_never_restores_over_new_dns_or_binding(self):
        for race in ('dns', 'binding', 'unreadable'):
            with self.subTest(race=race):
                self.cloud.binding = []
                original = self.cloud.request
                lost = [False]

                def lose_response(session, method, url, **kwargs):
                    if lost[0] and race == 'unreadable' and '/dns_records?' in url:
                        raise OSError('recovery DNS state unavailable')
                    response = original(session, method, url, **kwargs)
                    if method == 'DELETE':
                        lost[0] = True
                        if race == 'dns':
                            self.cloud.records = [{'id': 'other', 'name': self.deploy.HOST, 'type': 'A', 'content': '192.0.2.1'}]
                        elif race == 'binding':
                            self.cloud.binding = [{'id': 'other', 'hostname': self.deploy.HOST, 'service': 'another-worker'}]
                        raise OSError('ambiguous DELETE')
                    return response

                with patch.object(self.cloud, 'request', side_effect=lose_response):
                    with self.assertRaises((OSError, RuntimeError)):
                        self.run_deploy('--bind')
                self.assertFalse([c for c in self.cloud.calls if c[0] == 'POST' and c[1].endswith('/dns_records')])
                shutil.rmtree(self.backup)
                self.cloud = Cloud(self.deploy, self.backup)

    def test_dns_restore_requires_exact_readback(self):
        self.cloud.binding = []; self.cloud.migration_fail = True
        original = self.cloud.request
        restoring = [False]

        def wrong_restored_record(session, method, url, **kwargs):
            response = original(session, method, url, **kwargs)
            if method == 'POST' and url.endswith('/dns_records'):
                restoring[0] = True
                self.cloud.records[0]['content'] = 'changed.example.test'
            return response

        with patch.object(self.cloud, 'request', side_effect=wrong_restored_record):
            with self.assertRaisesRegex(RuntimeError, 'DNS recovery readback mismatch'):
                self.run_deploy('--bind')
        self.assertTrue(restoring[0])
        self.assertFalse((self.backup/'deployment-verified.json').exists())


class ReleaseTest(unittest.TestCase):
    def test_real_source_release_and_bundle_in_isolated_fixture(self):
        major = subprocess.check_output(['bash', '-c', 'printf %s "${BASH_VERSINFO[0]}"'], text=True)
        if int(major) < 4:
            self.skipTest('Actual project source needs Bash >=4; run this check in the Linux regression runner')
        with tempfile.TemporaryDirectory(prefix='toolbox-release-source-') as temporary:
            root = Path(temporary).resolve()
            shutil.copy2(REPO/'toolbox.sh', root/'toolbox.sh')
            shutil.copytree(REPO/'modules', root/'modules')
            shutil.copytree(REPO/'web', root/'web')
            (root/'scripts').mkdir(); (root/'docs').mkdir()
            for name in ('build.sh', 'release.sh', 'build-worker.py', 'deploy-cloudflare.py'):
                shutil.copy2(REPO/'scripts'/name, root/'scripts'/name)
            (root/'docs/index.html').write_text('old release retained until successful build\n')
            for argv in (['bash', str(root/'scripts/release.sh')], [os.sys.executable, str(root/'scripts/build-worker.py')]):
                p = subprocess.run(argv, capture_output=True, text=True, timeout=90)
                self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
            deploy = load_script('deploy-cloudflare'); deploy.ROOT = root
            manifest, modules = deploy.load_bundle()
            self.assertEqual(set(modules), set(deploy.MODULES))
            self.assertEqual(manifest['sha256'], hashlib.sha256((root/'docs/index.html').read_bytes()).hexdigest())
            for argument in ('--help', '--list'):
                artifact = subprocess.run(['bash', str(root/'docs/index.html'), argument], capture_output=True, text=True, timeout=30)
                source = subprocess.run(['bash', str(root/'toolbox.sh'), argument], capture_output=True, text=True, timeout=30)
                self.assertEqual((artifact.returncode, source.returncode), (0, 0))
                self.assertEqual(artifact.stdout, source.stdout)

    def test_failed_build_keeps_original_and_success_replaces_atomically(self):
        with tempfile.TemporaryDirectory(prefix='toolbox-release-test-') as temporary:
            root = Path(temporary).resolve()
            (root/'scripts').mkdir(); (root/'docs').mkdir()
            shutil.copyfile(REPO/'scripts/release.sh', root/'scripts/release.sh')
            release = root/'docs/index.html'; release.write_bytes(b'original published bytes\n')
            build = root/'scripts/build.sh'
            for code in ('exit 3\n', 'printf "if\\n" > "$1"\n', 'printf "wrong artifact\\n" > "$1"\n'):
                build.write_text('#!/bin/bash\n'+code)
                p = subprocess.run(['bash', str(root/'scripts/release.sh')], capture_output=True, text=True)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(release.read_bytes(), b'original published bytes\n')
                self.assertEqual(list((root/'docs').glob('.toolbox-release.*')), [])
            build.write_text('#!/bin/bash\nprintf "#!/usr/bin/env bash\\nprintf candidate\\n" > "$1"\nchmod 755 "$1"\n')
            p = subprocess.run(['bash', str(root/'scripts/release.sh')], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertTrue(release.read_bytes().startswith(b'#!/usr/bin/env bash\n'))
            self.assertTrue(os.access(release, os.X_OK))
            self.assertIn(hashlib.sha256(release.read_bytes()).hexdigest(), p.stdout)
            self.assertEqual(list((root/'docs').glob('.toolbox-release.*')), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
