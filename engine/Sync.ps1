# Shared engine extracted from the original ValheimSaveManager.ps1.
# Windows PowerShell 5.1; no GUI, console prompts or character-save operations.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not ('ValheimSaveManager.ZipIntegrity' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ZipIntegrity.cs') -ReferencedAssemblies System.IO.Compression,System.IO.Compression.FileSystem
}

function Assert-WorldName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80 -or
        $Name -match '[\x00-\x1f<>:"/\\|?*\[\]]' -or $Name -match '[. ]$' -or
        $Name -match '^(\.|\.\.|CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
        throw 'Nieprawidlowa nazwa swiata. Uzyj nazwy folderu, bez sciezki i znakow specjalnych.'
    }
}

function Get-FullFolder([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '^[a-zA-Z]:[^\\/]') {
        throw 'Podaj pelna, bezwzgledna sciezke folderu.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\','/')
}

function Test-Within([string]$Path, [string]$Root) {
    return $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoLinks([string]$Path, [switch]$Tree) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Dowiazanie lub punkt ponownej analizy nie jest obslugiwany: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($Tree -and (Test-Path -LiteralPath $Path)) {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Swiat zawiera dowiazanie: $($item.FullName)"
            }
        }
    }
}

function Read-Configuration([string]$AppDataDir = (Join-Path $env:LOCALAPPDATA 'ValheimSaveManager')) {
    $defaults = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $file = Join-Path $AppDataDir 'config.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.PSObject.Properties['driveFolder']) { $defaults.driveFolder = [string]$saved.driveFolder }
            if ($saved.PSObject.Properties['worldName']) { $defaults.worldName = [string]$saved.worldName }
        } catch { throw "Nie mozna odczytac konfiguracji $file. Popraw JSON lub zmien nazwe pliku. $($_.Exception.Message)" }
    }
    Assert-WorldName $defaults.worldName
    $defaults.driveFolder = Get-FullFolder $defaults.driveFolder
    return $defaults
}

function Write-JsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $tmp = Join-Path $parent ('.vsm-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function New-SyncContext($Configuration,
    [string]$AppDataDir = (Join-Path $env:LOCALAPPDATA 'ValheimSaveManager'),
    [string]$WorldsRoot = (Join-Path $env:USERPROFILE 'AppData\LocalLow\IronGate\Valheim\worlds_local')) {
    Assert-WorldName $Configuration.worldName
    $app = Get-FullFolder $AppDataDir
    $worlds = Get-FullFolder $WorldsRoot
    $drive = Get-FullFolder $Configuration.driveFolder
    # Neither archive storage nor backup storage may overlap the worlds directory.
    foreach ($other in @($drive, $app)) {
        if ((Test-Within $worlds $other) -or (Test-Within $other $worlds)) { throw 'Foldery swiata, konfiguracji i Drive musza byc oddzielne.' }
    }
    if ((Test-Within $drive $app) -or (Test-Within $app $drive)) { throw 'Folder Drive nie moze zawierac konfiguracji ani backupow aplikacji.' }
    return [pscustomobject]@{
        WorldName = [string]$Configuration.worldName; DriveFolder = $drive; WorldsRoot = $worlds
        LocalWorld = Join-Path $worlds $Configuration.worldName; AppDataDir = $app
        BackupDir = Join-Path $app 'Backups'; ConfigFile = Join-Path $app 'config.json'
        StateFile = Join-Path $app ("state_{0}.json" -f $Configuration.worldName)
        HistoryFile = Join-Path $app ("history_{0}.json" -f $Configuration.worldName)
        JournalFile = Join-Path $worlds ('.' + $Configuration.worldName + '.vsm-transaction.json')
    }
}

function Save-Configuration($Context) {
    if (-not (Test-Path -LiteralPath $Context.DriveFolder -PathType Container)) { throw "Brak folderu Google Drive: $($Context.DriveFolder)" }
    Assert-NoLinks $Context.AppDataDir
    Write-JsonAtomic $Context.ConfigFile @{ driveFolder = $Context.DriveFolder; worldName = $Context.WorldName }
}

