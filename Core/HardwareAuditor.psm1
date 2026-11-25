<#
.SYNOPSIS
    WinForge Engine - HardwareAuditor.
.DESCRIPTION
    Realiza telemetría completa de hardware y sistema operativo usando exclusivamente
    Get-CimInstance, Storage Cmdlets y .NET APIs (cero Get-WmiObject).
    Clasifica el equipo por Tier (Legacy/Low-End vs Moderno/Híbrido) y aplica Guardrails
    inquebrantables de seguridad para HDD (SysMain), RAM (Memory Compression) y Laptops.
#>

Set-StrictMode -Version Latest

function Get-SafeProp {
    param(
        [object]$Object,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        return $prop.Value
    }
    return $DefaultValue
}

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
        $diskNum = [string](Get-SafeProp $disk 'Number' '')
        $diskUid = [string](Get-SafeProp $disk 'UniqueId' '')
        $diskFriendly = [string](Get-SafeProp $disk 'FriendlyName' 'Desconocido')
        $diskBus = [string](Get-SafeProp $disk 'BusType' 'Unknown')

        $physDisk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object {
                ([string](Get-SafeProp $_ 'DeviceId' '') -eq $diskNum) -or
                (-not [string]::IsNullOrEmpty($diskUid) -and [string](Get-SafeProp $_ 'UniqueId' '') -eq $diskUid)
            } |
            Select-Object -First 1

        if ($null -eq $physDisk -and -not [string]::IsNullOrEmpty($diskNum)) {
            $physDisk = Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction SilentlyContinue |
                Where-Object { [string](Get-SafeProp $_ 'DeviceId' '') -eq $diskNum } |
                Select-Object -First 1
        }

        if ($null -ne $physDisk) {
            $mediaRaw = [string](Get-SafeProp $physDisk 'MediaType' 'Unspecified')
            $busRaw = [string](Get-SafeProp $physDisk 'BusType' $diskBus)
            $friendly = [string](Get-SafeProp $physDisk 'FriendlyName' '')
            $result.Model = if (-not [string]::IsNullOrWhiteSpace($friendly)) { $friendly } else { $diskFriendly }

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

            $spindle = Get-SafeProp $physDisk 'SpindleSpeed' $null
            if ($result.MediaType -eq 'Unspecified' -and $null -ne $spindle) {
                if ([int]$spindle -gt 0) {
                    $result.MediaType = 'HDD'
                }
                elseif ($result.BusType -eq 'NVMe') {
                    $result.MediaType = 'SSD'
                }
            }
        }
        else {
            $result.Model = $diskFriendly
            if ($diskBus -eq 'NVMe') {
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
        $typesVal = Get-SafeProp $enclosure 'ChassisTypes' $null
        if ($null -ne $typesVal) {
            $chassisRaw = @($typesVal)
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

    $productName = [string](Get-SafeProp $ntProps 'ProductName' 'Windows')
    if ($osBuild -ge 22000 -and $productName -match 'Windows 10') {
        $productName = $productName -replace 'Windows 10', 'Windows 11'
    }

    $displayVersion = [string](Get-SafeProp $ntProps 'DisplayVersion' '')
    if ([string]::IsNullOrWhiteSpace($displayVersion)) {
        $displayVersion = [string](Get-SafeProp $ntProps 'ReleaseId' 'N/A')
    }
    $ubr = [int](Get-SafeProp $ntProps 'UBR' 0)

    $cpu = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction SilentlyContinue | Select-Object -First 1
    $cs = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction SilentlyContinue | Select-Object -First 1

    $cpuName = ([string](Get-SafeProp $cpu 'Name' 'Desconocido')).Trim()
    $cpuCores = [int](Get-SafeProp $cpu 'NumberOfCores' 0)
    $cpuThreads = [int](Get-SafeProp $cpu 'NumberOfLogicalProcessors' 0)

    $totalMemBytes = [double](Get-SafeProp $cs 'TotalPhysicalMemory' 0)
    $totalRamGb = if ($totalMemBytes -gt 0) {
        [Math]::Round($totalMemBytes / 1GB, 1)
    }
    else { 0 }

    $freeMemKb = [double](Get-SafeProp $os 'FreePhysicalMemory' 0)
    $freeRamGb = if ($freeMemKb -gt 0) {
        [Math]::Round(($freeMemKb * 1KB) / 1GB, 1)
    }
    else { 0 }

    $ramTier = if ($totalRamGb -le 4.5) {
        'Critical'
    }
    elseif ($totalRamGb -le 8.5) {
        'Low'
    }
    elseif ($totalRamGb -lt 24) {
        'Standard'
    }
    else {
        'High'
    }

    $isLowEndCpu = ($cpuCores -le 2 -or $cpuName -match 'Celeron|Pentium|Atom|Athlon Silver')
    $isHybridCpu = ($cpuCores -ge 6 -and $cpuThreads -gt $cpuCores -and $cpuThreads -lt ($cpuCores * 2) -and $cpuName -match 'Intel|Core')

    $activePlan = 'Desconocido'
    try {
        $powerOut = (& powercfg.exe /getactivescheme 2>$null) -join ' '
        if ($powerOut -match '\(([^)]+)\)') {
            $activePlan = $Matches[1]
        }
    }
    catch { }

    $storage = Get-SystemDriveStorageInfo
    $chassis = Get-SystemChassisInfo

    $recommendedTier = if ($storage.IsHDD -or $ramTier -in @('Critical', 'Low') -or $isLowEndCpu) {
        'Legacy'
    }
    elseif ($chassis.IsLaptop) {
        'Laptop'
    }
    else {
        'Modern'
    }

    return [PSCustomObject]@{
        OSName          = $productName
        DisplayVersion  = $displayVersion
        BuildNumber     = $osBuild
        FullBuild       = "$osBuild.$ubr"
        IsWindows11     = ($osBuild -ge 22000)
        CpuName         = $cpuName
        CpuCores        = $cpuCores
        CpuThreads      = $cpuThreads
        IsLowEndCpu     = $isLowEndCpu
        IsHybridCpu     = $isHybridCpu
        TotalRamGB      = $totalRamGb
        FreeRamGB       = $freeRamGb
        RamTier         = $ramTier
        Storage         = $storage
        Chassis         = $chassis
        ActivePowerPlan = $activePlan
        RecommendedTier = $recommendedTier
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
    $minB = Get-SafeProp $Tweak 'minBuild' $null
    $maxB = Get-SafeProp $Tweak 'maxBuild' $null

    if ($null -ne $minB -and $currentBuild -lt [int]$minB) {
        return [PSCustomObject]@{
            Status = 'Blocked'
            Reason = "Requiere Windows Build $minB+ (Actual: $currentBuild)."
        }
    }
    if ($null -ne $maxB -and $currentBuild -gt [int]$maxB) {
        return [PSCustomObject]@{
            Status = 'Blocked'
            Reason = "Compatible solo hasta Windows Build $maxB (Actual: $currentBuild)."
        }
    }

    $storageSafe = [string](Get-SafeProp $Tweak 'storageSafe' 'All')
    if ($HardwareProfile.Storage.IsHDD) {
        if ($Tweak.id -eq 'PERF_SYSMAIN' -or $storageSafe -eq 'SSDOnly') {
            return [PSCustomObject]@{
                Status = 'Blocked'
                Reason = "BLOQUEADO POR SEGURIDAD: La unidad del sistema ($($HardwareProfile.Storage.DriveLetter)) es un HDD mecánico. Desactivar $($Tweak.name) degradaría gravemente los tiempos de arranque y carga."
            }
        }
    }

    if ($Tweak.id -eq 'PERF_MEM_COMPRESSION_OFF' -and $HardwareProfile.TotalRamGB -le 8.5) {
        return [PSCustomObject]@{
            Status = 'Blocked'
            Reason = "BLOQUEADO POR SEGURIDAD: Tu equipo tiene $($HardwareProfile.TotalRamGB) GB de RAM. Desactivar la compresión de memoria en equipos con <= 8 GB provoca uso intensivo de disco (paginación) y tirones severos."
        }
    }

    $chassisWarn = [string](Get-SafeProp $Tweak 'chassisWarning' 'None')
    if ($HardwareProfile.Chassis.IsLaptop -and $chassisWarn -eq 'Laptop') {
        $guardStatus = 'Warning'
        $guardReason = 'ALERTA LAPTOP: Este ajuste puede reducir la autonomía de batería o afectar la suspensión/hibernación segura en equipos portátiles.'
    }
    elseif (-not $HardwareProfile.Chassis.IsLaptop -and $chassisWarn -eq 'Desktop') {
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
        $risk = [string](Get-SafeProp $tweak 'riskLevel' 'Bajo')
        if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'Bajo' }

        $item = [PSCustomObject]@{
            id              = $tweak.id
            category        = $tweak.category
            name            = $tweak.name
            description     = $tweak.description
            component       = $tweak.component
            targetPath      = $tweak.targetPath
            benefit         = $tweak.benefit
            sideEffect      = $tweak.sideEffect
            riskLevel       = $risk
            minBuild        = Get-SafeProp $tweak 'minBuild' $null
            maxBuild        = Get-SafeProp $tweak 'maxBuild' $null
            chassisWarning  = Get-SafeProp $tweak 'chassisWarning' 'None'
            storageSafe     = Get-SafeProp $tweak 'storageSafe' 'All'
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
