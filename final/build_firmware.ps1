param([Parameter(Mandatory=$true)][string]$ToolchainBin, [string]$PythonExe='python')
$ErrorActionPreference='Stop'
& $PythonExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\build_camera_firmware.py') --toolchain $ToolchainBin
if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src\firmware\firmware_init.vh') -Destination (Join-Path $PSScriptRoot 'pds\firmware_init.vh') -Force
Write-Output 'Build completed. Modified sources/ROM require new functional, timing, ROM/CDC and board qualification.'
