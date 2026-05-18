const http = require('http');

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url.startsWith('/users/')) {
    let pathEnd = req.url.indexOf('?');
    if (pathEnd === -1) pathEnd = req.url.length;
    const idStr = req.url.slice(7, pathEnd);
    const id = parseInt(idStr, 10);
    const user = {
      id,
      name: 'User ' + idStr,
      email: 'user' + idStr + '@example.com',
      created: 1737000000,
    };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(user));
    return;
  }
  res.writeHead(404);
  res.end();
});

server.listen(8080, '127.0.0.1');
