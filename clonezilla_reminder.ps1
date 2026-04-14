# ===== IMPORTS =====
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ===== CONFIGURATION =====
$basePath    = "C:\Scripts"
$stateFile   = "$basePath\ClonezillaReminder.json"
$logFile     = "$basePath\ClonezillaBackupHistory.log"
$usbLabel    = "CLONEZILLA"
$backupLabel = "External"
$minFreeGB   = 250

# ======================================================
# [TEST MODE]
#   Set $true to enable a test override
#   Set $false for production use
# ======================================================
$TEST_SkipScheduleCheck = $false
$TEST_SkipReboot        = $false
$TEST_ForceFirstRun     = $false
$TEST_FakeDevices       = $false
# ======================================================

# ===== HELPER FUNCTIONS =====

function Get-VolumeByLabel($label) {
    Get-Volume | Where-Object { $_.FileSystemLabel -eq $label }
}

function Save-State($state) {
    $obj = @{
        LastBackup = if ($state.LastBackup) { $state.LastBackup.ToString("yyyy-MM-dd HH:mm") } else { $null }
        NextRun    = if ($state.NextRun)    { $state.NextRun.ToString("yyyy-MM-dd HH:mm") }    else { $null }
    }

    $obj | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
}

function Read-JsonDate($val) {
    if ($null -eq $val -or $val -eq "") { return $null }

    if ($val -match '/Date\((\d+)\)/') {
        $epoch = [datetime]"1970-01-01T00:00:00Z"
        return $epoch.AddMilliseconds([double]$matches[1]).ToLocalTime()
    }

    try { return [datetime]::ParseExact($val, "yyyy-MM-dd HH:mm", $null) } catch {}
    try { return [datetime]$val } catch {}

    return $null
}

function Get-NextSaturday([datetime]$from) {
    $daysUntilSat = (6 - [int]$from.DayOfWeek + 7) % 7
    return $from.Date.AddDays($daysUntilSat)
}

function Get-NextBackupDate {
    $target = (Get-Date).AddMonths(2)
    return Get-NextSaturday $target
}

function Show-CustomDateDialog($ownerWindow) {
    [xml]$dialogXaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Set Reminder"
    Height="220"
    Width="420"
    WindowStartupLocation="CenterOwner"
    ResizeMode="NoResize"
    Background="#1e1e1e"
    ShowInTaskbar="False"
    Topmost="True">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0"
                   Text="Enter reminder date"
                   Foreground="White"
                   FontSize="16"
                   FontWeight="Bold"
                   Margin="0,0,0,10"/>

        <TextBlock Grid.Row="1"
                   Text="Examples: 2026-04-15 or +10"
                   Foreground="#cccccc"
                   Margin="0,0,0,10"/>

        <TextBox Grid.Row="2"
                 Name="InputBox"
                 Height="30"
                 Text="+7"
                 Background="#2a2a2a"
                 Foreground="White"
                 BorderBrush="#555555"
                 Margin="0,0,0,10"/>

        <TextBlock Grid.Row="3"
                   Name="ErrorText"
                   Foreground="#ff8080"
                   Text=""
                   TextWrapping="Wrap"
                   Margin="0,0,0,10"/>

        <WrapPanel Grid.Row="4" HorizontalAlignment="Right">
            <Button Name="OkBtn" Content="OK" Width="80" Height="32" Margin="5"/>
            <Button Name="CancelBtn" Content="Cancel" Width="80" Height="32" Margin="5"/>
        </WrapPanel>
    </Grid>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXaml
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)

    $dialog.Owner = $ownerWindow
    $dialog.Topmost = $true

    $inputBox  = $dialog.FindName("InputBox")
    $errorText = $dialog.FindName("ErrorText")
    $okBtn     = $dialog.FindName("OkBtn")
    $cancelBtn = $dialog.FindName("CancelBtn")

    $script:DialogResultValue = $null

    $okAction = {
        $value = $inputBox.Text.Trim()

        try {
            if ($value -match '^\+?(\d+)$') {
                $script:DialogResultValue = (Get-Date).Date.AddDays([int]$matches[1])
            }
            else {
                $script:DialogResultValue = ([datetime]::Parse($value)).Date
            }

            $dialog.DialogResult = $true
            $dialog.Close()
        }
        catch {
            $errorText.Text = "Invalid value. Use format: 2026-04-15 or +10"
        }
    }

    $okBtn.Add_Click($okAction)

    $cancelBtn.Add_Click({
        $dialog.DialogResult = $false
        $dialog.Close()
    })

    $inputBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq "Enter") {
            & $okAction
        }
    })

    $dialog.Add_ContentRendered({
        $inputBox.Focus()
        $inputBox.SelectAll()
    })

    [void]$dialog.ShowDialog()
    return $script:DialogResultValue
}

