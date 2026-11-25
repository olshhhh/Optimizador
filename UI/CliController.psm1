<#
.SYNOPSIS
    WinForge Engine - CliController.
.DESCRIPTION
    Menú interactivo en consola y ejecutor automático de perfiles para entornos headless,
    Windows Server Core, sesiones SSH o WinPE sin soporte WPF.
#>

Set-StrictMode -Version Latest

function Show-CliBanner {
    param([Parameter(Mandatory)][PSCustomObject]$HardwareProfile)

    Clear-Host
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host '  WINFORGE ENGINE — MODO CONSOLA (CLI / HEADLESS / WINPE)' -ForegroundColor White
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host ("  OS      : {0} ({1} Build {2})" -f $HardwareProfile.OSName, $HardwareProfile.DisplayVersion, $HardwareProfile.FullBuild) -ForegroundColor Gray
    Write-Host ("  CPU/RAM : {0} | {1} GB RAM" -f $HardwareProfile.CpuName, $HardwareProfile.TotalRamGB) -ForegroundColor Gray

    $storageColor = if ($HardwareProfile.Storage.IsHDD) { 'Red' } else { 'Green' }
    Write-Host ("  Disco C : {0}" -f $HardwareProfile.Storage.DisplayText) -ForegroundColor $storageColor

    $chassisColor = if ($HardwareProfile.Chassis.IsLaptop) { 'Yellow' } else { 'Gray' }
    Write-Host ("  Chasis  : {0} | Plan Energía: {1}" -f $HardwareProfile.Chassis.FormFactor, $HardwareProfile.ActivePowerPlan) -ForegroundColor $chassisColor
    Write-Host '==========================================================================' -ForegroundColor Cyan
}

function Invoke-CliBatchApply {
    param(
        [hashtable]$Config,
        [PSCustomObject[]]$TweaksToApply,
        [string]$Label
    )

    $allowed = @($TweaksToApply | Where-Object { $_.GuardStatus -ne 'Blocked' })
    $blocked = @($TweaksToApply | Where-Object { $_.GuardStatus -eq 'Blocked' })

    foreach ($b in $blocked) {
        Write-Host "[BLOQUEADO] $($b.name) -> $($b.GuardReason)" -ForegroundColor Red
    }

    if ($allowed.Count -eq 0) {
        Write-Host '[WinForge] No hay ajustes elegibles para aplicar tras evaluar guardrails.' -ForegroundColor Yellow
        return
    }

    $nonMaint = @($allowed | Where-Object { $_.category -ne 'Maintenance' })
    if ($nonMaint.Count -gt 0) {
        Write-Host '[Seguridad] Creando Punto de Restauración y exportando claves .reg...' -ForegroundColor Cyan
        $session = New-WinForgeBackupSession -BackupRoot $Config.BackupRoot -TweaksToApply $nonMaint -SessionLabel $Label -CreateRestorePoint
        Write-Host "  -> $($session.RestorePoint.Message)" -ForegroundColor Gray
        Write-Host "  -> Respaldos en: $($session.SessionDir)" -ForegroundColor Gray
    }

    foreach ($tw in $allowed) {
        if ($tw.GuardStatus -eq 'Warning') {
            Write-Host "[ADVERTENCIA] $($tw.name): $($tw.GuardReason)" -ForegroundColor DarkYellow
        }
        Write-Host "[Aplicando] $($tw.name)..." -ForegroundColor White
        $res = Invoke-WinForgeTweakApply -Tweak $tw
        $color = if ($res.Success) { 'Green' } else { 'Red' }
        Write-Host "  -> $($res.Message)" -ForegroundColor $color
    }
}

