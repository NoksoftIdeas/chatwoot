# mailtrap-relay

Bridges Mailtrap Inbound to Chatwoot's ActionMailbox `relay` ingress.

## Why this exists

Chatwoot passes `RAILS_INBOUND_EMAIL_SERVICE` straight to
`config.action_mailbox.ingress` (`config/initializers/mailer.rb`), and Rails 7.2
only accepts `relay`, `mailgun`, `mandrill`, `postmark`, `sendgrid`, `ses`.
There is no Mailtrap adapter.

The `relay` ingress would work, except it wants raw RFC822 as the request body
and **Mailtrap's inbound webhook carries no message** — just an `events` array
with ids (event type, event id, timestamp, inbox id, message id, sender name).
Mailtrap Inbound also exposes no IMAP, so Chatwoot's IMAP email channel cannot
poll it either.

What Mailtrap does expose is `raw_message_url` on
`GET /api/inbound/inboxes/{inbox_id}/messages/{id}` — a pre-signed link to the
raw `.eml`, valid for an hour. This service closes the gap:

    Mailtrap webhook -> verify HMAC -> fetch raw .eml -> POST to relay ingress

If you are not committed to Mailtrap, **Postmark or Mailgun avoid all of this** —
they are native ActionMailbox ingresses and need one env var plus a webhook URL.

## Enabling it

Inert by default: it sits behind a compose profile, so it does not start unless
asked. In Coolify, set:

    COMPOSE_PROFILES=mailtrap

Then supply:

| Variable | Meaning |
| --- | --- |
| `MAILTRAP_SIGNING_SECRET` | Shown when you create the webhook. Authenticates callers. |
| `MAILTRAP_API_TOKEN` | Mailtrap → API Tokens. Used to fetch the message. |
| `MAILTRAP_API_BASE` | Defaults to `https://mailtrap.io`. See caveats. |
| `MAILER_INBOUND_EMAIL_DOMAIN` | The domain whose MX points at Mailtrap, e.g. `reply.example.com`. |

`RAILS_INBOUND_EMAIL_PASSWORD` is shared with the Rails service via Coolify's
generated `SERVICE_PASSWORD_INBOUND`, so the basic-auth credential is never typed
by hand.

Give Mailtrap the FQDN Coolify assigns this service as the webhook URL. The
signature check is the only thing authenticating that endpoint.

## Verifying the ingress separately

Before debugging the relay, confirm Chatwoot's side is live:

```bash
curl -u "actionmailbox:$RAILS_INBOUND_EMAIL_PASSWORD" \
  -H "Content-Type: message/rfc822" \
  --data-binary @sample.eml \
  https://your-chatwoot-domain/rails/action_mailbox/relay/inbound_emails
```

`204` means the ingress is live. `404` means `RAILS_INBOUND_EMAIL_SERVICE` did
not take effect.

## Tests

`test.js` stands up a fake Mailtrap API and a fake Chatwoot ingress and drives
real HTTP through the shim. No dependencies, no network:

```bash
docker run --rm -v "$PWD/docker/mailtrap-relay:/relay:ro" -w /relay node:22-alpine node test.js
```

Covers the happy path, HMAC rejection (and that a bad signature short-circuits
before any upstream call), both payload formats, event filtering, and health.

## Caveats

These come from Mailtrap's docs, not from an observed response — the first real
inbound email is the real test, so watch this service's logs then.

- **`MAILTRAP_API_BASE`** defaults to `https://mailtrap.io`, but Mailtrap serves
  some products from `send.api.mailtrap.io`. If the message fetch 404s, that is
  the knob.
- Field names `raw_message_url`, `inbox_id`, `message_id` and the `Api-Token`
  header are all doc-derived.

The service acks the webhook **before** doing the fetch-and-forward, because
Mailtrap retries on a non-2xx and the round trip is slow enough to cause
duplicate deliveries otherwise. Failures are logged with the upstream status.