# ===== LOAD STATE =====
$firstRun = $false

if ($TEST_ForceFirstRun) {
    Write-Host "[TEST] Forcing first run — ignoring existing state file." -ForegroundColor Yellow
    $state = @{
        LastBackup = $null
        NextRun    = $null
    }
    $firstRun = $true
    Save-State $state
}
elseif (Test-Path $stateFile) {
    $raw = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state = @{
        LastBackup = Read-JsonDate $raw.LastBackup
        NextRun    = Read-JsonDate $raw.NextRun
    }
}
else {
    $state = @{
        LastBackup = $null
        NextRun    = $null
    }
    $firstRun = $true
    Save-State $state
}

$now = Get-Date

# ===== SCHEDULE CHECK =====
if (-not $TEST_SkipScheduleCheck) {
    if (-not $firstRun -and $state.NextRun -ne $null -and $now.Date -lt $state.NextRun.Date) {
        exit
    }
}
else {
    Write-Host "[TEST] Schedule check skipped — window will always show." -ForegroundColor Yellow
}

# ===== LOAD BACKUP HISTORY =====
$historyText = "No history found"
if (Test-Path $logFile) {
    $historyText = (Get-Content $logFile | Select-Object -Last 5) -join "`n"
}

# ===== UI (XAML) =====
[xml]$xaml = @"
<Window 
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Clonezilla Backup" 
    Height="560" Width="720" 
    Background="#1e1e1e" 
    WindowStartupLocation="CenterScreen"
    Topmost="True"
    ShowInTaskbar="True">
<Grid Margin="15">
<StackPanel>

    <TextBlock Text="🛡️ Clonezilla Backup Manager" FontSize="20" Foreground="White" FontWeight="Bold" Margin="0,0,0,15"/>

    <TextBlock Text="Device status:" Foreground="White" FontWeight="Bold"/>
    <TextBlock Name="UsbStatus" Margin="0,0,0,5"/>
    <TextBlock Name="BackupStatus" Margin="0,0,0,10"/>

    <TextBlock Text="📅 Last backup:" Foreground="White"/>
    <TextBlock Name="LastBackupText" Foreground="#cccccc" Margin="0,0,0,5"/>

    <TextBlock Text="⏭️ Next reminder:" Foreground="White"/>
    <TextBlock Name="NextRunText" Foreground="#cccccc" Margin="0,0,0,10"/>

    <TextBlock Text="📜 History (last 5):" Foreground="White"/>
    <TextBox Name="HistoryBox" Height="100" IsReadOnly="True" Background="#2a2a2a" Foreground="#cccccc" Margin="0,0,0,15"/>

    <TextBlock Text="Instructions:" Foreground="White" FontWeight="Bold"/>
    <TextBlock Foreground="#cccccc" Margin="0,0,0,15" TextWrapping="Wrap">
        1. Plug in the Clonezilla USB drive
        <LineBreak/>
        2. Plug in the External backup drive
        <LineBreak/>
        3. Click 'Run now' — PC will reboot in 60 seconds
    </TextBlock>

    <WrapPanel HorizontalAlignment="Center">
        <Button Name="NowBtn"      Content="🚀 Run now"  Width="160" Height="40" Margin="5"/>
        <Button Name="LaterBtn"    Content="❌ Later"    Width="100" Height="40" Margin="5"/>
        <Button Name="TomorrowBtn" Content="⏳ Tomorrow" Width="100" Height="40" Margin="5"/>
        <Button Name="WeekBtn"     Content="📆 One week" Width="100" Height="40" Margin="5"/>
        <Button Name="CustomBtn"   Content="🗓️ Custom"   Width="120" Height="40" Margin="5"/>
    </WrapPanel>

</StackPanel>
</Grid>
</Window>
"@

