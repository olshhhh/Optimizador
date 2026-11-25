<#
.SYNOPSIS
    WinForge Engine - GuiController.
.DESCRIPTION
    Controlador WPF puro que parsea UI/MainWindow.xaml mediante XamlReader, construye
    tarjetas con Transparencia Radical y Nivel de Riesgo, incluye el Asistente Guiado
    paso a paso y el Gestor de Apps de Inicio, delegando
    todas las tareas largas al RunspacePool.
#>

Set-StrictMode -Version Latest

function Convert-ColorFromHex {
    param([string]$Hex)
    $converter = [System.Windows.Media.BrushConverter]::new()
    return $converter.ConvertFromString($Hex)
}

function Add-WinForgeLogLine {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SyncHash,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $Message`r`n"

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        $console = $SyncHash.Controls['TxtConsoleLog']
        if ($null -ne $console) {
            $console.AppendText($line)
            $console.ScrollToEnd()
        }
    }
}

function Update-SelectedCounterUi {
    param([hashtable]$SyncHash)

    $selectedCount = 0
    foreach ($entry in $SyncHash.TweakCheckBoxes.GetEnumerator()) {
        if ($entry.Value.IsChecked -eq $true -and $entry.Value.IsEnabled) {
            $selectedCount++
        }
    }

    $btnApply = $SyncHash.Controls['BtnApplySelected']
    if ($null -ne $btnApply) {
        $btnApply.Content = "Aplicar Seleccionados ($selectedCount)"
        $btnApply.IsEnabled = (-not $SyncHash.IsBusy) -and ($selectedCount -gt 0)
    }
}

function Set-UiBusyState {
    param(
        [hashtable]$SyncHash,
        [bool]$Busy,
        [string]$StatusText = ''
    )

    $SyncHash.IsBusy = $Busy

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        $controlsToToggle = @(
            'BtnGuidedWizard', 'BtnRefreshStatus', 'BtnRollbackAll',
            'BtnProfileLegacy', 'BtnProfileGaming', 'BtnProfileTrabajo', 'BtnProfileLaptop', 'BtnProfileExtremo',
            'BtnSelectAllVisible', 'BtnClearSelection'
        )
        foreach ($name in $controlsToToggle) {
            $ctrl = $SyncHash.Controls[$name]
            if ($null -ne $ctrl) {
                $ctrl.IsEnabled = (-not $Busy)
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($StatusText)) {
            $SyncHash.Controls['TxtSessionStatus'].Text = $StatusText
        }

        Update-SelectedCounterUi -SyncHash $SyncHash
    }
}

