$ErrorActionPreference = 'Stop'
$base = Join-Path $PSScriptRoot 'runs'
if (-not (Test-Path -LiteralPath $base)) { Write-Output 'No run directory exists.'; exit 0 }
$active = @(Get-ChildItem -LiteralPath $base -Directory | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName 'WATCHDOG_READY')) -and
    -not (Test-Path -LiteralPath (Join-Path $_.FullName 'wrapper_result.json'))
})
foreach ($run in $active) {
    Set-Content -LiteralPath (Join-Path $run.FullName 'STOP') -Value 'Operator requested STOP; wait for verified SRAM cleanup.' -Encoding UTF8
    Write-Output "STOP requested: $($run.FullName)"
}
if ($active.Count -eq 0) { Write-Output 'No active session found.' }
