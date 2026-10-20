[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ReportPath) { $ReportPath = Join-Path $PSScriptRoot '..\test-results\engine.json' }
. (Join-Path $PSScriptRoot '..\engine\Sync.ps1')
# The real game may be open. Fixtures must remain testable without touching it.
# Override only the process query in this test process, never in production code.
function Get-Process { param($Name,$ErrorAction) return @() }
$script:TestRoot = Join-Path $env:TEMP ('ValheimManagerTests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Counter = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Action, [string]$Pattern = '.') {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true; if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" } }
    Assert $caught 'Expected operation to fail.'
}
function Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:Results.Add([pscustomobject]@{name=$Name;passed=$true;detail='OK'}); Write-Host "PASS $Name" }
    catch { $script:Results.Add([pscustomobject]@{name=$Name;passed=$false;detail=$_.ToString()}); Write-Host "FAIL $Name : $_" -ForegroundColor Red }
}
function New-Case([string]$World = 'NewWorld') {
    $script:Counter++
    $base = Join-Path $script:TestRoot ("test $script:Counter polskie znaki zażółć")
    $drive = Join-Path $base 'Mój dysk\VALHEIM'
    [IO.Directory]::CreateDirectory($drive) | Out-Null
    return New-SyncContext ([pscustomobject]@{worldName=$World;driveFolder=$drive}) -AppDataDir (Join-Path $base 'App Data') -WorldsRoot (Join-Path $base 'worlds_local')
}
function New-FakeWorld([string]$Folder, [string]$Content = 'fixture') {
    [IO.Directory]::CreateDirectory((Join-Path $Folder 'chunks')) | Out-Null
    foreach ($ext in @('ok','db2','fwl2','chunks')) { [IO.File]::WriteAllText((Join-Path $Folder ("_main.1.$ext")), ($Content + '-' + $ext)) }
    [IO.File]::WriteAllText((Join-Path $Folder 'chunks\001.chunk'), $Content)
    [IO.Directory]::CreateDirectory((Join-Path $Folder 'cacheMinimap')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Folder 'cacheMinimap\map'), 'fixture-cache')
    foreach ($file in Get-ChildItem -LiteralPath $Folder -Recurse -File) { $file.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10) }
}
function Copy-Context($C, [string]$Suffix) {
    return New-SyncContext ([pscustomobject]@{worldName=$C.WorldName;driveFolder=$C.DriveFolder}) -AppDataDir ($C.AppDataDir + $Suffix) -WorldsRoot ($C.WorldsRoot + $Suffix)
}
function Publish($C) { return Invoke-WorldSync $C Upload }
try {
    Test 'default configuration and old drive-only config migration' {
        $c = New-Case
        $defaults = Read-Configuration $c.AppDataDir
        Assert ($defaults.worldName -ceq 'NewWorld') 'Wrong default world'
        Write-JsonAtomic $c.ConfigFile @{driveFolder=$c.DriveFolder}
        $loaded = Read-Configuration $c.AppDataDir
        Assert ($loaded.worldName -ceq 'NewWorld' -and $loaded.driveFolder -ceq $c.DriveFolder) 'Legacy config lost'
        Save-Configuration $c
        Assert ((Read-Configuration $c.AppDataDir).driveFolder -ceq $c.DriveFolder) 'Configuration roundtrip failed'
    }
    Test 'corrupt configuration fails closed' {
        $c=New-Case; [IO.Directory]::CreateDirectory($c.AppDataDir) | Out-Null
        [IO.File]::WriteAllText($c.ConfigFile, '{broken')
        Throws { Read-Configuration $c.AppDataDir } 'konfiguracji'
    }
    Test 'world names and overlapping paths rejected' {
        foreach ($name in @('..','CON','bad/name','a*','a[1]','a.','a ')) { Throws { Assert-WorldName $name } }
        $c=New-Case
        Throws { New-SyncContext ([pscustomobject]@{worldName='NewWorld';driveFolder=$c.WorldsRoot}) -AppDataDir $c.AppDataDir -WorldsRoot $c.WorldsRoot } 'oddzielne'
    }
    Test 'missing local world and cache-only folder blocked' {
        $c=New-Case; Throws { Publish $c } 'Brak kompletnego'
        [IO.Directory]::CreateDirectory((Join-Path $c.LocalWorld 'cacheMinimap')) | Out-Null
        Throws { Publish $c } 'Brak kompletnego'
        Assert (-not (Test-CompleteWorld $c.LocalWorld)) 'Cache passed validation'
    }
    Test 'complete generation required; empty ok marker supported' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        [IO.File]::WriteAllText((Join-Path $c.LocalWorld '_main.1.ok'), '')
        Assert (Test-CompleteWorld $c.LocalWorld) 'Empty marker rejected'
        [IO.File]::Move((Join-Path $c.LocalWorld '_main.1.db2'),(Join-Path $c.LocalWorld '_main.2.db2'))
        Assert (-not (Test-CompleteWorld $c.LocalWorld)) 'Mixed generations accepted'
    }
    Test 'missing Drive blocks both operations' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        [IO.Directory]::Delete($c.DriveFolder)
        Throws { Publish $c } 'niedostepny'
        Throws { Invoke-WorldSync $c Download -Confirmed } 'niedostepny'
    }
    Test 'corrupt ZIP leaves local world and state intact' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        $before=Get-WorldSnapshot $c.LocalWorld
        [IO.File]::WriteAllText((Join-Path $c.DriveFolder 'VALHEIM_NewWorld_999.zip'), 'not zip')
        Throws { Invoke-WorldSync $c Download -Confirmed }
        Assert ((Get-WorldSnapshot $c.LocalWorld).Fingerprint -ceq $before.Fingerprint) 'Local changed'
        Assert (-not [IO.File]::Exists($c.StateFile)) 'State changed'
    }
    Test 'real upload/download, Polish paths, unchanged format and character isolation' {
        $c=New-Case 'Świat Żółwia'; New-FakeWorld $c.LocalWorld
        $characters=Join-Path (Split-Path -Parent $c.WorldsRoot) 'characters_local'
        [IO.Directory]::CreateDirectory($characters) | Out-Null
        [IO.File]::WriteAllText((Join-Path $characters 'hero.fch'), 'do-not-touch')
        $expected=Get-WorldSnapshot $c.LocalWorld
        $upload=Publish $c
        Assert ($upload.Archive -match '^VALHEIM_Świat Żółwia_\d{8}T\d{9}Z_.+\.zip$') 'Archive naming changed'
        Assert ($upload.Message -match 'Poczekaj') 'Missing Drive synchronization caveat'
        $receiver=Copy-Context $c '-receiver'
        Throws { Invoke-WorldSync $receiver Download } 'potwierdzenia'
        $download=Invoke-WorldSync $receiver Download -Confirmed
        Assert ((Get-WorldSnapshot $receiver.LocalWorld).Fingerprint -ceq $expected.Fingerprint) 'Roundtrip content changed'
        Assert ([IO.File]::ReadAllText((Join-Path $characters 'hero.fch')) -ceq 'do-not-touch') 'Character touched'
        Assert ((Get-LastSeenArchive $receiver) -ceq $upload.Archive) 'Receiver state not recorded'
        Assert ((Get-SyncStatus $receiver).History.lastSuccess.Operation -ceq 'Download') 'Success history missing'
    }
    Test 'original v1 archives remain readable by new engine and vice versa' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        $uploaded=Publish $c
        $unpack=Join-Path $c.AppDataDir 'original-format'
        [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $c.DriveFolder $uploaded.Archive),$unpack)
        $manifest=Get-Content -LiteralPath (Join-Path $unpack 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($manifest.version -eq 1 -and $manifest.worldName -ceq 'NewWorld') 'Manifest changed'
        Assert (Test-CompleteWorld (Join-Path $unpack 'world\NewWorld')) 'Original folder layout changed'
        # Repack with the exact original ZipFile API/manifest contract.
        $oldZip=Join-Path $c.DriveFolder 'VALHEIM_NewWorld_999-original.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($unpack,$oldZip,[IO.Compression.CompressionLevel]::Optimal,$false)
        $receiver=Copy-Context $c '-original'
        [void](Invoke-WorldSync $receiver Download -Confirmed)
        Assert (Test-CompleteWorld $receiver.LocalWorld) 'Original archive incompatible'
    }
    Test 'unseen remote branch blocks upload' {
        $c=New-Case; New-FakeWorld $c.LocalWorld; [void](Publish $c)
        $other=Copy-Context $c '-other'; New-FakeWorld $other.LocalWorld 'other'
        Throws { Publish $other } 'niepobrana'
    }
    Test 'older local upload and newer local download blocked' {
        $c=New-Case; New-FakeWorld $c.LocalWorld; [void](Publish $c)
        [IO.File]::WriteAllText((Join-Path $c.LocalWorld '_main.1.db2'),'older-content')
        foreach ($file in Get-ChildItem -LiteralPath $c.LocalWorld -Recurse -File) { $file.LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1) }
        Throws { Publish $c } 'starszy'
        foreach ($file in Get-ChildItem -LiteralPath $c.LocalWorld -Recurse -File) { $file.LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(2) }
        $before=Get-WorldSnapshot $c.LocalWorld
        Throws { Invoke-WorldSync $c Download -Confirmed } 'nowszy'
        Assert ((Get-WorldSnapshot $c.LocalWorld).Fingerprint -ceq $before.Fingerprint) 'Newer save overwritten'
    }
    Test 'backup verified and retained before replacing local world' {
        $c=New-Case; New-FakeWorld $c.LocalWorld 'remote'; [void](Publish $c)
        $receiver=Copy-Context $c '-receiver'; New-FakeWorld $receiver.LocalWorld 'old-local'
        $before=Get-WorldSnapshot $receiver.LocalWorld
        $result=Invoke-WorldSync $receiver Download -Confirmed
        Assert ([IO.Directory]::Exists($result.Backup)) 'Backup missing'
        Assert ((Get-WorldSnapshot $result.Backup).Fingerprint -ceq $before.Fingerprint) 'Backup differs'
        Assert ((Get-WorldSnapshot $receiver.LocalWorld).Fingerprint -ceq (Get-WorldSnapshot $c.LocalWorld).Fingerprint) 'Import failed'
    }
    Test 'copy failure leaves original world intact and publishes no ZIP' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        $script:BlockedCopySource=$c.LocalWorld
        function Copy-Item { [CmdletBinding()]param($LiteralPath,$Destination,[switch]$Recurse,[switch]$Force)
            if ($LiteralPath -ceq $script:BlockedCopySource) { throw 'simulated-copy-error' }
            Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
        }
        try { Throws { Publish $c } 'simulated-copy-error' }
        finally { Remove-Item Function:\Copy-Item; Remove-Variable BlockedCopySource -Scope Script }
        Assert (Test-CompleteWorld $c.LocalWorld) 'World damaged'
        Assert (@(Get-ChildItem -LiteralPath $c.DriveFolder -File).Count -eq 0) 'Partial archive published'
    }
    Test 'state-write failure AFTER install rolls filesystem and state back' {
        $c=New-Case; New-FakeWorld $c.LocalWorld 'remote'; [void](Publish $c)
        $receiver=Copy-Context $c '-receiver'; New-FakeWorld $receiver.LocalWorld 'original'
        $before=Get-WorldSnapshot $receiver.LocalWorld
        $savedFunction=${function:Write-JsonAtomic}
        $script:BlockedState=$receiver.StateFile
        function Write-JsonAtomic([string]$Path,$Value) {
            if ($Path -ceq $script:BlockedState) { throw 'simulated-state-error-after-rename' }
            & $savedFunction $Path $Value
        }
        try { Throws { Invoke-WorldSync $receiver Download -Confirmed } 'przywrocono poprzedni stan' }
        finally { Set-Item Function:\Write-JsonAtomic $savedFunction; Remove-Variable BlockedState -Scope Script }
        Assert ((Get-WorldSnapshot $receiver.LocalWorld).Fingerprint -ceq $before.Fingerprint) 'Rollback failed'
        Assert (-not [IO.File]::Exists($receiver.StateFile)) 'State not rolled back'
        Assert (-not [IO.File]::Exists($receiver.JournalFile)) 'Journal not cleaned'
    }
    Test 'interrupted transaction recovery restores world and old state' {
        $c=New-Case; New-FakeWorld $c.LocalWorld 'original'
        $before=Get-WorldSnapshot $c.LocalWorld
        $id=[guid]::NewGuid().ToString('N'); $paths=Get-TransactionPaths $c $id
        [IO.Directory]::Move($c.LocalWorld,$paths.Previous)
        New-FakeWorld $c.LocalWorld 'partially-installed'
        Write-JsonAtomic $c.JournalFile @{id=$id;phase='prepared';hadLocal=$true;oldStateExists=$true;oldArchive='old.zip'}
        Set-LastSeenArchive $c 'new.zip'
        Recover-Import $c
        Assert ((Get-WorldSnapshot $c.LocalWorld).Fingerprint -ceq $before.Fingerprint) 'Crash recovery failed'
        Assert ((Get-LastSeenArchive $c) -ceq 'old.zip') 'Previous state not restored'
    }
    Test 'concurrent operations blocked by exclusive lock' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        [IO.Directory]::CreateDirectory($c.AppDataDir) | Out-Null
        $lock=[IO.File]::Open((Join-Path $c.AppDataDir 'operation.lock'),'OpenOrCreate','ReadWrite','None')
        try { Throws { Publish $c } 'Inna operacja' } finally { $lock.Dispose() }
    }
    Test 'game process blocks sync (process query simulated)' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        function Get-Process { param($Name,$ErrorAction) return [pscustomobject]@{ProcessName='valheim'} }
        try { Throws { Publish $c } 'Valheim nadal dziala' } finally { Remove-Item Function:\Get-Process }
    }
    Test 'real host game-process detector, on synthetic world only' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        $before=(Get-WorldSnapshot $c.LocalWorld).Fingerprint
        function Get-Process { param($Name,$ErrorAction) Microsoft.PowerShell.Management\Get-Process -Name $Name -ErrorAction $ErrorAction }
        $running=@(Microsoft.PowerShell.Management\Get-Process -Name valheim,valheim_server -ErrorAction SilentlyContinue).Count -gt 0
        if ($running) { Throws { Publish $c } 'Valheim nadal dziala'; Assert ((Get-WorldSnapshot $c.LocalWorld).Fingerprint -ceq $before) 'Running game allowed copy' }
        else { Assert-GameClosed }
    }
    Test 'ZIP traversal, duplicate names and wrong-world content rejected' {
        foreach ($names in @(@('../escape.txt'),@('manifest.json','manifest.json'),@('world/Other/_main.1.ok'))) {
            $c=New-Case
            $zipPath=Join-Path $c.DriveFolder 'VALHEIM_NewWorld_999.zip'
            $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
            try { foreach ($entryName in $names) { $entry=$zip.CreateEntry($entryName); $stream=New-Object IO.StreamWriter($entry.Open()); try {$stream.Write('bad')} finally {$stream.Dispose()} } }
            finally { $zip.Dispose() }
            Throws { Invoke-WorldSync $c Download -Confirmed }
            Assert (-not [IO.Directory]::Exists($c.LocalWorld)) 'Unsafe ZIP installed'
        }
    }
    Test 'CRC corruption rejected even when ZIP structure is readable' {
        $c=New-Case
        $zipPath=Join-Path $c.DriveFolder 'VALHEIM_NewWorld_999.zip'
        $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry=$zip.CreateEntry('manifest.json',[IO.Compression.CompressionLevel]::NoCompression)
            $writer=New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('abcdef') } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        $bytes=[IO.File]::ReadAllBytes($zipPath)
        # Corrupt the central-directory checksum without altering compressed data.
        # This remains structurally readable even by .NET versions that ignore CRC.
        $offset=[int][BitConverter]::ToUInt32($bytes,$bytes.Length-6)+16
        $bytes[$offset]=$bytes[$offset] -bxor 1
        [IO.File]::WriteAllBytes($zipPath,$bytes)
        Throws { [ValheimSaveManager.ZipIntegrity]::Verify($zipPath) } 'CRC32'
    }
    Test 'Drive copy verification failure removes owned .uploading file' {
        $c=New-Case; New-FakeWorld $c.LocalWorld
        function Get-FileHash { [CmdletBinding()]param($LiteralPath,$Algorithm='SHA256')
            if ($LiteralPath.EndsWith('.uploading')) { throw 'simulated-Drive-copy-failure' }
            Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
        }
        try { Throws { Publish $c } 'simulated-Drive-copy-failure' }
        finally { Remove-Item Function:\Get-FileHash }
        Assert (@(Get-ChildItem -LiteralPath $c.DriveFolder -File).Count -eq 0) 'Partial upload left behind'
    }
    Test 'backup copy failure does not start world replacement' {
        $c=New-Case; New-FakeWorld $c.LocalWorld 'remote'; [void](Publish $c)
        $receiver=Copy-Context $c '-receiver'; New-FakeWorld $receiver.LocalWorld 'original'
        $before=Get-WorldSnapshot $receiver.LocalWorld
        $script:BlockedBackupRoot=$receiver.BackupDir
        function Copy-Item { [CmdletBinding()]param($LiteralPath,$Destination,[switch]$Recurse,[switch]$Force)
            if ($Destination.StartsWith($script:BlockedBackupRoot)) { throw 'simulated-backup-copy-failure' }
            Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
        }
        try { Throws { Invoke-WorldSync $receiver Download -Confirmed } 'simulated-backup-copy-failure' }
        finally { Remove-Item Function:\Copy-Item; Remove-Variable BlockedBackupRoot -Scope Script }
        Assert ((Get-WorldSnapshot $receiver.LocalWorld).Fingerprint -ceq $before.Fingerprint) 'World changed without backup'
        Assert (-not [IO.File]::Exists($receiver.JournalFile)) 'Replacement started before backup'
    }
    Test 'known corrupt newest archive blocks upload and records last failed attempt' {
        $c=New-Case; New-FakeWorld $c.LocalWorld; $up=Publish $c
        [IO.File]::WriteAllText((Join-Path $c.DriveFolder $up.Archive),'broken')
        Throws { Publish $c }
        $history=(Get-SyncStatus $c).History
        Assert (-not $history.lastAttempt.success -and $history.lastSuccess.Operation -ceq 'Upload') 'Last success was lost'
    }
} finally {
    $report=[pscustomobject]@{powershell=$PSVersionTable.PSVersion.ToString();utc=[DateTime]::UtcNow.ToString('o');syntheticDataOnly=$true;passed=@($script:Results | Where-Object passed).Count;failed=@($script:Results | Where-Object {-not $_.passed}).Count;tests=$script:Results.ToArray()}
    Write-JsonAtomic ([IO.Path]::GetFullPath($ReportPath)) $report
    # Explicitly verify the resolved target before recursively deleting our own fixtures.
    $resolved=[IO.Path]::GetFullPath($script:TestRoot)
    Assert ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -and [IO.Path]::GetFileName($resolved).StartsWith('ValheimManagerTests-')) 'Unsafe test cleanup target'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($report.failed -gt 0) { exit 1 }
