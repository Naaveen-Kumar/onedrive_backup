Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Configuration
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "backup-config.json"
$defaultBackupRootName = "OneDriveBackup"
$defaultSettings = [PSCustomObject]@{
    Sources = @()
    BackupMode = 'Manual'
    IntervalMinutes = 60
    Frequency = 'Manual'
    OneDrivePath = ''
    CleanupDays = 30
}

function Ensure-SettingsProperties($settings) {
    $changed = $false
    foreach ($property in $defaultSettings.PSObject.Properties.Name) {
        if (-not ($settings | Get-Member -Name $property -Force)) {
            $settings | Add-Member -NotePropertyName $property -NotePropertyValue $defaultSettings.$property
            $changed = $true
        }
    }
    return @{ Settings = $settings; Changed = $changed }
}

# Load saved settings or defaults
function Load-Settings {
    if (Test-Path $configFile) {
        try {
            $json = Get-Content $configFile -Raw
            $settings = ConvertFrom-Json $json
            $result = Ensure-SettingsProperties $settings
            if ($result.Changed) {
                Save-Settings $result.Settings
            }
            return $result.Settings
        } catch {
            return $defaultSettings
        }
    } else {
        return $defaultSettings
    }
}

function Save-Settings($settings) {
    $json = $settings | ConvertTo-Json -Depth 5
    $json | Set-Content -Path $configFile -Encoding UTF8
}

function Resolve-OneDrivePath {
    if ($settings.OneDrivePath -and (Test-Path $settings.OneDrivePath)) {
        return $settings.OneDrivePath
    }

    if ($env:OneDrive -and (Test-Path $env:OneDrive)) {
        return $env:OneDrive
    }

    return $null
}

function Prompt-OneDrivePath {
    $browse = New-Object System.Windows.Forms.FolderBrowserDialog
    $browse.Description = 'Select your local OneDrive folder'
    $browse.ShowNewFolderButton = $false
    if ($browse.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $settings.OneDrivePath = $browse.SelectedPath
        Save-Settings $settings
        Update-UiStatus("OneDrive path set to: $($settings.OneDrivePath)")
        $txtOneDrivePath.Text = $settings.OneDrivePath
        Update-OneDriveWarning
    }
}

function Update-OneDriveWarning {
    if (-not $settings.OneDrivePath) {
        $lblOneDriveWarning.Visible = $false
        return
    }

    if ($env:OneDrive -and (Test-Path $env:OneDrive)) {
        try {
            $manualPath = (Resolve-Path -Path $settings.OneDrivePath -ErrorAction Stop).ProviderPath
            $envPath = (Resolve-Path -Path $env:OneDrive -ErrorAction Stop).ProviderPath
            if ($manualPath -and $envPath -and $manualPath.ToLowerInvariant() -ne $envPath.ToLowerInvariant()) {
                $lblOneDriveWarning.Text = "Warning: selected OneDrive path differs from env:OneDrive."
                $lblOneDriveWarning.Visible = $true
                return
            }
        } catch {
            # ignore invalid env or manual path when resolving
        }
    }

    $lblOneDriveWarning.Visible = $false
}

function Update-SourcesListBox {
    $lstSources.Items.Clear()
    foreach ($source in $settings.Sources) {
        [void]$lstSources.Items.Add($source)
    }
}

function Update-UiStatus($message) {
    $txtStatus.Text = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message"
}

function Add-Source($path) {
    if (-not (Test-Path $path)) {
        Update-UiStatus("Source path not found: $path")
        return
    }

    $existing = $settings.Sources | Where-Object { $_ -eq $path }
    if ($existing) {
        Update-UiStatus("Path already exists in source list: $path")
        return
    }

    $settings.Sources += $path
    Save-Settings $settings
    Update-SourcesListBox
    Update-UiStatus("Added source: $path")
}

