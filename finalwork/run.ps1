param([ValidateSet('Both','P','V')][string]$Mode='Both',[string]$Port='COM11',[string]$PythonExe='python',[string]$PdsBin='')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'setup.ps1') -PythonExe $PythonExe -PdsBin $PdsBin
if ($LASTEXITCODE -ne 0) { throw 'Setup failed before board operation.' }
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\run_benchmark.py') --mode $Mode --port $Port
if ($LASTEXITCODE -ne 0) { throw 'CoreMark failed; inspect runs/ and cleanup status.' }