function Assert-GameClosed {
    # Preserved from the original script, including dedicated-server detection.
    $processes = @(Get-Process -Name 'valheim', 'valheim_server' -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) { throw 'Valheim nadal dziala. Zamknij gre i serwer przed kopiowaniem zapisu.' }
}

function Test-CompleteWorld([string]$Folder) {
    # Same generation-based quartet as the original. cacheMinimap alone never qualifies.
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $false }
    foreach ($okFile in Get-ChildItem -LiteralPath $Folder -File -Filter '_main.*.ok') {
        if ($okFile.Name -match '^_main\.(\d+)\.ok$') {
            $generation = $Matches[1]
            $complete = $true
            foreach ($extension in @('ok', 'db2', 'fwl2', 'chunks')) {
                $part = Join-Path $Folder ("_main.{0}.{1}" -f $generation, $extension)
                if (-not (Test-Path -LiteralPath $part -PathType Leaf)) { $complete = $false; break }
                if ($extension -in @('db2','fwl2') -and (Get-Item -LiteralPath $part).Length -eq 0) { $complete = $false; break }
            }
            if ($complete) { return $true }
        }
    }
    return $false
}

function Get-WorldSnapshot([string]$Folder) {
    Assert-NoLinks $Folder -Tree
    if (-not (Test-CompleteWorld $Folder)) { throw "Brak kompletnego swiata w $Folder. cacheMinimap nie jest zapisem. W grze wybierz Move to Local." }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $latest = [DateTime]::MinValue
    foreach ($file in Get-ChildItem -LiteralPath $Folder -Force -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Folder.TrimEnd('\').Length + 1)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $lines.Add($relative + '|' + $file.Length + '|' + $hash)
        if ($relative -notmatch '(^|[\\/])cacheMinimap([\\/]|$)' -and $file.LastWriteTimeUtc -gt $latest) { $latest = $file.LastWriteTimeUtc }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','') }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ Fingerprint = $fingerprint; LatestWriteUtc = $latest }
}

function Get-LatestArchive($Context) {
    if (-not (Test-Path -LiteralPath $Context.DriveFolder -PathType Container)) { throw "Folder Google Drive niedostepny: $($Context.DriveFolder). Sprawdz Drive for desktop lub ustawienia." }
    $pattern = 'VALHEIM_' + $Context.WorldName + '_*.zip'
    $archives = @(Get-ChildItem -LiteralPath $Context.DriveFolder -File -Filter $pattern | Sort-Object Name -Descending)
    if ($archives.Count -eq 0) { return $null }
    return $archives[0]
}

function Get-LastSeenArchive($Context) {
    if (-not (Test-Path -LiteralPath $Context.StateFile -PathType Leaf)) { return '' }
    try {
        $state = Get-Content -LiteralPath $Context.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$state.lastSeenArchive
    } catch { throw 'Nie mozna odczytac stanu ostatniego archiwum. Synchronizacja zablokowana; zachowaj plik stanu i sprawdz JSON.' }
}

function Set-LastSeenArchive($Context, [string]$Name) {
    Write-JsonAtomic $Context.StateFile @{ lastSeenArchive = $Name }
}

function Set-SyncProgress($Progress, [string]$Message) { if ($null -ne $Progress) { $Progress.Message = $Message } }

function Remove-OwnedTree([string]$Path, [string]$Parent, [string]$Prefix) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ine $expectedParent -or
        -not [IO.Path]::GetFileName($full).StartsWith($Prefix, [StringComparison]::Ordinal)) { throw 'Odmowa usuniecia sciezki spoza katalogu roboczego.' }
    if (Test-Path -LiteralPath $full) { Assert-NoLinks $full -Tree; Remove-Item -LiteralPath $full -Recurse -Force }
}

