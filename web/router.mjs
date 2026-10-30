// Serve one audited shell artifact and a browser landing page, without an origin fetch.
export function createHandler({ script, page, sha256, contentSecurityPolicy }) {
  return async function handle(request) {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed\n', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    if (url.protocol === 'http:') {
      url.protocol = 'https:';
      return new Response(null, { status: 308, headers: { Location: url.href, 'Cache-Control': 'public, max-age=300' } });
    }
    const headers = new Headers({
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'strict-origin-when-cross-origin',
      'Strict-Transport-Security': 'max-age=86400',
      'Cache-Control': 'public, max-age=60',
    });
    let body;
    let status = 200;
    const ua = request.headers.get('User-Agent') || '';
    const accept = request.headers.get('Accept') || '';
    const cli = /(?:curl|wget|httpie|python-requests|libwww-perl)\//i.test(ua);
    const html = /text\/html/i.test(accept);
    if (url.pathname === '/toolbox.sh' || (url.pathname === '/' && (cli || !html || url.searchParams.get('download') === '1'))) {
      body = script;
      headers.set('Content-Type', 'text/plain; charset=utf-8');
      headers.set('ETag', `"${sha256}"`);
      headers.set('X-Toolbox-SHA256', sha256);
      if (url.pathname === '/toolbox.sh') headers.set('Content-Disposition', 'attachment; filename="toolbox.sh"');
      if (url.pathname === '/') headers.set('Vary', 'Accept, User-Agent');
    } else if (url.pathname === '/' || url.pathname === '/index.html') {
      body = page;
      headers.set('Content-Type', 'text/html; charset=utf-8');
      headers.set('Content-Security-Policy', contentSecurityPolicy);
      headers.set('Vary', 'Accept, User-Agent');
    } else if (url.pathname === '/sha256') {
      body = `${sha256}  toolbox.sh\n`;
      headers.set('Content-Type', 'text/plain; charset=utf-8');
    } else if (url.pathname === '/robots.txt') {
      body = 'User-agent: *\nAllow: /\n';
      headers.set('Content-Type', 'text/plain; charset=utf-8');
    } else if (url.pathname === '/favicon.ico') {
      return new Response(null, { status: 204, headers });
    } else {
      body = 'Not found\n';
      status = 404;
      headers.set('Content-Type', 'text/plain; charset=utf-8');
    }
    return new Response(request.method === 'HEAD' ? null : body, { status, headers });
  };
}
