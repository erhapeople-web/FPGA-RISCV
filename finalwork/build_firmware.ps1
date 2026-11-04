param([Parameter(Mandatory=$true)][string]$ToolchainBin,[string]$PythonExe='python')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\rebuild_firmware.py') --toolchain-bin $ToolchainBin
if ($LASTEXITCODE -ne 0) { throw 'Exact firmware reproduction failed; frozen artifacts were not replaced.' }
