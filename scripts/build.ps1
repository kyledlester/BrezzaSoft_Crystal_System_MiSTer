# Command-line build of the Crystal core (same result as Processing > Start Compilation in the Quartus GUI).
# The post-flow script copies the RBF to Releases/Crystal_YYYYMMDD.rbf. Prints a one-line summary at the end.
param([string]$QuartusRoot = 'C:\intelFPGA_lite\17.0\quartus')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    New-Item -ItemType Directory -Force build | Out-Null
    & (Join-Path $QuartusRoot 'bin64\quartus_sh.exe') --flow compile Crystal *> build\quartus_flow.log
    $rc = $LASTEXITCODE
    # Quartus rewrites Crystal.qsf with the expanded contents of the sourced Tcl files; keep the tracked copy clean
    if (Test-Path .git) { & git checkout -- Crystal.qsf 2>$null }
    & python scripts\quartus_summary.py
    if ($rc -ne 0) { throw 'Quartus build failed; see build\quartus_flow.log and output_files reports.' }
} finally { Pop-Location }
