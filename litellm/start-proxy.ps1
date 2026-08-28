# Starts the LiteLLM proxy that translates Anthropic <-> OpenAI.
# Leave this running in its own terminal window.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# load .env into this process only
Get-Content "$root\.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), "Process")
  }
}

# LiteLLM prints a Unicode banner; the default cp1252 console encoding
# kills startup with UnicodeEncodeError. Force UTF-8.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if (-not $env:GLM_API_KEY)        { throw "GLM_API_KEY missing from .env" }
if (-not $env:LITELLM_MASTER_KEY) { throw "LITELLM_MASTER_KEY missing from .env" }

$exe = "$root\.venv-litellm\Scripts\litellm.exe"
if (-not (Test-Path $exe)) {
  Write-Host "litellm.exe not found - the pip install has not finished." -ForegroundColor Red
  Write-Host "Expected at: $exe" -ForegroundColor DarkGray
  exit 1
}

Write-Host "LiteLLM proxy -> http://127.0.0.1:4000" -ForegroundColor Green
Write-Host "backend: GLM-5.3-Flash UNCENSORED on RunPod" -ForegroundColor DarkGray
Write-Host "Ctrl+C to stop.`n"

& $exe --config "$root\litellm\config.yaml" --port 4000
