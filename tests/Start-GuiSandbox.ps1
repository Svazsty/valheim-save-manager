[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $project ('test-results\gui-sandbox-' + [guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = Join-Path $sandbox 'App Data'
$env:USERPROFILE = Join-Path $sandbox 'Test User'
$drive = Join-Path $sandbox 'Mój dysk\VALHEIM'
$world = Join-Path $env:USERPROFILE 'AppData\LocalLow\IronGate\Valheim\worlds_local\NewWorld'
[IO.Directory]::CreateDirectory($drive) | Out-Null
[IO.Directory]::CreateDirectory($world) | Out-Null
foreach ($ext in @('ok','db2','fwl2','chunks')) { [IO.File]::WriteAllText((Join-Path $world ("_main.1.$ext")), 'synthetic-gui-fixture') }
$configDir = Join-Path $env:LOCALAPPDATA 'ValheimSaveManager'
[IO.Directory]::CreateDirectory($configDir) | Out-Null
@{driveFolder=$drive;worldName='NewWorld'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding UTF8
[IO.Directory]::CreateDirectory((Join-Path $project 'test-results')) | Out-Null
@{sandbox=$sandbox;appData=$configDir;world=$world;drive=$drive;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $project 'test-results\gui-session.json') -Encoding UTF8
# Exercise the real CMD -> WScript -> hidden PowerShell launcher, with isolated inherited paths.
Start-Process -FilePath (Join-Path $project 'Uruchom-Valheim-Save-Manager.cmd') -WindowStyle Hidden
