#!/usr/bin/env python3
"""Bundle the landing page and released Bash bytes as Cloudflare Worker text modules."""
import base64
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'dist' / 'worker'


def main():
    script = (ROOT / 'docs' / 'index.html').read_bytes()
    page = (ROOT / 'web' / 'index.html').read_bytes()
    if not script.startswith(b'#!/usr/bin/env bash\n'):
        raise SystemExit('The released artifact is not a Bash script')
    page_text = page.decode('utf-8')
    if '<title>Terry Toolbox' not in page_text:
        raise SystemExit('Missing landing page title')
    sha = hashlib.sha256(script).hexdigest()
    script_hashes = ["'sha256-" + base64.b64encode(hashlib.sha256(x.encode()).digest()).decode() + "'"
                     for x in re.findall(r'<script>(.*?)</script>', page_text, re.S)]
    style_hashes = ["'sha256-" + base64.b64encode(hashlib.sha256(x.encode()).digest()).decode() + "'"
                    for x in re.findall(r'<style>(.*?)</style>', page_text, re.S)]
    csp = "default-src 'none'; script-src " + ' '.join(script_hashes) + '; style-src ' + ' '.join(style_hashes)
    csp += "; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    main_module = (
        "import script from './toolbox.txt';\nimport page from './welcome.txt';\n"
        "import { createHandler } from './router.mjs';\n"
        "export default { fetch: createHandler({ script, page, sha256: " + json.dumps(sha)
        + ", contentSecurityPolicy: " + json.dumps(csp) + " }) };\n"
    )
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'toolbox.txt').write_bytes(script)
    (OUT / 'welcome.txt').write_bytes(page)
    (OUT / 'router.mjs').write_bytes((ROOT / 'web' / 'router.mjs').read_bytes())
    (OUT / 'worker.mjs').write_text(main_module)
    (OUT / 'manifest.json').write_text(json.dumps({'sha256': sha, 'content_security_policy': csp}, indent=2) + '\n')
    print(f'Worker bundle: {OUT}\nBash SHA-256: {sha}')


if __name__ == '__main__':
    main()