function New-TweakCardElement {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Tweak,
        [Parameter(Mandatory)]
        [hashtable]$SyncHash,
        [Parameter(Mandatory)]
        [PSCustomObject]$RunspaceContext
    )

    $isBlocked = ($Tweak.GuardStatus -eq 'Blocked')
    $isWarning = ($Tweak.GuardStatus -eq 'Warning')

    $borderBrush = if ($isBlocked) {
        Convert-ColorFromHex '#E81123'
    }
    elseif ($isWarning) {
        Convert-ColorFromHex '#FF8C00'
    }
    else {
        Convert-ColorFromHex '#3F3F3F'
    }

    $card = [System.Windows.Controls.Border]::new()
    $card.Background = Convert-ColorFromHex '#2D2D2D'
    $card.BorderBrush = $borderBrush
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $card.Padding = [System.Windows.Thickness]::new(14)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

    $rootStack = [System.Windows.Controls.StackPanel]::new()
    $card.Child = $rootStack

    $headerGrid = [System.Windows.Controls.Grid]::new()
    $col0 = [System.Windows.Controls.ColumnDefinition]::new()
    $col0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $col1 = [System.Windows.Controls.ColumnDefinition]::new()
    $col1.Width = [System.Windows.GridLength]::Auto
    $headerGrid.ColumnDefinitions.Add($col0)
    $headerGrid.ColumnDefinitions.Add($col1)

    $leftStack = [System.Windows.Controls.StackPanel]::new()
    $leftStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    [System.Windows.Controls.Grid]::SetColumn($leftStack, 0)

    $chk = [System.Windows.Controls.CheckBox]::new()
    $chk.IsEnabled = (-not $isBlocked)
    $chk.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $chk.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $chk.Tag = $Tweak.id
    $chk.Add_Checked({ Update-SelectedCounterUi -SyncHash $SyncHash }.GetNewClosure())
    $chk.Add_Unchecked({ Update-SelectedCounterUi -SyncHash $SyncHash }.GetNewClosure())
    $SyncHash.TweakCheckBoxes[$Tweak.id] = $chk
    [void]$leftStack.Children.Add($chk)

    $titleText = [System.Windows.Controls.TextBlock]::new()
    $titleText.Text = $Tweak.name
    $titleText.FontSize = 14.5
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleText.Foreground = if ($isBlocked) { Convert-ColorFromHex '#A0A0A0' } else { Convert-ColorFromHex '#FFFFFF' }
    $titleText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$leftStack.Children.Add($titleText)

    $compBadge = [System.Windows.Controls.Border]::new()
    $compBadge.Background = Convert-ColorFromHex '#202020'
    $compBadge.BorderBrush = Convert-ColorFromHex '#3F3F3F'
    $compBadge.BorderThickness = [System.Windows.Thickness]::new(1)
    $compBadge.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $compBadge.Padding = [System.Windows.Thickness]::new(7, 2, 7, 2)
    $compBadge.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    $compBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $compTxt = [System.Windows.Controls.TextBlock]::new()
    $compTxt.Text = "$($Tweak.category) • $($Tweak.component)"
    $compTxt.FontSize = 11
    $compTxt.Foreground = Convert-ColorFromHex '#A0A0A0'
    $compBadge.Child = $compTxt
    [void]$leftStack.Children.Add($compBadge)

    # Badge Nivel de Riesgo
    $riskBadge = [System.Windows.Controls.Border]::new()
    $riskBadge.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $riskBadge.Padding = [System.Windows.Thickness]::new(7, 2, 7, 2)
    $riskBadge.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $riskBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $riskTxt = [System.Windows.Controls.TextBlock]::new()
    $riskTxt.FontSize = 11
    $riskTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
    $riskTxt.Text = "Riesgo: $($Tweak.riskLevel)"

    switch ($Tweak.riskLevel) {
        'Alto' {
            $riskBadge.Background = Convert-ColorFromHex '#3A181B'
            $riskTxt.Foreground = Convert-ColorFromHex '#FF6B6B'
        }
        'Moderado' {
            $riskBadge.Background = Convert-ColorFromHex '#3A2810'
            $riskTxt.Foreground = Convert-ColorFromHex '#FFA940'
        }
        default {
            $riskBadge.Background = Convert-ColorFromHex '#123227'
            $riskTxt.Foreground = Convert-ColorFromHex '#34D399'
        }
    }
    $riskBadge.Child = $riskTxt
    [void]$leftStack.Children.Add($riskBadge)

    $rightStack = [System.Windows.Controls.StackPanel]::new()
    $rightStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $rightStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($rightStack, 1)

    $statusBadge = [System.Windows.Controls.Border]::new()
    $statusBadge.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $statusBadge.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
    $statusBadge.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)

    $statusTxt = [System.Windows.Controls.TextBlock]::new()
    $statusTxt.FontSize = 11.5
    $statusTxt.FontWeight = [System.Windows.FontWeights]::SemiBold

    if ($isBlocked) {
        $statusBadge.Background = Convert-ColorFromHex '#3A181B'
        $statusTxt.Foreground = Convert-ColorFromHex '#FF6B6B'
        $statusTxt.Text = 'BLOQUEADO'
    }
    else {
        $statusBadge.Background = Convert-ColorFromHex '#202020'
        $statusTxt.Foreground = Convert-ColorFromHex '#A0A0A0'
        $statusTxt.Text = $Tweak.DetectionState
    }

    $statusBadge.Child = $statusTxt
    $SyncHash.TweakStatusLabels[$Tweak.id] = [PSCustomObject]@{
        Badge = $statusBadge
        Text  = $statusTxt
    }
    [void]$rightStack.Children.Add($statusBadge)

    if (-not $isBlocked -and $Tweak.category -ne 'Maintenance') {
        $btnRevertOne = [System.Windows.Controls.Button]::new()
        $btnRevertOne.Content = 'Revertir'
        $btnRevertOne.Style = $SyncHash.Window.Resources['FluentSecondaryButton']
        $btnRevertOne.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
        $btnRevertOne.FontSize = 11.5
        $btnRevertOne.Tag = $Tweak
        $btnRevertOne.Add_Click({
            param($s, $e)
            if ($SyncHash.IsBusy) { return }
            $tw = $s.Tag
            Set-UiBusyState -SyncHash $SyncHash -Busy $true -StatusText "Revirtiendo $($tw.name)..."
            Invoke-WinForgeAsync -RunspaceContext $RunspaceContext -ScriptBlock {
                param($SyncHash, $Tweak)
                return Invoke-WinForgeTweakRevert -Tweak $Tweak
            } -Parameters @{ Tweak = $tw } -OnComplete {
                param($res)
                Add-WinForgeLogLine -SyncHash $SyncHash -Message "$($res.Name): $($res.Message)"
                Update-TweakStatusBadge -SyncHash $SyncHash -Tweak $tw
                Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Listo'
            }.GetNewClosure() -OnError {
                param($err)
                Add-WinForgeLogLine -SyncHash $SyncHash -Message "Error al revertir $($tw.name): $err"
                Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Error'
            }.GetNewClosure() | Out-Null
        }.GetNewClosure())
        [void]$rightStack.Children.Add($btnRevertOne)
    }

    [void]$headerGrid.Children.Add($leftStack)
    [void]$headerGrid.Children.Add($rightStack)
    [void]$rootStack.Children.Add($headerGrid)

    if ($isBlocked -or $isWarning) {
        $alertBorder = [System.Windows.Controls.Border]::new()
        $alertBorder.Background = if ($isBlocked) { Convert-ColorFromHex '#3A181B' } else { Convert-ColorFromHex '#3A2810' }
        $alertBorder.BorderBrush = if ($isBlocked) { Convert-ColorFromHex '#E81123' } else { Convert-ColorFromHex '#FF8C00' }
        $alertBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        $alertBorder.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $alertBorder.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
        $alertBorder.Margin = [System.Windows.Thickness]::new(26, 8, 0, 4)

        $alertTxt = [System.Windows.Controls.TextBlock]::new()
        $alertTxt.Text = $Tweak.GuardReason
        $alertTxt.Foreground = if ($isBlocked) { Convert-ColorFromHex '#FF8A8A' } else { Convert-ColorFromHex '#FFA940' }
        $alertTxt.FontSize = 12
        $alertTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
        $alertTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $alertBorder.Child = $alertTxt
        [void]$rootStack.Children.Add($alertBorder)
    }

    $detailsGrid = [System.Windows.Controls.StackPanel]::new()
    $detailsGrid.Margin = [System.Windows.Thickness]::new(26, 8, 0, 0)

    $descTxt = [System.Windows.Controls.TextBlock]::new()
    $descTxt.Text = $Tweak.description
    $descTxt.Foreground = Convert-ColorFromHex '#E0E0E0'
    $descTxt.FontSize = 12.5
    $descTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$detailsGrid.Children.Add($descTxt)

    $targetTxt = [System.Windows.Controls.TextBlock]::new()
    $targetTxt.Text = "Objetivo técnico: $($Tweak.targetPath)"
    $targetTxt.Foreground = Convert-ColorFromHex '#A0A0A0'
    $targetTxt.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
    $targetTxt.FontSize = 11.5
    $targetTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $targetTxt.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$detailsGrid.Children.Add($targetTxt)

    $benefitTxt = [System.Windows.Controls.TextBlock]::new()
    $benefitTxt.Text = "Beneficio real: $($Tweak.benefit)"
    $benefitTxt.Foreground = Convert-ColorFromHex '#38BDF8'
    $benefitTxt.FontSize = 12
    $benefitTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $benefitTxt.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$detailsGrid.Children.Add($benefitTxt)

    $sideTxt = [System.Windows.Controls.TextBlock]::new()
    $sideTxt.Text = "Desventaja / Impacto: $($Tweak.sideEffect)"
    $sideTxt.Foreground = Convert-ColorFromHex '#F59E0B'
    $sideTxt.FontSize = 12
    $sideTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $sideTxt.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    [void]$detailsGrid.Children.Add($sideTxt)

    [void]$rootStack.Children.Add($detailsGrid)

    return $card
}