function Start-WinForgeCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [PSCustomObject]$HardwareProfile,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$Tweaks,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [string]$AutoProfile = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($AutoProfile)) {
        $prof = $Profiles | Where-Object { $_.id -eq $AutoProfile -or $_.name -eq $AutoProfile } | Select-Object -First 1
        if ($null -eq $prof) {
            throw "Perfil '$AutoProfile' no encontrado en profiles.json."
        }
        Show-CliBanner -HardwareProfile $HardwareProfile
        Write-Host "[Auto-Perfil] Aplicando perfil '$($prof.name)'..." -ForegroundColor Cyan
        $batch = @($Tweaks | Where-Object { $prof.tweakIds -contains $_.id })
        Invoke-CliBatchApply -Config $Config -TweaksToApply $batch -Label "CLI_$($prof.id)"
        return
    }

    $running = $true
    while ($running) {
        Show-CliBanner -HardwareProfile $HardwareProfile
        Write-Host "`n  [1] Auditar y listar todos los ajustes (Transparencia completa)" -ForegroundColor White
        Write-Host '  [2] Aplicar un Perfil Preconfigurado (Gaming / Trabajo / Laptop / Extremo)' -ForegroundColor White
        Write-Host '  [3] Aplicar ajuste individual por ID' -ForegroundColor White
        Write-Host '  [4] Ejecutar tareas de Mantenimiento (DISM / SFC / Temp / Iconos)' -ForegroundColor White
        Write-Host '  [5] Deshacer Todo / Revertir última sesión (Rollback)' -ForegroundColor Red
        Write-Host '  [0] Salir' -ForegroundColor DarkGray

        $choice = Read-Host "`nSelecciona una opción"

        switch ($choice) {
            '1' {
                foreach ($tw in $Tweaks) {
                    $st = if ($tw.GuardStatus -eq 'Blocked') { 'BLOQUEADO' } else { (Get-WinForgeTweakStatus -Tweak $tw).Label }
                    $col = switch ($st) {
                        'BLOQUEADO' { 'Red' }
                        'Aplicado'  { 'Green' }
                        default     { 'Yellow' }
                    }
                    Write-Host ("`n[{0}] {1} ({2}) - Estado: {3}" -f $tw.id, $tw.name, $tw.category, $st) -ForegroundColor $col
                    Write-Host "  Qué hace  : $($tw.description)" -ForegroundColor Gray
                    Write-Host "  Beneficio : $($tw.benefit)" -ForegroundColor Cyan
                    Write-Host "  Desventaja: $($tw.sideEffect)" -ForegroundColor DarkYellow
                    if ($tw.GuardReason) {
                        Write-Host "  Guardrail : $($tw.GuardReason)" -ForegroundColor Red
                    }
                }
                Read-Host "`nPresiona ENTER para volver al menú"
            }
            '2' {
                Write-Host "`nPerfiles disponibles:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $Profiles.Count; $i++) {
                    Write-Host ("  [{0}] {1} - {2}" -f ($i + 1), $Profiles[$i].name, $Profiles[$i].description)
                }
                $pSel = Read-Host 'Número de perfil'
                $idx = 0
                if ([int]::TryParse($pSel, [ref]$idx) -and $idx -ge 1 -and $idx -le $Profiles.Count) {
                    $prof = $Profiles[$idx - 1]
                    $batch = @($Tweaks | Where-Object { $prof.tweakIds -contains $_.id })
                    Invoke-CliBatchApply -Config $Config -TweaksToApply $batch -Label "CLI_$($prof.id)"
                }
                Read-Host "`nPresiona ENTER para continuar"
            }
            '3' {
                $tid = Read-Host 'Introduce el ID exacto del ajuste (ej. PRIV_DIAGTRACK)'
                $tw = $Tweaks | Where-Object { $_.id -eq $tid.Trim() } | Select-Object -First 1
                if ($null -eq $tw) {
                    Write-Host 'ID no encontrado.' -ForegroundColor Red
                }
                else {
                    Invoke-CliBatchApply -Config $Config -TweaksToApply @($tw) -Label "CLI_$($tw.id)"
                }
                Read-Host "`nPresiona ENTER para continuar"
            }
            '4' {
                $maint = @($Tweaks | Where-Object { $_.category -eq 'Maintenance' })
                for ($i = 0; $i -lt $maint.Count; $i++) {
                    Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $maint[$i].name, $maint[$i].description)
                }
                $mSel = Read-Host 'Selecciona tarea (o 0 para cancelar)'
                $mIdx = 0
                if ([int]::TryParse($mSel, [ref]$mIdx) -and $mIdx -ge 1 -and $mIdx -le $maint.Count) {
                    $res = Invoke-WinForgeTweakApply -Tweak $maint[$mIdx - 1]
                    Write-Host $res.Message -ForegroundColor Green
                }
                Read-Host "`nPresiona ENTER para continuar"
            }
            '5' {
                $confirm = Read-Host '¿Seguro que deseas revertir los cambios de la última sesión? (S/N)'
                if ($confirm -match '^[SsYy]') {
                    $null = Invoke-WinForgeRollback -BackupRoot $Config.BackupRoot -AllTweaks $Tweaks -LogCallback {
                        param($m) Write-Host $m -ForegroundColor Cyan
                    }
                }
                Read-Host "`nPresiona ENTER para continuar"
            }
            '0' {
                $running = $false
            }
        }
    }
}

Export-ModuleMember -Function @('Start-WinForgeCli')
