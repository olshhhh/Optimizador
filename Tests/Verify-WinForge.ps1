<#
.SYNOPSIS
    WinForge Engine - Suite de Pruebas de Verificación (Solo Lectura).
.DESCRIPTION
    Valida sintaxis de scripts/módulos, integridad de JSON (tweaks y profiles),
    parseo XAML WPF de MainWindow y del Asistente Guiado, importación de módulos
    bajo Set-StrictMode -Version Latest, auditoría de hardware y ejecución en modo
    solo lectura de los 42 detectScript sin modificar el sistema.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passed = 0
$failed = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-TestCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$TestBlock
    )

    try {
        & $TestBlock
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
    }
    catch {
        Write-Host "[FAIL] $Name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:failures.Add("$Name : $($_.Exception.Message)")
        $script:failed++
    }
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  WinForge Engine - Verificación Automatizada (Solo Lectura)' -ForegroundColor White
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Ruta evaluada: $RepoRoot`n" -ForegroundColor DarkGray

Invoke-TestCase 'Archivos requeridos presentes' {
    $required = @(
        'bootstrap.ps1',
        'WinForge.ps1',
        'Core\RunspaceManager.psm1',
        'Core\HardwareAuditor.psm1',
        'Core\SafetyManager.psm1',
        'Core\TweakEngine.psm1',
        'UI\MainWindow.xaml',
        'UI\GuiController.psm1',
        'UI\CliController.psm1',
        'Data\tweaks.json',
        'Data\profiles.json'
    )
    foreach ($rel in $required) {
        $full = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Falta archivo requerido: $rel"
        }
    }
}

Invoke-TestCase 'Sintaxis PowerShell AST válida en todos los .ps1/.psm1' {
    $psFiles = Get-ChildItem -Path $RepoRoot -Include '*.ps1', '*.psm1' -Recurse
    foreach ($f in $psFiles) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $errText = ($errors | ForEach-Object { "Línea $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
            throw "Errores AST en $($f.Name): $errText"
        }
    }
}

Invoke-TestCase 'Sin uso de Get-WmiObject en código ejecutable' {
    $psFiles = Get-ChildItem -Path $RepoRoot -Include '*.ps1', '*.psm1' -Recurse
    foreach ($f in $psFiles) {
        $lines = Get-Content -LiteralPath $f.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i].Trim()
            if ($line.StartsWith('#') -or $line.StartsWith('<#') -or $line -match 'cero Get-WmiObject') { continue }
            if ($line -match '\bGet-WmiObject\b') {
                throw "Se encontró Get-WmiObject en $($f.Name) línea $($i + 1)"
            }
        }
    }
}

$tweaks = @()
$profiles = @()

Invoke-TestCase 'Validación de Data/tweaks.json y Data/profiles.json' {
    $tweaksRaw = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'Data\tweaks.json'), [System.Text.Encoding]::UTF8)
    $profilesRaw = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'Data\profiles.json'), [System.Text.Encoding]::UTF8)

    $script:tweaks = @($tweaksRaw | ConvertFrom-Json)
    $script:profiles = @($profilesRaw | ConvertFrom-Json)

    if ($script:tweaks.Count -lt 30) {
        throw "Se esperaban al menos 30 tweaks, encontrados: $($script:tweaks.Count)"
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in $script:tweaks) {
        if (-not $seen.Add($t.id)) {
            throw "ID duplicado en tweaks.json: $($t.id)"
        }
        if ([string]::IsNullOrWhiteSpace($t.riskLevel)) {
            throw "Falta riskLevel en $($t.id)"
        }
    }

    foreach ($p in $script:profiles) {
        foreach ($tid in $p.tweakIds) {
            if (-not $seen.Contains($tid)) {
                throw "El perfil '$($p.id)' referencia un ID inexistente: $tid"
            }
        }
    }
}

Invoke-TestCase 'Parseo WPF XAML de MainWindow.xaml y Asistente Guiado' {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop

    $mainXaml = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'UI\MainWindow.xaml'), [System.Text.Encoding]::UTF8)
    $mainWin = [System.Windows.Markup.XamlReader]::Parse($mainXaml)
    if ($null -eq $mainWin) {
        throw 'MainWindow.xaml devolvió null al parsear'
    }
    $mainWin.Close()

    $guiText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'UI\GuiController.psm1'), [System.Text.Encoding]::UTF8)
    if ($guiText -match "(?s)\`$wizXaml = @'\r?\n(.*?)\r?\n'@") {
        $wizWin = [System.Windows.Markup.XamlReader]::Parse($Matches[1])
        if ($null -eq $wizWin) {
            throw 'wizXaml devolvió null al parsear'
        }
        $wizWin.Close()
    }
    else {
        throw 'No se pudo extraer $wizXaml de GuiController.psm1'
    }

    if ($guiText -match "(?s)\`$dlgXaml = @'\r?\n(.*?)\r?\n'@") {
        $dlgWin = [System.Windows.Markup.XamlReader]::Parse($Matches[1])
        if ($null -eq $dlgWin) {
            throw 'dlgXaml devolvió null al parsear'
        }
        $dlgWin.Close()
    }
    else {
        throw 'No se pudo extraer $dlgXaml de GuiController.psm1'
    }
}

Invoke-TestCase 'Importación de todos los módulos Core y UI bajo StrictMode' {
    $modules = @(
        'Core\HardwareAuditor.psm1',
        'Core\SafetyManager.psm1',
        'Core\TweakEngine.psm1',
        'Core\RunspaceManager.psm1',
        'UI\GuiController.psm1',
        'UI\CliController.psm1'
    )
    foreach ($m in $modules) {
        Import-Module -Name (Join-Path $RepoRoot $m) -Force -DisableNameChecking -ErrorAction Stop
    }
}

$hwProfile = $null
$evaluated = @()

Invoke-TestCase 'Auditoría de Hardware (Get-WinForgeHardwareProfile) y Guardrails' {
    $script:hwProfile = Get-WinForgeHardwareProfile
    if ($null -eq $script:hwProfile -or [string]::IsNullOrWhiteSpace($script:hwProfile.OSName)) {
        throw 'HardwareProfile vacío o inválido'
    }
    Write-Host ("       -> OS: {0} | RAM: {1} GB | Disco: {2} | Tier: {3}" -f $script:hwProfile.OSName, $script:hwProfile.TotalRamGB, $script:hwProfile.Storage.MediaType, $script:hwProfile.RecommendedTier) -ForegroundColor DarkGray

    $script:evaluated = @(Resolve-WinForgeTweakCompatibility -Tweaks $script:tweaks -HardwareProfile $script:hwProfile)
    if ($script:evaluated.Count -ne $script:tweaks.Count) {
        throw 'Resolve-WinForgeTweakCompatibility no devolvió el mismo número de tweaks'
    }
}

Invoke-TestCase 'Ejecución en solo lectura de todos los detectScript bajo StrictMode' {
    $errorsFound = @()
    foreach ($tw in $script:evaluated) {
        $st = Get-WinForgeTweakStatus -Tweak $tw
        if ($null -ne $st.Error) {
            $errorsFound += "$($tw.id): $($st.Error)"
        }
    }
    if ($errorsFound.Count -gt 0) {
        throw ($errorsFound -join ' | ')
    }
}

Invoke-TestCase 'Lectura de Aplicaciones de Inicio (Get-WinForgeStartupApps)' {
    $apps = @(Get-WinForgeStartupApps)
    Write-Host "       -> Entradas de inicio detectadas: $($apps.Count)" -ForegroundColor DarkGray
}

Invoke-TestCase 'Inicialización y cierre limpio de RunspacePool' {
    $mods = @(
        (Join-Path $RepoRoot 'Core\HardwareAuditor.psm1'),
        (Join-Path $RepoRoot 'Core\SafetyManager.psm1'),
        (Join-Path $RepoRoot 'Core\TweakEngine.psm1'),
        (Join-Path $RepoRoot 'Core\RunspaceManager.psm1')
    )
    $ctx = Initialize-WinForgeRunspacePool -MaxThreads 2 -ModulePaths $mods
    if ($null -eq $ctx -or $null -eq $ctx.SyncHash.LogQueue) {
        throw 'RunspaceContext o LogQueue no inicializados'
    }
    Close-WinForgeRunspacePool -RunspaceContext $ctx
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host ("  Resultado: {0} pruebas exitosas, {1} fallidas" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '============================================================' -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
}
exit 0