function Update-TweakStatusBadge {
    param(
        [hashtable]$SyncHash,
        [PSCustomObject]$Tweak
    )

    if ($Tweak.GuardStatus -eq 'Blocked') {
        return
    }

    $entry = $SyncHash.TweakStatusLabels[$Tweak.id]
    if ($null -eq $entry) { return }

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        if ($Tweak.category -eq 'Maintenance') {
            $entry.Badge.Background = Convert-ColorFromHex '#1E293B'
            $entry.Text.Foreground = Convert-ColorFromHex '#38BDF8'
            $entry.Text.Text = 'Bajo demanda'
        }
        elseif ($Tweak.IsApplied) {
            $entry.Badge.Background = Convert-ColorFromHex '#064E3B'
            $entry.Text.Foreground = Convert-ColorFromHex '#34D399'
            $entry.Text.Text = 'APLICADO'
        }
        else {
            $entry.Badge.Background = Convert-ColorFromHex '#202020'
            $entry.Text.Foreground = Convert-ColorFromHex '#A0A0A0'
            $entry.Text.Text = 'ORIGINAL'
        }
    }
}

function Render-TweakList {
    param(
        [hashtable]$SyncHash,
        [PSCustomObject[]]$Tweaks,
        [string]$CategoryFilter,
        [string]$SearchText
    )

    $SyncHash.Controls['TweakCardsScrollViewer'].Visibility = [System.Windows.Visibility]::Visible
    $SyncHash.Controls['StartupAppsScrollViewer'].Visibility = [System.Windows.Visibility]::Collapsed

    $panel = $SyncHash.Controls['TweakCardsPanel']
    $panel.Children.Clear()

    $query = if ($null -eq $SearchText) { '' } else { $SearchText.Trim() }

    foreach ($tweak in $Tweaks) {
        if ($CategoryFilter -ne 'All' -and $tweak.category -ne $CategoryFilter) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($query)) {
            $haystack = "$($tweak.name) $($tweak.description) $($tweak.id) $($tweak.targetPath) $($tweak.riskLevel)"
            if ($haystack -notlike "*$query*") {
                continue
            }
        }

        $card = $SyncHash.TweakCards[$tweak.id]
        if ($null -ne $card) {
            [void]$panel.Children.Add($card)
        }
    }
}

function Render-StartupAppsList {
    param(
        [hashtable]$SyncHash,
        [PSCustomObject]$RunspaceContext
    )

    $SyncHash.Controls['TweakCardsScrollViewer'].Visibility = [System.Windows.Visibility]::Collapsed
    $SyncHash.Controls['StartupAppsScrollViewer'].Visibility = [System.Windows.Visibility]::Visible

    $panel = $SyncHash.Controls['StartupAppsPanel']
    $panel.Children.Clear()

    $hdr = [System.Windows.Controls.TextBlock]::new()
    $hdr.Text = 'Gestor Reversible de Aplicaciones de Inicio (HKCU / HKLM Run)'
    $hdr.FontSize = 15
    $hdr.FontWeight = [System.Windows.FontWeights]::Bold
    $hdr.Foreground = Convert-ColorFromHex '#FFFFFF'
    $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [void]$panel.Children.Add($hdr)

    $sub = [System.Windows.Controls.TextBlock]::new()
    $sub.Text = 'Al desactivar una app de inicio, WinForge la mueve de forma segura a una clave de respaldo para que puedas reactivarla con 1 clic en cualquier momento.'
    $sub.FontSize = 12
    $sub.Foreground = Convert-ColorFromHex '#A0A0A0'
    $sub.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $sub.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    [void]$panel.Children.Add($sub)

    $apps = @(Get-WinForgeStartupApps)
    if ($apps.Count -eq 0) {
        $empty = [System.Windows.Controls.TextBlock]::new()
        $empty.Text = 'No se detectaron entradas de inicio en el Registro.'
        $empty.Foreground = Convert-ColorFromHex '#A0A0A0'
        [void]$panel.Children.Add($empty)
        return
    }

    foreach ($app in $apps) {
        $card = [System.Windows.Controls.Border]::new()
        $card.Background = Convert-ColorFromHex '#2D2D2D'
        $card.BorderBrush = Convert-ColorFromHex '#3F3F3F'
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $card.Padding = [System.Windows.Thickness]::new(12)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

        $grid = [System.Windows.Controls.Grid]::new()
        $c0 = [System.Windows.Controls.ColumnDefinition]::new()
        $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c1 = [System.Windows.Controls.ColumnDefinition]::new()
        $c1.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($c0)
        $grid.ColumnDefinitions.Add($c1)

        $info = [System.Windows.Controls.StackPanel]::new()
        [System.Windows.Controls.Grid]::SetColumn($info, 0)

        $t1 = [System.Windows.Controls.TextBlock]::new()
        $t1.Text = "$($app.Name)  [$($app.Scope)]"
        $t1.FontSize = 13.5
        $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
        $t1.Foreground = Convert-ColorFromHex '#FFFFFF'
        [void]$info.Children.Add($t1)

        $t2 = [System.Windows.Controls.TextBlock]::new()
        $t2.Text = $app.Command
        $t2.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $t2.FontSize = 11
        $t2.Foreground = Convert-ColorFromHex '#A0A0A0'
        $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t2.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        [void]$info.Children.Add($t2)

        $btn = [System.Windows.Controls.Button]::new()
        [System.Windows.Controls.Grid]::SetColumn($btn, 1)
        $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $btn.Style = $SyncHash.Window.Resources['FluentSecondaryButton']
        $btn.Content = if ($app.Enabled) { 'Desactivar Inicio' } else { 'Reactivar Inicio' }
        $btn.Foreground = if ($app.Enabled) { Convert-ColorFromHex '#FFA940' } else { Convert-ColorFromHex '#34D399' }
        $btn.Tag = $app
        $btn.Add_Click({
            param($s, $e)
            $targetApp = $s.Tag
            $newState = (-not $targetApp.Enabled)
            $null = Set-WinForgeStartupAppState -StartupApp $targetApp -Enable $newState
            Add-WinForgeLogLine -SyncHash $SyncHash -Message "Inicio '$($targetApp.Name)' -> $(if ($newState) { 'Activado' } else { 'Desactivado' })."
            Render-StartupAppsList -SyncHash $SyncHash -RunspaceContext $RunspaceContext
        }.GetNewClosure())

        [void]$grid.Children.Add($info)
        [void]$grid.Children.Add($btn)
        $card.Child = $grid
        [void]$panel.Children.Add($card)
    }
}

