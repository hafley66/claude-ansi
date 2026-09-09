const http = require('http');
const https = require('https');

const UPSTREAM = process.env.ANSI_PROXY_UPSTREAM || 'api.anthropic.com';
const PORT = Number(process.env.ANSI_PROXY_PORT || 8787);
const ESC = String.fromCharCode(27);
const CSI = /\[((?:\d{1,3};){0,5}\d{1,3})m/g;
const PARTIAL = /\[(?:\d{1,3};){0,5}\d{0,3}$/;
const pend = new Map();

function splitTail(s) {
  const m = PARTIAL.exec(s);
  return m ? [s.slice(0, m.index), s.slice(m.index)] : [s, ''];
}

const DOCUMENTED = /(?:\\(?:033|e|x1[bB]|u001[bB])|0x1[bB]|ESC|CSI|\^\[?|\\)$/;

function reinject(s) {
  if (typeof s !== 'string' || s.indexOf('[') === -1) return s;
  return s.replace(CSI, (m, p, off) => {
    if (s.charCodeAt(off - 1) === 27) return m;
    if (DOCUMENTED.test(s.slice(Math.max(0, off - 8), off))) return m;
    return ESC + '[' + p + 'm';
  });
}

function rewriteEvent(line, emit) {
  if (!line.startsWith('data: ')) { emit(line); return; }
  const body = line.slice(6);
  if (body === '[DONE]') { emit(line); return; }
  let o;
  try { o = JSON.parse(body); } catch { emit(line); return; }
  const idx = o.index === undefined ? 0 : o.index;
  const d = o.delta;
  if (o.type === 'content_block_delta' && d && typeof d.text === 'string') {
    const joined = (pend.get(idx) || '') + d.text;
    const parts = splitTail(joined);
    if (parts[1]) pend.set(idx, parts[1]); else pend.delete(idx);
    if (!parts[0]) return;

    d.text = reinject(parts[0]);
    emit('data: ' + JSON.stringify(o));
    return;
  }
  if (o.type === 'content_block_stop' && pend.get(idx)) {
    const left = pend.get(idx);
    pend.delete(idx);
    emit('data: ' + JSON.stringify({ type: 'content_block_delta', index: idx, delta: { type: 'text_delta', text: reinject(left) } }));
  }
  emit(line);
}

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, host: UPSTREAM };
  delete headers['accept-encoding'];
  const up = https.request(
    { hostname: UPSTREAM, port: 443, path: req.url, method: req.method, headers },
    (ur) => {
      const ct = ur.headers['content-type'] || '';
      const oh = { ...ur.headers };
      delete oh['content-length'];
      res.writeHead(ur.statusCode, oh);
      if (!ct.includes('text/event-stream')) {
        if (!ct.includes('application/json')) { ur.pipe(res); return; }
        let jb = '';
        ur.setEncoding('utf8');
        ur.on('data', (c) => { jb += c; });
        ur.on('end', () => {
          let out = jb;
          try {
            const j = JSON.parse(jb);
            if (Array.isArray(j.content)) {
              let hit = false;
              for (const b of j.content) {
                if (b && b.type === 'text' && typeof b.text === 'string') {
                  const nx = reinject(b.text);
                  if (nx !== b.text) { b.text = nx; hit = true; }
                }
              }
              if (hit) { out = JSON.stringify(j); console.error('INJECT-JSON'); }
            }
          } catch (e) {}
          res.end(out);
        });
        ur.on('error', () => res.end());
        return;
      }
      let buf = '';
      ur.setEncoding('utf8');
      ur.on('data', (chunk) => {
        buf += chunk;
        let i;
        while ((i = buf.indexOf('\n')) !== -1) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          rewriteEvent(line, (l) => res.write(l + '\n'));
        }
      });
      ur.on('end', () => { if (buf) rewriteEvent(buf, (l) => res.write(l)); res.end(); });
      ur.on('error', () => res.end());
    }
  );
  up.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
  req.pipe(up);
});

const fs = require('fs');
const os = require('os');
const path = require('path');
const CACHE = path.join(os.homedir(), '.cache', 'claude-ansi');

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE' && !process.env.ANSI_PROXY_PORT) {
    server.listen(0, '127.0.0.1');
    return;
  }
  console.error(String(e));
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  const port = server.address().port;
  fs.mkdirSync(CACHE, { recursive: true });
  fs.writeFileSync(path.join(CACHE, 'port'), String(port));
  console.log('ansi-proxy 127.0.0.1:' + port + ' -> ' + UPSTREAM);
});
