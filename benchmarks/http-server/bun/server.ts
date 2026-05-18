Bun.serve({
  port: 8080,
  hostname: '127.0.0.1',
  fetch(req) {
    const url = req.url;
    const pathStart = url.indexOf('/', 8); // skip "http://" + host
    if (req.method === 'GET' && pathStart > 0 && url.startsWith('/users/', pathStart)) {
      let pathEnd = url.indexOf('?', pathStart);
      if (pathEnd === -1) pathEnd = url.length;
      const idStr = url.slice(pathStart + 7, pathEnd);
      const id = parseInt(idStr, 10);
      const user = {
        id,
        name: 'User ' + idStr,
        email: 'user' + idStr + '@example.com',
        created: 1737000000,
      };
      return new Response(JSON.stringify(user), {
        headers: { 'content-type': 'application/json' },
      });
    }
    return new Response('', { status: 404 });
  },
});
