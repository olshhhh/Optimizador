<#
.SYNOPSIS
    WinForge Engine - HardwareAuditor.
.DESCRIPTION
    Realiza telemetría completa de hardware y sistema operativo usando exclusivamente
    Get-CimInstance, Storage Cmdlets y .NET APIs (cero Get-WmiObject).
    Aplica Guardrails inquebrantables de seguridad para HDD (SysMain) y Laptops (Energía).
#>

Set-StrictMode -Version Latest

function Get-SystemDriveStorageInfo {
    [CmdletBinding()]
    param()

    $sysDrive = ($env:SystemDrive -replace ':', '').Trim()
    if ([string]::IsNullOrWhiteSpace($sysDrive)) {
        $sysDrive = 'C'
    }

    $result = [PSCustomObject]@{
        DriveLetter = "${sysDrive}:"
        MediaType   = 'Unspecified'
        BusType     = 'Unknown'
        Model       = 'Desconocido'
        IsSSD       = $false
        IsHDD       = $false
        IsNVMe      = $false
        DisplayText = 'No determinado'
    }

    try {
        $partition = Get-Partition -DriveLetter $sysDrive -ErrorAction Stop | Select-Object -First 1
        $disk = $partition | Get-Disk -ErrorAction Stop | Select-Object -First 1
        $physDisk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceId -eq "$($disk.Number)" -or $_.UniqueId -eq $disk.UniqueId } |
            Select-Object -First 1

        if ($null -eq $physDisk) {
            $physDisk = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction SilentlyContinue |
                Where-Object { $_.DeviceId -eq "$($disk.Number)" } |
                Select-Object -First 1
        }

        if ($null -ne $physDisk) {
            $mediaRaw = "$($physDisk.MediaType)"
            $busRaw = "$($physDisk.BusType)"
            $result.Model = if ($physDisk.FriendlyName) { $physDisk.FriendlyName } else { $disk.FriendlyName }

            switch ($mediaRaw) {
                '3'   { $result.MediaType = 'HDD' }
                '4'   { $result.MediaType = 'SSD' }
                '5'   { $result.MediaType = 'SCM' }
                'HDD' { $result.MediaType = 'HDD' }
                'SSD' { $result.MediaType = 'SSD' }
                'SCM' { $result.MediaType = 'SSD' }
                default { $result.MediaType = $mediaRaw }
            }

            switch ($busRaw) {
                '17'   { $result.BusType = 'NVMe' }
                '11'   { $result.BusType = 'SATA' }
                'NVMe' { $result.BusType = 'NVMe' }
                'SATA' { $result.BusType = 'SATA' }
                default { $result.BusType = $busRaw }
            }

            if ($result.MediaType -eq 'Unspecified' -and $physDisk.PSObject.Properties['SpindleSpeed']) {
                if ($physDisk.SpindleSpeed -gt 0) {
                    $result.MediaType = 'HDD'
                }
                elseif ($result.BusType -eq 'NVMe') {
                    $result.MediaType = 'SSD'
                }
            }
        }
        else {
            $result.Model = $disk.FriendlyName
            if ($disk.BusType -eq 'NVMe') {
                $result.MediaType = 'SSD'
                $result.BusType = 'NVMe'
            }
        }

        $result.IsNVMe = ($result.BusType -eq 'NVMe')
        $result.IsSSD = ($result.MediaType -eq 'SSD' -or $result.IsNVMe)
        $result.IsHDD = ($result.MediaType -eq 'HDD')

        if ($result.IsNVMe) {
            $result.DisplayText = "NVMe SSD ($($result.Model))"
        }
        elseif ($result.IsSSD) {
            $result.DisplayText = "SSD $($result.BusType) ($($result.Model))"
        }
        elseif ($result.IsHDD) {
            $result.DisplayText = "HDD Mecánico ($($result.Model))"
        }
        else {
            $result.DisplayText = "Virtual/Otro [$($result.MediaType)/$($result.BusType)] ($($result.Model))"
        }
    }
    catch {
        $result.DisplayText = "No detectado ($($_.Exception.Message))"
    }

    return $result
}

function Get-SystemChassisInfo {
    [CmdletBinding()]
    param()

    $laptopChassisTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $false
    $hasBattery = $false
    $chassisLabel = 'Desktop'
    $chassisRaw = @()

    try {
        $enclosure = Get-CimInstance -ClassName 'Win32_SystemEnclosure' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $enclosure -and $null -ne $enclosure.ChassisTypes) {
            $chassisRaw = @($enclosure.ChassisTypes)
            foreach ($code in $chassisRaw) {
                if ($laptopChassisTypes -contains [int]$code) {
                    $isLaptop = $true
                    break
                }
            }
        }

        $batteries = @(Get-CimInstance -ClassName 'Win32_Battery' -ErrorAction SilentlyContinue)
        if ($batteries.Count -gt 0) {
            $hasBattery = $true
            $isLaptop = $true
        }
    }
    catch { }

    if ($isLaptop) {
        $chassisLabel = 'Laptop'
    }

    return [PSCustomObject]@{
        FormFactor   = $chassisLabel
        IsLaptop     = $isLaptop
        HasBattery   = $hasBattery
        ChassisCodes = $chassisRaw
    }
}

