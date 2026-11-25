<#
.SYNOPSIS
    WinForge Engine - SafetyManager.
.DESCRIPTION
    Gestiona Puntos de Restauración del Sistema (VSS/Checkpoint-Computer), exportación
    automática de claves de registro (.reg) y manifiestos de sesión en
    $env:LOCALAPPDATA\WinForge\Backups\<Timestamp>\, además del motor de Rollback completo.
#>

Set-StrictMode -Version Latest

function New-WinForgeRestorePoint {
    [CmdletBinding()]
    param(
        [string]$Description = 'WinForge Engine Pre-Optimization Snapshot'
    )

    $result = [PSCustomObject]@{
        Success = $false
        Message = ''
    }

    try {
        $vss = Get-Service -Name 'VSS' -ErrorAction SilentlyContinue
        if ($null -eq $vss) {
            $result.Message = 'El servicio VSS no está disponible en este entorno (ej. WinPE).'
            return $result
        }

        if ($vss.StartType -eq 'Disabled') {
            $result.Message = 'El servicio Instantáneas de volumen (VSS) está deshabilitado. Se omitió el Punto de Restauración (los backups .reg continúan activos).'
            return $result
        }

        $sysDrive = "$($env:SystemDrive)\"
        try {
            Enable-ComputerRestore -Drive $sysDrive -ErrorAction SilentlyContinue
        }
        catch { }

        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $result.Success = $true
        $result.Message = "Punto de Restauración del Sistema creado: '$Description'."
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '1440|frequency|frecuencia') {
            $result.Success = $true
            $result.Message = 'Ya existe un Punto de Restauración reciente (<24h). Continuando con respaldo de registro de sesión.'
        }
        else {
            $result.Message = "No se pudo crear el Punto de Restauración ($msg). Se continuará con respaldo granular .reg."
        }
    }

    return $result
}

function ConvertTo-RegExePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PowerShellPath
    )

    $clean = $PowerShellPath.Trim()
    $clean = $clean -replace '^HKLM:\\', 'HKLM\'
    $clean = $clean -replace '^HKCU:\\', 'HKCU\'
    $clean = $clean -replace '^HKCR:\\', 'HKCR\'
    $clean = $clean -replace '^HKU:\\', 'HKU\'
    $clean = $clean -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\'
    $clean = $clean -replace '^HKEY_CURRENT_USER\\', 'HKCU\'
    return $clean
}

function Extract-RegistryPathsFromTweak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak
    )

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $combined = "$($Tweak.targetPath)`n$($Tweak.applyScript)"
    $matches = [regex]::Matches($combined, '(HKLM|HKCU|HKCR|HKU):\\[^''"`\r\n;]+')
    foreach ($m in $matches) {
        $raw = $m.Value.TrimEnd('\', ' ', ')')
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            [void]$paths.Add($raw)
        }
    }

    return @($paths)
}

function New-WinForgeBackupSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$TweaksToApply,

        [string]$SessionLabel = 'Manual',

        [switch]$CreateRestorePoint
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sessionDir = Join-Path $BackupRoot $timestamp
    $regDir = Join-Path $sessionDir 'Registry'

    New-Item -Path $regDir -ItemType Directory -Force | Out-Null

    $restoreResult = [PSCustomObject]@{
        Success = $false
        Message = 'Omitido por configuración.'
    }

    if ($CreateRestorePoint.IsPresent) {
        $restoreResult = New-WinForgeRestorePoint -Description "WinForge_$timestamp"
    }

    $exportedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $exportedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $fileIndex = 0
    foreach ($tweak in $TweaksToApply) {
        $psPaths = Extract-RegistryPathsFromTweak -Tweak $tweak
        foreach ($psPath in $psPaths) {
            if ($exportedKeys.Contains($psPath)) {
                continue
            }
            [void]$exportedKeys.Add($psPath)

            if (Test-Path -LiteralPath $psPath) {
                $fileIndex++
                $safeName = ($tweak.id -replace '[^a-zA-Z0-9_-]', '_')
                $regFileName = "{0:D3}_{1}.reg" -f $fileIndex, $safeName
                $regFilePath = Join-Path $regDir $regFileName
                $nativeKey = ConvertTo-RegExePath -PowerShellPath $psPath

                try {
                    $proc = Start-Process -FilePath $regExe -ArgumentList @('export', "`"$nativeKey`"", "`"$regFilePath`"", '/y') -WindowStyle Hidden -Wait -PassThru
                    if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $regFilePath)) {
                        $exportedFiles.Add([PSCustomObject]@{
                            TweakId    = $tweak.id
                            PsPath     = $psPath
                            NativeKey  = $nativeKey
                            RegFile    = $regFileName
                        })
                    }
                }
                catch { }
            }
        }
    }

    $manifest = [PSCustomObject]@{
        SessionId         = $timestamp
        CreatedAt         = (Get-Date).ToString('o')
        Label             = $SessionLabel
        RestorePoint      = $restoreResult
        TweakIds          = @($TweaksToApply | ForEach-Object { $_.id })
        ExportedRegFiles  = $exportedFiles.ToArray()
    }

    $manifestPath = Join-Path $sessionDir 'session_manifest.json'
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{
        SessionId      = $timestamp
        SessionDir     = $sessionDir
        ManifestPath   = $manifestPath
        RestorePoint   = $restoreResult
        RegBackupCount = $exportedFiles.Count
    }
}

