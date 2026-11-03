param(
    [string]$ModelSimBin = "C:\modeltech64_10.7\win64"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$rtl = Join-Path $root "test.srcs\sources_1\afdx"
$tb = Join-Path $root "test.srcs\sim_1\afdx\tb_afdx_lib.v"
$vec = Join-Path $root "sim\vectors\lib_vectors.txt"
$runDir = Join-Path $root ("sim\modelsim_lib_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"))
$vlog = Join-Path $ModelSimBin "vlog.exe"
$vsim = Join-Path $ModelSimBin "vsim.exe"
$gui = Join-Path $ModelSimBin "modelsim.exe"

foreach ($tool in @($vlog, $vsim, $gui, (Join-Path $ModelSimBin "vlib.exe"))) {
    if (-not (Test-Path $tool)) { throw "ModelSim executable not found: $tool" }
}
if (-not (Test-Path $vec)) {
    & python (Join-Path $PSScriptRoot "gen_vectors.py")
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate library vectors" }
}

New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Push-Location $runDir
try {
    if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
    & (Join-Path $ModelSimBin "vlib.exe") work
    if ($LASTEXITCODE -ne 0) { throw "vlib failed" }
    $inc = "+incdir+$($rtl.Replace('\','/'))"
    & $vlog -work work -vlog01compat $inc `
        (Join-Path $rtl "afdx_crc32.v") `
        (Join-Path $rtl "afdx_checksum16.v") `
        $tb
    if ($LASTEXITCODE -ne 0) { throw "ModelSim compilation failed" }

    $doFile = Join-Path $runDir "run_lib.do"
    $log = Join-Path $runDir "lib_gui.log"
    $doContent = @(
        "transcript file {$log}"
        "vsim -lib work work.tb_afdx_lib +VEC=$($vec.Replace('\','/'))"
        "view wave"
        "add wave -r sim:/tb_afdx_lib/*"
        "configure wave -namecolwidth 260"
        "configure wave -valuecolwidth 120"
        "configure wave -timelineunits ns"
        "run -all"
        "wave zoom full"
    ) -join "`r`n"
    Set-Content -LiteralPath $doFile -Value $doContent -Encoding ASCII
    Start-Process -FilePath $gui -ArgumentList @("-do", $doFile) -WorkingDirectory $runDir
    Write-Host "ModelSim GUI launched. It will compile the selected test, run it, and keep the window open."
} finally {
    Pop-Location
}
