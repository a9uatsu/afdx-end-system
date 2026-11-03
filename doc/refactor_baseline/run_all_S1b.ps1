# =============================================================================
# run_all.ps1 - AFDX project regression (Icarus Verilog + Python reference checks)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1 -IverilogRoot "D:\path\to\iverilog"
#
# This script only runs simulations; it does not modify any design file.
# Each case prints "RESULT: PASS/FAIL"; a summary is printed at the end.
# The same testbenches can be run with eLinx built-in simulator or ModelSim
# if Icarus Verilog is not installed.
# =============================================================================
param(
    [string]$IverilogRoot = "D:\FPGA\afdx\tools\iverilog"
)

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$rtl   = Join-Path $root "test.srcs\sources_1\afdx"
$sim   = Join-Path $root "test.srcs\sim_1\afdx"
$work  = Join-Path $root "sim\work"
$vec   = Join-Path $root "sim\vectors"
$ivenv = Join-Path $IverilogRoot "bin\iverilog.exe"
$vvp   = Join-Path $IverilogRoot "bin\vvp.exe"

if (-not (Test-Path $ivenv)) {
    Write-Host "[ERROR] iverilog not found at $ivenv"
    Write-Host "        use -IverilogRoot to point to your Icarus Verilog installation"
    exit 2
}

New-Item -ItemType Directory -Force -Path $work, $vec | Out-Null
$rtlFiles = Get-ChildItem "$rtl\*.v" | ForEach-Object { $_.FullName }
$vecF = $vec -replace '\\','/'
$workF = $work -replace '\\','/'

function Invoke-HdlCase {
    param([string]$Name, [string]$Tb, [string[]]$Plusargs)
    Write-Host ""
    Write-Host "=== case: $Name ===" -ForegroundColor Cyan
    Push-Location $work
    & $ivenv -g2005 -I $rtl -o "$Name.out" @rtlFiles (Join-Path $sim $Tb) 2>&1 |
        Where-Object { $_ -match "error|Error" } | Select-Object -First 5 |
        ForEach-Object { Write-Host $_ }
    & $vvp "$Name.out" @Plusargs 2>&1 |
        Select-String -Pattern "RESULT|FAIL|WARN|TX|RX|frames|errors|===" |
        ForEach-Object { Write-Host $_.Line }
    Pop-Location
}

Write-Host "=============================================="
Write-Host " AFDX regression (Icarus Verilog)"
Write-Host " tool root: $IverilogRoot"
Write-Host "=============================================="

# ---------- 0. static check: multiple drivers -------------------------------
Write-Host ""
Write-Host "=== case: static (multiple-driver check) ===" -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot "check_multidriver.py") $rtl |
    Select-String -Pattern "RESULT|MULTIDRIVER|===" | ForEach-Object { Write-Host $_.Line }

# ---------- 1. library units: CRC-32 / checksum -----------------------------
& python (Join-Path $PSScriptRoot "gen_vectors.py") | Out-Null
Invoke-HdlCase -Name "lib" -Tb "tb_afdx_lib.v" -Plusargs @("+VEC=$vecF/lib_vectors.txt")

# ---------- 2. transmit path ------------------------------------------------
Invoke-HdlCase -Name "tx" -Tb "tb_afdx_tx.v" `
    -Plusargs @("+OUT=$workF/buslog.txt", "+NFRAME=60")
Write-Host ""
Write-Host "=== case: tx_frame_check (Python independent check) ===" -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot "check_frames.py") (Join-Path $work "buslog.txt") |
    Select-String -Pattern "RESULT|FAIL|VLID|===|errors" | ForEach-Object { Write-Host $_.Line }

# ---------- 3. receive path -------------------------------------------------
& python (Join-Path $PSScriptRoot "gen_rx_frames.py") | Out-Null
Invoke-HdlCase -Name "rx" -Tb "tb_afdx_rx.v" `
    -Plusargs @("+FRAMES=$vecF/rx_frames.txt", "+OUT=$workF/rx_deliv.txt")
Write-Host ""
Write-Host "=== case: rx_check (Python independent check) ===" -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot "check_rx.py") `
    (Join-Path $work "rx_deliv.txt") (Join-Path $vec "rx_expect.txt") |
    Select-String -Pattern "RESULT|FAIL|PASS|===|counters|delivered" | ForEach-Object { Write-Host $_.Line }

# ---------- 4. system level -------------------------------------------------
Invoke-HdlCase -Name "top" -Tb "tb_afdx_top.v" -Plusargs @()

# ---------- 5. SNMP agent ---------------------------------------------------
& python (Join-Path $PSScriptRoot "gen_snmp_vectors.py") | Out-Null
Invoke-HdlCase -Name "snmp" -Tb "tb_afdx_snmp.v" `
    -Plusargs @("+VEC=$vecF/snmp_vectors.txt", "+OUT=$workF/snmp_resp.txt")
Write-Host ""
Write-Host "=== case: snmp_check (Python independent check) ===" -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot "check_snmp.py") `
    (Join-Path $work "snmp_resp.txt") (Join-Path $vec "snmp_expect.txt") |
    Select-String -Pattern "RESULT|FAIL|PASS|===|counters" | ForEach-Object { Write-Host $_.Line }

# ---------- 6. SNMP over Ethernet/IP/UDP ------------------------------------
& python (Join-Path $PSScriptRoot "gen_snmp_frames.py") | Out-Null
Invoke-HdlCase -Name "snmpnet" -Tb "tb_afdx_snmp_net.v" `
    -Plusargs @("+FRAMES=$vecF/snmp_frames.txt", "+OUT=$workF/snmp_net_resp.txt")
Write-Host ""
Write-Host "=== case: snmp_net_check (Python independent check) ===" -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot "check_snmp.py") `
    (Join-Path $work "snmp_net_resp.txt") (Join-Path $vec "snmp_net_expect.txt") |
    Select-String -Pattern "RESULT|FAIL|PASS|===|counters" | ForEach-Object { Write-Host $_.Line }

# ---------- 7. RTC time sync ------------------------------------------------
Invoke-HdlCase -Name "rtc" -Tb "tb_afdx_rtc.v" -Plusargs @()

# ---------- 8. ARINC 615A data loader ---------------------------------------
& python (Join-Path $PSScriptRoot "gen_load_vectors.py") | Out-Null
Invoke-HdlCase -Name "load" -Tb "tb_afdx_load.v" `
    -Plusargs @("+VEC=$vecF/load_vectors.txt", "+OUT=$workF/load_resp.txt")

# ---------- 9. performance ---------------------------------------------------
Invoke-HdlCase -Name "perf" -Tb "tb_afdx_perf.v" -Plusargs @()

Write-Host ""
Write-Host "=============================================="
Write-Host " Regression finished - check each RESULT line"
Write-Host " intermediate files: $work"
Write-Host "=============================================="
