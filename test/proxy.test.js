const { spawn, execFileSync } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert');

const PROXY = path.join(__dirname, '..', 'ansi-proxy.js');
const ESC = String.fromCharCode(27);

function freePort() {
  return new Promise((resolve) => {
    const s = http.createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}

// Launch the proxy with a temp HOME so its port file never touches the real
// cache, and return { port, kill } once the health endpoint answers.
function launchProxy(env, proxyPort) {
  return new Promise((resolve) => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ansi-test-'));
    const child = spawn(process.execPath, [PROXY], {
      env: { ...process.env, HOME: home, ANSI_PROXY_PORT: String(proxyPort), ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { out += c; });
    const started = Date.now();
    const poll = () => {
      if (out.includes('ansi-proxy 127.0.0.1:')) {
        resolve({ port: proxyPort, home, kill: () => child.kill(), log: () => out });
        return;
      }
      if (Date.now() - started > 5000) {
        resolve({ port: proxyPort, home, kill: () => child.kill(), log: () => out, timeout: true });
        return;
      }
      setTimeout(poll, 20);
    };
    poll();
  });
}

function post(port, pathName, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: '127.0.0.1', port, path: pathName, method: 'POST', headers: headers || {} },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; });
        res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
      }
    );
    req.on('error', reject);
    req.end();
  });
}

test('proxy reinserts ESC for JSON and SSE, forwards to the configured upstream', async () => {
  let sawRequest = null;
  let sawStream = null;
  const mockPort = await freePort();
  const mock = http.createServer((req, res) => {
    if (req.url === '/v1/messages') {
      sawRequest = { host: req.headers.host, url: req.url };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ content: [{ type: 'text', text: 'hello [38;5;114mgreen[0m world' }] }));
      return;
    }
    if (req.url === '/v1/messages/stream') {
      sawStream = { host: req.headers.host, url: req.url };
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write('data: ' + JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '[38;5;114mgreen[0m' } }) + '\n\n');
      res.end('data: [DONE]\n\n');
      return;
    }
    res.writeHead(404); res.end();
  });
  await new Promise((r) => mock.listen(mockPort, '127.0.0.1', r));

  const proxyPort = await freePort();
  const proxy = await launchProxy({ ANSI_PROXY_UPSTREAM: 'http://127.0.0.1:' + mockPort }, proxyPort);
  assert.ok(proxy.port, 'proxy started (timeout? ' + (proxy.timeout || '') + ' log: ' + proxy.log() + ')');

  const json = await post(proxyPort, '/v1/messages');
  const jsonText = JSON.parse(json.body).content[0].text;
  assert.ok(jsonText.includes(ESC + '[38;5;114mgreen' + ESC + '[0m'), 'ESC reinserted in JSON');
  assert.equal(sawRequest.url, '/v1/messages');
  assert.equal(sawRequest.host, '127.0.0.1:' + mockPort, 'explicit port echoed in Host header');

  const sse = await post(proxyPort, '/v1/messages/stream');
  const sseDelta = JSON.parse(sse.body.split('\n').find((l) => l.startsWith('data: ') && !l.includes('[DONE]')).slice(6)).delta.text;
  assert.ok(sseDelta.includes(ESC + '[38;5;114mgreen' + ESC + '[0m'), 'ESC reinserted in SSE');
  assert.equal(sawStream.url, '/v1/messages/stream');
  assert.equal(sawStream.host, '127.0.0.1:' + mockPort);

  proxy.kill();
  await new Promise((r) => mock.close(r));
});

test('upstream parse table via startup banner', async () => {
  const cases = [
    { in: 'api.anthropic.com', want: 'https://api.anthropic.com:443' },
    { in: 'api.anthropic.com:8443', want: 'https://api.anthropic.com:8443' },
    { in: 'https://gate.example', want: 'https://gate.example:443' },
    { in: 'https://gate.example:9443', want: 'https://gate.example:9443' },
    { in: 'http://z.example:8080', want: 'http://z.example:8080' },
    { in: 'not a url at all', want: 'https://not a url at all:443' },
    { in: '', want: 'https://api.anthropic.com:443' },
  ];
  for (const c of cases) {
    const port = await freePort();
    const proxy = await launchProxy({ ANSI_PROXY_UPSTREAM: c.in }, port);
    assert.ok(proxy.log().includes('-> ' + c.want), c.in + ' -> ' + c.want + ' (got: ' + proxy.log().trim() + ')');
    proxy.kill();
  }
});