function Remove-SelectedSources {
    if ($lstSources.SelectedItems.Count -eq 0) {
        Update-UiStatus('No selected source to remove.')
        return
    }

    $itemsToRemove = @()
    foreach ($item in $lstSources.SelectedItems) {
        $itemsToRemove += $item
    }

    foreach ($source in $itemsToRemove) {
        $settings.Sources = $settings.Sources | Where-Object { $_ -ne $source }
    }

    Save-Settings $settings
    Update-SourcesListBox
    Update-UiStatus('Removed selected source(s).')
}

function Copy-ItemToOneDrive($source, $destinationRoot) {
    if (Test-Path $source -PathType Container) {
        $directoryEntries = Get-ChildItem -Path $source -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($entry in $directoryEntries) {
            $relative = $entry.FullName.Substring($source.Length).TrimStart('\')
            $targetPath = Join-Path $destinationRoot $relative
            if ($entry.PSIsContainer) {
                if (-not (Test-Path $targetPath)) {
                    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                }
            } else {
                $targetDir = Split-Path -Parent $targetPath
                if (-not (Test-Path $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                Copy-Item -Path $entry.FullName -Destination $targetPath -Force -ErrorAction Stop
            }
        }
    } else {
        $fileName = Split-Path $source -Leaf
        $targetPath = Join-Path $destinationRoot $fileName
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -Path $source -Destination $targetPath -Force -ErrorAction Stop
    }
}

function Perform-Backup {
    $oneDriveRoot = Resolve-OneDrivePath
    if (-not $oneDriveRoot) {
        Update-UiStatus('OneDrive folder not found. Please select it manually.')
        Prompt-OneDrivePath
        $oneDriveRoot = Resolve-OneDrivePath
        if (-not $oneDriveRoot) {
            Update-UiStatus('Backup cannot proceed without a valid OneDrive path.')
            return
        }
    }

    if ($settings.Sources.Count -eq 0) {
        Update-UiStatus('No sources have been selected for backup.')
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $backupFolder = "$defaultBackupRootName_$timestamp"
    $destinationRoot = Join-Path $oneDriveRoot $backupFolder
    if (-not (Test-Path $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    }

    Update-UiStatus("Backup started into: $destinationRoot")
    $progress = 0
    $totalSources = $settings.Sources.Count
    foreach ($source in $settings.Sources) {
        try {
            $sourceName = Split-Path -Leaf $source
            $targetFolder = Join-Path $destinationRoot $sourceName
            if (Test-Path $source -PathType Container) {
                Copy-ItemToOneDrive $source $targetFolder
            } else {
                Copy-ItemToOneDrive $source $destinationRoot
            }
            $progress++
            $lblProgress.Text = "Backing up $progress of $totalSources..."
            [System.Windows.Forms.Application]::DoEvents()
        } catch {
            Update-UiStatus("Error copying ${source}: $($_.Exception.Message)")
        }
    }

    Update-UiStatus('Backup completed.')
    $lblProgress.Text = 'Ready.'
}

function Cleanup-OldBackups {
    param([int]$days)

    $oneDriveRoot = Resolve-OneDrivePath
    if (-not $oneDriveRoot) {
        Update-UiStatus('OneDrive folder not found. Please select it manually before cleanup.')
        return
    }

    $cutoff = (Get-Date).AddDays(-$days)
    $folders = Get-ChildItem -Path $oneDriveRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "${defaultBackupRootName}_*" -and $_.LastWriteTime -lt $cutoff
    }

    if (-not $folders) {
        Update-UiStatus("No backup folders older than $days day(s) were found.")
        return
    }

    foreach ($folder in $folders) {
        try {
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
            Update-UiStatus("Deleted old backup folder: $($folder.Name)")
        } catch {
            Update-UiStatus("Failed to delete $($folder.Name): $($_.Exception.Message)")
        }
    }
}

function Start-Schedule {
    $settings.Frequency = $comboFrequency.SelectedItem
    if ($settings.Frequency -eq 'Manual') {
        $timer.Stop()
        Update-UiStatus('Recurring backup disabled.')
        return
    }

    switch ($settings.Frequency) {
        'Daily' { $settings.IntervalMinutes = 24 * 60 }
        'Weekly' { $settings.IntervalMinutes = 7 * 24 * 60 }
        'Custom' { $settings.IntervalMinutes = [int]$numCustomMinutes.Value }
        default { $settings.IntervalMinutes = [int]$numCustomMinutes.Value }
    }

    if ($settings.IntervalMinutes -le 0) {
        Update-UiStatus('Please select a valid interval greater than zero.')
        return
    }

    $timer.Interval = $settings.IntervalMinutes * 60 * 1000
    $timer.Start()
    Save-Settings $settings
    Update-UiStatus("Scheduled backup every $($settings.IntervalMinutes) minute(s).")
}

function On-TimerTick {
    Perform-Backup
}

# Initialize settings
$settings = Load-Settings

# Build form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'OneDrive Backup Manager'
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$lblOneDrive = New-Object System.Windows.Forms.Label
$lblOneDrive.Text = 'OneDrive folder:'
$lblOneDrive.Location = New-Object System.Drawing.Point(14, 16)
$lblOneDrive.Size = New-Object System.Drawing.Size(110, 20)
[void]$form.Controls.Add($lblOneDrive)

$txtOneDrivePath = New-Object System.Windows.Forms.TextBox
$txtOneDrivePath.Location = New-Object System.Drawing.Point(130, 12)
$txtOneDrivePath.Size = New-Object System.Drawing.Size(500, 24)
$txtOneDrivePath.ReadOnly = $true
[void]$form.Controls.Add($txtOneDrivePath)

$lblOneDriveWarning = New-Object System.Windows.Forms.Label
$lblOneDriveWarning.Location = New-Object System.Drawing.Point(130, 38)
$lblOneDriveWarning.Size = New-Object System.Drawing.Size(500, 20)
$lblOneDriveWarning.ForeColor = [System.Drawing.Color]::Red
$lblOneDriveWarning.Visible = $false
[void]$form.Controls.Add($lblOneDriveWarning)

$btnBrowseOneDrive = New-Object System.Windows.Forms.Button
$btnBrowseOneDrive.Text = 'Browse...'
$btnBrowseOneDrive.Location = New-Object System.Drawing.Point(640, 10)
$btnBrowseOneDrive.Size = New-Object System.Drawing.Size(100, 28)
[void]$form.Controls.Add($btnBrowseOneDrive)

$grpSources = New-Object System.Windows.Forms.GroupBox
$grpSources.Text = 'Backup sources'
$grpSources.Location = New-Object System.Drawing.Point(14, 50)
$grpSources.Size = New-Object System.Drawing.Size(726, 250)
[void]$form.Controls.Add($grpSources)

$lstSources = New-Object System.Windows.Forms.ListBox
$lstSources.Location = New-Object System.Drawing.Point(12, 22)
$lstSources.Size = New-Object System.Drawing.Size(700, 170)
$lstSources.SelectionMode = 'MultiExtended'
[void]$grpSources.Controls.Add($lstSources)

$btnAddFile = New-Object System.Windows.Forms.Button
$btnAddFile.Text = 'Add File'
$btnAddFile.Location = New-Object System.Drawing.Point(12, 200)
$btnAddFile.Size = New-Object System.Drawing.Size(100, 28)
[void]$grpSources.Controls.Add($btnAddFile)

$btnAddFolder = New-Object System.Windows.Forms.Button
$btnAddFolder.Text = 'Add Folder'
$btnAddFolder.Location = New-Object System.Drawing.Point(122, 200)
$btnAddFolder.Size = New-Object System.Drawing.Size(100, 28)
[void]$grpSources.Controls.Add($btnAddFolder)

$btnRemoveSource = New-Object System.Windows.Forms.Button
$btnRemoveSource.Text = 'Remove Selected'
$btnRemoveSource.Location = New-Object System.Drawing.Point(232, 200)
$btnRemoveSource.Size = New-Object System.Drawing.Size(120, 28)
[void]$grpSources.Controls.Add($btnRemoveSource)

$grpSchedule = New-Object System.Windows.Forms.GroupBox
$grpSchedule.Text = 'Schedule'
$grpSchedule.Location = New-Object System.Drawing.Point(14, 310)
$grpSchedule.Size = New-Object System.Drawing.Size(726, 160)
[void]$form.Controls.Add($grpSchedule)

$lblFrequency = New-Object System.Windows.Forms.Label
$lblFrequency.Text = 'Frequency:'
$lblFrequency.Location = New-Object System.Drawing.Point(12, 28)
$lblFrequency.Size = New-Object System.Drawing.Size(80, 20)
[void]$grpSchedule.Controls.Add($lblFrequency)

$comboFrequency = New-Object System.Windows.Forms.ComboBox
$comboFrequency.Location = New-Object System.Drawing.Point(100, 24)
$comboFrequency.Size = New-Object System.Drawing.Size(180, 24)
$comboFrequency.DropDownStyle = 'DropDownList'
[void]$comboFrequency.Items.AddRange(@('Manual','Daily','Weekly','Custom'))
[void]$grpSchedule.Controls.Add($comboFrequency)

$lblCustom = New-Object System.Windows.Forms.Label
$lblCustom.Text = 'Custom interval (minutes):'
$lblCustom.Location = New-Object System.Drawing.Point(12, 62)
$lblCustom.Size = New-Object System.Drawing.Size(180, 20)
[void]$grpSchedule.Controls.Add($lblCustom)

$numCustomMinutes = New-Object System.Windows.Forms.NumericUpDown
$numCustomMinutes.Location = New-Object System.Drawing.Point(200, 60)
$numCustomMinutes.Size = New-Object System.Drawing.Size(80, 24)
$numCustomMinutes.Minimum = 1
$numCustomMinutes.Maximum = 10080
$numCustomMinutes.Value = 60
$numCustomMinutes.Enabled = $false
[void]$grpSchedule.Controls.Add($numCustomMinutes)

$lblCleanup = New-Object System.Windows.Forms.Label
$lblCleanup.Text = 'Purge backups older than (days):'
$lblCleanup.Location = New-Object System.Drawing.Point(12, 92)
$lblCleanup.Size = New-Object System.Drawing.Size(220, 20)
[void]$grpSchedule.Controls.Add($lblCleanup)

$numCleanupDays = New-Object System.Windows.Forms.NumericUpDown
$numCleanupDays.Location = New-Object System.Drawing.Point(240, 90)
$numCleanupDays.Size = New-Object System.Drawing.Size(80, 24)
$numCleanupDays.Minimum = 1
$numCleanupDays.Maximum = 3650
$numCleanupDays.Value = 30
[void]$grpSchedule.Controls.Add($numCleanupDays)

$btnCleanupOld = New-Object System.Windows.Forms.Button
$btnCleanupOld.Text = 'Delete old backups'
$btnCleanupOld.Location = New-Object System.Drawing.Point(340, 90)
$btnCleanupOld.Size = New-Object System.Drawing.Size(150, 28)
[void]$grpSchedule.Controls.Add($btnCleanupOld)

$btnSaveSettings = New-Object System.Windows.Forms.Button
$btnSaveSettings.Text = 'Save Settings'
$btnSaveSettings.Location = New-Object System.Drawing.Point(12, 130)
$btnSaveSettings.Size = New-Object System.Drawing.Size(120, 32)
[void]$grpSchedule.Controls.Add($btnSaveSettings)

$btnBackupNow = New-Object System.Windows.Forms.Button
$btnBackupNow.Text = 'Backup Now'
$btnBackupNow.Location = New-Object System.Drawing.Point(150, 130)
$btnBackupNow.Size = New-Object System.Drawing.Size(120, 32)
[void]$grpSchedule.Controls.Add($btnBackupNow)

$btnStartSchedule = New-Object System.Windows.Forms.Button
$btnStartSchedule.Text = 'Start Schedule'
$btnStartSchedule.Location = New-Object System.Drawing.Point(288, 130)
$btnStartSchedule.Size = New-Object System.Drawing.Size(120, 32)
[void]$grpSchedule.Controls.Add($btnStartSchedule)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = 'Ready.'
$lblProgress.Location = New-Object System.Drawing.Point(12, 145)
$lblProgress.Size = New-Object System.Drawing.Size(700, 20)
[void]$grpSchedule.Controls.Add($lblProgress)

$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Location = New-Object System.Drawing.Point(14, 480)
$txtStatus.Size = New-Object System.Drawing.Size(726, 60)
$txtStatus.Multiline = $true
$txtStatus.ReadOnly = $true
$txtStatus.ScrollBars = 'Vertical'
[void]$form.Controls.Add($txtStatus)

# Timer for recurring backup
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60 * 60 * 1000
[void]$timer.Add_Tick({ On-TimerTick })

# Event handlers
[void]$btnBrowseOneDrive.Add_Click({ Prompt-OneDrivePath })

[void]$btnAddFile.Add_Click({
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Multiselect = $true
    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($file in $fileDialog.FileNames) {
            Add-Source $file
        }
    }
})

$btnAddFolder.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-Source $folderDialog.SelectedPath
    }
})

