param([string]$PythonExe='python',[string]$PdsBin='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'environment.ps1')
$baseExe=Get-BundlePython $PythonExe
Set-BundleEnvironment $PdsBin
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\portable_package.py') --check-path
if ($LASTEXITCODE -ne 0) { throw 'Extract to a short ASCII path without spaces, for example E:\J5_CAMERA_8S.' }
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\verify_package.py')
if ($LASTEXITCODE -ne 0) { throw 'Package integrity failed before setup.' }
& $baseExe -c "import sys,struct; assert sys.version_info >= (3,10) and struct.calcsize('P')==8"
if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python.' }
$dependencyProbe=@'
import sys
try:
    import psutil,serial
    ok=psutil.__version__=='7.2.2' and serial.VERSION=='3.5'
except ImportError:
    ok=False
sys.exit(0 if ok else 1)
'@
& $baseExe -c $dependencyProbe
if ($LASTEXITCODE -ne 0) {
    & $baseExe -m pip install --no-index --find-links (Join-Path $PSScriptRoot 'vendor\wheels') --target (Join-Path $PSScriptRoot '.runtime\site-packages') --upgrade --no-compile -r (Join-Path $PSScriptRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Bundled dependency installation failed.' }
}
& $baseExe -B -X utf8 (Join-Path $PSScriptRoot 'tools\portable_package.py') --bind
if ($LASTEXITCODE -ne 0) { throw 'Local qualification binding failed.' }
Write-Output 'SETUP_PASS: local runtime ready; no board operation performed.'
