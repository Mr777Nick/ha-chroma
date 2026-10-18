<#
.SYNOPSIS
    System tray switch for Home Assistant's Chroma control through the LAN proxy.

.DESCRIPTION
    While Home Assistant holds a Chroma SDK session, Synapse counts it as a running
    Chroma app (AIOChroma). Its lighting engine then stops driving USB/Bluetooth
    devices, so Synapse Quick Effects and profiles only reach Wi-Fi lights, even
    when AIOChroma is switched off in Synapse.

    This tray icon pauses and resumes Home Assistant control by creating or deleting
    the proxy's pause file (see chroma-proxy.ps1 -PauseFile). Paused, the proxy
    closes the session and refuses new ones. Resumed, Home Assistant reconnects
    within a few seconds and gets its last colors back.

    Synapse 4 only checks which Chroma app is running when it starts, so after a
    pause or resume use "Restart Synapse" for the lights to switch over.

    Icon colors: green = Home Assistant connected, blue = proxy running but Home
    Assistant not connected, orange = paused, gray = proxy not running.
    Double-click the icon to pause or resume.

.PARAMETER Port
    Port the LAN proxy listens on.

.PARAMETER PauseFile
    Pause file watched by the proxy. Must match the proxy's -PauseFile.

.PARAMETER Install
    Start the tray icon at every logon (shortcut in the Startup folder) and start it now.

.PARAMETER Uninstall
    Remove the Startup shortcut. Exit a running tray icon from its menu.
#>
[CmdletBinding()]
param(
    [int]$Port = 54236,
    [string]$PauseFile = (Join-Path $env:USERPROFILE ".chroma-proxy.paused"),
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Chroma proxy tray.lnk"
$proxyScript = Join-Path $PSScriptRoot "chroma-proxy.ps1"
$proxyLog = Join-Path $env:LOCALAPPDATA "chroma-proxy.log"
$proxyTask = "Chroma SDK LAN proxy"

if ($Uninstall) {
    Remove-Item -LiteralPath $shortcutPath -ErrorAction SilentlyContinue
    Write-Host "Removed '$shortcutPath'. Exit a running tray icon from its menu."
    return
}

if ($Install) {
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -PauseFile `"$PauseFile`""
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcutPath)
    $link.TargetPath = "powershell.exe"
    $link.Arguments = $arguments
    $link.WorkingDirectory = $PSScriptRoot
    $link.WindowStyle = 7
    $link.Description = "Pause or resume Home Assistant Chroma control"
    $link.Save()
    Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden
    Write-Host "Installed '$shortcutPath' and started the tray icon."
    return
}

# One tray icon per user session
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\ChromaProxyTray", [ref]$createdNew)
if (-not $createdNew) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(160, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 1, 1, 13, 13)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$icons = @{
    Connected = New-DotIcon ([System.Drawing.Color]::FromArgb(68, 214, 44))
    Waiting   = New-DotIcon ([System.Drawing.Color]::FromArgb(60, 140, 230))
    Paused    = New-DotIcon ([System.Drawing.Color]::FromArgb(240, 150, 30))
    Stopped   = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
}

function Get-ProxyState {
    $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $listening = @($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }).Count -gt 0
    $clients = @($props.GetActiveTcpConnections() | Where-Object {
        $_.LocalEndPoint.Port -eq $Port -and
        $_.State -eq [System.Net.NetworkInformation.TcpState]::Established -and
        -not [System.Net.IPAddress]::IsLoopback($_.RemoteEndPoint.Address)
    })
    [pscustomobject]@{
        Paused    = Test-Path -LiteralPath $PauseFile
        Listening = $listening
        Connected = $clients.Count -gt 0
    }
}