test('wrapper gate: per-upstream port files, reuse within, never across', () => {
  const wrap = fs.readFileSync(path.join(__dirname, '..', 'claude-wrapper.sh'), 'utf8');
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ansi-gate-'));
  const cache = path.join(home, '.cache', 'claude-ansi');
  // Evaluate only the proxy branch in isolation: stub the helpers and the
  // exec target, run the gate, capture which exports happened, and which port
  // file each start_proxy call was handed (recorded to TEST_LOG).
  const gate = (env, tag) => {
    const log = path.join(home, 'starts-' + tag + '.log');
    const stubbed = wrap
      .replace(/^newest\(\).*?^}/ms, 'newest() { echo ""; }')
      .replace(/^newest_patched\(\).*?^}/ms, 'newest_patched() { echo ""; }')
      .replace(/^repatch\(\).*?^}/ms, 'repatch() { return 1; }')
      .replace(/^alive\(\) \{[\s\S]*?\n\}/m, 'alive() { [ -n "${1:-}" ]; }')
      .replace(/^start_proxy\(\) \{[\s\S]*?\n\}/ms, 'start_proxy() { local pf="$1"; printf "%s\\n" "$pf" >> "${TEST_LOG:-/dev/null}"; echo 9999; }')
      .replace('exec "$REAL" "$@"', 'printf "%s\\n" "FINAL_ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}" "FINAL_ANSI_PROXY_UPSTREAM=${ANSI_PROXY_UPSTREAM:-}"')
      .replace(/if \[ ! -x "\$REAL" \]; then\n  echo "claude-ansi: no runnable claude binary under \$SHARE" >&2\n  exit 127\nfi/, 'REAL=/bin/true');
    // The gate's meaning depends on these being absent: a shell that exports
    // ANTHROPIC_BASE_URL for ccz (this machine's default) would turn every
    // "unset" case into a chained one and fail the test on correct behavior.
    const base = { ...process.env };
    delete base.ANTHROPIC_BASE_URL;
    delete base.ANSI_PROXY_UPSTREAM;
    delete base._CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL;
    // Run under system /bin/bash (3.2), not the $PATH resolution which boop
    // may point at Homebrew bash 5: 3.2 is the regime the wrapper has to work in.
    const out = execFileSync('/bin/bash', ['-c', stubbed], { env: { ...base, HOME: home, TEST_LOG: log, ...env }, encoding: 'utf8' });
    const res = {};
    for (const line of out.split('\n')) {
      const m = /^FINAL_(\w+)=(.*)$/.exec(line);
      if (m) res[m[1]] = m[2];
    }
    const starts = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
    return { res, starts };
  };

  const A = 'https://upstream-x.example';
  const B = 'https://upstream-y.example';

  // Different upstreams resolve to different port files, and both start.
  const a1 = gate({ ANTHROPIC_BASE_URL: A }, 'a1');
  const b1 = gate({ ANTHROPIC_BASE_URL: B }, 'b1');
  assert.equal(a1.starts.length, 1);
  assert.equal(b1.starts.length, 1);
  assert.notEqual(a1.starts[0], b1.starts[0], 'different upstream, different port file');
  assert.ok(path.basename(a1.starts[0]).startsWith('port-'), 'chained port file is hash-keyed');
  assert.equal(a1.res.ANTHROPIC_BASE_URL, 'http://127.0.0.1:9999');
  assert.equal(a1.res.ANSI_PROXY_UPSTREAM, A);
  assert.equal(b1.res.ANSI_PROXY_UPSTREAM, B);

  // Same upstream re-resolves to the same port file.
  const a2 = gate({ ANTHROPIC_BASE_URL: A }, 'a2');
  assert.equal(a2.starts[0], a1.starts[0], 'same upstream, same port file');

  // An alive port file for its own upstream is reused, not restarted.
  fs.mkdirSync(path.dirname(b1.starts[0]), { recursive: true });
  fs.writeFileSync(b1.starts[0], '9999');
  const b2 = gate({ ANTHROPIC_BASE_URL: B }, 'b2');
  assert.equal(b2.starts.length, 0, 'alive upstream file is reused');
  assert.equal(b2.res.ANSI_PROXY_UPSTREAM, B);

  // A differing upstream's live port file is never picked up by another chain.
  const a3 = gate({ ANTHROPIC_BASE_URL: A }, 'a3');
  assert.equal(a3.starts.length, 1, 'X still starts its own proxy');
  assert.equal(a3.starts[0], a1.starts[0]);
  assert.notEqual(a3.starts[0], b1.starts[0]);

  // Unset still uses the plain (non-hashed) port file.
  const unset = gate({}, 'unset');
  assert.equal(unset.res.ANSI_PROXY_UPSTREAM, '');
  assert.equal(unset.starts.length, 1);
  assert.equal(unset.starts[0], path.join(cache, 'port'), 'unset uses the plain port file');

  // Already-local URL keeps the no-wrap no-op, nothing starts.
  const local = gate({ ANTHROPIC_BASE_URL: 'http://127.0.0.1:9999' }, 'local');
  assert.equal(local.starts.length, 0);
  assert.equal(local.res.ANSI_PROXY_UPSTREAM, '');

  fs.rmSync(home, { recursive: true, force: true });
});
