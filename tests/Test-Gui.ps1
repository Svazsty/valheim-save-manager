[CmdletBinding()]
param([switch]$Launcher)
# Native WPF integration test, exclusively on generated fixtures.
# The test copy mocks only the worker's game-process query. Production is unchanged.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot
$reportProject=$project
if ($Launcher) {
    $clone=Join-Path $project ('test-results\launcher-zażółć gęślą-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($clone) | Out-Null
    foreach ($name in @('engine','ui','assets','config','tests','ValheimSaveManager.ps1','Start-ValheimSaveManager.vbs','Uruchom-Valheim-Save-Manager.cmd')) {
        Copy-Item -LiteralPath (Join-Path $project $name) -Destination $clone -Recurse -Force
    }
    $project=$clone
}
$sandbox=Join-Path $project ('test-results\gui-integration-' + [guid]::NewGuid().ToString('N'))
$env:USERPROFILE=Join-Path $sandbox 'User'
$env:LOCALAPPDATA=Join-Path $sandbox 'App Data'
$app=Join-Path $env:LOCALAPPDATA 'ValheimSaveManager'
$world=Join-Path $env:USERPROFILE 'AppData\LocalLow\IronGate\Valheim\worlds_local\NewWorld'
$drive=Join-Path $sandbox 'Mój dysk\VALHEIM'
foreach ($folder in @($app,$world,$drive)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
foreach ($ext in @('ok','db2','fwl2','chunks')) {
    $path=Join-Path $world ("_main.1.$ext")
    [IO.File]::WriteAllText($path,'synthetic-gui-save')
    [IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddMinutes(-10))
}
@{driveFolder=$drive;worldName='NewWorld'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'config.json') -Encoding UTF8
$tempScript=Join-Path $project ('.vsm-gui-test-' + [guid]::NewGuid().ToString('N') + '.ps1')
if ($Launcher) { $tempScript=Join-Path $project 'ValheimSaveManager.ps1' }
$source=Get-Content -LiteralPath (Join-Path $project 'ValheimSaveManager.ps1') -Raw -Encoding UTF8
$source=$source.Replace('. $Engine', ". `$Engine`n            function Get-Process { param(`$Name,`$ErrorAction) return @() }")
$source=$source.Replace('[void]$script:Window.ShowDialog()', ". (Join-Path `$PSScriptRoot 'tests\GuiScenario.ps1')`n    [void]`$script:Window.ShowDialog()")
[IO.File]::WriteAllText($tempScript,$source,(New-Object Text.UTF8Encoding($true)))
if ($Launcher) {
    Start-Process -FilePath (Join-Path $project 'Uruchom-Valheim-Save-Manager.cmd') -WindowStyle Hidden
    $deadline=[DateTime]::UtcNow.AddSeconds(45)
    $resultFile=Join-Path $project 'test-results\gui.json'
    while (-not [IO.File]::Exists($resultFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not [IO.File]::Exists($resultFile)) { throw 'Launcher test timed out.' }
    Copy-Item -LiteralPath $resultFile -Destination (Join-Path $reportProject 'test-results\launcher.json')
} else {
    try { & $tempScript -AppDataDir $app }
    finally { if ([IO.File]::Exists($tempScript)) { [IO.File]::Delete($tempScript) } }
}
$report=Get-Content -LiteralPath (Join-Path $project 'test-results\gui.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output ($report | ConvertTo-Json -Depth 6)
if (-not $report.passed) { exit 1 }