function Show-GuidedWizardDialog {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SyncHash,
        [Parameter(Mandatory)]
        [PSCustomObject]$HardwareProfile,
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Tweaks
    )

    $wizXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Asistente Guiado WinForge (Modo Paso a Paso)"
        Width="640" Height="520"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#202020" Foreground="#FFFFFF"
        FontFamily="Segoe UI Variable Text, Segoe UI">
    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,14">
            <TextBlock Text="Asistente Inteligente de Optimización" FontSize="19" FontWeight="Bold" Foreground="#FFFFFF"/>
            <TextBlock x:Name="TxtWizHw" Text="Hardware detectado..." FontSize="12" Foreground="#38BDF8" Margin="0,4,0,0"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <Border Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="1. ¿Cuál es el uso principal de este equipo?" FontWeight="SemiBold" FontSize="13"/>
                        <ComboBox x:Name="CmbWizUsage" Margin="0,8,0,0" Height="30">
                            <ComboBoxItem Content="PC Antiguo / Rescate de Recursos (HDD o &lt;=8GB RAM)" Tag="Legacy"/>
                            <ComboBoxItem Content="Gaming y Baja Latencia (P-Cores, HAGS, Nagle)" Tag="Gaming"/>
                            <ComboBoxItem Content="Trabajo / Productividad / Oficina" Tag="Trabajo"/>
                            <ComboBoxItem Content="Laptop / Priorizar Batería y Movilidad" Tag="Laptop"/>
                        </ComboBox>
                    </StackPanel>
                </Border>

                <Border Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="2. Privacidad, Telemetría e IA (Windows 11 24H2+)" FontWeight="SemiBold" FontSize="13"/>
                        <CheckBox x:Name="ChkWizPrivacy" Content="Desactivar telemetría DiagTrack, Copilot, Recall IA, Advertising ID y Edge Boost" IsChecked="True" Foreground="#E0E0E0" Margin="0,8,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="3. Aplicaciones de Microsoft Store (Debloat)" FontWeight="SemiBold" FontSize="13"/>
                        <CheckBox x:Name="ChkWizDebloat" Content="Eliminar Cortana, Bing News/Weather, Clipchamp y Solitaire" IsChecked="True" Foreground="#E0E0E0" Margin="0,8,0,4"/>
                        <CheckBox x:Name="ChkWizRemoveXbox" Content="Eliminar también Xbox Game Bar / Xbox Apps (No juego en este PC)" IsChecked="False" Foreground="#FFA940" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,10">
                    <StackPanel>
                        <TextBlock Text="4. ¿Utilizas impresora física o 'Imprimir a PDF'?" FontWeight="SemiBold" FontSize="13"/>
                        <CheckBox x:Name="ChkWizPrinter" Content="Sí, utilizo impresoras (Mantener servicio Print Spooler activo)" IsChecked="True" Foreground="#E0E0E0" Margin="0,8,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="1" CornerRadius="6" Padding="12">
                    <StackPanel>
                        <TextBlock Text="5. Optimización de DNS (Opcional)" FontWeight="SemiBold" FontSize="13"/>
                        <ComboBox x:Name="CmbWizDns" Margin="0,8,0,0" Height="30">
                            <ComboBoxItem Content="Mantener DNS actual / DHCP del router" Tag="NONE" IsSelected="True"/>
                            <ComboBoxItem Content="Cloudflare DNS (1.1.1.1) — Máxima velocidad" Tag="NET_DNS_CLOUDFLARE"/>
                            <ComboBoxItem Content="AdGuard DNS (94.140.14.14) — Bloqueo de anuncios/rastreadores" Tag="NET_DNS_ADGUARD"/>
                        </ComboBox>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="BtnWizCancel" Content="Cancelar" Width="100" Height="34" Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#3F3F3F" Margin="0,0,10,0"/>
            <Button x:Name="BtnWizBuild" Content="Generar Selección Segura" Width="190" Height="34" Background="#0078D4" Foreground="#FFFFFF" FontWeight="SemiBold" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $wizWin = [System.Windows.Markup.XamlReader]::Parse($wizXaml)
    $wizWin.Owner = $SyncHash.Window

    $txtHw = $wizWin.FindName('TxtWizHw')
    $cmbUsage = $wizWin.FindName('CmbWizUsage')
    $chkPriv = $wizWin.FindName('ChkWizPrivacy')
    $chkDebloat = $wizWin.FindName('ChkWizDebloat')
    $chkXbox = $wizWin.FindName('ChkWizRemoveXbox')
    $chkPrinter = $wizWin.FindName('ChkWizPrinter')
    $cmbDns = $wizWin.FindName('CmbWizDns')

    $txtHw.Text = "Recomendación automática para tu hardware ($($HardwareProfile.TotalRamGB) GB RAM • $($HardwareProfile.Storage.MediaType) • $($HardwareProfile.Chassis.FormFactor)): $($HardwareProfile.RecommendedTier)"

    foreach ($item in $cmbUsage.Items) {
        if ($item.Tag -eq $HardwareProfile.RecommendedTier) {
            $cmbUsage.SelectedItem = $item
            break
        }
    }
    if ($null -eq $cmbUsage.SelectedItem) {
        $cmbUsage.SelectedIndex = 0
    }

    $wizWin.FindName('BtnWizCancel').Add_Click({ $wizWin.DialogResult = $false; $wizWin.Close() })
    $wizWin.FindName('BtnWizBuild').Add_Click({ $wizWin.DialogResult = $true; $wizWin.Close() })

    if ($wizWin.ShowDialog() -ne $true) {
        return
    }

    $chosenTier = $cmbUsage.SelectedItem.Tag
    $idsToSelect = [System.Collections.Generic.HashSet[string]]::new()

    # Base segura universal
    foreach ($id in @('PERF_WAIT_TO_KILL', 'PERF_NTFS_LAST_ACCESS', 'NET_DNS_CACHE', 'SVC_FAX', 'SVC_REMOTE_REGISTRY', 'SVC_MAPS_BROKER')) {
        [void]$idsToSelect.Add($id)
    }

    switch ($chosenTier) {
        'Legacy' {
            foreach ($id in @('PERF_TRANSPARENCY_OFF', 'PERF_VISUAL_EFFECTS', 'PERF_GAME_DVR', 'SVC_WER')) { [void]$idsToSelect.Add($id) }
        }
        'Gaming' {
            foreach ($id in @('PERF_SYSMAIN', 'PERF_GAME_DVR', 'PERF_HAGS_ON', 'PERF_HYBRID_PCORE', 'NET_NAGLE', 'NET_THROTTLING')) { [void]$idsToSelect.Add($id) }
        }
        'Trabajo' {
            foreach ($id in @('PERF_WIN11_MENU', 'PERF_GAME_DVR')) { [void]$idsToSelect.Add($id) }
        }
        'Laptop' {
            foreach ($id in @('PERF_GAME_DVR')) { [void]$idsToSelect.Add($id) }
        }
    }

    if ($chkPriv.IsChecked -eq $true) {
        foreach ($id in @('PRIV_DIAGTRACK', 'PRIV_WIN11_COPILOT', 'PRIV_WIN11_AI_RECALL', 'PRIV_DELIVERY_OPT', 'PRIV_CORTANA', 'PRIV_CONSUMER_EXP', 'PRIV_EDGE_TELEMETRY', 'PRIV_ADVERTISING_ID', 'PRIV_ACTIVITY_HISTORY')) {
            [void]$idsToSelect.Add($id)
        }
    }

    if ($chkDebloat.IsChecked -eq $true) {
        foreach ($id in @('DEBLOAT_CORTANA_APP', 'DEBLOAT_BING_WEATHER', 'DEBLOAT_CLIPCHAMP', 'DEBLOAT_SOLITAIRE')) {
            [void]$idsToSelect.Add($id)
        }
    }

    if ($chkXbox.IsChecked -eq $true) {
        [void]$idsToSelect.Add('DEBLOAT_XBOX_APPS')
    }

    if ($chkPrinter.IsChecked -ne $true) {
        [void]$idsToSelect.Add('SVC_SPOOLER')
    }

    $dnsTag = $cmbDns.SelectedItem.Tag
    if ($dnsTag -ne 'NONE') {
        [void]$idsToSelect.Add($dnsTag)
    }

    foreach ($chk in $SyncHash.TweakCheckBoxes.Values) { $chk.IsChecked = $false }
    $selectedCount = 0
    foreach ($tid in $idsToSelect) {
        $chk = $SyncHash.TweakCheckBoxes[$tid]
        if ($null -ne $chk -and $chk.IsEnabled) {
            $chk.IsChecked = $true
            $selectedCount++
        }
    }

    Update-SelectedCounterUi -SyncHash $SyncHash
    Add-WinForgeLogLine -SyncHash $SyncHash -Message "Asistente Guiado completado ($chosenTier): $selectedCount ajustes compatibles preseleccionados. Revisa los detalles y pulsa 'Aplicar Seleccionados'."
}

