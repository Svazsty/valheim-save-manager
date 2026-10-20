[CmdletBinding()]
param([switch]$Console, [string]$AppDataDir = (Join-Path $env:LOCALAPPDATA 'ValheimSaveManager'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try { . (Join-Path $PSScriptRoot 'engine\Sync.ps1') }
catch {
    if ($Console) { throw }
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show($_.Exception.Message, 'Valheim Save Manager - błąd silnika', 'OK', 'Error')
    exit 1
}

if ($Console) {
    while ($true) {
        try {
            $context = New-SyncContext (Read-Configuration $AppDataDir) -AppDataDir $AppDataDir
            Write-Host "`nVALHEIM SAVE MANAGER | $($context.WorldName)`nLokalny: $($context.LocalWorld)`nDrive: $($context.DriveFolder)"
            Write-Host '1 Upload | 2 Download | 3 Ustawienia | 0 Wyjdz'
            switch (Read-Host 'Wybor') {
                '0' { return }
                '1' { (Invoke-WorldSync $context Upload).Message | Write-Host }
                '2' {
                    Write-Host 'Najnowsze archiwum zastapi lokalny swiat. Poprzedni zapis trafi do backupu. Starszy import jest blokowany.'
                    if ((Read-Host 'Wpisz POBIERZ, aby kontynuowac') -ceq 'POBIERZ') { (Invoke-WorldSync $context Download -Confirmed).Message | Write-Host }
                }
                '3' {
                    $name = Read-Host 'Nazwa swiata'
                    $path = Read-Host 'Pelna sciezka folderu Drive'
                    $next = New-SyncContext ([pscustomobject]@{worldName=$name;driveFolder=$path.Trim('"')}) -AppDataDir $AppDataDir
                    Save-Configuration $next
                }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red; [void](Read-Host 'ENTER') }
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'GUI wymaga PowerShell -STA. Uzyj launchera CMD.' }
    $script:Context = New-SyncContext (Read-Configuration $AppDataDir) -AppDataDir $AppDataDir
    $reader = New-Object Xml.XmlNodeReader ([xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ui\Main.xaml') -Raw -Encoding UTF8))
    try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $fontUri = New-Object Uri ((Join-Path $PSScriptRoot 'assets\fonts') + '\')
    $script:Window.FontFamily = New-Object Windows.Media.FontFamily($fontUri, './#Onest')
    $script:Controls = @{}
    foreach ($name in @('MinimizeButton','MaximizeButton','CloseButton','WorldSettingsButton','MainView','SettingsView','WorldLabel','LocalLabel','DriveLabel','DownloadButton','UploadButton','BusyBar','StatusLabel','SuccessLabel','SettingsButton','WorldInput','DriveInput','BrowseButton','WorldPathLabel','BackupsButton','SettingsError','CancelSettingsButton','SaveSettingsButton')) {
        $script:Controls[$name] = $script:Window.FindName($name)
    }
    $script:Worker = $null
    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)

    function Set-Busy([bool]$Busy) {
        foreach ($name in @('DownloadButton','UploadButton','SettingsButton','WorldSettingsButton')) { $script:Controls[$name].IsEnabled = -not $Busy }
        $script:Controls.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    }

    function Show-UiError($ErrorRecord) {
        $message = [string]$ErrorRecord.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Operacja nie zwrocila poprawnego wyniku. Szczegoly zapisano w gui-error.log.' }
        $script:Controls.StatusLabel.Text = $message
        $script:Controls.StatusLabel.Foreground = '#E3B6AF'
        try {
            [IO.Directory]::CreateDirectory($script:Context.AppDataDir) | Out-Null
            $detail = [DateTime]::UtcNow.ToString('o') + "`r`n" + $ErrorRecord.ToString() + "`r`n" + $ErrorRecord.ScriptStackTrace + "`r`n`r`n"
            [IO.File]::AppendAllText((Join-Path $script:Context.AppDataDir 'gui-error.log'), $detail, (New-Object Text.UTF8Encoding($true)))
        } catch { }
        try { [void][Windows.MessageBox]::Show($script:Window, $message, 'Valheim Save Manager - blad operacji', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) } catch { }
    }

    function Update-Status($Status, [switch]$KeepMessage) {
        $script:Controls.WorldLabel.Text = $script:Context.WorldName
        $script:Controls.WorldLabel.ToolTip = $script:Context.WorldName
        $script:Controls.LocalLabel.Text = if ($Status.LocalComplete) { 'Local  ·  kompletny zapis' } else { 'Local  ·  brak zapisu' }
        $script:Controls.LocalLabel.ToolTip = $script:Context.LocalWorld
        $script:Controls.DriveLabel.Text = if ($Status.DriveAvailable) { 'Drive  ·  folder dostępny' } else { 'Drive  ·  folder niedostępny' }
        $script:Controls.DriveLabel.ToolTip = $script:Context.DriveFolder
        $script:Controls.WorldPathLabel.Text = $script:Context.LocalWorld
        if ($null -ne $Status.History) {
            if ($null -ne $Status.History.lastSuccess) {
                $success = $Status.History.lastSuccess
                $localTime = [DateTimeOffset]::Parse($success.CompletedUtc).ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss')
                $script:Controls.SuccessLabel.Text = "Ostatnio poprawnie: $($success.Operation) / $localTime"
            } else { $script:Controls.SuccessLabel.Text = 'Brak udanych operacji na tym komputerze.' }
            if (-not $KeepMessage) {
                $attempt = $Status.History.lastAttempt
                $attemptTime = [DateTimeOffset]::Parse($attempt.utc).ToLocalTime().ToString('dd.MM HH:mm:ss')
                $script:Controls.StatusLabel.Text = "$($attempt.operation) · $attemptTime`n$($attempt.message)"
                $script:Controls.StatusLabel.Foreground = if ($attempt.success) { '#D9DADD' } else { '#E3B6AF' }
            }
        } elseif (-not $KeepMessage) {
            $script:Controls.SuccessLabel.Text = 'Brak udanych operacji na tym komputerze.'
            $script:Controls.StatusLabel.Text = 'Gotowy. Przed hostowaniem pobierz, po grze wyslij.'
        }
        if ($Status.RecoveryPending) { $script:Controls.StatusLabel.Text = 'Przerwany import. Zamknij gre; nastepna operacja najpierw przywroci spojny stan.' }
    }

    function Start-Worker([string]$Operation) {
        if ($null -ne $script:Worker) { return }
        Set-Busy $true
        $script:Controls.StatusLabel.Foreground = '#D9DADD'
        $shared = [hashtable]::Synchronized(@{ Message = 'Sprawdzanie...' })
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($Engine, $Context, $Operation, $Progress)
            . $Engine
            try {
                if ($Operation -eq 'Status') { return @{ OK = $true; Status = (Get-SyncStatus $Context); Result = $null } }
                $result = Invoke-WorldSync $Context $Operation $Progress -Confirmed
                return @{ OK = $true; Status = (Get-SyncStatus $Context); Result = $result }
            } catch { return @{ OK = $false; Message = $_.Exception.Message; Status = (Get-SyncStatus $Context); Result = $null } }
        }).AddArgument((Join-Path $PSScriptRoot 'engine\Sync.ps1')).AddArgument($script:Context).AddArgument($Operation).AddArgument($shared)
        try {
            $handle = $ps.BeginInvoke()
            $script:Worker = @{ PowerShell = $ps; Handle = $handle; Progress = $shared; Operation = $Operation }
            $script:Timer.Start()
        } catch { $ps.Dispose(); Set-Busy $false; throw }
    }

    $script:Timer.Add_Tick({
        if ($null -eq $script:Worker) { return }
        $script:Controls.StatusLabel.Text = $script:Worker.Progress.Message
        if (-not $script:Worker.Handle.IsCompleted) { return }
        $script:Timer.Stop()
        $worker = $script:Worker
        try {
            $values = @($worker.PowerShell.EndInvoke($worker.Handle))
            # The structured result owns success/failure. HadErrors can be set by
            # a suppressed diagnostic even when the worker returned a valid result.
            if ($values.Count -eq 0) {
                $details = ($worker.PowerShell.Streams.Error | Out-String).Trim()
                if (-not $details) { $details = 'Operacja nie zwrocila wyniku. Sprawdz gui-error.log.' }
                throw $details
            }
            $value = $values[-1]
            Update-Status $value.Status
            if (-not $value.OK) {
                $script:Controls.StatusLabel.Text = $value.Message
                $script:Controls.StatusLabel.Foreground = '#E3B6AF'
                [void][Windows.MessageBox]::Show($script:Window, $value.Message, 'Synchronizacja zablokowana', 'OK', 'Warning')
            } elseif ($null -ne $value.Result) {
                $resultTime = [DateTimeOffset]::Parse($value.Result.CompletedUtc).ToLocalTime().ToString('HH:mm:ss')
                $script:Controls.StatusLabel.Text = "$($value.Result.Operation) · $resultTime`n$($value.Result.Message)"
            }
        } catch {
            Show-UiError $_
        } finally { $worker.PowerShell.Dispose(); $script:Worker = $null; Set-Busy $false }
    })
    $script:Controls.DownloadButton.Add_Click({
        try {
            $script:Controls.StatusLabel.Text = 'Download: oczekiwanie na potwierdzenie...'
            $message = "Pobrac najnowszy kompletny ZIP dla '$($script:Context.WorldName)'?`n`nZastapi lokalny swiat. Przed podmiana zostanie utworzony i sprawdzony backup. Starsze archiwum zostanie zablokowane.`n`nZamknij gre i upewnij sie, ze Drive zakonczyl synchronizacje."
            $answer = [Windows.MessageBox]::Show($script:Window, $message, 'Download World', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
            if ($answer -eq [Windows.MessageBoxResult]::Yes) { Start-Worker Download }
            else { $script:Controls.StatusLabel.Text = 'Anulowano pobieranie. Niczego nie zmieniono.' }
        } catch { Show-UiError $_ }
    })
    $script:Controls.UploadButton.Add_Click({ try { Start-Worker Upload } catch { Show-UiError $_ } })
    $script:Controls.MinimizeButton.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $script:Controls.MaximizeButton.Add_Click({ $script:Window.WindowState = if ($script:Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
    $script:Controls.CloseButton.Add_Click({ $script:Window.Close() })
    $script:Window.Add_Closing({ param($sender,$eventArgs)
        if ($null -ne $script:Worker) { $eventArgs.Cancel = $true; $script:Controls.StatusLabel.Text = 'Operacja trwa. Poczekaj na jej zakonczenie przed zamknieciem.' }
    })
    function Open-Settings {
        if ($null -ne $script:Worker) { return }
        $script:Controls.WorldInput.Text = $script:Context.WorldName
        $script:Controls.DriveInput.Text = $script:Context.DriveFolder
        $script:Controls.SettingsError.Text = ''
        $script:Controls.WorldPathLabel.Text = $script:Context.LocalWorld
        $script:Controls.MainView.Visibility = 'Collapsed'
        $script:Controls.SettingsView.Visibility = 'Visible'
        [void]$script:Controls.WorldInput.Focus()
    }
    function Close-Settings {
        $script:Controls.SettingsView.Visibility = 'Collapsed'
        $script:Controls.MainView.Visibility = 'Visible'
        [void]$script:Controls.SettingsButton.Focus()
    }
    $script:Controls.SettingsButton.Add_Click({ Open-Settings })
    $script:Controls.WorldSettingsButton.Add_Click({ Open-Settings })
    $script:Controls.CancelSettingsButton.Add_Click({ Close-Settings })
    $script:Controls.BrowseButton.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description = 'Wspolny folder VALHEIM w Google Drive for desktop'
            $dialog.SelectedPath = $script:Controls.DriveInput.Text
            if ($dialog.ShowDialog() -eq 'OK') { $script:Controls.DriveInput.Text = $dialog.SelectedPath }
        } finally { $dialog.Dispose() }
    })
    $script:Controls.BackupsButton.Add_Click({
        try { Assert-NoLinks $script:Context.BackupDir; [IO.Directory]::CreateDirectory($script:Context.BackupDir) | Out-Null; Start-Process explorer.exe -ArgumentList ('"' + $script:Context.BackupDir + '"') }
        catch { $script:Controls.SettingsError.Text = $_.Exception.Message }
    })
    $script:Controls.SaveSettingsButton.Add_Click({
        try {
            $config = [pscustomobject]@{ worldName = $script:Controls.WorldInput.Text.Trim(); driveFolder = $script:Controls.DriveInput.Text.Trim().Trim('"') }
            $next = New-SyncContext $config -AppDataDir $AppDataDir
            Save-Configuration $next
            $script:Context = $next
            Close-Settings
            Start-Worker Status
        } catch { $script:Controls.SettingsError.Text = $_.Exception.Message }
    })
    $script:Window.Add_PreviewKeyDown({ param($sender,$eventArgs)
        if ($eventArgs.Key -eq 'Escape' -and $script:Controls.SettingsView.Visibility -eq 'Visible') { Close-Settings; $eventArgs.Handled = $true }
        if ($eventArgs.Key -eq 'OemComma' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { Open-Settings; $eventArgs.Handled = $true }
    })
    $script:Window.Add_ContentRendered({ Start-Worker Status })
    [void]$script:Window.ShowDialog()
} catch {
    [void][Windows.MessageBox]::Show($_.Exception.Message, 'Valheim Save Manager - blad uruchomienia', 'OK', 'Error')
    exit 1
}
