<#
.SYNOPSIS
    WinForge Engine - Orquestador Principal.
.DESCRIPTION
    Inicializa el entorno de ejecución, carga los módulos Core/UI, ejecuta la auditoría de
    hardware previa y decide automáticamente si iniciar la interfaz gráfica WPF (STA) o el
    controlador CLI interactivo para entornos headless/WinPE.
#>

[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$Profile = '',
    [string]$BasePath = $PSScriptRoot,
    [switch]$NoPauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    $BasePath = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$script:WinForgeConfig = @{
    Version       = '1.0.0'
    BasePath      = $BasePath
    CorePath      = Join-Path $BasePath 'Core'
    UiPath        = Join-Path $BasePath 'UI'
    DataPath      = Join-Path $BasePath 'Data'
    TweaksFile    = Join-Path $BasePath 'Data\tweaks.json'
    ProfilesFile  = Join-Path $BasePath 'Data\profiles.json'
    XamlFile      = Join-Path $BasePath 'UI\MainWindow.xaml'
    BackupRoot    = Join-Path $env:LOCALAPPDATA 'WinForge\Backups'
    LogRoot       = Join-Path $env:LOCALAPPDATA 'WinForge\Logs'
}

function Test-CanLaunchWpfGui {
    param([switch]$ForceCli)

    if ($ForceCli.IsPresent) {
        return $false
    }
    if (-not [System.Environment]::UserInteractive) {
        return $false
    }

    $isWinPE = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
    if ($isWinPE) {
        return $false
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

$useGui = Test-CanLaunchWpfGui -ForceCli:$Cli

if ($useGui -and ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA)) {
    $shellExe = if ($PSVersionTable.PSEdition -eq 'Core') {
        (Get-Process -Id $PID).Path
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $argList = @(
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($MyInvocation.MyCommand.Path)`"",
        '-BasePath', "`"$BasePath`""
    )
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $argList += '-Profile'
        $argList += "`"$Profile`""
    }
    if ($NoPauseOnError.IsPresent) {
        $argList += '-NoPauseOnError'
    }

    $proc = Start-Process -FilePath $shellExe -ArgumentList $argList -NoNewWindow -Wait -PassThru
    exit $proc.ExitCode
}

$runspaceContext = $null

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'WinForge Engine requiere ejecutarse con privilegios de Administrador.'
    }

    $modulesToImport = @(
        (Join-Path $script:WinForgeConfig.CorePath 'HardwareAuditor.psm1'),
        (Join-Path $script:WinForgeConfig.CorePath 'SafetyManager.psm1'),
        (Join-Path $script:WinForgeConfig.CorePath 'TweakEngine.psm1'),
        (Join-Path $script:WinForgeConfig.CorePath 'RunspaceManager.psm1')
    )

    foreach ($mod in $modulesToImport) {
        if (-not (Test-Path -LiteralPath $mod)) {
            throw "Módulo crítico no encontrado: $mod"
        }
        Import-Module -Name $mod -Force -DisableNameChecking
    }

    $tweaksDatabase = Get-WinForgeTweaks -TweaksFilePath $script:WinForgeConfig.TweaksFile
    $profilesDatabase = Get-WinForgeProfiles -ProfilesFilePath $script:WinForgeConfig.ProfilesFile

    $hardwareProfile = Get-WinForgeHardwareProfile
    $evaluatedTweaks = Resolve-WinForgeTweakCompatibility -Tweaks $tweaksDatabase -HardwareProfile $hardwareProfile

    if ($useGui -and [string]::IsNullOrWhiteSpace($Profile)) {
        Import-Module -Name (Join-Path $script:WinForgeConfig.UiPath 'GuiController.psm1') -Force -DisableNameChecking

        $runspaceContext = Initialize-WinForgeRunspacePool -MaxThreads 4 -ModulePaths $modulesToImport
        Start-WinForgeGui `
            -Config $script:WinForgeConfig `
            -HardwareProfile $hardwareProfile `
            -Tweaks $evaluatedTweaks `
            -Profiles $profilesDatabase `
            -RunspaceContext $runspaceContext
    }
    else {
        Import-Module -Name (Join-Path $script:WinForgeConfig.UiPath 'CliController.psm1') -Force -DisableNameChecking

        Start-WinForgeCli `
            -Config $script:WinForgeConfig `
            -HardwareProfile $hardwareProfile `
            -Tweaks $evaluatedTweaks `
            -Profiles $profilesDatabase `
            -AutoProfile $Profile
    }
}
catch {
    $errText = "[WinForge Error] $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    Write-Host "`n$errText" -ForegroundColor Red
    try {
        if (-not (Test-Path -LiteralPath $script:WinForgeConfig.LogRoot)) {
            New-Item -Path $script:WinForgeConfig.LogRoot -ItemType Directory -Force | Out-Null
        }
        $logFile = Join-Path $script:WinForgeConfig.LogRoot 'last_error.log'
        [System.IO.File]::WriteAllText($logFile, $errText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[WinForge] Detalle guardado en: $logFile" -ForegroundColor Yellow
    }
    catch { }

    if (-not $NoPauseOnError.IsPresent -and [System.Environment]::UserInteractive) {
        Read-Host "`nOcurrió un error al iniciar WinForge. Presiona ENTER para cerrar"
    }
    exit 1
}
finally {
    if ($null -ne $runspaceContext) {
        Close-WinForgeRunspacePool -RunspaceContext $runspaceContext
    }
}
