# v4 build + flat ABIs in artifacts/<Contract>.abi.json
Set-Location (Join-Path $PSScriptRoot "..")
$env:FOUNDRY_PROFILE = "v4"
forge build @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
python scripts/export-abi.py @args
