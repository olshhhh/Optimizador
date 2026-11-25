<#
.SYNOPSIS
    WinForge Engine - TweakEngine.
.DESCRIPTION
    Carga la base de datos de tweaks y perfiles desde JSON, evalúa el estado actual de cada
    ajuste de forma idempotente, ejecuta acciones respetando guardrails de HardwareAuditor y
    gestiona aplicaciones de inicio (Startup Apps) de forma reversible.
#>

Set-StrictMode -Version Latest

function Get-WinForgeTweaks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TweaksFilePath
    )

    if (-not (Test-Path -LiteralPath $TweaksFilePath)) {
        throw "No se encontró el archivo de tweaks: $TweaksFilePath"
    }

    $rawJson = [System.IO.File]::ReadAllText($TweaksFilePath, [System.Text.Encoding]::UTF8)
    $parsed = $rawJson | ConvertFrom-Json
    return @($parsed)
}

function Get-WinForgeProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfilesFilePath
    )

    if (-not (Test-Path -LiteralPath $ProfilesFilePath)) {
        throw "No se encontró el archivo de perfiles: $ProfilesFilePath"
    }

    $rawJson = [System.IO.File]::ReadAllText($ProfilesFilePath, [System.Text.Encoding]::UTF8)
    $parsed = $rawJson | ConvertFrom-Json
    return @($parsed)
}

function Get-WinForgeTweakStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak
    )

    if ([string]::IsNullOrWhiteSpace($Tweak.detectScript)) {
        return [PSCustomObject]@{
            IsApplied = $false
            Label     = 'Acción bajo demanda'
            Error     = $null
        }
    }

    try {
        $sb = [scriptblock]::Create($Tweak.detectScript)
        $res = [bool](& $sb)
        return [PSCustomObject]@{
            IsApplied = $res
            Label     = if ($res) { 'Aplicado' } else { 'Original' }
            Error     = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            IsApplied = $false
            Label     = 'Error de detección'
            Error     = $_.Exception.Message
        }
    }
}

function Invoke-WinForgeTweakApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak,

        [switch]$ForceIgnoreWarning
    )

    if ($Tweak.GuardStatus -eq 'Blocked') {
        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $false
            Skipped = $true
            Message = "Omitido (Bloqueado): $($Tweak.GuardReason)"
        }
    }

    try {
        if ($Tweak.category -ne 'Maintenance') {
            $preCheck = Get-WinForgeTweakStatus -Tweak $Tweak
            if ($preCheck.IsApplied) {
                $Tweak.IsApplied = $true
                $Tweak.DetectionState = 'Aplicado'
                return [PSCustomObject]@{
                    Id      = $Tweak.id
                    Name    = $Tweak.name
                    Success = $true
                    Skipped = $false
                    Message = 'Ya estaba aplicado (Idempotente).'
                }
            }
        }

        $sb = [scriptblock]::Create($Tweak.applyScript)
        $output = & $sb 2>&1 | Out-String

        if ($Tweak.category -eq 'Maintenance') {
            return [PSCustomObject]@{
                Id      = $Tweak.id
                Name    = $Tweak.name
                Success = $true
                Skipped = $false
                Message = if ([string]::IsNullOrWhiteSpace($output)) { 'Tarea de mantenimiento completada.' } else { $output.Trim() }
            }
        }

        $postCheck = Get-WinForgeTweakStatus -Tweak $Tweak
        $Tweak.IsApplied = $postCheck.IsApplied
        $Tweak.DetectionState = $postCheck.Label

        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $true
            Skipped = $false
            Message = "Aplicado correctamente. Estado actual: $($postCheck.Label)."
        }
    }
    catch {
        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $false
            Skipped = $false
            Message = "Error al aplicar: $($_.Exception.Message)"
        }
    }
}

