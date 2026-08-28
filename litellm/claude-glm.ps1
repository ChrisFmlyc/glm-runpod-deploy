# Launches Claude Code pointed at your own GLM endpoint via the LiteLLM proxy.
# Env vars are set for THIS PROCESS ONLY, so your normal `claude` is unaffected.
# Requires start-proxy.ps1 to be running in another window.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Get-Content "$root\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

try {
  $null = Invoke-WebRequest -Uri "http://127.0.0.1:4000/health/liveliness" -TimeoutSec 5 -UseBasicParsing
} catch {
  Write-Host "Proxy not reachable on :4000 - run start-proxy.ps1 first." -ForegroundColor Red
  exit 1
}

$env:ANTHROPIC_BASE_URL         = "http://127.0.0.1:4000"
$env:ANTHROPIC_AUTH_TOKEN       = $env:LITELLM_MASTER_KEY
$env:ANTHROPIC_MODEL            = "glm53"
$env:ANTHROPIC_SMALL_FAST_MODEL = "glm53-small"

# Claude Code does not recognise "glm53", so it assumes a small context window
# and auto-compacts aggressively to stay inside it. LiteLLM's model_info is NOT
# read by Claude Code - these env vars are the only way to tell it the truth.
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1048576"
$env:CLAUDE_CODE_MAX_OUTPUT_TOKENS  = "16384"

Write-Host "Claude Code -> GLM-5.3-Flash UNCENSORED (via LiteLLM)" -ForegroundColor Green
claude @args
