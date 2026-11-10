# Services_Requirements.psm1   (BASE TIER)
#
# Declare what a tab (or feature) needs on the machine it runs on, so a missing
# dependency shows as a plain message instead of a confusing error later.
#
#   if (-not (Register-AppRequirement -App $App -Page $Page -For 'User Lookup' -Module 'ActiveDirectory' `
#             -Hint 'Install RSAT: Active Directory module.')) { return }
#
# Call it at the top of the tab's New-<Tab> function - that runs at start-up,
# even for lazy tabs - and return when it says $false.
#
#   -Module <name>          a PowerShell module that must be installed
#     [-MinimumVersion v]   ... at least this version
#   -Command <name>         a command or program that must be found (Get-Command:
#                           cmdlets, functions, EXEs on the PATH)
#   -For <feature>          what needs it (shown in the message and the log)
#   -Hint <text>            how to fix it (shown when it is missing)
#   -Page <TabPage>         when missing: a message band is added to the page
#
# Each module / command is checked ONCE per run (cached) and logged in
# Session.log:  [Requirements] OK ActiveDirectory 1.0.1.0 (User Lookup)
#           or  [Requirements] MISSING ActiveDirectory - needed by User Lookup ...
#
#   Get-AppRequirementStatus     every requirement checked this run (For, Kind,
#                                Name, Ok, Found, Message) - e.g. for an About page.

$script:RequirementCache = @{}      # 'Module:name' / 'Command:name' -> found version / path ('' = missing)
$script:RequirementLog   = New-Object System.Collections.ArrayList

function Register-AppRequirement {
    [CmdletBinding(DefaultParameterSetName = 'Module')]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)] [string]$For,
        [Parameter(Mandatory, ParameterSetName = 'Module')]  [string]$Module,
        [Parameter(ParameterSetName = 'Module')]             [string]$MinimumVersion = '',
        [Parameter(Mandatory, ParameterSetName = 'Command')] [string]$Command,
        [string]$Hint = '',
        $Page = $null
    )
    $kind = $PSCmdlet.ParameterSetName
    $name = $(if ($kind -eq 'Module') { $Module } else { $Command })
    $key  = $kind + ':' + $name.ToLowerInvariant()

    # ---- find it (once per run) ----
    if (-not $script:RequirementCache.ContainsKey($key)) {
        $found = ''
        try {
            if ($kind -eq 'Module') {
                $m = @(Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
                if ($m.Count -gt 0) { $found = [string]$m[0].Version }
            }
            else {
                $c = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($c) { $found = $(if ($c.Path) { [string]$c.Path } elseif ($c.Version) { [string]$c.Version } else { [string]$c.CommandType }) }
            }
        }
        catch { $found = '' }
        $script:RequirementCache[$key] = $found
    }
    $found = [string]$script:RequirementCache[$key]

    # ---- judge it ----
    $ok = ($found -ne '')
    $why = ''
    if (-not $ok) {
        $why = $(if ($kind -eq 'Module') { "The PowerShell module '$name' is not installed on this machine." }
                 else { "'$name' was not found on this machine." })
    }
    elseif ($kind -eq 'Module' -and $MinimumVersion) {
        $have = $null; $need = $null
        if ([version]::TryParse($found, [ref]$have) -and [version]::TryParse($MinimumVersion, [ref]$need) -and $have -lt $need) {
            $ok = $false
            $why = "The PowerShell module '$name' is version $found; $MinimumVersion or later is needed."
        }
    }

    # ---- log once per (feature, requirement) ----
    $logKey = $For + '|' + $key + '|' + $MinimumVersion
    $already = $false
    foreach ($r in $script:RequirementLog) { if ($r.LogKey -eq $logKey) { $already = $true; break } }
    if (-not $already) {
        [void]$script:RequirementLog.Add([pscustomobject]@{
            LogKey = $logKey; For = $For; Kind = $kind; Name = $name; Ok = $ok; Found = $found
            Message = $(if ($ok) { '' } else { $why })
        })
        try {
            if ($ok) { $App.Log('INFO', 'Requirements', "OK $name $found ($For)") }
            else     { $App.Log('WARN', 'Requirements', "MISSING $name - needed by $For. $why $Hint".Trim()) }
        } catch { }
    }

    # ---- tell the user on the page ----
    if (-not $ok -and $Page) {
        $band = New-Object System.Windows.Forms.Label
        $band.Dock = 'Top'; $band.AutoSize = $false; $band.Height = 64
        $band.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)
        $band.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 206)
        $band.ForeColor = [System.Drawing.Color]::FromArgb(110, 70, 0)
        $band.Text = "$For is not available on this machine.`r`n$why" + $(if ($Hint) { "`r`n$Hint" } else { '' })
        $Page.Controls.Add($band)
        $band.BringToFront()
    }
    return $ok
}

function Get-AppRequirementStatus {
    [CmdletBinding()]
    param()
    foreach ($r in $script:RequirementLog) {
        [pscustomobject]@{ For = $r.For; Kind = $r.Kind; Name = $r.Name; Ok = $r.Ok; Found = $r.Found; Message = $r.Message }
    }
}
