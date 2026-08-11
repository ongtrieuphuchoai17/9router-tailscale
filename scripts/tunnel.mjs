import { createHash } from 'node:crypto'
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { readFileSync } from 'node:fs'

const DATA_DIR = process.env.DATA_DIR || path.join(os.homedir(), '.9router')
const CLI_TOKEN_SALT = '9r-cli-auth'

const PORT = Number(process.env.PORT || 20128)

// Load .env so PORT etc. are honored even if not exported by the caller
if (!process.env.PORT) {
  try {
    for (const raw of readFileSync('.env', 'utf8').split('\n')) {
      const line = raw.trim()
      if (!line || line.startsWith('#')) continue
      const eq = line.indexOf('=')
      if (eq === -1) continue
      process.env[line.slice(0, eq).trim()] = line.slice(eq + 1).trim()
    }
  } catch {}
}

function machineIdSync() {
  try {
    const id =
      fs.readFileSync('/etc/machine-id', 'utf8').trim() ||
      fs.readFileSync('/var/lib/dbus/machine-id', 'utf8').trim()
    if (id) return createHash('sha256').update(id).digest('hex')
  } catch {}
  return ''
}

function loadRawMachineId() {
  try {
    const raw = fs.readFileSync(path.join(DATA_DIR, 'machine-id'), 'utf8').trim()
    if (raw) return raw
  } catch {}
  return machineIdSync()
}

function loadCliSecret() {
  const file = path.join(DATA_DIR, 'auth', 'cli-secret')
  try {
    const s = fs.readFileSync(file, 'utf8').trim()
    if (s) return s
  } catch {}
  return ''
}

function getCliToken() {
  const raw = loadRawMachineId()
  const secret = loadCliSecret()
  if (!raw || !secret) return ''
  return createHash('sha256').update(raw + CLI_TOKEN_SALT + secret).digest('hex').substring(0, 16)
}

function makeRequest(method, pathname, body = null) {
  return new Promise((resolve) => {
    const token = getCliToken()
    const req = http.request(
      {
        host: '127.0.0.1',
        port: PORT,
        method,
        path: pathname,
        headers: {
          'x-9r-cli-token': token,
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
      },
      (res) => {
        let data = ''
        res.on('data', (d) => (data += d))
        res.on('end', () => {
          let parsed = null
          try {
            parsed = JSON.parse(data)
          } catch {}
          resolve({ statusCode: res.statusCode, data: parsed ?? data })
        })
      }
    )
    req.on('error', (err) => resolve({ statusCode: 0, data: null, error: err.message }))
    req.setTimeout(90000, () => {
      req.destroy(new Error('Request timeout'))
    })
    if (body) req.write(JSON.stringify(body))
    req.end()
  })
}

const ENDPOINTS = {
  status: ['GET', '/api/tunnel/status'],
  enable: ['POST', '/api/tunnel/enable'],
  disable: ['POST', '/api/tunnel/disable'],
  'tailscale-status': ['GET', '/api/tunnel/status'],
  'tailscale-enable': ['POST', '/api/tunnel/tailscale-enable'],
  'tailscale-disable': ['POST', '/api/tunnel/tailscale-disable'],
  'tailscale-check': ['GET', '/api/tunnel/tailscale-check'],
}

const action = process.argv[2] || 'status'
const [method, pathname] = ENDPOINTS[action] || ['GET', '/api/tunnel/status']

const res = await makeRequest(method, pathname)

if (res.statusCode !== 200) {
  console.error(`HTTP ${res.statusCode}: ${JSON.stringify(res.data)}`)
  process.exit(1)
}
console.log(JSON.stringify(res.data, null, 2))
