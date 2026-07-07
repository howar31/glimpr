# Record-worker black-box end-to-end check (TC-W3).
#
# Spawns `glimpr.exe --record-worker` for a short self-terminating display
# recording and asserts the argv/stdout contract + a real output file. This
# exercises the recorder_client <-> record_worker IPC and the WGC -> Media
# Foundation pipeline that unit tests cannot reach.
#
# MUST run in an INTERACTIVE DESKTOP session (Windows.Graphics.Capture cannot
# create a swapchain in SSH session 0). It briefly records the primary display
# (~2 s). Run it when the machine is free.
#
#   cd D:\Projects\Glimpr\glimpr
#   powershell -ExecutionPolicy Bypass -File windows\test\record_worker_e2e.ps1
#
# Optional: -Exe <path> to pick a specific build; -Gif to record a GIF instead
# of mp4. Exit code 0 = PASS.

param(
  [string]$Exe = "",
  [switch]$Gif
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # ...\glimpr

if (-not $Exe) {
  $cands = @(
    "$root\build\windows\x64\runner\Release\glimpr.exe",
    "$root\build\windows\x64\runner\Debug\glimpr.exe"
  )
  $Exe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Exe -or -not (Test-Path $Exe)) {
  Write-Host "FAIL: glimpr.exe not found (build the app first, or pass -Exe)."
  exit 1
}

$ext = if ($Gif) { "gif" } else { "mp4" }
$outPath = Join-Path $env:TEMP ("glimpr_rw_e2e_{0}.{1}" -f $PID, $ext)
if (Test-Path $outPath) { Remove-Item $outPath -Force }
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($outPath))

$argList = @(
  "--record-worker", "--mode=display", "--output-b64=$b64",
  "--fps=30", "--maxdur=2"
)
if ($Gif) { $argList += "--gif=1"; $argList += "--giffps=15" }

Write-Host "exe    : $Exe"
Write-Host "output : $outPath"
Write-Host "args   : $($argList -join ' ')"
Write-Host "--- launching worker ---"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardInput = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$lines = New-Object System.Collections.ArrayList
$onData = {
  if ($EventArgs.Data) {
    [void]$Event.MessageData.Add($EventArgs.Data)
    Write-Host "  worker> $($EventArgs.Data)"
  }
}
$sub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived `
  -Action $onData -MessageData $lines
[void]$proc.Start()
$proc.BeginOutputReadLine()

# The worker self-stops at --maxdur; give it headroom to finalize the file.
# Fallback: nudge STOP over stdin if it is still up after 8 s.
$deadline = (Get-Date).AddSeconds(20)
$nudged = $false
while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  if (-not $nudged -and $proc.StartTime.AddSeconds(8) -lt (Get-Date)) {
    try { $proc.StandardInput.WriteLine("STOP") } catch {}
    $nudged = $true
  }
}
if (-not $proc.HasExited) {
  try { $proc.StandardInput.WriteLine("ABORT") } catch {}
  Start-Sleep -Seconds 2
  if (-not $proc.HasExited) { $proc.Kill() }
}
$proc.WaitForExit()
Start-Sleep -Milliseconds 200  # let the last async lines flush
Unregister-Event -SourceIdentifier $sub.Name
$exit = $proc.ExitCode

Write-Host "--- worker exited: $exit ---"

# ---- assertions ----
$fail = 0
function Check($cond, $msg) {
  if ($cond) { Write-Host "PASS: $msg" }
  else { Write-Host "FAIL: $msg"; $script:fail++ }
}

$joined = [string]::Join("`n", $lines.ToArray())
Check ($lines | Where-Object { $_ -like "STARTED *" }) "STARTED emitted"
Check ($lines | Where-Object { $_ -like "FINISHED *" }) "FINISHED emitted"
Check ($exit -eq 0) "exit code 0 (got $exit)"
$exists = Test-Path $outPath
Check $exists "output file exists"
if ($exists) {
  $size = (Get-Item $outPath).Length
  Check ($size -gt 1000) "output file non-trivial ($size bytes)"
}
if ($joined -match "FAILED") { Write-Host "NOTE: a FAILED line appeared"; $fail++ }

# The FINISHED path the worker reports should match what we asked for.
$finLine = $lines | Where-Object { $_ -like "FINISHED *" } | Select-Object -First 1
if ($finLine) {
  $finPath = $finLine.Substring("FINISHED ".Length)
  Check ($finPath -eq $outPath) "FINISHED path matches the requested output"
}

if (Test-Path $outPath) { Remove-Item $outPath -Force }

Write-Host "-----------------------------------------"
if ($fail -eq 0) { Write-Host "record-worker E2E: PASS"; exit 0 }
else { Write-Host "record-worker E2E: FAIL ($fail failed)"; exit 1 }
