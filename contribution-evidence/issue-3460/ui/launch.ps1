param([ValidateSet('baseline','patched')][string]$Variant = 'baseline')
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot $Variant
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $root 'app\Plain Craft Launcher 2.exe'
$psi.WorkingDirectory = Join-Path $root 'app'
$psi.UseShellExecute = $false
$psi.Environment['DOTNET_ROOT'] = if ($env:PCL_TEST_DOTNET) { Split-Path -Parent $env:PCL_TEST_DOTNET } elseif ($env:DOTNET_ROOT) { $env:DOTNET_ROOT } else { Split-Path -Parent (Get-Command dotnet -ErrorAction Stop).Source }
$psi.Environment['DOTNET_ROOT_X64'] = $psi.Environment['DOTNET_ROOT']
$psi.Environment['DOTNET_STARTUP_HOOKS'] = Join-Path $PSScriptRoot 'bin\Release\net10.0-windows\UiHook.dll'
$psi.Environment['PCL_UI_TEST_ROOT'] = $root
$psi.Environment['APPDATA'] = Join-Path $root 'roaming'
$psi.Environment['LOCALAPPDATA'] = Join-Path $root 'localappdata'
$psi.Environment['TEMP'] = Join-Path $root 'temp'
$psi.Environment['TMP'] = $psi.Environment['TEMP']
foreach ($key in @('APPDATA','LOCALAPPDATA','TEMP')) { New-Item -ItemType Directory -Path $psi.Environment[$key] -Force | Out-Null }
foreach ($key in @('http_proxy','https_proxy','all_proxy','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
    if ($psi.Environment[$key]) { $psi.Environment[$key] = $psi.Environment[$key] -replace '^socks5h:', 'socks5:' }
}
$process = [Diagnostics.Process]::Start($psi)
$process.Id | Set-Content -LiteralPath (Join-Path $root 'process-id.txt')
Write-Output "Launched $Variant process $($process.Id)."
