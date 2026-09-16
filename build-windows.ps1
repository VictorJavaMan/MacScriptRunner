$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = 'C:\Users\Victor\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$Dist = Join-Path $ProjectDir 'dist-windows'
$Vendor = Join-Path $ProjectDir 'windows\vendor'

if (-not (Test-Path $Python)) { throw "Python runtime not found: $Python" }
if (-not (Test-Path (Join-Path $Vendor 'PyInstaller'))) {
  & $Python -m pip install --disable-pip-version-check --target $Vendor pyinstaller
  if ($LASTEXITCODE -ne 0) { throw 'PyInstaller installation failed' }
}
$env:PYTHONPATH = $Vendor
$env:TCL_LIBRARY = Join-Path (Split-Path $Python -Parent) 'tcl\tcl8.6'
$env:TK_LIBRARY = Join-Path (Split-Path $Python -Parent) 'tcl\tk8.6'
$PythonRoot = Split-Path $Python -Parent

$IconPng = Join-Path $ProjectDir 'Assets\AppIcon.png'
$IconIco = Join-Path $ProjectDir 'windows\AppIcon.ico'
& $Python -c "from PIL import Image; im=Image.open(r'$IconPng').convert('RGBA'); im.save(r'$IconIco', sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"

& $Python -m PyInstaller --noconfirm --clean --onefile --windowed `
  --name MacScriptRunner-Windows --icon $IconIco `
  --additional-hooks-dir (Join-Path $ProjectDir 'windows\hooks') `
  --hidden-import tkinter --hidden-import tkinter.ttk --hidden-import tkinter.filedialog `
  --hidden-import tkinter.messagebox --hidden-import tkinter.simpledialog `
  --add-binary "$(Join-Path $PythonRoot 'DLLs\_tkinter.pyd');." `
  --add-binary "$(Join-Path $PythonRoot 'DLLs\tcl86t.dll');." `
  --add-binary "$(Join-Path $PythonRoot 'DLLs\tk86t.dll');." `
  --add-data "$(Join-Path $PythonRoot 'tcl\tcl8.6');_tcl_data" `
  --add-data "$(Join-Path $PythonRoot 'tcl\tk8.6');_tk_data" `
  --add-data "$IconIco;." `
  --distpath $Dist --workpath (Join-Path $ProjectDir 'build-windows') `
  --specpath (Join-Path $ProjectDir 'windows') `
  (Join-Path $ProjectDir 'windows\mac_script_runner.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }

Write-Host "Built: $(Join-Path $Dist 'MacScriptRunner-Windows.exe')"
