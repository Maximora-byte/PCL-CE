$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$testRoot = $PSScriptRoot
$sdk = if ($env:PCL_TEST_DOTNET) { $env:PCL_TEST_DOTNET } else { (Get-Command dotnet -ErrorAction Stop).Source }
$fixtures = Join-Path $testRoot 'fixtures'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$inputs = [ordered]@{
    'manifest.json' = 'https://launchermeta.mojang.com/mc/game/version_manifest.json'
    'cleanroom.json' = 'https://api.github.com/repos/CleanroomMC/Cleanroom/releases'
    'legacyfabric.json' = 'https://meta.legacyfabric.net/v2/versions'
    'legacyapi.json' = 'https://api.modrinth.com/v2/project/legacy-fabric-api/version?include_changelog=false'
    'legacyapi-project.json' = 'https://api.modrinth.com/v2/project/legacy-fabric-api'
    'legacyapi-deps.json' = 'https://api.modrinth.com/v2/projects?ids=%5B%22EHGtwpJv%22%5D'
}
foreach ($entry in $inputs.GetEnumerator()) {
    $target = Join-Path $fixtures $entry.Key
    if (!(Test-Path -LiteralPath $target)) {
        Invoke-WebRequest -Uri $entry.Value -Proxy ($env:https_proxy -replace '^socks5h:', 'socks5:') -OutFile $target -TimeoutSec 30
    }
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $fixtures 'manifest.json') | ConvertFrom-Json
foreach ($version in @('1.12.2', '1.8.9')) {
    $entry = $manifest.versions | Where-Object id -eq $version
    $target = Join-Path $fixtures "$version.json"
    Invoke-WebRequest -Uri $entry.url -Proxy ($env:https_proxy -replace '^socks5h:', 'socks5:') -OutFile $target -TimeoutSec 30
}
$inputs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtures 'sources.json') -Encoding utf8NoBOM
Get-ChildItem -LiteralPath $fixtures -Filter '*.json' | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'fixture-hashes.json') -Encoding utf8NoBOM
$baseSrc = Join-Path $testRoot 'base-source'
if (!(Test-Path -LiteralPath $baseSrc)) {
    New-Item -ItemType Directory -Path $baseSrc | Out-Null
    & git -C $repo archive --format=tar -o (Join-Path $testRoot 'base.tar') 8f0beaf9315597fdd4cf6171d7e1074e10171be9
    if ($LASTEXITCODE) { throw 'git archive failed' }
    & tar -xf (Join-Path $testRoot 'base.tar') -C $baseSrc
    if ($LASTEXITCODE) { throw 'tar extraction failed' }
}
foreach ($variant in @('patched','baseline')) {
    $run = Join-Path $testRoot $variant
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    if ($variant -eq 'patched') {
        New-Item -ItemType Directory -Path (Join-Path $run 'app') -Force | Out-Null
        Copy-Item -Path (Join-Path $repo 'Plain Craft Launcher 2\bin\Release\net10.0-windows\*') -Destination (Join-Path $run 'app') -Recurse -Force
    }
    $fixtureDest = Join-Path $run 'fixtures'
    New-Item -ItemType Directory -Path $fixtureDest -Force | Out-Null
    Copy-Item -Path (Join-Path $fixtures '*.json') -Destination $fixtureDest -Force
    'fail' | Set-Content -LiteralPath (Join-Path $run 'mode.txt') -Encoding utf8NoBOM
    $mc = Join-Path $run 'app\.minecraft'
    foreach ($version in @('1.12.2','1.8.9')) {
        $instance = Join-Path $mc "versions\$version"
        New-Item -ItemType Directory -Path $instance -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtures "$version.json") -Destination (Join-Path $instance "$version.json") -Force
        $metadataPath = Join-Path $instance "$version.json"
        $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json -AsHashtable
        $metadata['clientVersion'] = $version
        $metadata | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $metadataPath -Encoding utf8NoBOM
    }
}
foreach ($proxyName in @('http_proxy','https_proxy','all_proxy','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
    $proxyValue = [Environment]::GetEnvironmentVariable($proxyName)
    if ($proxyValue) { [Environment]::SetEnvironmentVariable($proxyName, ($proxyValue -replace '^socks5h:', 'socks5:')) }
}
& $sdk build (Join-Path $testRoot 'UiHook.csproj') -c Release --nologo *> (Join-Path $testRoot 'hook-build.log')
if ($LASTEXITCODE) { Get-Content -LiteralPath (Join-Path $testRoot 'hook-build.log') -Tail 20; throw 'Hook build failed' }
& $sdk build (Join-Path $baseSrc 'Plain Craft Launcher 2\Plain Craft Launcher 2.csproj') -c Release -p:Platform=x64 -o (Join-Path $testRoot 'baseline\app') --nologo *> (Join-Path $testRoot 'baseline-build.log')
if ($LASTEXITCODE) { Get-Content -LiteralPath (Join-Path $testRoot 'baseline-build.log') -Tail 20; throw 'Baseline build failed' }
Get-Content -LiteralPath (Join-Path $testRoot 'baseline-build.log') -Tail 4
Write-Output 'Prepared baseline and patched full-launcher UI sessions.'
