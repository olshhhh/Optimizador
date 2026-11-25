<#
.SYNOPSIS
    WinForge Engine - CliController.
.DESCRIPTION
    Menú interactivo en consola, Asistente Guiado paso a paso (inspirado en APBOptimizer),
    Gestor de Aplicaciones de Inicio y ejecutor de perfiles para entornos headless/WinPE.
#>

Set-StrictMode -Version Latest

function Show-CliBanner {
    param([Parameter(Mandatory)][PSCustomObject]$HardwareProfile)

    Clear-Host
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host '  WINFORGE ENGINE — MODO CONSOLA (CLI / HEADLESS / WINPE)' -ForegroundColor White
    Write-Host '==========================================================================' -ForegroundColor Cyan
    Write-Host ("  OS      : {0} ({1} Build {2})" -f $HardwareProfile.OSName, $HardwareProfile.DisplayVersion, $HardwareProfile.FullBuild) -ForegroundColor Gray
    Write-Host ("  CPU/RAM : {0} | {1} GB RAM ({2}) | Tier sugerido: {3}" -f $HardwareProfile.CpuName, $HardwareProfile.TotalRamGB, $HardwareProfile.RamTier, $HardwareProfile.RecommendedTier) -ForegroundColor Gray

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

function Invoke-CliGuidedWizard {
    param(
        [hashtable]$Config,
        [PSCustomObject]$HardwareProfile,
        [PSCustomObject[]]$Tweaks
    )

    Show-CliBanner -HardwareProfile $HardwareProfile
    Write-Host "`n--- ASISTENTE GUIADO PASO A PASO (Modo Recomendado) ---" -ForegroundColor Cyan
    Write-Host "Tier detectado automáticamente para tu equipo: $($HardwareProfile.RecommendedTier)`n" -ForegroundColor Yellow

    $ids = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in @('PERF_WAIT_TO_KILL', 'PERF_NTFS_LAST_ACCESS', 'NET_DNS_CACHE', 'SVC_FAX', 'SVC_REMOTE_REGISTRY', 'SVC_MAPS_BROKER')) {
        [void]$ids.Add($id)
    }

    Write-Host '1. Uso principal: [1] PC Antiguo (Legacy)  [2] Gaming  [3] Trabajo  [4] Laptop'
    $u = Read-Host 'Elige una opción (1-4)'
    switch ($u) {
        '1' { foreach ($id in @('PERF_TRANSPARENCY_OFF', 'PERF_VISUAL_EFFECTS', 'PERF_GAME_DVR', 'SVC_WER')) { [void]$ids.Add($id) } }
        '2' { foreach ($id in @('PERF_SYSMAIN', 'PERF_GAME_DVR', 'PERF_HAGS_ON', 'PERF_HYBRID_PCORE', 'NET_NAGLE', 'NET_THROTTLING')) { [void]$ids.Add($id) } }
        '3' { foreach ($id in @('PERF_WIN11_MENU', 'PERF_GAME_DVR')) { [void]$ids.Add($id) } }
        default { [void]$ids.Add('PERF_GAME_DVR') }
    }

    if ((Read-Host '2. ¿Bloquear Telemetría, Copilot y Recall IA 24H2+? (S/N)') -match '^[SsYy]') {
        foreach ($id in @('PRIV_DIAGTRACK', 'PRIV_WIN11_COPILOT', 'PRIV_WIN11_AI_RECALL', 'PRIV_DELIVERY_OPT', 'PRIV_CORTANA', 'PRIV_CONSUMER_EXP', 'PRIV_EDGE_TELEMETRY', 'PRIV_ADVERTISING_ID')) {
            [void]$ids.Add($id)
        }
    }

    if ((Read-Host '3. ¿Desinstalar Bloatware UWP (Cortana, Bing, Clipchamp, Solitaire)? (S/N)') -match '^[SsYy]') {
        foreach ($id in @('DEBLOAT_CORTANA_APP', 'DEBLOAT_BING_WEATHER', 'DEBLOAT_CLIPCHAMP', 'DEBLOAT_SOLITAIRE')) {
            [void]$ids.Add($id)
        }
    }

    if ((Read-Host '4. ¿Usas impresora o Imprimir a PDF? (S/N)') -notmatch '^[SsYy]') {
        [void]$ids.Add('SVC_SPOOLER')
    }

    $dnsChoice = Read-Host '5. DNS: [0] Mantener actual  [1] Cloudflare (1.1.1.1)  [2] AdGuard Bloqueo Ads (94.140.14.14)'
    if ($dnsChoice -eq '1') { [void]$ids.Add('NET_DNS_CLOUDFLARE') }
    elseif ($dnsChoice -eq '2') { [void]$ids.Add('NET_DNS_ADGUARD') }

    $batch = @($Tweaks | Where-Object { $ids.Contains($_.id) })
    Write-Host "`nSe aplicarán hasta $($batch.Count) ajustes respetando guardrails." -ForegroundColor Cyan
    if ((Read-Host '¿Confirmar y ejecutar con respaldo previo? (S/N)') -match '^[SsYy]') {
        Invoke-CliBatchApply -Config $Config -TweaksToApply $batch -Label 'CLI_GuidedWizard'
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
        Write-Host "`n  [1] Auditar y listar todos los ajustes (Transparencia + Riesgo)" -ForegroundColor White
        Write-Host '  [2] Aplicar un Perfil Preconfigurado (Legacy / Gaming / Trabajo / Laptop / Extremo)' -ForegroundColor White
        Write-Host '  [3] Asistente Guiado Paso a Paso (Recomendado)' -ForegroundColor Cyan
        Write-Host '  [4] Aplicar ajuste individual por ID' -ForegroundColor White
        Write-Host '  [5] Ejecutar tareas de Mantenimiento (DISM / SFC / Temp / Iconos)' -ForegroundColor White
        Write-Host '  [6] Gestor Reversible de Aplicaciones de Inicio (Startup)' -ForegroundColor White
        Write-Host '  [7] Deshacer Todo / Revertir última sesión (Rollback)' -ForegroundColor Red
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
                    Write-Host ("`n[{0}] {1} ({2} | Riesgo: {3}) - Estado: {4}" -f $tw.id, $tw.name, $tw.category, $tw.riskLevel, $st) -ForegroundColor $col
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
                Invoke-CliGuidedWizard -Config $Config -HardwareProfile $HardwareProfile -Tweaks $Tweaks
                Read-Host "`nPresiona ENTER para continuar"
            }
            '4' {
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
            '5' {
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
            '6' {
                $apps = @(Get-WinForgeStartupApps)
                if ($apps.Count -eq 0) {
                    Write-Host 'No se encontraron aplicaciones de inicio.' -ForegroundColor Yellow
                }
                else {
                    for ($i = 0; $i -lt $apps.Count; $i++) {
                        $stLabel = if ($apps[$i].Enabled) { 'ACTIVO' } else { 'DESACTIVADO' }
                        Write-Host ("  [{0}] [{1}] {2} ({3})" -f ($i + 1), $stLabel, $apps[$i].Name, $apps[$i].Scope)
                    }
                    $aSel = Read-Host 'Número de app para alternar estado (o 0 para volver)'
                    $aIdx = 0
                    if ([int]::TryParse($aSel, [ref]$aIdx) -and $aIdx -ge 1 -and $aIdx -le $apps.Count) {
                        $target = $apps[$aIdx - 1]
                        $null = Set-WinForgeStartupAppState -StartupApp $target -Enable (-not $target.Enabled)
                        Write-Host "Estado actualizado para '$($target.Name)'." -ForegroundColor Green
                    }
                }
                Read-Host "`nPresiona ENTER para continuar"
            }
            '7' {
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
