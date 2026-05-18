// WORKERS=4 node server-fork.js

const cluster = require('cluster');
const http = require('http');
const os = require('os');

if (cluster.isPrimary) {
  const workers = parseInt(process.env.WORKERS || os.cpus().length, 10);
  for (let i = 0; i < workers; i++) cluster.fork();
  cluster.on('exit', () => cluster.fork());
} else {
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
}