function Invoke-WinForgeTweakRevert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak
    )

    if ($Tweak.GuardStatus -eq 'Blocked') {
        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $false
            Message = 'Este ajuste estuvo bloqueado por hardware; no requiere reversión.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($Tweak.revertScript)) {
        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $true
            Message = 'No aplica reversión para esta tarea.'
        }
    }

    try {
        $sb = [scriptblock]::Create($Tweak.revertScript)
        $null = & $sb

        $postCheck = Get-WinForgeTweakStatus -Tweak $Tweak
        $Tweak.IsApplied = $postCheck.IsApplied
        $Tweak.DetectionState = $postCheck.Label

        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $true
            Message = "Revertido correctamente. Estado actual: $($postCheck.Label)."
        }
    }
    catch {
        return [PSCustomObject]@{
            Id      = $Tweak.id
            Name    = $Tweak.name
            Success = $false
            Message = "Error al revertir: $($_.Exception.Message)"
        }
    }
}

function Get-WinForgeStartupApps {
    [CmdletBinding()]
    param()

    $locations = @(
        @{ Scope = 'Usuario (HKCU)'; ActivePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; DisabledPath = 'HKCU:\Software\WinForge\DisabledRun' },
        @{ Scope = 'Sistema (HKLM)'; ActivePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; DisabledPath = 'HKLM:\SOFTWARE\WinForge\DisabledRun' }
    )

    $list = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($loc in $locations) {
        if (Test-Path -LiteralPath $loc.ActivePath) {
            $props = Get-ItemProperty -Path $loc.ActivePath -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                    $list.Add([PSCustomObject]@{
                        Name         = $p.Name
                        Command      = [string]$p.Value
                        Scope        = $loc.Scope
                        ActivePath   = $loc.ActivePath
                        DisabledPath = $loc.DisabledPath
                        Enabled      = $true
                    })
                }
            }
        }

        if (Test-Path -LiteralPath $loc.DisabledPath) {
            $dProps = Get-ItemProperty -Path $loc.DisabledPath -ErrorAction SilentlyContinue
            if ($null -ne $dProps) {
                foreach ($p in $dProps.PSObject.Properties) {
                    if ($p.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                    $list.Add([PSCustomObject]@{
                        Name         = $p.Name
                        Command      = [string]$p.Value
                        Scope        = $loc.Scope
                        ActivePath   = $loc.ActivePath
                        DisabledPath = $loc.DisabledPath
                        Enabled      = $false
                    })
                }
            }
        }
    }

    return $list.ToArray()
}

function Set-WinForgeStartupAppState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$StartupApp,

        [Parameter(Mandatory)]
        [bool]$Enable
    )

    if ($Enable) {
        if (-not (Test-Path -LiteralPath $StartupApp.ActivePath)) {
            New-Item -Path $StartupApp.ActivePath -Force | Out-Null
        }
        Set-ItemProperty -Path $StartupApp.ActivePath -Name $StartupApp.Name -Value $StartupApp.Command -Type String
        if (Test-Path -LiteralPath $StartupApp.DisabledPath) {
            Remove-ItemProperty -Path $StartupApp.DisabledPath -Name $StartupApp.Name -ErrorAction SilentlyContinue
        }
        $StartupApp.Enabled = $true
    }
    else {
        if (-not (Test-Path -LiteralPath $StartupApp.DisabledPath)) {
            New-Item -Path $StartupApp.DisabledPath -Force | Out-Null
        }
        Set-ItemProperty -Path $StartupApp.DisabledPath -Name $StartupApp.Name -Value $StartupApp.Command -Type String
        if (Test-Path -LiteralPath $StartupApp.ActivePath) {
            Remove-ItemProperty -Path $StartupApp.ActivePath -Name $StartupApp.Name -ErrorAction SilentlyContinue
        }
        $StartupApp.Enabled = $false
    }

    return $StartupApp
}

Export-ModuleMember -Function @(
    'Get-WinForgeTweaks',
    'Get-WinForgeProfiles',
    'Get-WinForgeTweakStatus',
    'Invoke-WinForgeTweakApply',
    'Invoke-WinForgeTweakRevert',
    'Get-WinForgeStartupApps',
    'Set-WinForgeStartupAppState'
)
