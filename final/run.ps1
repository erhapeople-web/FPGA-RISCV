param([string]$PythonExe='python',[string]$PdsBin='')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'setup.ps1') -PythonExe $PythonExe -PdsBin $PdsBin
if ($LASTEXITCODE -ne 0) { throw 'Setup failed; no board operation started.' }
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\run_ai_camera_board.py')
if ($LASTEXITCODE -ne 0) { throw 'Board session failed; inspect runs/ for cleanup status.' }