[void]$btnRemoveSource.Add_Click({ Remove-SelectedSources })

[void]$btnSaveSettings.Add_Click({
    $settings.Frequency = $comboFrequency.SelectedItem
    if ($settings.Frequency -eq 'Custom') {
        $settings.IntervalMinutes = [int]$numCustomMinutes.Value
    }
    if (-not $settings.PSObject.Properties.Match('CleanupDays')) {
        $settings | Add-Member -NotePropertyName 'CleanupDays' -NotePropertyValue 30
    }
    $settings.CleanupDays = [int]$numCleanupDays.Value
    Save-Settings $settings
    Update-UiStatus('Settings saved.')
})

[void]$btnCleanupOld.Add_Click({
    if (-not $settings.PSObject.Properties.Match('CleanupDays')) {
        $settings | Add-Member -NotePropertyName 'CleanupDays' -NotePropertyValue 30
    }
    $settings.CleanupDays = [int]$numCleanupDays.Value
    Save-Settings $settings
    Cleanup-OldBackups -days $settings.CleanupDays
})

[void]$btnBackupNow.Add_Click({ Perform-Backup })

[void]$btnStartSchedule.Add_Click({ Start-Schedule })

$comboFrequency.Add_SelectedIndexChanged({
    $numCustomMinutes.Enabled = $comboFrequency.SelectedItem -eq 'Custom'
})

# Load settings into UI
if (-not $settings.OneDrivePath -and $env:OneDrive) {
    $settings.OneDrivePath = $env:OneDrive
}

$txtOneDrivePath.Text = $settings.OneDrivePath
if ($settings.Frequency -and $comboFrequency.Items.Contains($settings.Frequency)) {
    $comboFrequency.SelectedItem = $settings.Frequency
} else {
    $comboFrequency.SelectedItem = 'Manual'
}

$numCustomMinutes.Enabled = $comboFrequency.SelectedItem -eq 'Custom'
if ($settings.IntervalMinutes -gt 0) {
    $numCustomMinutes.Value = $settings.IntervalMinutes
}

if ($settings.CleanupDays -gt 0) {
    $numCleanupDays.Value = $settings.CleanupDays
}

Update-OneDriveWarning

Update-SourcesListBox
Update-UiStatus('Ready. Load complete.')

# Run the form
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