function New-WorkDir {
    $folder = Join-Path $env:TEMP ('ValheimSync-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    return $folder
}

function Expand-WorldArchive([string]$Zip, [string]$Unpack, $Context) {
    # Validate all names BEFORE extracting; reject traversal, aliases, ADS and unexpected roots.
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\','/')
            $parts = $name.TrimEnd('/').Split('/')
            if ($name.StartsWith('/') -or $name.Contains(':') -or $parts.Count -eq 0) { throw 'Niebezpieczna sciezka w ZIP.' }
            foreach ($part in $parts) {
                if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$|[\x00-\x1f<>"|?*]' -or
                    $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { throw 'Niedozwolona nazwa w ZIP.' }
            }
            if (-not $seen.Add($name.TrimEnd('/'))) { throw 'ZIP zawiera powtorzone sciezki.' }
            $worldPrefix = 'world/' + $Context.WorldName
            if ($name -cne 'manifest.json' -and $name -cne 'world/' -and $name -cne ($worldPrefix + '/') -and
                -not $name.StartsWith($worldPrefix + '/', [StringComparison]::Ordinal)) { throw 'ZIP zawiera dane spoza wybranego swiata.' }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000) { throw 'ZIP zawiera dowiazanie symboliczne.' }
        }
    } finally { $archive.Dispose() }
    [ValheimSaveManager.ZipIntegrity]::Verify($Zip)
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Unpack)
    $manifest = Get-Content -LiteralPath (Join-Path $Unpack 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.version -ne 1 -or $manifest.worldName -cne $Context.WorldName) { throw 'Manifest ZIP nie pasuje do wybranego swiata lub wersji formatu.' }
    $created = [DateTimeOffset]::Parse([string]$manifest.createdUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    if ($created -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'Archiwum ma date z przyszlosci. Sprawdz zegary komputerow.' }
    $world = Join-Path (Join-Path $Unpack 'world') $Context.WorldName
    $snapshot = Get-WorldSnapshot $world
    return [pscustomobject]@{ World = $world; CreatedUtc = $created; Snapshot = $snapshot }
}

function Get-TransactionPaths($Context, [string]$Id) {
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'Uszkodzony dziennik transakcji; wymagana reczna kontrola.' }
    return [pscustomobject]@{
        Stage = Join-Path $Context.WorldsRoot ('.vsm-stage-' + $Id)
        Previous = Join-Path $Context.WorldsRoot ('.vsm-previous-' + $Id)
    }
}

function Recover-Import($Context) {
    if (-not (Test-Path -LiteralPath $Context.JournalFile)) { return }
    $journal = Get-Content -LiteralPath $Context.JournalFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.phase -notin @('prepared','committed') -or $journal.hadLocal -isnot [bool] -or $journal.oldStateExists -isnot [bool]) {
        throw 'Uszkodzony dziennik transakcji. Zachowano wszystkie katalogi; wymagana reczna kontrola.'
    }
    $paths = Get-TransactionPaths $Context $journal.id
    foreach ($p in @($paths.Stage,$paths.Previous,$Context.LocalWorld)) { Assert-NoLinks $p -Tree }
    if ($journal.phase -ne 'committed') {
        if (Test-Path -LiteralPath $paths.Previous) {
            if (Test-Path -LiteralPath $Context.LocalWorld) {
                # Move the newly installed world aside, never recursively delete a live-world path.
                Remove-OwnedTree $paths.Stage $Context.WorldsRoot '.vsm-stage-'
                [IO.Directory]::Move($Context.LocalWorld, $paths.Stage)
            }
            [IO.Directory]::Move($paths.Previous, $Context.LocalWorld)
        } elseif (-not $journal.hadLocal -and (Test-Path -LiteralPath $Context.LocalWorld)) {
            Remove-OwnedTree $paths.Stage $Context.WorldsRoot '.vsm-stage-'
            [IO.Directory]::Move($Context.LocalWorld, $paths.Stage)
        }
        # State is restored together with the filesystem after an interrupted import.
        if ($journal.oldStateExists) { Write-JsonAtomic $Context.StateFile @{ lastSeenArchive = [string]$journal.oldArchive } }
        elseif (Test-Path -LiteralPath $Context.StateFile) { [IO.File]::Delete($Context.StateFile) }
    }
    Remove-OwnedTree $paths.Stage $Context.WorldsRoot '.vsm-stage-'
    Remove-OwnedTree $paths.Previous $Context.WorldsRoot '.vsm-previous-'
    [IO.File]::Delete($Context.JournalFile)
}