function Start-Proxy {
    try {
        Start-ScheduledTask -TaskName $proxyTask -ErrorAction Stop
    }
    catch {
        # The task may need admin rights to start; run the proxy directly instead.
        # The task's own 5-minute trigger then fails to bind the port and exits.
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
            "-File", "`"$proxyScript`"", "-Port", $Port, "-LogFile", "`"$proxyLog`"",
            "-PauseFile", "`"$PauseFile`"")
    }
}

# Synapse's lighting engine only checks which Chroma app is running when it starts,
# so a pause or resume takes effect on the lights after a Synapse restart.
function Restart-Synapse {
    $exe = Join-Path $env:ProgramFiles "Razer\RazerAppEngine\RazerAppEngine.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    Stop-Process -Name RazerAppEngine, RzEngineMon -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Get-Process RazerAppEngine -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 500
    }
    Start-Process -FilePath $exe -ArgumentList "--url-params=apps=synapse"
    return $true
}

function Restart-Proxy {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like "*chroma-proxy.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Start-Proxy
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Enabled = $false
$toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem
$synapseItem = New-Object System.Windows.Forms.ToolStripMenuItem "Restart Synapse"
$restartItem = New-Object System.Windows.Forms.ToolStripMenuItem "Restart proxy"
$logItem = New-Object System.Windows.Forms.ToolStripMenuItem "Open proxy log"
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "Exit tray icon"
[void]$menu.Items.Add($statusItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($toggleItem)
[void]$menu.Items.Add($synapseItem)
[void]$menu.Items.Add($restartItem)
[void]$menu.Items.Add($logItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)
$notify.ContextMenuStrip = $menu

function Update-Tray {
    $s = Get-ProxyState
    if ($s.Paused) {
        $state = "Paused"; $text = "Home Assistant Chroma: paused"
    }
    elseif (-not $s.Listening) {
        $state = "Stopped"; $text = "Home Assistant Chroma: proxy not running"
    }
    elseif ($s.Connected) {
        $state = "Connected"; $text = "Home Assistant Chroma: connected"
    }
    else {
        $state = "Waiting"; $text = "Home Assistant Chroma: waiting for HA"
    }
    $notify.Icon = $icons[$state]
    $notify.Text = $text
    $statusItem.Text = $text
    $toggleItem.Text = if ($s.Paused) { "Resume Home Assistant control" } else { "Pause Home Assistant control" }
    $restartItem.Text = if ($s.Listening) { "Restart proxy" } else { "Start proxy" }
}

function Switch-Pause {
    if (Test-Path -LiteralPath $PauseFile) {
        Remove-Item -LiteralPath $PauseFile -Force
        $notify.ShowBalloonTip(3000, "Home Assistant Chroma resumed",
            "Home Assistant reconnects within a few seconds. Restart Synapse to hand it the lights.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
    else {
        New-Item -ItemType File -Path $PauseFile -Force | Out-Null
        $notify.ShowBalloonTip(3000, "Home Assistant Chroma paused",
            "Restart Synapse so its effects and profiles reach all your devices.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Update-Tray
}

$toggleItem.add_Click({ Switch-Pause })
$notify.add_DoubleClick({ Switch-Pause })
$synapseItem.add_Click({
    if (Restart-Synapse) {
        $notify.ShowBalloonTip(3000, "Restarting Synapse",
            "Your devices come back once Synapse has loaded them.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
    else {
        $notify.ShowBalloonTip(3000, "Synapse not found",
            "RazerAppEngine.exe is not in its usual folder.",
            [System.Windows.Forms.ToolTipIcon]::Warning)
    }
})
$restartItem.add_Click({ Restart-Proxy; Start-Sleep -Seconds 2; Update-Tray })
$logItem.add_Click({ if (Test-Path -LiteralPath $proxyLog) { Start-Process notepad.exe -ArgumentList "`"$proxyLog`"" } })
$exitItem.add_Click({
    $timer.Stop()
    $notify.Visible = $false
    [System.Windows.Forms.Application]::ExitThread()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({ Update-Tray })

Update-Tray
$notify.Visible = $true
$timer.Start()
[System.Windows.Forms.Application]::Run()

$notify.Dispose()
$mutex.ReleaseMutex()
