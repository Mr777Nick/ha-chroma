<#
.SYNOPSIS
    Allow Home Assistant (or any LAN device) to reach the Chroma SDK LAN proxy.

.DESCRIPTION
    The Razer Chroma SDK only serves local clients (HTTP.sys answers remote
    requests to http://localhost:54235/ with 400 or 403), so opening port 54235
    or the SDK session ports in the firewall does not help. Remote clients go
    through scripts/chroma-proxy.ps1 instead, which listens on a single port
    (default 54236) for both the SDK entry point and the session.

    This script creates one inbound rule for that port, limited to the given
    remote address(es). It also removes rules created by older versions of
    this script.

    Run it from an elevated PowerShell on the PC with the Razer devices.

.PARAMETER RemoteAddress
    Who is allowed to connect. Use your Home Assistant IP (recommended), or the
    default "LocalSubnet" to allow every device on the local network.

.PARAMETER Port
    Port of the LAN proxy.

.PARAMETER Remove
    Remove the rules created by this script.

.EXAMPLE
    .\chroma-firewall.ps1 -RemoteAddress 192.168.0.20

.EXAMPLE
    .\chroma-firewall.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string[]]$RemoteAddress = @("LocalSubnet"),
    [int]$Port = 54236,
    [switch]$Remove
)

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$group = "Razer Chroma SDK (Home Assistant)"

Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) {
    Write-Host "Removed firewall rules in group '$group'."
    return
}

New-NetFirewallRule -Group $group -DisplayName "Chroma SDK LAN proxy (TCP $Port)" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress $RemoteAddress -Profile "Private,Domain" | Out-Null

Write-Host "Allowed TCP $Port from: $($RemoteAddress -join ', ')"
Write-Host "Note: the network profile must be Private or Domain. Current profile(s):"
Get-NetConnectionProfile | Format-Table InterfaceAlias, NetworkCategory -AutoSize
