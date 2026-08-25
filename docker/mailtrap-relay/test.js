// Integration harness for mailtrap-relay.js.
// Stands up a fake Mailtrap API and a fake Chatwoot ingress, boots the shim as
// a child process, and drives real HTTP through it.

const http = require('node:http');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const SECRET = 'a'.repeat(32);
const INBOUND_PASSWORD = 'inbound-pw';
const EML = 'From: someone@example.com\r\nSubject: Hello\r\n\r\nBody text.\r\n';

let received = null;
let rawFetches = 0;

const mailtrap = http.createServer((req, res) => {
  if (req.url === '/api/inbound/inboxes/7/messages/42') {
    if (req.headers['api-token'] !== 'test-token') { res.writeHead(401).end(); return; }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ id: 42, raw_message_url: 'http://127.0.0.1:9001/raw/42' }));
    return;
  }
  if (req.url === '/raw/42') {
    rawFetches++;
    res.writeHead(200, { 'Content-Type': 'message/rfc822' });
    res.end(EML);
    return;
  }
  res.writeHead(404).end();
});

const chatwoot = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    received = {
      url: req.url,
      contentType: req.headers['content-type'],
      auth: req.headers.authorization,
      body: Buffer.concat(chunks).toString('utf8'),
    };
    res.writeHead(204).end();
  });
});

function post(path, body, headers) {
  return new Promise((resolve) => {
    const req = http.request(
      { host: '127.0.0.1', port: 9003, path, method: 'POST', headers },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
      }
    );
    req.end(body);
  });
}

const sign = (body) => crypto.createHmac('sha256', SECRET).update(body).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const results = [];
function check(name, pass, detail) {
  results.push({ name, pass, detail });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -- ' + detail : ''}`);
}

(async () => {
  mailtrap.listen(9001);
  chatwoot.listen(9002);

  const shim = spawn('node', [require('node:path').join(__dirname, 'server.js')], {
    env: {
      ...process.env,
      MAILTRAP_SIGNING_SECRET: SECRET,
      MAILTRAP_API_TOKEN: 'test-token',
      MAILTRAP_API_BASE: 'http://127.0.0.1:9001',
      CHATWOOT_INTERNAL_URL: 'http://127.0.0.1:9002',
      RAILS_INBOUND_EMAIL_PASSWORD: INBOUND_PASSWORD,
      PORT: '9003',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const shimLog = [];
  shim.stdout.on('data', (d) => shimLog.push(d.toString()));
  shim.stderr.on('data', (d) => shimLog.push(d.toString()));

  await sleep(700);

  // 1. Happy path: events-array payload, valid signature.
  const payload = JSON.stringify({
    events: [{ event: 'inbound.message_received', id: 'evt_1', inbox_id: 7, message_id: 42 }],
  });
  let res = await post('/', payload, { 'Content-Type': 'application/json', 'Mailtrap-Signature': sign(payload) });
  check('acks webhook with 200', res.status === 200, `got ${res.status}`);
  await sleep(600);
  check('forwarded the raw eml to Chatwoot', received?.body === EML,
    received ? `body len ${received.body.length}` : 'nothing received');
  check('posted as message/rfc822', received?.contentType === 'message/rfc822', received?.contentType);
  check('used actionmailbox basic auth',
    received?.auth === 'Basic ' + Buffer.from(`actionmailbox:${INBOUND_PASSWORD}`).toString('base64'),
    received?.auth);
  check('hit the relay ingress path',
    received?.url === '/rails/action_mailbox/relay/inbound_emails', received?.url);

  // 2. Bad signature must be rejected before any upstream call.
  received = null;
  const before = rawFetches;
  res = await post('/', payload, { 'Content-Type': 'application/json', 'Mailtrap-Signature': 'deadbeef' });
  check('rejects bad signature with 401', res.status === 401, `got ${res.status}`);
  await sleep(400);
  check('bad signature does not reach Mailtrap or Chatwoot',
    received === null && rawFetches === before, `rawFetches ${before}->${rawFetches}`);

  // 3. Missing signature header.
  res = await post('/', payload, { 'Content-Type': 'application/json' });
  check('rejects missing signature with 401', res.status === 401, `got ${res.status}`);

  // 4. JSON Lines payload format.
  received = null;
  const jsonl = JSON.stringify({ event: 'inbound.message_received', inbox_id: 7, message_id: 42 });
  res = await post('/', jsonl, { 'Content-Type': 'application/x-ndjson', 'Mailtrap-Signature': sign(jsonl) });
  await sleep(600);
  check('handles JSON Lines payload', res.status === 200 && received?.body === EML,
    `status ${res.status}, received ${received ? 'yes' : 'no'}`);

  // 5. Non-inbound events are ignored.
  received = null;
  const other = JSON.stringify({ events: [{ event: 'inbound.something_else', inbox_id: 7, message_id: 42 }] });
  res = await post('/', other, { 'Content-Type': 'application/json', 'Mailtrap-Signature': sign(other) });
  await sleep(400);
  check('ignores unrelated event types', res.status === 200 && received === null,
    `status ${res.status}, received ${received ? 'yes' : 'no'}`);

  // 6. Health endpoint.
  const health = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port: 9003, path: '/health' }, (r) => resolve(r.statusCode));
  });
  check('health endpoint returns 200', health === 200, `got ${health}`);

  shim.kill();
  mailtrap.close();
  chatwoot.close();

  const failed = results.filter((r) => !r.pass);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('\n--- shim log ---\n' + shimLog.join(''));
  }
  process.exit(failed.length ? 1 : 0);
})();
