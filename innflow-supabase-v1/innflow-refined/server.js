const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, 'public');
const port = Number(process.env.PORT || 3000);
const types = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg','.webp':'image/webp'};
function send(res, status, body, type='text/plain; charset=utf-8') {
  res.writeHead(status, {'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin', 'X-Frame-Options': 'DENY', 'Permissions-Policy': 'camera=(), microphone=(), geolocation=()'});
  res.end(body);
}
const server = http.createServer((req, res) => {
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url, `http://${req.headers.host || 'localhost'}`).pathname); }
  catch { return send(res, 400, 'Requisição inválida'); }
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Método não permitido');
  if (pathname === '/api/health') return send(res, 200, JSON.stringify({ok:true, service:'InnFlow demo', mode:'prototype', database:'browser-local-storage', productionReady:false}), 'application/json; charset=utf-8');
  let relative = pathname === '/manager' || pathname === '/manager/' ? 'manager.html' : pathname === '/apresentacao' || pathname === '/apresentacao/' ? 'presentation.html' : pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const full = path.resolve(root, relative);
  if (full !== root && !full.startsWith(root + path.sep)) return send(res, 403, 'Acesso negado');
  fs.readFile(full, (err, data) => {
    if (err) return send(res, 404, 'Página não encontrada');
    res.writeHead(200, {'Content-Type': types[path.extname(full)] || 'application/octet-stream', 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Referrer-Policy':'strict-origin-when-cross-origin', 'X-Frame-Options':'DENY', 'Permissions-Policy':'camera=(), microphone=(), geolocation=()'});
    if (req.method === 'HEAD') return res.end();
    res.end(data);
  });
});
server.listen(port, '127.0.0.1', () => console.log(`InnFlow Preview disponível em http://localhost:${port}, http://localhost:${port}/manager e http://localhost:${port}/apresentacao`));
