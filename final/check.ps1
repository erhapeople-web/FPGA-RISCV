param([string]$PythonExe='python',[string]$PdsBin='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
Set-BundleEnvironment $PdsBin
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\verify_package.py')
if ($LASTEXITCODE -ne 0) { throw 'Package check failed.' }
