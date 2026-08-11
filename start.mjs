import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'

const envFile = process.env.ENV_FILE || '.env'
const extra = {}
try {
  for (const raw of readFileSync(envFile, 'utf8').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq === -1) continue
    extra[line.slice(0, eq).trim()] = line.slice(eq + 1).trim()
  }
} catch (err) {
  console.warn(`[start] cannot read ${envFile}: ${err.message}`)
}

const port = process.env.PORT || extra.PORT || '20128'
const host = process.env.HOSTNAME || extra.HOSTNAME || '0.0.0.0'

const args = [
  '-y',
  '9router',
  '--host', host,
  '--port', port,
  '--no-browser',
  '--skip-update',
]
if (process.argv.includes('-l') || process.argv.includes('--log')) args.push('-l')

console.log(`[start] npx ${args.join(' ')}`)
const child = spawn('npx', args, {
  stdio: 'inherit',
  env: { ...process.env, ...extra },
})
child.on('exit', (code) => process.exit(code ?? 0))
