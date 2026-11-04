function Get-BundlePython([string]$RequestedPython) {
    $baseExe = & $RequestedPython -c 'import sys; print(sys._base_executable)'
    if ($LASTEXITCODE -ne 0 -or -not $baseExe -or -not (Test-Path -LiteralPath $baseExe.Trim())) { throw 'Install 64-bit Python 3.10+ or pass -PythonExe with its path.' }
    return $baseExe.Trim()
}
function Set-BundleEnvironment([string]$RequestedPdsBin) {
    $selectedPds = $RequestedPdsBin
    if (-not $selectedPds) { $selectedPds = $env:J5_PDS_BIN }
    if (-not $selectedPds) {
        foreach ($candidatePds in @('D:\FPGA2\PDS_2022.2-SP6.4\bin','C:\pango\PDS_2022.2-SP6.4\bin')) {
            if (Test-Path -LiteralPath (Join-Path $candidatePds 'cdt_cfg_shell.exe')) { $selectedPds=$candidatePds; break }
        }
    }
    if (-not $selectedPds -or -not (Test-Path -LiteralPath (Join-Path $selectedPds 'pds_shell.exe'))) { throw 'Pass -PdsBin with the PDS 2022.2-SP6.4 bin directory.' }
    $env:J5_PDS_BIN=(Resolve-Path -LiteralPath $selectedPds).Path
    $env:PYTHONPATH=Join-Path $PSScriptRoot '.runtime\site-packages'
}