# ===== LOAD WINDOW =====
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$window.Topmost = $true
$window.Activate() | Out-Null
$window.Focus() | Out-Null

# ===== UI UPDATE FUNCTION =====
function Update-UI {

    if ($TEST_FakeDevices) {
        $window.FindName("UsbStatus").Text       = "✔️ [TEST] Clonezilla USB (simulated)"
        $window.FindName("UsbStatus").Foreground = "Orange"
        $window.FindName("BackupStatus").Text       = "✔️ [TEST] External disk — 500 GB free (simulated)"
        $window.FindName("BackupStatus").Foreground = "Orange"
        $window.FindName("NowBtn").IsEnabled = $true
        return
    }

    $usb    = Get-VolumeByLabel $usbLabel
    $backup = Get-VolumeByLabel $backupLabel

    $usbOK    = $null -ne $usb
    $backupOK = $null -ne $backup
    $freeGB   = 0
    $spaceOK  = $false

    if ($backupOK) {
        $freeGB  = [math]::Round($backup.SizeRemaining / 1GB, 1)
        $spaceOK = $freeGB -ge $minFreeGB
    }

    $window.FindName("UsbStatus").Text       = if ($usbOK) { "✔️ Clonezilla USB connected" } else { "❌ Clonezilla USB not found" }
    $window.FindName("UsbStatus").Foreground = if ($usbOK) { "LightGreen" } else { "Red" }

    if (-not $backupOK) {
        $window.FindName("BackupStatus").Text       = "❌ External backup disk not found"
        $window.FindName("BackupStatus").Foreground = "Red"
    }
    elseif (-not $spaceOK) {
        $window.FindName("BackupStatus").Text       = "❌ External disk — not enough space ($freeGB GB / required $minFreeGB GB)"
        $window.FindName("BackupStatus").Foreground = "Red"
    }
    else {
        $window.FindName("BackupStatus").Text       = "✔️ External disk — $freeGB GB free"
        $window.FindName("BackupStatus").Foreground = "LightGreen"
    }

    $window.FindName("NowBtn").IsEnabled = ($usbOK -and $backupOK -and $spaceOK)
}

# ===== INITIALIZE LABELS =====
Update-UI
$window.FindName("LastBackupText").Text = if ($state.LastBackup) { $state.LastBackup.ToString("yyyy-MM-dd HH:mm (dddd)") } else { "No data" }
$window.FindName("NextRunText").Text    = if ($state.NextRun)    { $state.NextRun.ToString("yyyy-MM-dd HH:mm (dddd)") }    else { "Not set" }
$window.FindName("HistoryBox").Text     = $historyText

# ===== BUTTON HANDLERS =====

$window.FindName("NowBtn").Add_Click({
    $date             = Get-Date
    $state.LastBackup = $date
    $state.NextRun    = Get-NextBackupDate

    Save-State $state

    Add-Content $logFile ("$($date.ToString('yyyy-MM-dd HH:mm')) - Backup completed | Next reminder: $($state.NextRun.ToString('yyyy-MM-dd HH:mm'))")

    if (-not $TEST_SkipReboot) {
        shutdown /r /t 60
    }
    else {
        Write-Host "[TEST] Reboot skipped. NextRun set to: $($state.NextRun.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Yellow
    }

    $window.Close()
})

$window.FindName("LaterBtn").Add_Click({
    $window.Close()
})

$window.FindName("TomorrowBtn").Add_Click({
    $state.NextRun = (Get-Date).Date.AddDays(1)
    Save-State $state
    $window.Close()
})

$window.FindName("WeekBtn").Add_Click({
    $state.NextRun = (Get-Date).Date.AddDays(7)
    Save-State $state
    $window.Close()
})

$window.FindName("CustomBtn").Add_Click({
    $selectedDate = Show-CustomDateDialog $window

    if ($null -ne $selectedDate) {
        $state.NextRun = $selectedDate
        Save-State $state
        $window.Close()
    }
})

# ===== SAFETY NET =====
$window.Add_Closing({
    if ($null -eq $state.NextRun) {
        $state.NextRun = (Get-Date).Date.AddDays(7)
        Save-State $state
    }
})

# ===== REFRESH TIMER =====
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-UI })
$timer.Start()

# ===== SHOW WINDOW =====
$window.ShowDialog() | Out-Null