function Start-AsyncStatusAudit {
    param(
        [hashtable]$SyncHash,
        [PSCustomObject]$RunspaceContext,
        [PSCustomObject[]]$Tweaks
    )

    Set-UiBusyState -SyncHash $SyncHash -Busy $true -StatusText 'Auditando estado del sistema...'
    Update-WinForgeUi -SyncHash $SyncHash -Action {
        $SyncHash.Controls['TxtProgressDetail'].Text = 'Auditando estado de ajustes...'
        $SyncHash.Controls['MainProgressBar'].IsIndeterminate = $true
    }

    Invoke-WinForgeAsync -RunspaceContext $RunspaceContext -ScriptBlock {
        param($SyncHash, $Tweaks)
        $results = @()
        foreach ($t in $Tweaks) {
            if ($t.GuardStatus -eq 'Blocked') { continue }
            $status = Get-WinForgeTweakStatus -Tweak $t
            $t.IsApplied = $status.IsApplied
            $t.DetectionState = $status.Label
            $results += $t
        }
        return $results
    } -Parameters @{ Tweaks = $Tweaks } -OnComplete {
        param($updatedTweaks)
        foreach ($t in $updatedTweaks) {
            Update-TweakStatusBadge -SyncHash $SyncHash -Tweak $t
        }
        Update-WinForgeUi -SyncHash $SyncHash -Action {
            $SyncHash.Controls['MainProgressBar'].IsIndeterminate = $false
            $SyncHash.Controls['MainProgressBar'].Value = 100
            $SyncHash.Controls['TxtProgressDetail'].Text = 'Auditoría completada'
        }
        Add-WinForgeLogLine -SyncHash $SyncHash -Message "Auditoría inicial completada sobre $($Tweaks.Count) ajustes."
        Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Listo'
    }.GetNewClosure() -OnError {
        param($err)
        Update-WinForgeUi -SyncHash $SyncHash -Action {
            $SyncHash.Controls['MainProgressBar'].IsIndeterminate = $false
        }
        Add-WinForgeLogLine -SyncHash $SyncHash -Message "Error en auditoría: $err"
        Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Error'
    }.GetNewClosure() | Out-Null
}

