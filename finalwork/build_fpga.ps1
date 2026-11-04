param([string]$PythonExe='python',[string]$PdsBin='',[switch]$CompileOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
Set-BundleEnvironment $PdsBin
$buildArgs=@('-B','-X','utf8',(Join-Path $PSScriptRoot 'tools\build_project.py'),'--pds-bin',$env:J5_PDS_BIN)
if ($CompileOnly) { $buildArgs+='--compile-only' }
& $baseExe @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'PDS build failed; see build/ logs.' }
