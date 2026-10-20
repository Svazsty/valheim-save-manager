# Runs INSIDE the tested WPF dispatcher; invokes controls as integration tests,
# not external UI Automation. Native mouse/physical multi-monitor acceptance remains manual.
$script:GuiResults=New-Object 'System.Collections.Generic.List[string]'
$script:GuiPhase=0
$script:GuiTicks=0
$script:GuiTimer=New-Object Windows.Threading.DispatcherTimer
$script:GuiTimer.Interval=[TimeSpan]::FromMilliseconds(200)
$script:GuiProject=Split-Path -Parent $PSScriptRoot
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VsmTestVisibility {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
function Assert-Gui($Value,[string]$Message) { if (-not $Value) { throw $Message }; $script:GuiResults.Add($Message) }
function Click-TestControl([string]$Name) { $script:Controls[$Name].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
function Save-GuiImage([string]$Name,[int]$Dpi=96) {
    $script:Window.UpdateLayout()
    $scale=$Dpi/96.0
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($script:Window.ActualWidth*$scale),[int]($script:Window.ActualHeight*$scale),$Dpi,$Dpi,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($script:Window)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $script:GuiProject ('test-results\'+$Name)))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
function Finish-GuiTest([bool]$Passed,[string]$Detail) {
    $script:GuiTimer.Stop()
    Write-JsonAtomic (Join-Path $script:GuiProject 'test-results\gui.json') @{passed=$Passed;detail=$Detail;utc=[DateTime]::UtcNow.ToString('o');powershell=$PSVersionTable.PSVersion.ToString();checks=$script:GuiResults.ToArray();syntheticDataOnly=$true;processQueryMocked=$true;nativeMouseTested=$false;physicalDpiSwitchTested=$false}
    $script:Window.Close()
}
$script:GuiTimer.Add_Tick({
    try {
        $script:GuiTicks++
        if ($script:GuiTicks -gt 300) { throw 'GUI integration test timed out.' }
        if ($null -ne $script:Worker) { return }
        switch ($script:GuiPhase) {
            0 {
                $handle=(New-Object Windows.Interop.WindowInteropHelper($script:Window)).Handle
                Assert-Gui ([VsmTestVisibility]::IsWindowVisible($handle)) 'Native WPF window is visible'
                Assert-Gui (-not [VsmTestVisibility]::IsWindowVisible([VsmTestVisibility]::GetConsoleWindow())) 'PowerShell console is not visible'
                Assert-Gui ($script:Controls.LocalLabel.Text -match 'kompletny') 'Startup status from asynchronous engine'
                $typeface=New-Object Windows.Media.Typeface($script:Window.FontFamily,[Windows.FontStyles]::Normal,[Windows.FontWeights]::Normal,[Windows.FontStretches]::Normal)
                $glyph=$null
                Assert-Gui ($typeface.TryGetGlyphTypeface([ref]$glyph) -and $glyph.FamilyNames.Values -contains 'Onest') 'Bundled Onest resolved by native WPF'
                Save-GuiImage 'main-100.png'
                Save-GuiImage 'main-150.png' 144
                $savedStatus=$script:Controls.StatusLabel.Text
                $script:Controls.StatusLabel.Text=('ZIP umieszczony w folderze Google Drive. Poczekaj na zakończenie synchronizacji. ' * 14) + ('VALHEIM_NewWorld_20261020T123456789Z_TEST.zip ' * 8)
                $script:Window.UpdateLayout()
                $scroll=$script:Window.FindName('StatusScroll')
                Assert-Gui ($scroll.ComputedVerticalScrollBarVisibility -eq 'Visible') 'Long status displays the dark vertical scrollbar'
                Assert-Gui ($scroll.ComputedHorizontalScrollBarVisibility -ne 'Visible' -and $scroll.ScrollableWidth -eq 0) 'Long status wraps without horizontal scrolling'
                $bar=$scroll.Template.FindName('PART_VerticalScrollBar',$scroll)
                $bar.ApplyTemplate() | Out-Null
                $track=$bar.Template.FindName('PART_Track',$bar)
                Assert-Gui ($null -ne $track -and $bar.ActualWidth -eq 12) "Compact custom scrollbar template is applied (width=$($bar.ActualWidth), styled=$($null -ne $bar.Style))"
                $scroll.ScrollToVerticalOffset(40)
                $script:Window.UpdateLayout()
                Assert-Gui ($scroll.VerticalOffset -gt 0) 'Status remains scrollable with custom theme'
                $scroll.ScrollToTop()
                $script:Window.UpdateLayout()
                Save-GuiImage 'scrollbar.png'
                Save-GuiImage 'scrollbar-150.png' 144
                $script:Controls.StatusLabel.Text=$savedStatus
                $script:Window.UpdateLayout()
                Click-TestControl WorldSettingsButton
                Assert-Gui ($script:Controls.SettingsView.Visibility -eq 'Visible') 'World card opens Settings'
                $script:Controls.WorldInput.Text='../unsafe'
                Click-TestControl SaveSettingsButton
                Assert-Gui ($script:Controls.SettingsError.Text.Length -gt 0 -and $script:Controls.SettingsView.Visibility -eq 'Visible') 'Invalid settings rejected and editor retained'
                $script:Controls.WorldInput.Text='NewWorld'
                Save-GuiImage 'settings.png'
                Click-TestControl SaveSettingsButton
                Assert-Gui ($script:Controls.SettingsView.Visibility -eq 'Collapsed') 'Valid settings saved through shared engine'
                $script:GuiPhase=1
            }
            1 {
                Click-TestControl UploadButton
                Assert-Gui (-not $script:Controls.DownloadButton.IsEnabled -and -not $script:Controls.UploadButton.IsEnabled -and -not $script:Controls.SettingsButton.IsEnabled) 'Sync disables actions while worker runs'
                $script:Window.Close()
                Assert-Gui $script:Window.IsLoaded 'Close blocked while sync is running'
                $script:GuiPhase=2
            }
            2 {
                $history=(Get-SyncStatus $script:Context).History
                Assert-Gui ($history.lastSuccess.Operation -eq 'Upload') 'Upload button completed real synthetic ZIP operation'
                Assert-Gui ($script:Controls.StatusLabel.Text -match 'Poczekaj') 'UI states Drive cloud synchronization is unconfirmed'
                $script:GuiFingerprint=(Get-WorldSnapshot $script:Context.LocalWorld).Fingerprint
                # Explicit confirmation is supplied by this test harness. The real download
                # button retains the native Yes/No confirmation, default No.
                Start-Worker Download
                $script:GuiPhase=3
            }
            3 {
                $history=(Get-SyncStatus $script:Context).History
                Assert-Gui ($history.lastSuccess.Operation -eq 'Download') 'Download worker imported synthetic world'
                Assert-Gui ((Get-WorldSnapshot $script:Context.LocalWorld).Fingerprint -ceq $script:GuiFingerprint) 'Download roundtrip preserved all synthetic bytes'
                Assert-Gui ([IO.Directory]::Exists($history.lastSuccess.Backup)) 'Download created a verified backup'
                Assert-Gui ($script:Controls.SuccessLabel.Text -match 'Download' -and $script:Controls.DownloadButton.IsEnabled) 'Completion updates history and reenables controls'
                Save-GuiImage 'complete.png'
                Click-TestControl MaximizeButton
                Assert-Gui ($script:Window.WindowState -eq 'Maximized') 'Green traffic-light button maximizes window'
                Click-TestControl MaximizeButton
                Assert-Gui ($script:Window.WindowState -eq 'Normal') 'Green traffic-light button restores window'
                Click-TestControl MinimizeButton
                Assert-Gui ($script:Window.WindowState -eq 'Minimized') 'Yellow traffic-light button minimizes window'
                $script:Window.WindowState='Normal'
                Finish-GuiTest $true 'Native WPF integration checks passed; physical mouse and monitor-DPI switch remain manual.'
            }
        }
    } catch { Finish-GuiTest $false $_.Exception.Message }
})
$script:GuiTimer.Start()
