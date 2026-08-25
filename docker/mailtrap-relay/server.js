// Mailtrap Inbound -> Chatwoot ActionMailbox relay ingress.
//
// Mailtrap's inbound webhook is notification-only: it carries message ids, not
// the message. ActionMailbox's relay ingress wants raw RFC822. This bridges the
// two: verify signature -> fetch raw .eml from Mailtrap -> POST to Chatwoot.
//
// Zero dependencies. Node 18+ (global fetch, crypto.timingSafeEqual).

const http = require('node:http');
const crypto = require('node:crypto');

const {
  MAILTRAP_SIGNING_SECRET,
  MAILTRAP_API_TOKEN,
  MAILTRAP_API_BASE = 'https://mailtrap.io',
  CHATWOOT_INTERNAL_URL = 'http://rails:3000',
  RAILS_INBOUND_EMAIL_PASSWORD,
  PORT = 8080,
} = process.env;

for (const [k, v] of Object.entries({ MAILTRAP_SIGNING_SECRET, MAILTRAP_API_TOKEN, RAILS_INBOUND_EMAIL_PASSWORD })) {
  if (!v) { console.error(`missing required env ${k}`); process.exit(1); }
}

const INGRESS = `${CHATWOOT_INTERNAL_URL}/rails/action_mailbox/relay/inbound_emails`;
const INGRESS_AUTH = 'Basic ' + Buffer.from(`actionmailbox:${RAILS_INBOUND_EMAIL_PASSWORD}`).toString('base64');

function signatureValid(rawBody, header) {
  if (!header) return false;
  const expected = crypto.createHmac('sha256', MAILTRAP_SIGNING_SECRET).update(rawBody).digest('hex');
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(String(header).trim(), 'utf8');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Mailtrap sends either a JSON object with an `events` array, or JSON Lines
// (one event object per line) depending on the webhook's payload format.
function parseEvents(rawBody) {
  const text = rawBody.toString('utf8').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed;
    if (Array.isArray(parsed.events)) return parsed.events;
    return [parsed];
  } catch {
    return text.split('\n').filter(Boolean).map((line) => JSON.parse(line));
  }
}

async function forward(event) {
  const inboxId = event.inbox_id;
  const messageId = event.message_id ?? event.id;
  if (!inboxId || !messageId) throw new Error(`event missing inbox_id/message_id: ${JSON.stringify(event)}`);

  const metaRes = await fetch(`${MAILTRAP_API_BASE}/api/inbound/inboxes/${inboxId}/messages/${messageId}`, {
    headers: { 'Api-Token': MAILTRAP_API_TOKEN, Accept: 'application/json' },
  });
  if (!metaRes.ok) throw new Error(`mailtrap message fetch ${metaRes.status}: ${await metaRes.text()}`);

  const { raw_message_url: rawUrl } = await metaRes.json();
  if (!rawUrl) throw new Error(`no raw_message_url on message ${messageId}`);

  // Pre-signed URL, expires in an hour. No Api-Token needed (and sending one can 400).
  const rawRes = await fetch(rawUrl);
  if (!rawRes.ok) throw new Error(`raw eml fetch ${rawRes.status}`);
  const eml = Buffer.from(await rawRes.arrayBuffer());

  const ingressRes = await fetch(INGRESS, {
    method: 'POST',
    headers: { 'Content-Type': 'message/rfc822', Authorization: INGRESS_AUTH },
    body: eml,
  });
  // ActionMailbox returns 204 on success, 404 if the ingress isn't :relay.
  if (!ingressRes.ok) throw new Error(`chatwoot ingress ${ingressRes.status}: ${await ingressRes.text()}`);

  console.log(`relayed message ${messageId} (${eml.length} bytes)`);
}

http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') { res.writeHead(200).end('ok'); return; }
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const rawBody = Buffer.concat(chunks);

    if (!signatureValid(rawBody, req.headers['mailtrap-signature'])) {
      console.warn('rejected webhook: bad signature');
      res.writeHead(401).end();
      return;
    }

    let events;
    try {
      events = parseEvents(rawBody);
    } catch (err) {
      console.error('unparseable payload:', err.message);
      res.writeHead(400).end();
      return;
    }

    // Ack before doing the work: Mailtrap retries on non-2xx, and a slow
    // ingress round-trip would otherwise cause duplicate deliveries.
    res.writeHead(200).end('ok');

    for (const event of events) {
      if (event.event && event.event !== 'inbound.message_received') continue;
      try {
        await forward(event);
      } catch (err) {
        console.error('relay failed:', err.message);
      }
    }
  });
}).listen(Number(PORT), () => console.log(`mailtrap-relay listening on ${PORT}`));
