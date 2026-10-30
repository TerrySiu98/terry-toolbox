import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createHandler } from '../web/router.mjs';

const script = await readFile(process.env.TOOLBOX_TEST_SCRIPT || new URL('../docs/index.html', import.meta.url), 'utf8');
const page = await readFile(new URL('../web/index.html', import.meta.url), 'utf8');
const sha256 = createHash('sha256').update(script).digest('hex');
const handler = createHandler({ script, page, sha256, contentSecurityPolicy: "default-src 'none'" });
const browser = { 'Accept': 'text/html,application/xhtml+xml', 'User-Agent': 'Mozilla/5.0 (iPhone)' };
const curl = { 'User-Agent': 'curl/8.0', 'Accept': '*/*' };
const wget = { 'User-Agent': 'Wget/1.21.3', 'Accept': '*/*' };
let checked = 0;
for (const headers of [curl, wget, {}, { ...browser, 'User-Agent': 'curl/8.0' }]) {
  const r = await handler(new Request('https://sh.uw.cx/', { headers }));
  assert.equal(r.status, 200);
  assert.equal(await r.text(), script);
  assert.equal(r.headers.get('X-Toolbox-SHA256'), sha256);
  assert.equal(r.headers.get('Vary'), 'Accept, User-Agent');
  checked++;
}
for (const path of ['/', '/index.html']) {
  const r = await handler(new Request('https://sh.uw.cx' + path, { headers: browser }));
  assert.equal(r.status, 200);
  assert.equal(await r.text(), page);
  assert.equal(r.headers.get('Content-Type'), 'text/html; charset=utf-8');
  assert.ok(r.headers.get('Content-Security-Policy'));
  assert.ok(r.headers.get('Cache-Control').includes('no-transform'), 'landing-page bytes must not be rewritten by edge injection');
  checked++;
}
for (const path of ['/toolbox.sh', '/?download=1']) {
  const r = await handler(new Request('https://sh.uw.cx' + path, { headers: browser }));
  assert.equal(await r.text(), script);
  checked++;
}
const redirect = await handler(new Request('http://sh.uw.cx/toolbox.sh?download=1', { headers: browser }));
assert.equal(redirect.status, 308);
assert.equal(redirect.headers.get('Location'), 'https://sh.uw.cx/toolbox.sh?download=1');
checked++;
const hash = await handler(new Request('https://sh.uw.cx/sha256'));
assert.equal(await hash.text(), sha256 + '  toolbox.sh\n'); checked++;
const head = await handler(new Request('https://sh.uw.cx/', { headers: browser, method: 'HEAD' }));
assert.equal(head.status, 200); assert.equal(await head.text(), ''); checked++;
const missing = await handler(new Request('https://sh.uw.cx/missing'));
assert.equal(missing.status, 404); checked++;
const post = await handler(new Request('https://sh.uw.cx/', { method: 'POST' }));
assert.equal(post.status, 405); assert.equal(post.headers.get('Allow'), 'GET, HEAD'); checked++;
console.log(`worker tests passed: ${checked} routing cases; shell hash ${sha256}`);
