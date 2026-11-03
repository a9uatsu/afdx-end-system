param(
    [string]$ModelSimBin = "C:\modeltech64_10.7\win64",
    [string]$RunDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$rtl = Join-Path $root "test.srcs\sources_1\afdx"
$sim = Join-Path $root "test.srcs\sim_1\afdx"
$vec = Join-Path $root "sim\vectors"
if (-not $RunDir) { $RunDir = Join-Path $root "sim\modelsim" }
$RunDir = [IO.Path]::GetFullPath($RunDir)
$vlog = Join-Path $ModelSimBin "vlog.exe"
$vsim = Join-Path $ModelSimBin "vsim.exe"

foreach ($tool in @($vlog, $vsim)) {
    if (-not (Test-Path $tool)) { throw "ModelSim executable not found: $tool" }
}
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$env:PATH = "$ModelSimBin;$env:PATH"
$env:PYTHONIOENCODING = "utf-8"

foreach ($generator in @("gen_vectors.py", "gen_rx_frames.py", "gen_snmp_vectors.py", "gen_snmp_frames.py", "gen_load_vectors.py")) {
    & python (Join-Path $PSScriptRoot $generator)
    if ($LASTEXITCODE -ne 0) { throw "Vector generation failed: $generator" }
}

Push-Location $RunDir
try {
    if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
    & (Join-Path $ModelSimBin "vlib.exe") work
    if ($LASTEXITCODE -ne 0) { throw "vlib failed" }

    $sources = @(Get-ChildItem (Join-Path $rtl "*.v") | ForEach-Object { $_.FullName }) +
               @(Get-ChildItem (Join-Path $sim "*.v") | ForEach-Object { $_.FullName })
    & $vlog -work work -vlog01compat "+incdir+$($rtl.Replace('\','/'))" @sources 2>&1 | Tee-Object compile.log
    if ($LASTEXITCODE -ne 0) { throw "ModelSim compilation failed" }

    $cases = @(
        @{ Name="lib"; Top="tb_afdx_lib"; Args=@("+VEC=$(Join-Path $vec 'lib_vectors.txt')"); Marker="RESULT: PASS" },
        @{ Name="tx"; Top="tb_afdx_tx"; Args=@("+OUT=$(Join-Path $RunDir 'tx_buslog.txt')", "+NFRAME=60"); Marker="RESULT: BUSLOG_DONE" },
        @{ Name="tx_capacity"; Top="tb_afdx_tx_capacity"; Args=@("+OUT=$(Join-Path $RunDir 'tx_capacity_buslog.txt')"); Marker="RESULT: TX_CAPACITY_DONE" },
        @{ Name="tx_full"; Top="tb_afdx_tx_full"; Args=@("+OUT=$(Join-Path $RunDir 'tx_full_buslog.txt')"); Marker="RESULT: TX_CAPACITY_DONE" },
        @{ Name="soak"; Top="tb_afdx_soak"; Args=@("+OUT=$(Join-Path $RunDir 'tx_soak_buslog.txt')", "+NFRAME=12000"); Marker="RESULT: SOAK_LOG_DONE" },
        @{ Name="rx"; Top="tb_afdx_rx"; Args=@("+FRAMES=$(Join-Path $vec 'rx_frames.txt')", "+OUT=$(Join-Path $RunDir 'rx_deliv.txt')"); Marker="RESULT: RXLOG_DONE" },
        @{ Name="rm_capacity"; Top="tb_afdx_rm_capacity"; Args=@(); Marker="RESULT: PASS" },
        @{ Name="rm_full"; Top="tb_afdx_rm_full"; Args=@(); Marker="RESULT: PASS" },
        @{ Name="top"; Top="tb_afdx_top"; Args=@(); Marker="RESULT: PASS" },
        @{ Name="snmp"; Top="tb_afdx_snmp"; Args=@("+VEC=$(Join-Path $vec 'snmp_vectors.txt')", "+OUT=$(Join-Path $RunDir 'snmp_resp.txt')"); Marker="RESULT: SNMP_LOG_DONE" },
        @{ Name="snmp_net"; Top="tb_afdx_snmp_net"; Args=@("+FRAMES=$(Join-Path $vec 'snmp_frames.txt')", "+OUT=$(Join-Path $RunDir 'snmp_net_resp.txt')"); Marker="RESULT: SNMP_NET_LOG_DONE" },
        @{ Name="rtc"; Top="tb_afdx_rtc"; Args=@(); Marker="RESULT: PASS" },
        @{ Name="load"; Top="tb_afdx_load"; Args=@("+VEC=$(Join-Path $vec 'load_vectors.txt')", "+OUT=$(Join-Path $RunDir 'load_resp.txt')"); Marker="RESULT: LOAD_LOG_DONE" },
        @{ Name="perf"; Top="tb_afdx_perf"; Args=@(); Marker="RESULT: PASS (>=100 Mbps)" }
    )

    $results = @()
    foreach ($case in $cases) {
        $log = "$($case.Name).log"
        $args = @("-c", "-lib", "work", $case.Top) + $case.Args + @("-do", "run -all; quit -f", "-l", $log)
        & $vsim @args
        $exitCode = $LASTEXITCODE
        $logText = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
        $ok = ($exitCode -eq 0) -and ($logText.Contains($case.Marker)) -and
              (-not $logText.Contains("[FAIL]")) -and (-not $logText.Contains("RESULT: TIMEOUT"))
        $results += [pscustomobject]@{ Case=$case.Name; Pass=$ok; Exit=$exitCode }
        Write-Host ("{0}: {1}" -f $case.Name, $(if ($ok) { "PASS" } else { "FAIL" }))
        if (-not $ok) { Write-Host "  See $log" }
    }

    $checks = @(
        @{ Name="tx_frame_check"; Script="check_frames.py"; Args=@("tx_buslog.txt"); Marker="RESULT: PASS" },
        @{ Name="tx_capacity_check"; Script="check_tx_capacity.py"; Args=@("tx_capacity_buslog.txt"); Marker="RESULT: PASS (32 VL)" },
        @{ Name="tx_full_check"; Script="check_tx_full.py"; Args=@("tx_full_buslog.txt"); Marker="RESULT: PASS (128 VL)" },
        @{ Name="soak_check"; Script="check_soak.py"; Args=@((Join-Path $RunDir "tx_soak_buslog.txt"), (Join-Path $RunDir "soak_summary.txt"), "20"); Marker="RESULT: PASS (128 VL SOAK)" },
        @{ Name="rx_check"; Script="check_rx.py"; Args=@("rx_deliv.txt", (Join-Path $vec "rx_expect.txt")); Marker="RESULT: PASS" },
        @{ Name="snmp_check"; Script="check_snmp.py"; Args=@("snmp_resp.txt", (Join-Path $vec "snmp_expect.txt")); Marker="RESULT: PASS" },
        @{ Name="snmp_net_check"; Script="check_snmp.py"; Args=@("snmp_net_resp.txt", (Join-Path $vec "snmp_net_expect.txt")); Marker="RESULT: PASS" }
    )
    foreach ($check in $checks) {
        $checkArgs = @($check.Args | ForEach-Object {
            if ($_ -is [string] -and ($_ -match '^[A-Za-z]:\\' -or $_.StartsWith('\\'))) { $_ }
            elseif ($_ -is [string] -and $_ -match '^\d+$') { $_ }
            else { Join-Path $RunDir $_ }
        })
        $checkLog = "$($check.Name).log"
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & python (Join-Path $PSScriptRoot $check.Script) @checkArgs 2>&1 | Tee-Object $checkLog
        $ErrorActionPreference = $oldErrorAction
        $exitCode = $LASTEXITCODE
        $logText = Get-Content $checkLog -Raw
        $ok = ($exitCode -eq 0) -and $logText.Contains($check.Marker)
        $results += [pscustomobject]@{ Case=$check.Name; Pass=$ok; Exit=$exitCode }
        Write-Host ("{0}: {1}" -f $check.Name, $(if ($ok) { "PASS" } else { "FAIL" }))
    }

    $results | Format-Table -AutoSize
    if (@($results | Where-Object { -not $_.Pass }).Count -gt 0) { exit 1 }
    Write-Host "ModelSim regression: PASS ($($results.Count) checks)"
} finally {
    Pop-Location
}
