param([string]$Port='COM11',[string]$PythonExe='python',[string]$PdsBin='')
& (Join-Path $PSScriptRoot 'run.ps1') -Mode V -Port $Port -PythonExe $PythonExe -PdsBin $PdsBin