function Get-WinForgeBackupSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        return @()
    }

    $sessions = [System.Collections.Generic.List[PSCustomObject]]::new()
    $dirs = Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending

    foreach ($dir in $dirs) {
        $manifestPath = Join-Path $dir.FullName 'session_manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $data = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $sessions.Add([PSCustomObject]@{
                    SessionId      = $data.SessionId
                    CreatedAt      = $data.CreatedAt
                    Label          = $data.Label
                    TweakCount     = @($data.TweakIds).Count
                    RegBackupCount = @($data.ExportedRegFiles).Count
                    SessionDir     = $dir.FullName
                    Manifest       = $data
                })
            }
            catch { }
        }
    }

    return $sessions.ToArray()
}

function Invoke-WinForgeRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$AllTweaks,

        [string]$SessionId = '',

        [scriptblock]$LogCallback = $null
    )

    $sessions = @(Get-WinForgeBackupSessions -BackupRoot $BackupRoot)
    $targetSession = $null

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $targetSession = $sessions | Where-Object { $_.SessionId -eq $SessionId } | Select-Object -First 1
    }
    elseif ($sessions.Count -gt 0) {
        $targetSession = $sessions[0]
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tweakMap = @{}
    foreach ($t in $AllTweaks) {
        $tweakMap[$t.id] = $t
    }

    if ($null -ne $targetSession) {
        if ($LogCallback) { & $LogCallback "[Rollback] Restaurando sesión $($targetSession.SessionId) ($($targetSession.Label))..." }

        $tweakIds = @($targetSession.Manifest.TweakIds)
        [array]::Reverse($tweakIds)

        foreach ($tid in $tweakIds) {
            if ($tweakMap.ContainsKey($tid)) {
                $tweak = $tweakMap[$tid]
                if ($tweak.category -eq 'Maintenance') { continue }
                try {
                    $sb = [scriptblock]::Create($tweak.revertScript)
                    $null = & $sb
                    $results.Add([PSCustomObject]@{ Id = $tid; Name = $tweak.name; Success = $true; Message = 'Revertido mediante revertScript' })
                    if ($LogCallback) { & $LogCallback "[OK] Revertido: $($tweak.name)" }
                }
                catch {
                    $results.Add([PSCustomObject]@{ Id = $tid; Name = $tweak.name; Success = $false; Message = $_.Exception.Message })
                    if ($LogCallback) { & $LogCallback "[ERROR] Fallo al revertir $($tweak.name): $($_.Exception.Message)" }
                }
            }
        }

        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        $regFolder = Join-Path $targetSession.SessionDir 'Registry'
        foreach ($regEntry in @($targetSession.Manifest.ExportedRegFiles)) {
            $regPath = Join-Path $regFolder $regEntry.RegFile
            if (Test-Path -LiteralPath $regPath) {
                try {
                    $proc = Start-Process -FilePath $regExe -ArgumentList @('import', "`"$regPath`"") -WindowStyle Hidden -Wait -PassThru
                    if ($proc.ExitCode -eq 0) {
                        if ($LogCallback) { & $LogCallback "[REG] Backup importado: $($regEntry.RegFile)" }
                    }
                }
                catch {
                    if ($LogCallback) { & $LogCallback "[REG WARN] No se pudo importar $($regEntry.RegFile): $($_.Exception.Message)" }
                }
            }
        }
    }
    else {
        if ($LogCallback) { & $LogCallback '[Rollback] Sin sesión previa. Revirtiendo todos los ajustes detectados como aplicados...' }

        foreach ($tweak in $AllTweaks) {
            if ($tweak.category -eq 'Maintenance') { continue }
            try {
                $detectSb = [scriptblock]::Create($tweak.detectScript)
                $isApplied = [bool](& $detectSb)
                if ($isApplied) {
                    $revertSb = [scriptblock]::Create($tweak.revertScript)
                    $null = & $revertSb
                    $results.Add([PSCustomObject]@{ Id = $tweak.id; Name = $tweak.name; Success = $true; Message = 'Estado original restaurado' })
                    if ($LogCallback) { & $LogCallback "[OK] Restaurado: $($tweak.name)" }
                }
            }
            catch {
                $results.Add([PSCustomObject]@{ Id = $tweak.id; Name = $tweak.name; Success = $false; Message = $_.Exception.Message })
                if ($LogCallback) { & $LogCallback "[ERROR] $($tweak.name): $($_.Exception.Message)" }
            }
        }
    }

    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'New-WinForgeRestorePoint',
    'New-WinForgeBackupSession',
    'Get-WinForgeBackupSessions',
    'Invoke-WinForgeRollback'
)