function Start-WinForgeGui {
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

        [Parameter(Mandatory)]
        [PSCustomObject]$RunspaceContext
    )

    $xamlContent = [System.IO.File]::ReadAllText($Config.XamlFile, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)

    $syncHash = $RunspaceContext.SyncHash
    $syncHash.Window = $window
    $syncHash['TweakCheckBoxes'] = @{}
    $syncHash['TweakStatusLabels'] = @{}
    $syncHash['TweakCards'] = @{}
    $syncHash['CurrentCategory'] = 'All'

    $controlNames = @(
        'TxtHardwareOS', 'TxtHardwareCPU', 'TxtHardwareRAM', 'TxtHardwareStorage', 'TxtHardwareChassis',
        'BadgeStorage', 'BadgeChassis', 'TxtGuardrailSummary', 'TxtSessionStatus',
        'BtnGuidedWizard', 'BtnRefreshStatus', 'BtnRollbackAll',
        'BtnProfileLegacy', 'BtnProfileGaming', 'BtnProfileTrabajo', 'BtnProfileLaptop', 'BtnProfileExtremo',
        'TxtSearchBox', 'ChkRestorePoint', 'BtnSelectAllVisible', 'BtnClearSelection', 'BtnApplySelected',
        'NavAll', 'NavPerformance', 'NavPrivacy', 'NavNetwork', 'NavServices', 'NavDebloat', 'NavMaintenance', 'NavStartup',
        'TweakCardsScrollViewer', 'TweakCardsPanel', 'StartupAppsScrollViewer', 'StartupAppsPanel',
        'TxtProgressDetail', 'MainProgressBar', 'TxtConsoleLog'
    )

    foreach ($name in $controlNames) {
        $syncHash.Controls[$name] = $window.FindName($name)
    }

    $cpuTypeLabel = if ($HardwareProfile.IsHybridCpu) { 'Híbrido P/E' } elseif ($HardwareProfile.IsLowEndCpu) { 'Legacy' } else { 'Estándar' }
    $syncHash.Controls['TxtHardwareOS'].Text = "OS: $($HardwareProfile.OSName) ($($HardwareProfile.DisplayVersion) • Build $($HardwareProfile.FullBuild))"
    $syncHash.Controls['TxtHardwareCPU'].Text = "CPU ($cpuTypeLabel): $($HardwareProfile.CpuName) ($($HardwareProfile.CpuCores)C/$($HardwareProfile.CpuThreads)T)"
    $syncHash.Controls['TxtHardwareRAM'].Text = "RAM ($($HardwareProfile.RamTier)): $($HardwareProfile.FreeRamGB)/$($HardwareProfile.TotalRamGB) GB libres"
    $syncHash.Controls['TxtHardwareStorage'].Text = "Disco $($HardwareProfile.Storage.DriveLetter) $($HardwareProfile.Storage.DisplayText)"
    $syncHash.Controls['TxtHardwareChassis'].Text = "Chasis: $($HardwareProfile.Chassis.FormFactor) • Energía: $($HardwareProfile.ActivePowerPlan)"

    $guardNotes = [System.Collections.Generic.List[string]]::new()
    $guardNotes.Add("• Perfil sugerido: $($HardwareProfile.RecommendedTier)")
    if ($HardwareProfile.Storage.IsHDD) {
        $syncHash.Controls['BadgeStorage'].BorderBrush = Convert-ColorFromHex '#E81123'
        $syncHash.Controls['TxtHardwareStorage'].Foreground = Convert-ColorFromHex '#FF6B6B'
        $guardNotes.Add('• HDD detectado: SysMain y SSDOnly bloqueados.')
    }
    if ($HardwareProfile.TotalRamGB -le 8.5) {
        $guardNotes.Add('• RAM <= 8 GB: Memory Compression protegida.')
    }
    if ($HardwareProfile.Chassis.IsLaptop) {
        $syncHash.Controls['BadgeChassis'].BorderBrush = Convert-ColorFromHex '#FF8C00'
        $syncHash.Controls['TxtHardwareChassis'].Foreground = Convert-ColorFromHex '#FFA940'
        $guardNotes.Add('• Laptop: Alertas de batería/hibernación activas.')
    }

    $syncHash.Controls['TxtGuardrailSummary'].Text = ($guardNotes -join "`n")

    foreach ($tweak in $Tweaks) {
        $card = New-TweakCardElement -Tweak $tweak -SyncHash $syncHash -RunspaceContext $RunspaceContext
        $syncHash.TweakCards[$tweak.id] = $card
    }

    Render-TweakList -SyncHash $syncHash -Tweaks $Tweaks -CategoryFilter 'All' -SearchText ''

    $navMap = @{
        'NavAll'         = 'All'
        'NavPerformance' = 'Performance'
        'NavPrivacy'     = 'Privacy'
        'NavNetwork'     = 'Network'
        'NavServices'    = 'Services'
        'NavDebloat'     = 'Debloat'
        'NavMaintenance' = 'Maintenance'
    }

    foreach ($btnName in $navMap.Keys) {
        $cat = $navMap[$btnName]
        $syncHash.Controls[$btnName].Add_Click({
            $syncHash.CurrentCategory = $cat
            Render-TweakList -SyncHash $syncHash -Tweaks $Tweaks -CategoryFilter $cat -SearchText $syncHash.Controls['TxtSearchBox'].Text
        }.GetNewClosure())
    }

    $syncHash.Controls['NavStartup'].Add_Click({
        $syncHash.CurrentCategory = 'Startup'
        Render-StartupAppsList -SyncHash $syncHash -RunspaceContext $RunspaceContext
    }.GetNewClosure())

    $syncHash.Controls['TxtSearchBox'].Add_TextChanged({
        if ($syncHash.CurrentCategory -ne 'Startup') {
            Render-TweakList -SyncHash $syncHash -Tweaks $Tweaks -CategoryFilter $syncHash.CurrentCategory -SearchText $syncHash.Controls['TxtSearchBox'].Text
        }
    }.GetNewClosure())

    $syncHash.Controls['BtnGuidedWizard'].Add_Click({
        if (-not $syncHash.IsBusy) {
            Show-GuidedWizardDialog -SyncHash $syncHash -HardwareProfile $HardwareProfile -Tweaks $Tweaks
        }
    }.GetNewClosure())

    $syncHash.Controls['BtnSelectAllVisible'].Add_Click({
        foreach ($t in $Tweaks) {
            if ($syncHash.CurrentCategory -ne 'All' -and $t.category -ne $syncHash.CurrentCategory) { continue }
            $chk = $syncHash.TweakCheckBoxes[$t.id]
            if ($chk -and $chk.IsEnabled) { $chk.IsChecked = $true }
        }
        Update-SelectedCounterUi -SyncHash $SyncHash
    }.GetNewClosure())

    $syncHash.Controls['BtnClearSelection'].Add_Click({
        foreach ($chk in $syncHash.TweakCheckBoxes.Values) {
            $chk.IsChecked = $false
        }
        Update-SelectedCounterUi -SyncHash $SyncHash
    }.GetNewClosure())

    $profileButtons = @{
        'BtnProfileLegacy'  = 'Legacy'
        'BtnProfileGaming'  = 'Gaming'
        'BtnProfileTrabajo' = 'Trabajo'
        'BtnProfileLaptop'  = 'Laptop'
        'BtnProfileExtremo' = 'Extremo'
    }

    foreach ($pBtn in $profileButtons.Keys) {
        $pName = $profileButtons[$pBtn]
        $syncHash.Controls[$pBtn].Add_Click({
            $prof = $Profiles | Where-Object { $_.id -eq $pName -or $_.name -eq $pName } | Select-Object -First 1
            if ($null -eq $prof) { return }

            foreach ($chk in $syncHash.TweakCheckBoxes.Values) { $chk.IsChecked = $false }

            $selectedIds = @($prof.tweakIds)
            $skippedCount = 0
            foreach ($tid in $selectedIds) {
                $chk = $syncHash.TweakCheckBoxes[$tid]
                if ($null -ne $chk) {
                    if ($chk.IsEnabled) {
                        $chk.IsChecked = $true
                    }
                    else {
                        $skippedCount++
                    }
                }
            }
            Update-SelectedCounterUi -SyncHash $SyncHash
            Add-WinForgeLogLine -SyncHash $syncHash -Message "Perfil '$($prof.name)' cargado: $($prof.description) (Omitidos por hardware: $skippedCount)."
        }.GetNewClosure())
    }

    $syncHash.Controls['BtnRefreshStatus'].Add_Click({
        if (-not $syncHash.IsBusy) {
            Start-AsyncStatusAudit -SyncHash $syncHash -RunspaceContext $RunspaceContext -Tweaks $Tweaks
        }
    }.GetNewClosure())

    $syncHash.Controls['BtnApplySelected'].Add_Click({
        if ($syncHash.IsBusy) { return }

        $toApply = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($t in $Tweaks) {
            $chk = $syncHash.TweakCheckBoxes[$t.id]
            if ($null -ne $chk -and $chk.IsChecked -eq $true -and $chk.IsEnabled) {
                $toApply.Add($t)
            }
        }
        if ($toApply.Count -eq 0) { return }

        $warnings = @($toApply | Where-Object { $_.GuardStatus -eq 'Warning' })
        if ($warnings.Count -gt 0) {
            $warnNames = ($warnings | ForEach-Object { "- $($_.name): $($_.GuardReason)" }) -join "`n"
            $confirm = [System.Windows.MessageBox]::Show(
                "Los siguientes ajustes seleccionados tienen advertencias de hardware para este equipo:`n`n$warnNames`n`n¿Deseas continuar aplicando estos ajustes?",
                'Advertencia de Hardware - WinForge Engine',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
        }

        $createRp = ($syncHash.Controls['ChkRestorePoint'].IsChecked -eq $true)
        Set-UiBusyState -SyncHash $syncHash -Busy $true -StatusText 'Creando respaldo y aplicando ajustes...'

        Update-WinForgeUi -SyncHash $syncHash -Action {
            $syncHash.Controls['MainProgressBar'].Value = 0
            $syncHash.Controls['TxtProgressDetail'].Text = 'Preparando respaldo de seguridad...'
        }

        $backupRoot = $Config.BackupRoot
        $tweaksBatch = $toApply.ToArray()

        Invoke-WinForgeAsync -RunspaceContext $RunspaceContext -ScriptBlock {
            param($SyncHash, $TweaksBatch, $BackupRoot, $CreateRestorePoint)

            $logFn = {
                param($msg)
                $ts = Get-Date -Format 'HH:mm:ss'
                $win = $SyncHash.Window
                if ($win -and -not $win.Dispatcher.HasShutdownStarted) {
                    $win.Dispatcher.Invoke([Action]{
                        $c = $SyncHash.Controls['TxtConsoleLog']
                        $c.AppendText("[$ts] $msg`r`n")
                        $c.ScrollToEnd()
                    })
                }
            }

            & $logFn 'Iniciando protocolo de seguridad (Punto de Restauración + Backup .reg)...'
            $nonMaint = @($TweaksBatch | Where-Object { $_.category -ne 'Maintenance' })
            if ($nonMaint.Count -gt 0) {
                $session = New-WinForgeBackupSession -BackupRoot $BackupRoot -TweaksToApply $nonMaint -SessionLabel 'GUI_Batch' -CreateRestorePoint:$CreateRestorePoint
                & $logFn $session.RestorePoint.Message
                & $logFn "Respaldo .reg guardado en: $($session.SessionDir) ($($session.RegBackupCount) claves exportadas)"
            }

            $total = $TweaksBatch.Count
            $current = 0
            $appliedResults = @()

            foreach ($item in $TweaksBatch) {
                if ($SyncHash.CancelFlag) { break }
                $current++
                $pct = [int](($current / $total) * 100)

                $win = $SyncHash.Window
                if ($win -and -not $win.Dispatcher.HasShutdownStarted) {
                    $win.Dispatcher.Invoke([Action]{
                        $SyncHash.Controls['MainProgressBar'].Value = $pct
                        $SyncHash.Controls['TxtProgressDetail'].Text = "Ejecutando ($current/$total): $($item.name)"
                    })
                }

                & $logFn "Aplicando [$($item.id)] $($item.name)..."
                $res = Invoke-WinForgeTweakApply -Tweak $item
                & $logFn " -> $($res.Message)"
                $appliedResults += [PSCustomObject]@{
                    Tweak  = $item
                    Result = $res
                }
            }

            return $appliedResults
        } -Parameters @{
            TweaksBatch        = $tweaksBatch
            BackupRoot         = $backupRoot
            CreateRestorePoint = $createRp
        } -OnComplete {
            param($results)
            foreach ($entry in $results) {
                Update-TweakStatusBadge -SyncHash $SyncHash -Tweak $entry.Tweak
            }
            Update-WinForgeUi -SyncHash $SyncHash -Action {
                $SyncHash.Controls['MainProgressBar'].Value = 100
                $SyncHash.Controls['TxtProgressDetail'].Text = 'Operación completada'
            }
            Add-WinForgeLogLine -SyncHash $SyncHash -Message 'Lote finalizado con éxito.'
            Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Listo'
        }.GetNewClosure() -OnError {
            param($err)
            Add-WinForgeLogLine -SyncHash $SyncHash -Message "Error en ejecución asíncrona: $err"
            Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Error'
        }.GetNewClosure() | Out-Null
    }.GetNewClosure())

    $syncHash.Controls['BtnRollbackAll'].Add_Click({
        if ($syncHash.IsBusy) { return }

        $confirm = [System.Windows.MessageBox]::Show(
            "¿Deseas revertir los cambios aplicados y restaurar las claves de registro desde la última sesión de respaldo?",
            'Deshacer Todo / Revertir - WinForge Engine',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }

        Set-UiBusyState -SyncHash $syncHash -Busy $true -StatusText 'Ejecutando Rollback completo...'
        Update-WinForgeUi -SyncHash $syncHash -Action {
            $syncHash.Controls['MainProgressBar'].IsIndeterminate = $true
            $syncHash.Controls['TxtProgressDetail'].Text = 'Revirtiendo cambios...'
        }

        $backupRoot = $Config.BackupRoot
        Invoke-WinForgeAsync -RunspaceContext $RunspaceContext -ScriptBlock {
            param($SyncHash, $BackupRoot, $AllTweaks)

            $logCb = {
                param($msg)
                $ts = Get-Date -Format 'HH:mm:ss'
                $win = $SyncHash.Window
                if ($win -and -not $win.Dispatcher.HasShutdownStarted) {
                    $win.Dispatcher.Invoke([Action]{
                        $c = $SyncHash.Controls['TxtConsoleLog']
                        $c.AppendText("[$ts] $msg`r`n")
                        $c.ScrollToEnd()
                    })
                }
            }

            $rbRes = Invoke-WinForgeRollback -BackupRoot $BackupRoot -AllTweaks $AllTweaks -LogCallback $logCb
            foreach ($t in $AllTweaks) {
                if ($t.GuardStatus -ne 'Blocked' -and $t.category -ne 'Maintenance') {
                    $st = Get-WinForgeTweakStatus -Tweak $t
                    $t.IsApplied = $st.IsApplied
                    $t.DetectionState = $st.Label
                }
            }
            return $rbRes
        } -Parameters @{
            BackupRoot = $backupRoot
            AllTweaks  = $Tweaks
        } -OnComplete {
            param($rbRes)
            foreach ($t in $Tweaks) {
                Update-TweakStatusBadge -SyncHash $SyncHash -Tweak $t
            }
            Update-WinForgeUi -SyncHash $SyncHash -Action {
                $SyncHash.Controls['MainProgressBar'].IsIndeterminate = $false
                $SyncHash.Controls['MainProgressBar'].Value = 100
                $SyncHash.Controls['TxtProgressDetail'].Text = 'Rollback finalizado'
            }
            Add-WinForgeLogLine -SyncHash $SyncHash -Message "Rollback finalizado ($($rbRes.Count) elementos procesados)."
            Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Listo'
        }.GetNewClosure() -OnError {
            param($err)
            Update-WinForgeUi -SyncHash $SyncHash -Action {
                $SyncHash.Controls['MainProgressBar'].IsIndeterminate = $false
            }
            Add-WinForgeLogLine -SyncHash $SyncHash -Message "Error en Rollback: $err"
            Set-UiBusyState -SyncHash $SyncHash -Busy $false -StatusText 'Estado: Error'
        }.GetNewClosure() | Out-Null
    }.GetNewClosure())

    $window.Add_ContentRendered({
        Add-WinForgeLogLine -SyncHash $syncHash -Message "WinForge Engine v$($Config.Version) inicializado en $($HardwareProfile.ComputerName) (Tier recomendado: $($HardwareProfile.RecommendedTier))."
        Start-AsyncStatusAudit -SyncHash $syncHash -RunspaceContext $RunspaceContext -Tweaks $Tweaks
    }.GetNewClosure())

    [void]$window.ShowDialog()
}

Export-ModuleMember -Function @('Start-WinForgeGui')
