<#
.SYNOPSIS
    WinForge Engine - Zero-Install Bootstrapper.
.DESCRIPTION
    Descarga WinForge Engine desde GitHub Raw a una carpeta temporal volátil en $env:TEMP,
    solicita elevación UAC si es necesario preservando los argumentos y origen, ejecuta el
    orquestador principal y destruye por completo los archivos temporales al finalizar.
.EXAMPLE
    irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$RepoOwner = 'olshhhh',
    [string]$RepoName = 'Optimizador',
    [string]$Branch = 'main',
    [string]$BaseUrl = '',
    [switch]$Cli,
    [string]$Profile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Forzar TLS 1.2 para descargas seguras en PowerShell 5.1 / Windows 10 & 11
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    if (-not [string]::IsNullOrWhiteSpace($env:WINFORGE_BASE_URL)) {
        $BaseUrl = $env:WINFORGE_BASE_URL.TrimEnd('/')
    }
    else {
        $BaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
    }
}
else {
    $BaseUrl = $BaseUrl.TrimEnd('/')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Host '[WinForge] Se requieren privilegios de Administrador. Solicitando elevación UAC...' -ForegroundColor Yellow

    $shellExe = if ($PSVersionTable.PSEdition -eq 'Core') {
        (Get-Process -Id $PID).Path
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $escapedBaseUrl = $BaseUrl.Replace("'", "''")
    $escapedProfile = $Profile.Replace("'", "''")
    $cliFlag = if ($Cli.IsPresent) { '-Cli' } else { '' }
    $profileArg = if (-not [string]::IsNullOrWhiteSpace($Profile)) { "-Profile '$escapedProfile'" } else { '' }

    # Si se ejecutó vía iex (sin ruta de script en disco), preservamos origen y parámetros vía EncodedCommand
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $elevatedCommand = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$env:WINFORGE_BASE_URL = '$escapedBaseUrl'
`$scriptText = Invoke-RestMethod -Uri '$escapedBaseUrl/bootstrap.ps1' -UseBasicParsing
`$sb = [scriptblock]::Create(`$scriptText)
& `$sb -BaseUrl '$escapedBaseUrl' $cliFlag $profileArg
"@
        $encodedBytes = [System.Text.Encoding]::Unicode.GetBytes($elevatedCommand)
        $encodedCmd = [Convert]::ToBase64String($encodedBytes)
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCmd)
    }
    else {
        $argList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"",
            '-BaseUrl', "`"$BaseUrl`""
        )
        if ($Cli.IsPresent) { $argList += '-Cli' }
        if (-not [string]::IsNullOrWhiteSpace($Profile)) {
            $argList += '-Profile'
            $argList += "`"$Profile`""
        }
    }

    try {
        Start-Process -FilePath $shellExe -ArgumentList $argList -Verb RunAs | Out-Null
    }
    catch {
        Write-Host "[WinForge] Elevación UAC cancelada o fallida: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    return
}

$sessionGuid = [Guid]::NewGuid().ToString('N')
$volatileRoot = Join-Path $env:TEMP "WinForge_$sessionGuid"

$manifestFiles = @(
    'WinForge.ps1',
    'Core/RunspaceManager.psm1',
    'Core/HardwareAuditor.psm1',
    'Core/SafetyManager.psm1',
    'Core/TweakEngine.psm1',
    'UI/MainWindow.xaml',
    'UI/GuiController.psm1',
    'UI/CliController.psm1',
    'Data/tweaks.json',
    'Data/profiles.json'
)

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  WinForge Engine - Zero-Install Bootstrapper' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "[WinForge] Origen: $BaseUrl" -ForegroundColor DarkGray
Write-Host "[WinForge] Contenedor volátil: $volatileRoot" -ForegroundColor DarkGray

$webClient = $null
try {
    New-Item -Path $volatileRoot -ItemType Directory -Force | Out-Null
    foreach ($subDir in @('Core', 'UI', 'Data')) {
        New-Item -Path (Join-Path $volatileRoot $subDir) -ItemType Directory -Force | Out-Null
    }

    $webClient = [System.Net.WebClient]::new()
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    $webClient.Headers.Add('User-Agent', 'WinForge-Engine-Bootstrapper/1.0')
    $webClient.Headers.Add('Cache-Control', 'no-cache')

    $total = $manifestFiles.Count
    $index = 0

    foreach ($relPath in $manifestFiles) {
        $index++
        $remoteUrl = "$BaseUrl/$relPath"
        $localPath = Join-Path $volatileRoot ($relPath -replace '/', '\')

        Write-Host ("[{0}/{1}] Descargando {2}..." -f $index, $total, $relPath) -ForegroundColor Gray
        $content = $webClient.DownloadString($remoteUrl)

        if ($relPath -match '\.(ps1|psm1)$') {
            $encoding = [System.Text.UTF8Encoding]::new($true)
        }
        else {
            $encoding = [System.Text.UTF8Encoding]::new($false)
        }

        [System.IO.File]::WriteAllText($localPath, $content, $encoding)
    }

    $entryScript = Join-Path $volatileRoot 'WinForge.ps1'
    $launchParams = @{
        BasePath = $volatileRoot
    }
    if ($Cli.IsPresent) {
        $launchParams['Cli'] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $launchParams['Profile'] = $Profile
    }

    Write-Host '[WinForge] Iniciando orquestador...' -ForegroundColor Green
    & $entryScript @launchParams
}
catch {
    Write-Host "[WinForge] Error fatal en bootstrap: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host "[WinForge] Detalle: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    }
    exit 1
}
finally {
    if ($null -ne $webClient) {
        $webClient.Dispose()
    }
    if (Test-Path -LiteralPath $volatileRoot) {
        Write-Host '[WinForge] Destruyendo huella local en carpeta temporal volátil...' -ForegroundColor DarkGray
        Remove-Item -LiteralPath $volatileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
