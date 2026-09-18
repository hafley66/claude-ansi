const http = require('http');
const https = require('https');

// The upstream may be a full URL (ccz sets ANTHROPIC_BASE_URL=https://z.example)
// or a bare host[:port]. Bare hosts default to https. Scheme decides which
// transport module talks to it and which port is the scheme default.
function parseUpstream(raw) {
  let scheme = 'https';
  let rest = raw;
  const m = /^(https?):\/\/(.*)$/.exec(raw);
  if (m) { scheme = m[1]; rest = m[2]; }
  const defaultPort = scheme === 'http' ? 80 : 443;
  let hostname = rest;
  let port = defaultPort;
  const colon = rest.lastIndexOf(':');
  if (colon !== -1) {
    const maybePort = Number(rest.slice(colon + 1));
    if (Number.isInteger(maybePort) && maybePort > 0 && maybePort < 65536) {
      hostname = rest.slice(0, colon);
      port = maybePort;
    }
  }
  return { mod: scheme === 'http' ? http : https, scheme, hostname, port, defaultPort };
}

const UPSTREAM = parseUpstream(process.env.ANSI_PROXY_UPSTREAM || 'https://api.anthropic.com:443');
const PORT = Number(process.env.ANSI_PROXY_PORT || 8787);
const ESC = String.fromCharCode(27);
const CSI = /\[((?:\d{1,3};){0,5}\d{1,3})m/g;
const PARTIAL = /\[(?:\d{1,3};){0,5}\d{0,3}$/;
const pend = new Map();
const ctx = new Map();

function splitTail(s) {
  const m = PARTIAL.exec(s);
  return m ? [s.slice(0, m.index), s.slice(m.index)] : [s, ''];
}

const DOCUMENTED = /(?:\\(?:033|e|x1[bB]|u001[bB])|0x1[bB]|ESC|CSI|\^\[?|\\)$/;

function reinject(s, prior) {
  if (typeof s !== 'string' || s.indexOf('[') === -1) return s;
  const pre = prior || '';
  return s.replace(CSI, (m, p, off) => {
    if (off > 0 && s.charCodeAt(off - 1) === 27) return m;
    if (off === 0 && pre.charCodeAt(pre.length - 1) === 27) return m;
    const look = (pre + s.slice(0, off)).slice(-8);
    if (DOCUMENTED.test(look)) return m;
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
    if (!parts[0]) { d.text = ''; emit('data: ' + JSON.stringify(o)); return; }

    d.text = reinject(parts[0], ctx.get(idx));
    ctx.set(idx, ((ctx.get(idx) || '') + parts[0]).slice(-8));
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

// Reachability is not identity. Anything else listening on the chosen port
// answers a bare TCP connect, and the wrapper would then point Claude Code at
// a stranger. The wrapper probes this path and matches the token.
const HEALTH_PATH = '/__claude_ansi_health';
const HEALTH_TOKEN = 'claude-ansi-proxy';

const server = http.createServer((req, res) => {
  if (req.url === HEALTH_PATH) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(HEALTH_TOKEN + '\n');
    return;
  }
  // A scheme-default port keeps the plain hostname in the Host header; an
  // explicit non-default port must be echoed so the upstream routes it right.
  const upHost = UPSTREAM.port === UPSTREAM.defaultPort ? UPSTREAM.hostname : UPSTREAM.hostname + ':' + UPSTREAM.port;
  const headers = { ...req.headers, host: upHost };
  delete headers['accept-encoding'];
  const up = UPSTREAM.mod.request(
    { hostname: UPSTREAM.hostname, port: UPSTREAM.port, path: req.url, method: req.method, headers },
    (ur) => {
      const ct = ur.headers['content-type'] || '';
      const oh = { ...ur.headers };
      delete oh['content-length'];
      delete oh['transfer-encoding'];
      delete oh['connection'];
      delete oh['keep-alive'];
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
        ur.on('error', () => res.destroy());
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
      ur.on('error', () => res.destroy());
    }
  );
  // Headers already sent means writeHead would throw uncaught and kill the
  // proxy; cut the response instead.
  up.on('error', (e) => {
    if (res.headersSent) { res.destroy(); return; }
    res.writeHead(502); res.end(String(e));
  });
  req.pipe(up);
});

const fs = require('fs');
const os = require('os');
const path = require('path');
const CACHE = path.join(os.homedir(), '.cache', 'claude-ansi');

// ANSI_PROXY_PORT is a preference, not a pin: an unrelated server already on
// it must not stop the proxy from starting. The wrapper reads the real port
// back out of the port file. ANSI_PROXY_PORT_STRICT=1 makes the port a hard
// requirement and turns a conflict back into an exit.
server.on('error', (e) => {
  if (e.code === 'EADDRINUSE' && process.env.ANSI_PROXY_PORT_STRICT !== '1') {
    console.error('port ' + PORT + ' taken; falling back to an ephemeral port');
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
  console.log('ansi-proxy 127.0.0.1:' + port + ' -> ' + UPSTREAM.scheme + '://' + UPSTREAM.hostname + ':' + UPSTREAM.port);
});