function Get-WinForgeHardwareProfile {
    [CmdletBinding()]
    param()

    $osBuild = [int][System.Environment]::OSVersion.Version.Build
    $ntKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ntProps = Get-ItemProperty -Path $ntKey -ErrorAction SilentlyContinue

    $productName = if ($ntProps -and $ntProps.ProductName) { $ntProps.ProductName } else { 'Windows' }
    if ($osBuild -ge 22000 -and $productName -match 'Windows 10') {
        $productName = $productName -replace 'Windows 10', 'Windows 11'
    }

    $displayVersion = if ($ntProps -and $ntProps.DisplayVersion) {
        $ntProps.DisplayVersion
    }
    elseif ($ntProps -and $ntProps.ReleaseId) {
        $ntProps.ReleaseId
    }
    else {
        'N/A'
    }
    $ubr = if ($ntProps -and $null -ne $ntProps.UBR) { $ntProps.UBR } else { 0 }

    $cpu = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction SilentlyContinue | Select-Object -First 1
    $cs = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction SilentlyContinue | Select-Object -First 1

    $totalRamGb = if ($cs -and $cs.TotalPhysicalMemory) {
        [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    }
    else { 0 }

    $freeRamGb = if ($os -and $os.FreePhysicalMemory) {
        [Math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
    }
    else { 0 }

    $activePlan = 'Desconocido'
    try {
        $powerOut = & powercfg.exe /getactivescheme 2>$null
        if ($powerOut -match '\(([^)]+)\)') {
            $activePlan = $Matches[1]
        }
    }
    catch { }

    $storage = Get-SystemDriveStorageInfo
    $chassis = Get-SystemChassisInfo

    return [PSCustomObject]@{
        OSName          = $productName
        DisplayVersion  = $displayVersion
        BuildNumber     = $osBuild
        FullBuild       = "$osBuild.$ubr"
        IsWindows11     = ($osBuild -ge 22000)
        CpuName         = if ($cpu) { $cpu.Name.Trim() } else { 'Desconocido' }
        CpuCores        = if ($cpu) { $cpu.NumberOfCores } else { 0 }
        CpuThreads      = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 0 }
        TotalRamGB      = $totalRamGb
        FreeRamGB       = $freeRamGb
        Storage         = $storage
        Chassis         = $chassis
        ActivePowerPlan = $activePlan
        ComputerName    = $env:COMPUTERNAME
        UserName        = $env:USERNAME
    }
}

function Test-TweakHardwareCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak,

        [Parameter(Mandatory)]
        [PSCustomObject]$HardwareProfile
    )

    $guardStatus = 'Allowed'
    $guardReason = ''

    $currentBuild = [int]$HardwareProfile.BuildNumber
    if ($null -ne $Tweak.minBuild -and $currentBuild -lt [int]$Tweak.minBuild) {
        return [PSCustomObject]@{
            Status = 'Blocked'
            Reason = "Requiere Windows Build $($Tweak.minBuild)+ (Actual: $currentBuild)."
        }
    }
    if ($null -ne $Tweak.maxBuild -and $currentBuild -gt [int]$Tweak.maxBuild) {
        return [PSCustomObject]@{
            Status = 'Blocked'
            Reason = "Compatible solo hasta Windows Build $($Tweak.maxBuild) (Actual: $currentBuild)."
        }
    }

    if ($HardwareProfile.Storage.IsHDD) {
        if ($Tweak.id -eq 'PERF_SYSMAIN' -or $Tweak.storageSafe -eq 'SSDOnly') {
            return [PSCustomObject]@{
                Status = 'Blocked'
                Reason = "BLOQUEADO POR SEGURIDAD: La unidad del sistema ($($HardwareProfile.Storage.DriveLetter)) es un HDD mecánico. Desactivar $($Tweak.name) degradaría gravemente los tiempos de arranque y carga."
            }
        }
    }

    if ($HardwareProfile.Chassis.IsLaptop -and $Tweak.chassisWarning -eq 'Laptop') {
        $guardStatus = 'Warning'
        $guardReason = 'ALERTA LAPTOP: Este ajuste puede reducir la autonomía de batería o afectar la suspensión/hibernación segura en equipos portátiles.'
    }
    elseif (-not $HardwareProfile.Chassis.IsLaptop -and $Tweak.chassisWarning -eq 'Desktop') {
        $guardStatus = 'Warning'
        $guardReason = 'ALERTA DESKTOP: Ajuste orientado originalmente a sistemas portátiles.'
    }

    return [PSCustomObject]@{
        Status = $guardStatus
        Reason = $guardReason
    }
}

function Resolve-WinForgeTweakCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Tweaks,

        [Parameter(Mandatory)]
        [PSCustomObject]$HardwareProfile
    )

    $resolved = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($tweak in $Tweaks) {
        $compat = Test-TweakHardwareCompatibility -Tweak $tweak -HardwareProfile $HardwareProfile

        $item = [PSCustomObject]@{
            id              = $tweak.id
            category        = $tweak.category
            name            = $tweak.name
            description     = $tweak.description
            component       = $tweak.component
            targetPath      = $tweak.targetPath
            benefit         = $tweak.benefit
            sideEffect      = $tweak.sideEffect
            minBuild        = $tweak.minBuild
            maxBuild        = $tweak.maxBuild
            chassisWarning  = $tweak.chassisWarning
            storageSafe     = $tweak.storageSafe
            detectScript    = $tweak.detectScript
            applyScript     = $tweak.applyScript
            revertScript    = $tweak.revertScript
            GuardStatus     = $compat.Status
            GuardReason     = $compat.Reason
            IsApplied       = $false
            DetectionState  = 'Pendiente'
        }
        $resolved.Add($item)
    }

    return $resolved.ToArray()
}

Export-ModuleMember -Function @(
    'Get-SystemDriveStorageInfo',
    'Get-SystemChassisInfo',
    'Get-WinForgeHardwareProfile',
    'Test-TweakHardwareCompatibility',
    'Resolve-WinForgeTweakCompatibility'
)
