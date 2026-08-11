#!/usr/bin/env node
//
// Tailscale full-automation via the Tailscale API.
//
// Given Tailscale API credentials (API access token OR OAuth client id+secret),
// this script programmatically:
//   1. Resolves an access token + tailnet.
//   2. Enables MagicDNS (if not already on).
//   3. Enables HTTPS certificates for the tailnet (PATCH /settings).
//   4. Adds the `funnel` node attribute to the tailnet ACL (no browser approval).
//   5. Creates a reusable, pre-authorized auth key.
//   6. Prints the auth key to stdout for `tailscale up --auth-key=...`.
//
// Env:
//   TAILSCALE_API_KEY             API access token (Bearer)   — OR —
//   TAILSCALE_CLIENT_ID / _SECRET OAuth client (client_credentials grant)
//   TAILSCALE_TAILNET             tailnet id/name; default "-" (token's tailnet)
//   TAILSCALE_TAGS                optional comma-separated device tags for the key
//   TAILSCALE_HOSTNAME            hostname used by tailscale-setup.sh
//   TAILSCALE_DESCRIPTION         optional key description
//
// Exit: 0 and prints the key; 1 on failure.

const API_BASE = 'https://api.tailscale.com/api/v2'

const env = (name) => process.env[name] ?? ''
const tailnet = env('TAILSCALE_TAILNET') || '-'
const TAGS = env('TAILSCALE_TAGS')
  .split(',')
  .map((t) => t.trim())
  .filter(Boolean)

function fail(msg) {
  console.error(`[tailscale-autoconfigure] ${msg}`)
  process.exit(1)
}

async function tsRequest(method, path, token, body, headers = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      ...(body !== undefined ? { 'Content-Type': 'application/hujson' } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  })
  const text = await res.text()
  if (!res.ok) {
    fail(`API ${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`)
  }
  return text
}

// ---------------------------------------------------------------------------
// 1. Resolve access token
// ---------------------------------------------------------------------------
async function resolveToken() {
  const apiKey = env('TAILSCALE_API_KEY')
  const clientId = env('TAILSCALE_CLIENT_ID')
  const clientSecret = env('TAILSCALE_CLIENT_SECRET')

  if (apiKey) {
    console.error('[1/5] using TAILSCALE_API_KEY')
    return apiKey
  }
  if (clientId && clientSecret) {
    console.error('[1/5] exchanging OAuth client credentials for a token')
    const body = new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: clientId,
      client_secret: clientSecret,
    })
    const res = await fetch(`${API_BASE}/oauth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })
    const text = await res.text()
    if (!res.ok) fail(`oauth/token -> ${res.status}: ${text.slice(0, 300)}`)
    const token = JSON.parse(text).access_token
    if (!token) fail('oauth/token returned no access_token')
    return token
  }
  fail('set TAILSCALE_API_KEY OR TAILSCALE_CLIENT_ID + TAILSCALE_CLIENT_SECRET')
}

async function getTailnetName(token) {
  try {
    const t = await tsRequest('GET', '/tailnet', token)
    const name = JSON.parse(t).tailnet
    console.error(`    tailnet: ${name}`)
    return name
  } catch {
    return tailnet
  }
}

// ---------------------------------------------------------------------------
// 2. MagicDNS
// ---------------------------------------------------------------------------
async function ensureMagicDNS(token) {
  console.error('[2/5] ensuring MagicDNS...')
  const prefs = JSON.parse(await tsRequest('GET', `/tailnet/${tailnet}/dns/preferences`, token))
  if (prefs.magicDNS) {
    console.error('    MagicDNS already enabled')
    return
  }
  const res = await tsRequest(
    'POST',
    `/tailnet/${tailnet}/dns/preferences`,
    token,
    { magicDNS: true },
    { 'Content-Type': 'application/json' }
  )
  console.error(`    MagicDNS enabled: ${JSON.parse(res).magicDNS}`)
}

// ---------------------------------------------------------------------------
// 3. HTTPS certificates (tailnet settings)
// ---------------------------------------------------------------------------
async function ensureHTTPS(token) {
  console.error('[3/5] ensuring HTTPS certificates...')
  let settings = {}
  try {
    settings = JSON.parse(await tsRequest('GET', `/tailnet/${tailnet}/settings`, token))
  } catch (e) {
    console.error('    could not read tailnet settings, attempting to enable HTTPS anyway')
  }
  if (settings.httpsEnabled) {
    console.error('    HTTPS already enabled')
    return
  }
  await tsRequest('PATCH', `/tailnet/${tailnet}/settings`, token, { httpsEnabled: true }, {
    'Content-Type': 'application/json',
  })
  console.error('    HTTPS enabled')
}

// ---------------------------------------------------------------------------
// 4. Funnel node attribute in the ACL
// ---------------------------------------------------------------------------
async function ensureFunnelAttr(token) {
  console.error('[4/5] ensuring funnel node attribute in ACL...')
  let raw = await tsRequest('GET', `/tailnet/${tailnet}/acl`, token, undefined, {
    Accept: 'application/hujson',
  })
  if (raw.includes('"funnel"')) {
    console.error('    funnel attr already present')
    return
  }
  let acl = null
  try {
    acl = JSON.parse(raw)
  } catch {
    // HuJSON with comments — fall back to text insertion below
  }
  if (acl) {
    acl.nodeAttrs = acl.nodeAttrs ?? []
    if (!acl.nodeAttrs.some((na) => (na.attr ?? []).includes('funnel'))) {
      acl.nodeAttrs.push({ target: ['autogroup:member'], attr: ['funnel'] })
    }
    raw = JSON.stringify(acl, null, 2)
  } else {
    const insert = '"nodeAttrs":[{"target":["autogroup:member"],"attr":["funnel"]}],'
    if (raw.includes('"acls"')) raw = raw.replace(/"acls"/, insert + '"acls"')
    else raw = raw.replace('{', `{\n${insert}`)
  }
  await tsRequest('POST', `/tailnet/${tailnet}/acl`, token, raw, {
    'Content-Type': 'application/hujson',
  })
  console.error('    funnel attr added to ACL')
}

// ---------------------------------------------------------------------------
// 5. Create a reusable, pre-authorized auth key
// ---------------------------------------------------------------------------
async function createAuthKey(token) {
  console.error('[5/5] creating reusable pre-authorized auth key...')
  const body = {
    capabilities: {
      devices: {
        create: {
          reusable: true,
          ephemeral: false,
          preauthorized: true,
          ...(TAGS.length ? { tags: TAGS } : {}),
        },
      },
    },
    description: env('TAILSCALE_DESCRIPTION') || `9router auto (${new Date().toISOString()})`,
    expirySeconds: 60 * 60 * 24 * 30,
  }
  const res = JSON.parse(
    await tsRequest('POST', `/tailnet/${tailnet}/keys`, token, body, {
      'Content-Type': 'application/json',
    })
  )
  if (!res.key) fail('key creation returned no key')
  console.error('    auth key created')
  return res.key
}

// ---------------------------------------------------------------------------
const token = await resolveToken()
await getTailnetName(token)
await ensureMagicDNS(token)
await ensureHTTPS(token)
await ensureFunnelAttr(token)
const key = await createAuthKey(token)
process.stdout.write(key + '\n')