function Upload-World($Context, $Progress) {
    $before = Get-WorldSnapshot $Context.LocalWorld
    $latest = Get-LatestArchive $Context
    $lastSeen = Get-LastSeenArchive $Context
    if ($null -ne $latest -and $latest.Name -cne $lastSeen) { throw 'Drive zawiera niepobrana wersje swiata. Upload zablokowany: najpierw uzgodnijcie ostatniego hosta i pobierz aktualny zapis.' }
    $work = New-WorkDir
    $pending = $null
    $ownsPending = $false
    try {
        Set-SyncProgress $Progress 'Sprawdzanie wersji i pakowanie swiata...'
        if ($null -ne $latest) {
            $previousZip = Join-Path $work 'previous.zip'
            Copy-Item -LiteralPath $latest.FullName -Destination $previousZip
            $remote = Expand-WorldArchive $previousZip (Join-Path $work 'previous') $Context
            if ($before.Fingerprint -cne $remote.Snapshot.Fingerprint -and $before.LatestWriteUtc -lt $remote.Snapshot.LatestWriteUtc) {
                throw 'Lokalny swiat jest starszy niz znane archiwum. Upload zablokowany.'
            }
        }
        $staging = Join-Path $work 'package'
        $worldContainer = Join-Path $staging 'world'
        [IO.Directory]::CreateDirectory($worldContainer) | Out-Null
        Copy-Item -LiteralPath $Context.LocalWorld -Destination $worldContainer -Recurse -Force
        $copied = Get-WorldSnapshot (Join-Path $worldContainer $Context.WorldName)
        $after = Get-WorldSnapshot $Context.LocalWorld
        if ($copied.Fingerprint -cne $before.Fingerprint -or $after.Fingerprint -cne $before.Fingerprint) { throw 'Swiat zmienil sie podczas kopiowania. Niczego nie wyslano.' }
        $createdUtc = [DateTime]::UtcNow
        @{ version = 1; worldName = $Context.WorldName; createdUtc = $createdUtc.ToString('o'); sourceComputer = $env:COMPUTERNAME } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'manifest.json') -Encoding UTF8
        $stamp = $createdUtc.ToString("yyyyMMdd'T'HHmmssfff'Z'")
        $computer = $env:COMPUTERNAME -replace '[^a-zA-Z0-9-]', '_'
        $fileName = "VALHEIM_$($Context.WorldName)_${stamp}_${computer}.zip"
        $localZip = Join-Path $work $fileName
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $localZip, [IO.Compression.CompressionLevel]::Optimal, $false)
        $verified = Expand-WorldArchive $localZip (Join-Path $work 'verify') $Context
        if ($verified.Snapshot.Fingerprint -cne $before.Fingerprint) { throw 'Weryfikacja ZIP nie powiodla sie.' }
        Set-SyncProgress $Progress 'Kopiowanie ZIP do folderu Google Drive...'
        $pending = Join-Path $Context.DriveFolder ($fileName + '.uploading')
        $destination = Join-Path $Context.DriveFolder $fileName
        # CreateNew prevents clobbering a concurrent upload; the .zip appears only after full verification.
        $inputStream = [IO.File]::OpenRead($localZip)
        try {
            $outputStream = New-Object IO.FileStream($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $ownsPending = $true
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
        if ((Get-FileHash -LiteralPath $localZip).Hash -cne (Get-FileHash -LiteralPath $pending).Hash) { throw 'Kopia archiwum na Drive ma inna sume kontrolna.' }
        Assert-GameClosed
        $nowLatest = Get-LatestArchive $Context
        $nowName = ''; if ($null -ne $nowLatest) { $nowName = $nowLatest.Name }
        $oldName = ''; if ($null -ne $latest) { $oldName = $latest.Name }
        if ($nowName -cne $oldName) { throw 'Na Drive pojawila sie inna wersja podczas wysylania. Niczego nie opublikowano.' }
        [IO.File]::Move($pending, $destination)
        $ownsPending = $false
        try { Set-LastSeenArchive $Context $fileName }
        catch { throw "ZIP zostal umieszczony w folderze Drive, ale nie zapisano stanu lokalnego. Nie ponawiaj uploadu; sprawdz archiwum $fileName. $($_.Exception.Message)" }
        return [pscustomobject]@{ Operation = 'Upload'; Archive = $fileName; Backup = ''; CompletedUtc = $createdUtc.ToString('o'); Message = 'ZIP umieszczony w folderze Google Drive. Poczekaj na zakonczenie synchronizacji w aplikacji Drive.' }
    } finally {
        if ($ownsPending -and [IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
        Remove-OwnedTree $work $env:TEMP 'ValheimSync-'
    }
}

function Download-World($Context, $Progress, [switch]$Confirmed) {
    if (-not $Confirmed) { throw 'Pobieranie wymaga potwierdzenia zastapienia lokalnego swiata.' }
    $archive = Get-LatestArchive $Context
    if ($null -eq $archive) { throw 'Brak archiwow swiata w folderze Google Drive.' }
    $work = New-WorkDir
    $paths = Get-TransactionPaths $Context ([guid]::NewGuid().ToString('N'))
    $backup = ''
    $backupPending = ''
    try {
        Set-SyncProgress $Progress 'Pobieranie i sprawdzanie ZIP...'
        $localZip = Join-Path $work 'world.zip'
        Copy-Item -LiteralPath $archive.FullName -Destination $localZip
        $package = Expand-WorldArchive $localZip (Join-Path $work 'unpacked') $Context
        $hadLocal = Test-Path -LiteralPath $Context.LocalWorld -PathType Container
        $before = $null
        if ($hadLocal) {
            # Incomplete existing folders are preserved too; no silent deletion of unknown data.
            if (-not (Test-CompleteWorld $Context.LocalWorld)) { throw 'Istniejacy folder swiata jest niekompletny. Zachowaj go recznie przed importem.' }
            $before = Get-WorldSnapshot $Context.LocalWorld
            if ($before.Fingerprint -cne $package.Snapshot.Fingerprint -and $before.LatestWriteUtc -gt $package.CreatedUtc) {
                throw 'Lokalny swiat jest nowszy niz archiwum. Pobranie zablokowane, aby nie cofnac postepu.'
            }
        }
        [IO.Directory]::CreateDirectory($Context.WorldsRoot) | Out-Null
        Copy-Item -LiteralPath $package.World -Destination $paths.Stage -Recurse
        if ((Get-WorldSnapshot $paths.Stage).Fingerprint -cne $package.Snapshot.Fingerprint) { throw 'Kopia przygotowana do importu jest niezgodna z ZIP.' }
        if ($hadLocal) {
            Set-SyncProgress $Progress 'Tworzenie i sprawdzanie backupu...'
            [IO.Directory]::CreateDirectory($Context.BackupDir) | Out-Null
            $backup = Join-Path $Context.BackupDir ($Context.WorldName + '_before_import_' + (Get-Date).ToString('yyyyMMdd_HHmmssfff') + '_' + [guid]::NewGuid().ToString('N'))
            $backupPending = $backup + '.partial'
            Copy-Item -LiteralPath $Context.LocalWorld -Destination $backupPending -Recurse
            if ((Get-WorldSnapshot $backupPending).Fingerprint -cne $before.Fingerprint -or
                (Get-WorldSnapshot $Context.LocalWorld).Fingerprint -cne $before.Fingerprint) { throw 'Swiat zmienil sie lub backup jest niekompletny. Import przerwany.' }
            [IO.Directory]::Move($backupPending, $backup)
        } elseif (Test-Path -LiteralPath $Context.LocalWorld) { throw 'Folder swiata pojawil sie podczas przygotowania. Import przerwany.' }
        Assert-GameClosed
        $current = Get-LatestArchive $Context
        if ($null -eq $current -or $current.Name -cne $archive.Name) { throw 'Wersja na Drive zmienila sie. Ponow pobieranie po zakonczeniu synchronizacji Drive.' }
        Set-SyncProgress $Progress 'Bezpieczna podmiana swiata...'
        $journal = @{ id = [IO.Path]::GetFileName($paths.Stage).Substring(11); hadLocal = [bool]$hadLocal; phase = 'prepared'; oldStateExists = [IO.File]::Exists($Context.StateFile); oldArchive = (Get-LastSeenArchive $Context) }
        Write-JsonAtomic $Context.JournalFile $journal
        try {
            if ($hadLocal) { [IO.Directory]::Move($Context.LocalWorld, $paths.Previous) }
            [IO.Directory]::Move($paths.Stage, $Context.LocalWorld)
            Set-LastSeenArchive $Context $archive.Name
            $journal.phase = 'committed'
            Write-JsonAtomic $Context.JournalFile $journal
        } catch {
            $originalError = $_.Exception.Message
            try { Recover-Import $Context } catch { throw "Import nieudany: $originalError. Automatyczne przywrocenie wymaga interwencji: $($_.Exception.Message). Backup: $backup; dziennik: $($Context.JournalFile)" }
            throw "Import nieudany; przywrocono poprzedni stan. $originalError"
        }
        # A committed journal permits safe cleanup on the next run if cleanup itself fails.
        try { Recover-Import $Context } catch { $ProgressMessage = ' Import zakonczony, ale katalog tymczasowy wymaga pozniejszego sprzatania.' }
        $message = 'Przywrocono kompletny swiat. Mozesz uruchomic Valheim.'
        if (Get-Variable ProgressMessage -ErrorAction SilentlyContinue) { $message += $ProgressMessage }
        return [pscustomobject]@{ Operation = 'Download'; Archive = $archive.Name; Backup = $backup; CompletedUtc = [DateTime]::UtcNow.ToString('o'); Message = $message }
    } finally {
        if ($backupPending -and (Test-Path -LiteralPath $backupPending)) { Remove-OwnedTree $backupPending $Context.BackupDir ($Context.WorldName + '_before_import_') }
        if (-not (Test-Path -LiteralPath $Context.JournalFile)) { Remove-OwnedTree $paths.Stage $Context.WorldsRoot '.vsm-stage-' }
        Remove-OwnedTree $work $env:TEMP 'ValheimSync-'
    }
}

function Get-SyncStatus($Context) {
    $history = $null
    if (Test-Path -LiteralPath $Context.HistoryFile) {
        try { $history = Get-Content -LiteralPath $Context.HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ LocalComplete = (Test-CompleteWorld $Context.LocalWorld); DriveAvailable = (Test-Path -LiteralPath $Context.DriveFolder -PathType Container); History = $history; RecoveryPending = (Test-Path -LiteralPath $Context.JournalFile) }
}

function Invoke-WorldSync($Context, [ValidateSet('Upload','Download')][string]$Operation, $Progress = $null, [switch]$Confirmed) {
    foreach ($p in @($Context.WorldsRoot,$Context.AppDataDir,$Context.LocalWorld,$Context.BackupDir)) { Assert-NoLinks $p }
    Assert-NoLinks $Context.LocalWorld -Tree
    [IO.Directory]::CreateDirectory($Context.AppDataDir) | Out-Null
    $lock = $null
    try { $lock = [IO.File]::Open((Join-Path $Context.AppDataDir 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Inna operacja Valheim Save Manager juz trwa albo folder konfiguracji jest niedostepny.' }
    try {
        Assert-GameClosed
        Recover-Import $Context
        if ($Operation -eq 'Upload') { $result = Upload-World $Context $Progress }
        else { $result = Download-World $Context $Progress -Confirmed:$Confirmed }
        $history = @{ lastSuccess = $result; lastAttempt = @{ operation = $Operation; utc = [DateTime]::UtcNow.ToString('o'); success = $true; message = $result.Message } }
        try { Write-JsonAtomic $Context.HistoryFile $history } catch { $result.Message += ' Nie udalo sie zapisac historii operacji.' }
        return $result
    } catch {
        $errorRecord = $_
        $lastSuccess = $null
        try { $lastSuccess = (Get-SyncStatus $Context).History.lastSuccess } catch { }
        try { Write-JsonAtomic $Context.HistoryFile @{ lastSuccess = $lastSuccess; lastAttempt = @{ operation = $Operation; utc = [DateTime]::UtcNow.ToString('o'); success = $false; message = $errorRecord.Exception.Message } } } catch { }
        throw $errorRecord
    } finally { $lock.Dispose() }
}
