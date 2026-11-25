<#
.SYNOPSIS
    WinForge Engine - GuiController.
.DESCRIPTION
    Controlador WPF ligero y monocromático que parsea UI/MainWindow.xaml mediante XamlReader,
    usa estado de módulo ($script:UiState) y pinceles congelados (Freeze) para minimizar consumo
    de CPU/RAM, soporta minimizar a segundo plano, cola diferida de pendientes y detalle de procesos.
#>

Set-StrictMode -Version Latest

$script:UiState = $null
$script:Brushes = @{}

function Get-FrozenBrush {
    param([Parameter(Mandatory)][string]$Hex)

    if ($script:Brushes.ContainsKey($Hex)) {
        return $script:Brushes[$Hex]
    }
    $converter = [System.Windows.Media.BrushConverter]::new()
    $brush = $converter.ConvertFromString($Hex)
    if ($brush -is [System.Windows.Freezable] -and $brush.CanFreeze) {
        $brush.Freeze()
    }
    $script:Brushes[$Hex] = $brush
    return $brush
}

function Add-WinForgeLogLine {
    param(
        [hashtable]$SyncHash = $null,
        [Parameter(Mandatory)][string]$Message
    )

    if ($null -eq $SyncHash -and $null -ne $script:UiState) {
        $SyncHash = $script:UiState.SyncHash
    }
    if ($null -eq $SyncHash) { return }

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $Message"

    if ($null -ne $SyncHash.LogQueue) {
        $SyncHash.LogQueue.Enqueue($line)
    }
}

function Set-ProcessPanelState {
    param(
        [hashtable]$SyncHash,
        [string]$Headline = '',
        [string]$StepDetail = '',
        [string]$StatsText = '',
        [int]$Percent = -1
    )

    if ($null -eq $SyncHash) { return }

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        if (-not [string]::IsNullOrEmpty($Headline)) {
            $ctrl = $SyncHash.Controls['TxtProgressDetail']
            if ($null -ne $ctrl) { $ctrl.Text = $Headline }
        }
        if (-not [string]::IsNullOrEmpty($StepDetail)) {
            $ctrl = $SyncHash.Controls['TxtProcessCurrentStep']
            if ($null -ne $ctrl) { $ctrl.Text = $StepDetail }
        }
        if (-not [string]::IsNullOrEmpty($StatsText)) {
            $ctrl = $SyncHash.Controls['TxtProcessStats']
            if ($null -ne $ctrl) { $ctrl.Text = $StatsText }
        }
        if ($Percent -ge 0) {
            $pb = $SyncHash.Controls['MainProgressBar']
            if ($null -ne $pb) {
                $pb.IsIndeterminate = $false
                $pb.Value = $Percent
            }
        }
    }
}

function Update-SelectedCounterUi {
    param([hashtable]$SyncHash = $null)

    if ($null -eq $SyncHash -and $null -ne $script:UiState) {
        $SyncHash = $script:UiState.SyncHash
    }
    if ($null -eq $SyncHash) { return }

    $selectedCount = 0
    foreach ($entry in $SyncHash.TweakCheckBoxes.GetEnumerator()) {
        if ($entry.Value.IsChecked -eq $true -and $entry.Value.IsEnabled) {
            $selectedCount++
        }
    }

    $btnApply = $SyncHash.Controls['BtnApplySelected']
    if ($null -ne $btnApply) {
        $btnApply.Content = "Aplicar ($selectedCount)"
        $btnApply.IsEnabled = (-not $SyncHash.IsBusy) -and ($selectedCount -gt 0)
    }

    $btnLater = $SyncHash.Controls['BtnQueueLater']
    if ($null -ne $btnLater) {
        $btnLater.IsEnabled = (-not $SyncHash.IsBusy) -and ($selectedCount -gt 0)
    }
}

function Set-UiBusyState {
    param(
        [hashtable]$SyncHash = $null,
        [Parameter(Mandatory)][bool]$Busy,
        [string]$StatusText = ''
    )

    if ($null -eq $SyncHash -and $null -ne $script:UiState) {
        $SyncHash = $script:UiState.SyncHash
    }
    if ($null -eq $SyncHash) { return }

    $SyncHash.IsBusy = $Busy

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        $controlsToToggle = @(
            'BtnGuidedWizard', 'BtnRefreshStatus', 'BtnRollbackAll',
            'BtnProfileLegacy', 'BtnProfileGaming', 'BtnProfileTrabajo', 'BtnProfileLaptop', 'BtnProfileExtremo',
            'BtnSelectAllVisible', 'BtnClearSelection', 'BtnRunPendingNow'
        )
        foreach ($name in $controlsToToggle) {
            $ctrl = $SyncHash.Controls[$name]
            if ($null -ne $ctrl) {
                $ctrl.IsEnabled = (-not $Busy)
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($StatusText)) {
            $stCtrl = $SyncHash.Controls['TxtSessionStatus']
            if ($null -ne $stCtrl) { $stCtrl.Text = $StatusText }
        }

        if (-not $Busy -and $null -ne $SyncHash.Window) {
            $SyncHash.Window.Title = $SyncHash.BaseWindowTitle
        }

        Update-SelectedCounterUi -SyncHash $SyncHash
    }
}

function New-TweakCardElement {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tweak,
        [Parameter(Mandatory)][hashtable]$SyncHash
    )

    $isBlocked = ($Tweak.GuardStatus -eq 'Blocked')
    $isWarning = ($Tweak.GuardStatus -eq 'Warning')

    $borderBrush = if ($isBlocked) {
        Get-FrozenBrush '#6E6E6E'
    }
    elseif ($isWarning) {
        Get-FrozenBrush '#545454'
    }
    else {
        Get-FrozenBrush '#2E2E2E'
    }

    $card = [System.Windows.Controls.Border]::new()
    $card.Background = Get-FrozenBrush '#1E1E1E'
    $card.BorderBrush = $borderBrush
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $card.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)

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
    $chk.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $chk.Tag = $Tweak.id
    $chk.Add_Checked({ Update-SelectedCounterUi })
    $chk.Add_Unchecked({ Update-SelectedCounterUi })
    $SyncHash.TweakCheckBoxes[$Tweak.id] = $chk
    [void]$leftStack.Children.Add($chk)

    $titleText = [System.Windows.Controls.TextBlock]::new()
    $titleText.Text = $Tweak.name
    $titleText.FontSize = 13
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleText.Foreground = if ($isBlocked) { Get-FrozenBrush '#7D7D7D' } else { Get-FrozenBrush '#F2F2F2' }
    $titleText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$leftStack.Children.Add($titleText)

    $metaTxt = [System.Windows.Controls.TextBlock]::new()
    $metaTxt.Text = "  [$($Tweak.category) • Riesgo: $($Tweak.riskLevel)]"
    $metaTxt.FontSize = 11
    $metaTxt.Foreground = switch ($Tweak.riskLevel) {
        'Alto'     { Get-FrozenBrush '#E5E5E5' }
        'Moderado' { Get-FrozenBrush '#B8B8B8' }
        default    { Get-FrozenBrush '#888888' }
    }
    $metaTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$leftStack.Children.Add($metaTxt)

    $rightStack = [System.Windows.Controls.StackPanel]::new()
    $rightStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $rightStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($rightStack, 1)

    $statusBadge = [System.Windows.Controls.Border]::new()
    $statusBadge.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $statusBadge.BorderThickness = [System.Windows.Thickness]::new(1)
    $statusBadge.BorderBrush = Get-FrozenBrush '#3A3A3A'
    $statusBadge.Padding = [System.Windows.Thickness]::new(7, 2, 7, 2)
    $statusBadge.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)

    $statusTxt = [System.Windows.Controls.TextBlock]::new()
    $statusTxt.FontSize = 10.5
    $statusTxt.FontWeight = [System.Windows.FontWeights]::SemiBold

    if ($isBlocked) {
        $statusBadge.Background = Get-FrozenBrush '#282828'
        $statusTxt.Foreground = Get-FrozenBrush '#9A9A9A'
        $statusTxt.Text = 'BLOQUEADO'
    }
    else {
        $statusBadge.Background = Get-FrozenBrush '#141414'
        $statusTxt.Foreground = Get-FrozenBrush '#9A9A9A'
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
        $btnRevertOne.Style = $SyncHash.Window.Resources['MonoSecondaryButton']
        $btnRevertOne.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
        $btnRevertOne.FontSize = 11
        $btnRevertOne.Tag = $Tweak
        $btnRevertOne.Add_Click({
            param($s, $e)
            $state = $script:UiState
            if ($null -eq $state -or $state.SyncHash.IsBusy) { return }
            $tw = $s.Tag
            Invoke-SingleTweakRevert -Tweak $tw
        })
        [void]$rightStack.Children.Add($btnRevertOne)
    }

    [void]$headerGrid.Children.Add($leftStack)
    [void]$headerGrid.Children.Add($rightStack)
    [void]$rootStack.Children.Add($headerGrid)

    $detailsPanel = [System.Windows.Controls.StackPanel]::new()
    $detailsPanel.Margin = [System.Windows.Thickness]::new(22, 4, 0, 0)

    if ($isBlocked -or $isWarning) {
        $alertTxt = [System.Windows.Controls.TextBlock]::new()
        $alertTxt.Text = $Tweak.GuardReason
        $alertTxt.Foreground = Get-FrozenBrush '#D4D4D4'
        $alertTxt.FontSize = 11
        $alertTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
        $alertTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $alertTxt.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
        [void]$detailsPanel.Children.Add($alertTxt)
    }

    $descTxt = [System.Windows.Controls.TextBlock]::new()
    $descTxt.Text = "$($Tweak.description)  •  Beneficio: $($Tweak.benefit)"
    $descTxt.Foreground = Get-FrozenBrush '#BDBDBD'
    $descTxt.FontSize = 11.5
    $descTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$detailsPanel.Children.Add($descTxt)

    $metaLine = [System.Windows.Controls.TextBlock]::new()
    $metaLine.Text = "Ruta: $($Tweak.targetPath)  |  Desventaja: $($Tweak.sideEffect)"
    $metaLine.Foreground = Get-FrozenBrush '#808080'
    $metaLine.FontSize = 10.5
    $metaLine.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $metaLine.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$detailsPanel.Children.Add($metaLine)

    [void]$rootStack.Children.Add($detailsPanel)

    return $card
}

function Update-TweakStatusBadge {
    param(
        [hashtable]$SyncHash = $null,
        [Parameter(Mandatory)][PSCustomObject]$Tweak
    )

    if ($null -eq $SyncHash -and $null -ne $script:UiState) {
        $SyncHash = $script:UiState.SyncHash
    }
    if ($null -eq $SyncHash -or $Tweak.GuardStatus -eq 'Blocked') { return }

    $entry = $SyncHash.TweakStatusLabels[$Tweak.id]
    if ($null -eq $entry) { return }

    Update-WinForgeUi -SyncHash $SyncHash -Action {
        if ($Tweak.category -eq 'Maintenance') {
            $entry.Badge.Background = Get-FrozenBrush '#141414'
            $entry.Badge.BorderBrush = Get-FrozenBrush '#3A3A3A'
            $entry.Text.Foreground = Get-FrozenBrush '#BDBDBD'
            $entry.Text.Text = 'Bajo demanda'
        }
        elseif ($Tweak.IsApplied) {
            $entry.Badge.Background = Get-FrozenBrush '#EDEDED'
            $entry.Badge.BorderBrush = Get-FrozenBrush '#EDEDED'
            $entry.Text.Foreground = Get-FrozenBrush '#121212'
            $entry.Text.Text = 'APLICADO'
        }
        else {
            $entry.Badge.Background = Get-FrozenBrush '#141414'
            $entry.Badge.BorderBrush = Get-FrozenBrush '#3A3A3A'
            $entry.Text.Foreground = Get-FrozenBrush '#9A9A9A'
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
    param([hashtable]$SyncHash = $null)

    if ($null -eq $SyncHash -and $null -ne $script:UiState) {
        $SyncHash = $script:UiState.SyncHash
    }
    if ($null -eq $SyncHash) { return }

    $SyncHash.Controls['TweakCardsScrollViewer'].Visibility = [System.Windows.Visibility]::Collapsed
    $SyncHash.Controls['StartupAppsScrollViewer'].Visibility = [System.Windows.Visibility]::Visible

    $panel = $SyncHash.Controls['StartupAppsPanel']
    $panel.Children.Clear()

    $hdr = [System.Windows.Controls.TextBlock]::new()
    $hdr.Text = 'Aplicaciones de Inicio (Reversible)'
    $hdr.FontSize = 14
    $hdr.FontWeight = [System.Windows.FontWeights]::Bold
    $hdr.Foreground = Get-FrozenBrush '#F2F2F2'
    $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [void]$panel.Children.Add($hdr)

    $sub = [System.Windows.Controls.TextBlock]::new()
    $sub.Text = 'Desactivar una app la mueve a una clave de respaldo de WinForge para poder reactivarla cuando quieras.'
    $sub.FontSize = 11.5
    $sub.Foreground = Get-FrozenBrush '#9A9A9A'
    $sub.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $sub.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$panel.Children.Add($sub)

    $apps = @(Get-WinForgeStartupApps)
    if ($apps.Count -eq 0) {
        $empty = [System.Windows.Controls.TextBlock]::new()
        $empty.Text = 'No se detectaron entradas de inicio en HKCU/HKLM Run.'
        $empty.Foreground = Get-FrozenBrush '#9A9A9A'
        [void]$panel.Children.Add($empty)
        return
    }

    foreach ($app in $apps) {
        $card = [System.Windows.Controls.Border]::new()
        $card.Background = Get-FrozenBrush '#1E1E1E'
        $card.BorderBrush = Get-FrozenBrush '#2E2E2E'
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $card.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)

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
        $t1.FontSize = 12.5
        $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
        $t1.Foreground = Get-FrozenBrush '#F2F2F2'
        [void]$info.Children.Add($t1)

        $t2 = [System.Windows.Controls.TextBlock]::new()
        $t2.Text = $app.Command
        $t2.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $t2.FontSize = 10.5
        $t2.Foreground = Get-FrozenBrush '#888888'
        $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t2.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        [void]$info.Children.Add($t2)

        $btn = [System.Windows.Controls.Button]::new()
        [System.Windows.Controls.Grid]::SetColumn($btn, 1)
        $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $btn.Style = $SyncHash.Window.Resources['MonoSecondaryButton']
        $btn.Content = if ($app.Enabled) { 'Desactivar' } else { 'Reactivar' }
        $btn.Foreground = if ($app.Enabled) { Get-FrozenBrush '#D4D4D4' } else { Get-FrozenBrush '#FFFFFF' }
        $btn.Tag = $app
        $btn.Add_Click({
            param($s, $e)
            $targetApp = $s.Tag
            $newState = (-not $targetApp.Enabled)
            $null = Set-WinForgeStartupAppState -StartupApp $targetApp -Enable $newState
            Add-WinForgeLogLine -Message "[INICIO] '$($targetApp.Name)' -> $(if ($newState) { 'Activado' } else { 'Desactivado' })."
            Render-StartupAppsList
        })

        [void]$grid.Children.Add($info)
        [void]$grid.Children.Add($btn)
        $card.Child = $grid
        [void]$panel.Children.Add($card)
    }
}

function Show-GuidedWizardDialog {
    param(
        [hashtable]$SyncHash,
        [PSCustomObject]$HardwareProfile,
        [PSCustomObject[]]$Tweaks
    )

    $wizXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Asistente Guiado WinForge"
        Width="560" Height="460"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#121212" Foreground="#F2F2F2"
        FontFamily="Segoe UI Variable Text, Segoe UI">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="Configuración Guiada (5 pasos)" FontSize="17" FontWeight="Bold" Foreground="#F2F2F2"/>
            <TextBlock x:Name="TxtWizHw" Text="Hardware detectado..." FontSize="11.5" Foreground="#9A9A9A" Margin="0,3,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <Border Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="5" Padding="10" Margin="0,0,0,8">
                    <StackPanel>
                        <TextBlock Text="1. Tipo de equipo / uso principal" FontWeight="SemiBold" FontSize="12.5"/>
                        <ComboBox x:Name="CmbWizUsage" Margin="0,6,0,0" Height="28">
                            <ComboBoxItem Content="PC Antiguo o Bajos Recursos (HDD o &lt;=8GB RAM)" Tag="Legacy"/>
                            <ComboBoxItem Content="Uso Diario / Oficina / Estudio" Tag="Trabajo"/>
                            <ComboBoxItem Content="Laptop (Priorizar Batería)" Tag="Laptop"/>
                            <ComboBoxItem Content="Gaming y Baja Latencia" Tag="Gaming"/>
                        </ComboBox>
                    </StackPanel>
                </Border>

                <Border Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="5" Padding="10" Margin="0,0,0,8">
                    <StackPanel>
                        <TextBlock Text="2. Reducir telemetría, Widgets e IA en segundo plano" FontWeight="SemiBold" FontSize="12.5"/>
                        <CheckBox x:Name="ChkWizPrivacy" Content="Desactivar DiagTrack, Widgets, Apps en 2º plano, Copilot y Recall IA" IsChecked="True" Foreground="#D8D8D8" Margin="0,6,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="5" Padding="10" Margin="0,0,0,8">
                    <StackPanel>
                        <TextBlock Text="3. Limpiar apps preinstaladas innecesarias (reinstalables)" FontWeight="SemiBold" FontSize="12.5"/>
                        <CheckBox x:Name="ChkWizDebloat" Content="Eliminar Cortana, Bing News/Weather, Clipchamp, Solitaire y Obtener Ayuda" IsChecked="True" Foreground="#D8D8D8" Margin="0,6,0,4"/>
                        <CheckBox x:Name="ChkWizRemoveXbox" Content="Eliminar también Xbox Apps (solo si no juegas en este PC)" IsChecked="False" Foreground="#9A9A9A" Margin="0,2,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="5" Padding="10" Margin="0,0,0,8">
                    <StackPanel>
                        <TextBlock Text="4. Impresoras o 'Imprimir a PDF'" FontWeight="SemiBold" FontSize="12.5"/>
                        <CheckBox x:Name="ChkWizPrinter" Content="Sí utilizo impresoras (mantener Print Spooler activo)" IsChecked="True" Foreground="#D8D8D8" Margin="0,6,0,0"/>
                    </StackPanel>
                </Border>

                <Border Background="#1A1A1A" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="5" Padding="10">
                    <StackPanel>
                        <TextBlock Text="5. DNS (Opcional)" FontWeight="SemiBold" FontSize="12.5"/>
                        <ComboBox x:Name="CmbWizDns" Margin="0,6,0,0" Height="28">
                            <ComboBoxItem Content="Mantener DNS actual / Router" Tag="NONE" IsSelected="True"/>
                            <ComboBoxItem Content="Cloudflare DNS (1.1.1.1) — Velocidad" Tag="NET_DNS_CLOUDFLARE"/>
                            <ComboBoxItem Content="AdGuard DNS (94.140.14.14) — Bloqueo de anuncios" Tag="NET_DNS_ADGUARD"/>
                        </ComboBox>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnWizCancel" Content="Cancelar" Width="90" Height="30" Background="#242424" Foreground="#E6E6E6" BorderBrush="#3A3A3A" Margin="0,0,8,0"/>
            <Button x:Name="BtnWizBuild" Content="Preparar Selección" Width="150" Height="30" Background="#EDEDED" Foreground="#121212" FontWeight="SemiBold" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $wizWin = [System.Windows.Markup.XamlReader]::Parse($wizXaml)
    $wizWin.Owner = $SyncHash.Window
    $wizWin.Tag = $wizWin

    $txtHw = $wizWin.FindName('TxtWizHw')
    $cmbUsage = $wizWin.FindName('CmbWizUsage')
    $chkPriv = $wizWin.FindName('ChkWizPrivacy')
    $chkDebloat = $wizWin.FindName('ChkWizDebloat')
    $chkXbox = $wizWin.FindName('ChkWizRemoveXbox')
    $chkPrinter = $wizWin.FindName('ChkWizPrinter')
    $cmbDns = $wizWin.FindName('CmbWizDns')

    $txtHw.Text = "Equipo: $($HardwareProfile.TotalRamGB) GB RAM • $($HardwareProfile.Storage.MediaType) • $($HardwareProfile.Chassis.FormFactor) (Sugerido: $($HardwareProfile.RecommendedTier))"

    foreach ($item in $cmbUsage.Items) {
        if ($item.Tag -eq $HardwareProfile.RecommendedTier) {
            $cmbUsage.SelectedItem = $item
            break
        }
    }
    if ($null -eq $cmbUsage.SelectedItem) {
        $cmbUsage.SelectedIndex = 0
    }

    $btnCancel = $wizWin.FindName('BtnWizCancel')
    $btnCancel.Tag = $wizWin
    $btnCancel.Add_Click({ param($s, $e) $s.Tag.DialogResult = $false; $s.Tag.Close() })

    $btnBuild = $wizWin.FindName('BtnWizBuild')
    $btnBuild.Tag = $wizWin
    $btnBuild.Add_Click({ param($s, $e) $s.Tag.DialogResult = $true; $s.Tag.Close() })

    if ($wizWin.ShowDialog() -ne $true) {
        return
    }

    $chosenTier = $cmbUsage.SelectedItem.Tag
    $idsToSelect = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($id in @('PERF_WAIT_TO_KILL', 'PERF_MENU_SHOW_DELAY', 'PERF_NTFS_LAST_ACCESS', 'NET_DNS_CACHE', 'SVC_FAX', 'SVC_REMOTE_REGISTRY', 'SVC_MAPS_BROKER')) {
        [void]$idsToSelect.Add($id)
    }

    switch ($chosenTier) {
        'Legacy' {
            foreach ($id in @('PERF_STARTUP_DELAY_OFF', 'PERF_TRANSPARENCY_OFF', 'PERF_VISUAL_EFFECTS', 'PERF_GAME_DVR', 'SVC_WER')) { [void]$idsToSelect.Add($id) }
        }
        'Gaming' {
            foreach ($id in @('PERF_STARTUP_DELAY_OFF', 'PERF_SYSMAIN', 'PERF_GAME_DVR', 'PERF_GAME_MODE_ON', 'PERF_HAGS_ON', 'PERF_HYBRID_PCORE', 'NET_NAGLE', 'NET_THROTTLING')) { [void]$idsToSelect.Add($id) }
        }
        'Trabajo' {
            foreach ($id in @('PERF_STARTUP_DELAY_OFF', 'PERF_WIN11_MENU', 'PERF_GAME_DVR')) { [void]$idsToSelect.Add($id) }
        }
        'Laptop' {
            foreach ($id in @('PERF_GAME_DVR')) { [void]$idsToSelect.Add($id) }
        }
    }

    if ($chkPriv.IsChecked -eq $true) {
        foreach ($id in @('PRIV_DIAGTRACK', 'SVC_WAP_PUSH', 'PRIV_WIDGETS_NEWS_OFF', 'PRIV_BACKGROUND_APPS_OFF', 'PRIV_WIN11_COPILOT', 'PRIV_WIN11_AI_RECALL', 'PRIV_DELIVERY_OPT', 'PRIV_CORTANA', 'PRIV_CONSUMER_EXP', 'PRIV_EDGE_TELEMETRY', 'PRIV_ADVERTISING_ID', 'PRIV_ACTIVITY_HISTORY')) {
            [void]$idsToSelect.Add($id)
        }
    }

    if ($chkDebloat.IsChecked -eq $true) {
        foreach ($id in @('DEBLOAT_CORTANA_APP', 'DEBLOAT_BING_WEATHER', 'DEBLOAT_CLIPCHAMP', 'DEBLOAT_SOLITAIRE', 'DEBLOAT_HELP_FEEDBACK')) {
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
    Add-WinForgeLogLine -Message "[ASISTENTE] Selección ($chosenTier): $selectedCount ajustes compatibles marcados. Puedes aplicarlos ahora o pulsar 'Después'."
    Set-ProcessPanelState -SyncHash $SyncHash -Headline "Selección lista ($selectedCount ajustes)" -StepDetail "Pulsa 'Aplicar' para ejecutar ahora o 'Después' si tienes un pendiente." -StatsText "$selectedCount marcados"
}

function Save-WinForgePendingQueue {
    param(
        [Parameter(Mandatory)][string]$PendingFilePath,
        [Parameter(Mandatory)][string[]]$TweakIds,
        [bool]$CreateRestorePoint = $true
    )

    $dir = Split-Path -Parent $PendingFilePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $payload = [PSCustomObject]@{
        SavedAt            = (Get-Date).ToString('o')
        CreateRestorePoint = $CreateRestorePoint
        TweakIds           = @($TweakIds)
    }
    $json = $payload | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($PendingFilePath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Clear-WinForgePendingQueue {
    param([string]$PendingFilePath)

    if (-not [string]::IsNullOrWhiteSpace($PendingFilePath) -and (Test-Path -LiteralPath $PendingFilePath)) {
        Remove-Item -LiteralPath $PendingFilePath -Force -ErrorAction SilentlyContinue
    }
}

function Update-PendingBannerUi {
    $state = $script:UiState
    if ($null -eq $state) { return }
    $syncHash = $state.SyncHash
    $box = $syncHash.Controls['PendingQueueBox']
    $txt = $syncHash.Controls['TxtPendingSummary']
    if ($null -eq $box -or $null -eq $txt) { return }

    if ($null -ne $state.PendingTimer -and $state.PendingSecondsLeft -gt 0) {
        $mins = [int][Math]::Floor($state.PendingSecondsLeft / 60)
        $secs = $state.PendingSecondsLeft % 60
        $box.Visibility = [System.Windows.Visibility]::Visible
        $txt.Text = ("Ejecución en 2º plano en {0:D2}:{1:D2} ({2} ajustes)." -f $mins, $secs, $state.PendingIds.Count)
        return
    }

    if ($state.PendingIds.Count -gt 0) {
        $box.Visibility = [System.Windows.Visibility]::Visible
        $txt.Text = "$($state.PendingIds.Count) ajustes guardados en cola."
    }
    else {
        $box.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Show-QueueLaterDialog {
    param([string[]]$SelectedIds)

    $state = $script:UiState
    $syncHash = $state.SyncHash

    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Ejecutar Después / En 2º Plano"
        Width="430" Height="260"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#121212" Foreground="#F2F2F2"
        FontFamily="Segoe UI Variable Text, Segoe UI">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="¿Cuándo deseas aplicar los ajustes?" FontSize="15" FontWeight="Bold" Foreground="#F2F2F2"/>
        <StackPanel Grid.Row="1" Margin="0,12,0,12">
            <TextBlock x:Name="TxtLaterCount" Text="0 ajustes seleccionados" FontSize="11.5" Foreground="#9A9A9A" Margin="0,0,0,10"/>
            <Button x:Name="BtnDelay10" Content="En 10 minutos (minimizar y ejecutar en 2º plano)" Height="32" Margin="0,0,0,6" Background="#EDEDED" Foreground="#121212" FontWeight="SemiBold" BorderThickness="0"/>
            <Button x:Name="BtnDelay30" Content="En 30 minutos (minimizar y ejecutar en 2º plano)" Height="30" Margin="0,0,0,6" Background="#242424" Foreground="#E6E6E6" BorderBrush="#3A3A3A"/>
            <Button x:Name="BtnSaveOnly" Content="Guardar en cola para cuando yo decida volver" Height="30" Background="#242424" Foreground="#E6E6E6" BorderBrush="#3A3A3A"/>
        </StackPanel>
        <Button x:Name="BtnLaterCancel" Grid.Row="2" Content="Cancelar" Width="90" Height="28" HorizontalAlignment="Right" Background="#1A1A1A" Foreground="#9A9A9A" BorderBrush="#2E2E2E"/>
    </Grid>
</Window>
'@

    $dlg = [System.Windows.Markup.XamlReader]::Parse($dlgXaml)
    $dlg.Owner = $syncHash.Window
    $dlg.FindName('TxtLaterCount').Text = "$($SelectedIds.Count) ajustes seleccionados se guardarán en tu cola."

    $resultHolder = @{ Choice = 'Cancel' }

    $b10 = $dlg.FindName('BtnDelay10')
    $b10.Tag = @{ Win = $dlg; Res = $resultHolder; Choice = 'Delay10' }
    $b10.Add_Click({ param($s, $e) $s.Tag.Res.Choice = $s.Tag.Choice; $s.Tag.Win.Close() })

    $b30 = $dlg.FindName('BtnDelay30')
    $b30.Tag = @{ Win = $dlg; Res = $resultHolder; Choice = 'Delay30' }
    $b30.Add_Click({ param($s, $e) $s.Tag.Res.Choice = $s.Tag.Choice; $s.Tag.Win.Close() })

    $bSave = $dlg.FindName('BtnSaveOnly')
    $bSave.Tag = @{ Win = $dlg; Res = $resultHolder; Choice = 'SaveOnly' }
    $bSave.Add_Click({ param($s, $e) $s.Tag.Res.Choice = $s.Tag.Choice; $s.Tag.Win.Close() })

    $bCan = $dlg.FindName('BtnLaterCancel')
    $bCan.Tag = $dlg
    $bCan.Add_Click({ param($s, $e) $s.Tag.Close() })

    [void]$dlg.ShowDialog()
    return $resultHolder.Choice
}

function Invoke-MinimizedBackgroundMode {
    $state = $script:UiState
    if ($null -eq $state) { return }
    $win = $state.SyncHash.Window
    if ($null -eq $win) { return }

    $win.WindowState = [System.Windows.WindowState]::Minimized
    Add-WinForgeLogLine -Message '[2º PLANO] Ventana minimizada. Los procesos y/o temporizador continúan ejecutándose en segundo plano.'
}

function Start-AsyncStatusAudit {
    param(
        [hashtable]$SyncHash = $null,
        [PSCustomObject]$RunspaceContext = $null,
        [PSCustomObject[]]$Tweaks = $null
    )

    $state = $script:UiState
    if ($null -eq $SyncHash -and $null -ne $state) { $SyncHash = $state.SyncHash }
    if ($null -eq $RunspaceContext -and $null -ne $state) { $RunspaceContext = $state.RunspaceContext }
    if ($null -eq $Tweaks -and $null -ne $state) { $Tweaks = $state.Tweaks }

    Set-UiBusyState -SyncHash $SyncHash -Busy $true -StatusText 'Auditando sistema...'
    Set-ProcessPanelState -SyncHash $SyncHash -Headline 'Auditoría inicial en curso' -StepDetail 'Paso actual: Comprobando estado real de Registro, servicios y paquetes en modo solo lectura...' -StatsText "0/$($Tweaks.Count)" -Percent 0

    Invoke-WinForgeAsync -RunspaceContext $RunspaceContext -ScriptBlock {
        param($SyncHash, $Tweaks)
        $results = @()
        $total = $Tweaks.Count
        $idx = 0
        foreach ($t in $Tweaks) {
            $idx++
            if ($SyncHash.CancelFlag) { break }
            if ($t.GuardStatus -eq 'Blocked') { continue }

            $pct = [int](($idx / [Math]::Max(1, $total)) * 100)
            $SyncHash.ProgressPct = $pct
            $SyncHash.ProgressDetail = 'Auditando estado del sistema'
            $SyncHash.ProgressStep = "Evaluando ($idx/$total): $($t.name) -> $($t.targetPath)"
            $SyncHash.ProgressStats = "$idx/$total ($pct%)"
            $SyncHash.ProgressDirty = $true

            $status = Get-WinForgeTweakStatus -Tweak $t
            $t.IsApplied = $status.IsApplied
            $t.DetectionState = $status.Label
            $results += $t
        }
        return $results
    } -Parameters @{ Tweaks = $Tweaks } -OnComplete {
        param($updatedTweaks)
        $st = $script:UiState
        foreach ($t in $updatedTweaks) {
            Update-TweakStatusBadge -SyncHash $st.SyncHash -Tweak $t
        }
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Auditoría completada' -StepDetail 'Paso actual: Sistema auditado. Marca los ajustes deseados o usa un Perfil.' -StatsText "$($st.Tweaks.Count)/$($st.Tweaks.Count) (100%)" -Percent 100
        Add-WinForgeLogLine -Message "[AUDITORÍA] Finalizada sobre $($st.Tweaks.Count) ajustes (hardware evaluado sin modificaciones)."
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Listo'
    } -OnError {
        param($err)
        $st = $script:UiState
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Error en auditoría' -StepDetail "Detalle: $err" -Percent 0
        Add-WinForgeLogLine -Message "[ERROR AUDITORÍA] $err"
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Error'
    } | Out-Null
}

function Start-BatchApplyTweaks {
    param(
        [Parameter(Mandatory)][PSCustomObject[]]$TweaksToApply,
        [Parameter(Mandatory)][bool]$CreateRestorePoint,
        [string]$OriginLabel = 'Manual'
    )

    $state = $script:UiState
    $syncHash = $state.SyncHash
    if ($syncHash.IsBusy -or $TweaksToApply.Count -eq 0) { return }

    $warnings = @($TweaksToApply | Where-Object { $_.GuardStatus -eq 'Warning' })
    if ($warnings.Count -gt 0 -and $syncHash.Window.WindowState -ne [System.Windows.WindowState]::Minimized) {
        $warnNames = ($warnings | ForEach-Object { "- $($_.name): $($_.GuardReason)" }) -join "`n"
        $confirm = [System.Windows.MessageBox]::Show(
            "Los siguientes ajustes tienen advertencias para este hardware:`n`n$warnNames`n`n¿Deseas continuar?",
            'Advertencia de Hardware - WinForge Engine',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
    }

    Set-UiBusyState -SyncHash $syncHash -Busy $true -StatusText "Ejecutando ($OriginLabel)..."
    Set-ProcessPanelState -SyncHash $syncHash -Headline "Iniciando lote ($OriginLabel)" -StepDetail 'Paso actual: Preparando Punto de Restauración y copias .reg de seguridad...' -StatsText "0/$($TweaksToApply.Count) (0%)" -Percent 0

    $backupRoot = $state.Config.BackupRoot
    $tweaksBatch = @($TweaksToApply)

    Invoke-WinForgeAsync -RunspaceContext $state.RunspaceContext -ScriptBlock {
        param($SyncHash, $TweaksBatch, $BackupRoot, $CreateRestorePoint, $OriginLabel)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $enqueue = {
            param($m)
            $ts = Get-Date -Format 'HH:mm:ss'
            if ($null -ne $SyncHash.LogQueue) {
                $SyncHash.LogQueue.Enqueue("[$ts] $m")
            }
        }

        & $enqueue "[INICIO] Lote '$OriginLabel' con $($TweaksBatch.Count) tareas."
        $nonMaint = @($TweaksBatch | Where-Object { $_.category -ne 'Maintenance' })
        if ($nonMaint.Count -gt 0) {
            $SyncHash.ProgressDetail = 'Creando respaldo de seguridad'
            $SyncHash.ProgressStep = "Exportando claves de Registro (.reg) para $($nonMaint.Count) ajustes..."
            $SyncHash.ProgressStats = "Respaldo • $([int]$sw.Elapsed.TotalSeconds)s"
            $SyncHash.ProgressDirty = $true

            $session = New-WinForgeBackupSession -BackupRoot $BackupRoot -TweaksToApply $nonMaint -SessionLabel $OriginLabel -CreateRestorePoint:$CreateRestorePoint
            & $enqueue "[BACKUP] $($session.RestorePoint.Message)"
            & $enqueue "[BACKUP] $($session.RegBackupCount) claves .reg exportadas en: $($session.SessionDir)"
        }

        $total = $TweaksBatch.Count
        $current = 0
        $appliedResults = @()

        foreach ($item in $TweaksBatch) {
            if ($SyncHash.CancelFlag) { break }
            $current++
            $pct = [int](($current / $total) * 100)
            $elapsed = $sw.Elapsed.ToString('mm\:ss')

            $SyncHash.ProgressPct = $pct
            $SyncHash.ProgressDetail = "Aplicando cambios ($current de $total)"
            $SyncHash.ProgressStep = "Ejecutando [$($item.component)]: $($item.name) -> $($item.targetPath)"
            $SyncHash.ProgressStats = "$current/$total ($pct%) • $elapsed"
            $SyncHash.ProgressDirty = $true

            & $enqueue "[RUN $current/$total] $($item.name) [$($item.targetPath)]"
            $res = Invoke-WinForgeTweakApply -Tweak $item
            & $enqueue "[RESULT] $($res.Message)"
            $appliedResults += [PSCustomObject]@{
                Tweak  = $item
                Result = $res
            }
        }

        $sw.Stop()
        return [PSCustomObject]@{
            Results = $appliedResults
            Elapsed = $sw.Elapsed.ToString('mm\:ss')
        }
    } -Parameters @{
        TweaksBatch        = $tweaksBatch
        BackupRoot         = $backupRoot
        CreateRestorePoint = $CreateRestorePoint
        OriginLabel        = $OriginLabel
    } -OnComplete {
        param($payload)
        $st = $script:UiState
        $resObj = @($payload) | Select-Object -First 1
        if ($null -eq $resObj) {
            Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Listo'
            return
        }
        $results = @($resObj.Results)
        foreach ($entry in $results) {
            Update-TweakStatusBadge -SyncHash $st.SyncHash -Tweak $entry.Tweak
        }
        $okCount = @($results | Where-Object { $_.Result.Success }).Count
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline "Lote completado en $($resObj.Elapsed)" -StepDetail "Paso actual: Finalizado ($okCount/$($results.Count) exitosos). Respaldos .reg listos para revertir si lo necesitas." -StatsText "$($results.Count)/$($results.Count) (100%) • $($resObj.Elapsed)" -Percent 100
        Add-WinForgeLogLine -Message "[FIN] Lote completado: $okCount/$($results.Count) exitosos en $($resObj.Elapsed)."
        Clear-WinForgePendingQueue -PendingFilePath $st.PendingFile
        $st.PendingIds = @()
        Update-PendingBannerUi
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Listo'
    } -OnError {
        param($err)
        $st = $script:UiState
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Error durante la ejecución' -StepDetail "Detalle: $err"
        Add-WinForgeLogLine -Message "[ERROR LOTE] $err"
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Error'
    } | Out-Null
}

function Invoke-SingleTweakRevert {
    param([Parameter(Mandatory)][PSCustomObject]$Tweak)

    $state = $script:UiState
    $syncHash = $state.SyncHash
    if ($syncHash.IsBusy) { return }

    Set-UiBusyState -SyncHash $syncHash -Busy $true -StatusText "Revirtiendo $($Tweak.name)..."
    Set-ProcessPanelState -SyncHash $syncHash -Headline "Revirtiendo ajuste individual" -StepDetail "Restaurando valor original: $($Tweak.name) -> $($Tweak.targetPath)" -StatsText '1/1' -Percent 30
    Add-WinForgeLogLine -Message "[REVERTIR] Ejecutando reversión de '$($Tweak.name)' en $($Tweak.targetPath)..."

    Invoke-WinForgeAsync -RunspaceContext $state.RunspaceContext -ScriptBlock {
        param($SyncHash, $Tweak)
        return Invoke-WinForgeTweakRevert -Tweak $Tweak
    } -Parameters @{ Tweak = $Tweak } -OnComplete {
        param($res)
        $st = $script:UiState
        $resObj = @($res) | Select-Object -First 1
        if ($null -eq $resObj) {
            Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Listo'
            return
        }
        $tw = $st.Tweaks | Where-Object { $_.id -eq $resObj.Id } | Select-Object -First 1
        if ($null -ne $tw) {
            Update-TweakStatusBadge -SyncHash $st.SyncHash -Tweak $tw
        }
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Reversión completada' -StepDetail "Resultado: $($resObj.Name) -> $($resObj.Message)" -StatsText '1/1 (100%)' -Percent 100
        Add-WinForgeLogLine -Message "[REVERTIR OK] $($resObj.Name): $($resObj.Message)"
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Listo'
    } -OnError {
        param($err)
        $st = $script:UiState
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Error al revertir' -StepDetail "Detalle: $err" -Percent 0
        Add-WinForgeLogLine -Message "[REVERTIR ERROR] $err"
        Set-UiBusyState -SyncHash $st.SyncHash -Busy $false -StatusText 'Estado: Error'
    } | Out-Null
}

function Start-WinForgeGui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][PSCustomObject]$HardwareProfile,
        [Parameter(Mandatory)][PSCustomObject[]]$Tweaks,
        [Parameter(Mandatory)][PSCustomObject[]]$Profiles,
        [Parameter(Mandatory)][PSCustomObject]$RunspaceContext
    )

    $xamlContent = [System.IO.File]::ReadAllText($Config.XamlFile, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)

    $syncHash = $RunspaceContext.SyncHash
    $syncHash.Window = $window
    $syncHash['TweakCheckBoxes'] = @{}
    $syncHash['TweakStatusLabels'] = @{}
    $syncHash['TweakCards'] = @{}
    $syncHash['CurrentCategory'] = 'All'

    Start-WinForgeJobMonitor -RunspaceContext $RunspaceContext

    $pendingPath = Join-Path (Split-Path -Parent $Config.BackupRoot) 'pending_queue.json'

    $script:UiState = [PSCustomObject]@{
        SyncHash           = $syncHash
        RunspaceContext    = $RunspaceContext
        Config             = $Config
        HardwareProfile    = $HardwareProfile
        Tweaks             = $Tweaks
        Profiles           = $Profiles
        PendingFile        = $pendingPath
        PendingIds         = @()
        PendingRestorePt   = $true
        PendingTimer       = $null
        PendingSecondsLeft = 0
        TrayIcon           = $null
    }
    $window.Tag = $script:UiState

    $controlNames = @(
        'TxtHardwareOS', 'TxtHardwareCPU', 'TxtHardwareRAM', 'TxtHardwareStorage', 'TxtHardwareChassis',
        'BadgeStorage', 'BadgeChassis', 'TxtGuardrailSummary', 'TxtSessionStatus',
        'BtnGuidedWizard', 'BtnBackgroundMode', 'BtnRefreshStatus', 'BtnRollbackAll',
        'BtnProfileLegacy', 'BtnProfileGaming', 'BtnProfileTrabajo', 'BtnProfileLaptop', 'BtnProfileExtremo',
        'TxtSearchBox', 'ChkRestorePoint', 'BtnSelectAllVisible', 'BtnClearSelection', 'BtnQueueLater', 'BtnApplySelected',
        'NavAll', 'NavPerformance', 'NavPrivacy', 'NavNetwork', 'NavServices', 'NavDebloat', 'NavMaintenance', 'NavStartup',
        'PendingQueueBox', 'TxtPendingSummary', 'BtnRunPendingNow', 'BtnCancelPending',
        'TweakCardsScrollViewer', 'TweakCardsPanel', 'StartupAppsScrollViewer', 'StartupAppsPanel',
        'TxtProgressDetail', 'TxtProcessStats', 'TxtProcessCurrentStep', 'MainProgressBar', 'TxtConsoleLog'
    )

    foreach ($name in $controlNames) {
        $syncHash.Controls[$name] = $window.FindName($name)
    }

    $cpuTypeLabel = if ($HardwareProfile.IsHybridCpu) { 'Híbrido' } elseif ($HardwareProfile.IsLowEndCpu) { 'Básico' } else { 'Estándar' }
    $syncHash.Controls['TxtHardwareOS'].Text = "$($HardwareProfile.OSName) ($($HardwareProfile.DisplayVersion) • $($HardwareProfile.FullBuild))"
    $syncHash.Controls['TxtHardwareCPU'].Text = "CPU ($cpuTypeLabel): $($HardwareProfile.CpuCores)C/$($HardwareProfile.CpuThreads)T"
    $syncHash.Controls['TxtHardwareRAM'].Text = "RAM: $($HardwareProfile.FreeRamGB)/$($HardwareProfile.TotalRamGB) GB libres"
    $syncHash.Controls['TxtHardwareStorage'].Text = "Disco $($HardwareProfile.Storage.DriveLetter) $($HardwareProfile.Storage.MediaType)"
    $syncHash.Controls['TxtHardwareChassis'].Text = "$($HardwareProfile.Chassis.FormFactor) • $($HardwareProfile.ActivePowerPlan)"

    $guardNotes = [System.Collections.Generic.List[string]]::new()
    $guardNotes.Add("• Sugerido: $($HardwareProfile.RecommendedTier)")
    if ($HardwareProfile.Storage.IsHDD) {
        $syncHash.Controls['BadgeStorage'].BorderBrush = Get-FrozenBrush '#8A8A8A'
        $guardNotes.Add('• HDD: SysMain y Search bloqueados.')
    }
    if ($HardwareProfile.TotalRamGB -le 8.5) {
        $guardNotes.Add('• RAM <= 8GB: Memory Compression protegida.')
    }
    if ($HardwareProfile.Chassis.IsLaptop) {
        $syncHash.Controls['BadgeChassis'].BorderBrush = Get-FrozenBrush '#7A7A7A'
        $guardNotes.Add('• Laptop: Avisos de batería activos.')
    }
    $syncHash.Controls['TxtGuardrailSummary'].Text = ($guardNotes -join "`n")

    foreach ($tweak in $Tweaks) {
        $card = New-TweakCardElement -Tweak $tweak -SyncHash $syncHash
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
        $btn = $syncHash.Controls[$btnName]
        $btn.Tag = $navMap[$btnName]
        $btn.Add_Click({
            param($s, $e)
            $st = $script:UiState
            $cat = [string]$s.Tag
            $st.SyncHash.CurrentCategory = $cat
            Render-TweakList -SyncHash $st.SyncHash -Tweaks $st.Tweaks -CategoryFilter $cat -SearchText $st.SyncHash.Controls['TxtSearchBox'].Text
        })
    }

    $syncHash.Controls['NavStartup'].Add_Click({
        $st = $script:UiState
        $st.SyncHash.CurrentCategory = 'Startup'
        Render-StartupAppsList -SyncHash $st.SyncHash
    })

    $syncHash.Controls['TxtSearchBox'].Add_TextChanged({
        $st = $script:UiState
        if ($st.SyncHash.CurrentCategory -ne 'Startup') {
            Render-TweakList -SyncHash $st.SyncHash -Tweaks $st.Tweaks -CategoryFilter $st.SyncHash.CurrentCategory -SearchText $st.SyncHash.Controls['TxtSearchBox'].Text
        }
    })

    $syncHash.Controls['BtnGuidedWizard'].Add_Click({
        $st = $script:UiState
        if (-not $st.SyncHash.IsBusy) {
            Show-GuidedWizardDialog -SyncHash $st.SyncHash -HardwareProfile $st.HardwareProfile -Tweaks $st.Tweaks
        }
    })

    $syncHash.Controls['BtnBackgroundMode'].Add_Click({
        Invoke-MinimizedBackgroundMode
    })

    $syncHash.Controls['BtnSelectAllVisible'].Add_Click({
        $st = $script:UiState
        foreach ($t in $st.Tweaks) {
            if ($st.SyncHash.CurrentCategory -ne 'All' -and $t.category -ne $st.SyncHash.CurrentCategory) { continue }
            $chk = $st.SyncHash.TweakCheckBoxes[$t.id]
            if ($chk -and $chk.IsEnabled) { $chk.IsChecked = $true }
        }
        Update-SelectedCounterUi -SyncHash $st.SyncHash
    })

    $syncHash.Controls['BtnClearSelection'].Add_Click({
        $st = $script:UiState
        foreach ($chk in $st.SyncHash.TweakCheckBoxes.Values) {
            $chk.IsChecked = $false
        }
        Update-SelectedCounterUi -SyncHash $st.SyncHash
    })

    $profileButtons = @{
        'BtnProfileLegacy'  = 'Legacy'
        'BtnProfileGaming'  = 'Gaming'
        'BtnProfileTrabajo' = 'Trabajo'
        'BtnProfileLaptop'  = 'Laptop'
        'BtnProfileExtremo' = 'Extremo'
    }

    foreach ($pBtn in $profileButtons.Keys) {
        $btn = $syncHash.Controls[$pBtn]
        $btn.Tag = $profileButtons[$pBtn]
        $btn.Add_Click({
            param($s, $e)
            $st = $script:UiState
            $pName = [string]$s.Tag
            $prof = $st.Profiles | Where-Object { $_.id -eq $pName -or $_.name -eq $pName } | Select-Object -First 1
            if ($null -eq $prof) { return }

            foreach ($chk in $st.SyncHash.TweakCheckBoxes.Values) { $chk.IsChecked = $false }

            $selectedIds = @($prof.tweakIds)
            $skippedCount = 0
            $checkedCount = 0
            foreach ($tid in $selectedIds) {
                $chk = $st.SyncHash.TweakCheckBoxes[$tid]
                if ($null -ne $chk) {
                    if ($chk.IsEnabled) {
                        $chk.IsChecked = $true
                        $checkedCount++
                    }
                    else {
                        $skippedCount++
                    }
                }
            }
            Update-SelectedCounterUi -SyncHash $st.SyncHash
            Add-WinForgeLogLine -Message "[PERFIL] '$($prof.name)' cargado: $checkedCount marcados, $skippedCount bloqueados por tu hardware."
            Set-ProcessPanelState -SyncHash $st.SyncHash -Headline "Perfil '$($prof.name)' preparado" -StepDetail "Listo para ejecutar $checkedCount ajustes ($skippedCount protegidos por hardware)." -StatsText "$checkedCount marcados"
        })
    }

    $syncHash.Controls['BtnRefreshStatus'].Add_Click({
        $st = $script:UiState
        if (-not $st.SyncHash.IsBusy) {
            Start-AsyncStatusAudit
        }
    })

    $syncHash.Controls['BtnApplySelected'].Add_Click({
        $st = $script:UiState
        if ($st.SyncHash.IsBusy) { return }

        $toApply = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($t in $st.Tweaks) {
            $chk = $st.SyncHash.TweakCheckBoxes[$t.id]
            if ($null -ne $chk -and $chk.IsChecked -eq $true -and $chk.IsEnabled) {
                $toApply.Add($t)
            }
        }
        if ($toApply.Count -eq 0) { return }

        $createRp = ($st.SyncHash.Controls['ChkRestorePoint'].IsChecked -eq $true)
        Start-BatchApplyTweaks -TweaksToApply $toApply.ToArray() -CreateRestorePoint $createRp -OriginLabel 'GUI_Ahora'
    })

    $syncHash.Controls['BtnQueueLater'].Add_Click({
        $st = $script:UiState
        if ($st.SyncHash.IsBusy) { return }

        $selectedIds = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $st.Tweaks) {
            $chk = $st.SyncHash.TweakCheckBoxes[$t.id]
            if ($null -ne $chk -and $chk.IsChecked -eq $true -and $chk.IsEnabled) {
                $selectedIds.Add($t.id)
            }
        }
        if ($selectedIds.Count -eq 0) { return }

        $choice = Show-QueueLaterDialog -SelectedIds $selectedIds.ToArray()
        if ($choice -eq 'Cancel') { return }

        $createRp = ($st.SyncHash.Controls['ChkRestorePoint'].IsChecked -eq $true)
        Save-WinForgePendingQueue -PendingFilePath $st.PendingFile -TweakIds $selectedIds.ToArray() -CreateRestorePoint $createRp
        $st.PendingIds = $selectedIds.ToArray()
        $st.PendingRestorePt = $createRp

        if ($null -ne $st.PendingTimer) {
            $st.PendingTimer.Stop()
            $st.PendingTimer = $null
        }

        if ($choice -in @('Delay10', 'Delay30')) {
            $st.PendingSecondsLeft = if ($choice -eq 'Delay10') { 600 } else { 1800 }
            $pTimer = [System.Windows.Threading.DispatcherTimer]::new()
            $pTimer.Interval = [TimeSpan]::FromSeconds(1)
            $pTimer.Add_Tick({
                $state = $script:UiState
                if ($null -eq $state) { return }
                $state.PendingSecondsLeft--
                Update-PendingBannerUi
                if ($state.PendingSecondsLeft -le 0) {
                    $state.PendingTimer.Stop()
                    $state.PendingTimer = $null
                    $batch = @($state.Tweaks | Where-Object { $state.PendingIds -contains $_.id -and $_.GuardStatus -ne 'Blocked' })
                    if ($batch.Count -gt 0 -and -not $state.SyncHash.IsBusy) {
                        Add-WinForgeLogLine -Message "[PENDIENTE] Tiempo cumplido. Iniciando ejecución automática en segundo plano de $($batch.Count) ajustes..."
                        Start-BatchApplyTweaks -TweaksToApply $batch -CreateRestorePoint $state.PendingRestorePt -OriginLabel 'Auto_Pendiente'
                    }
                }
            })
            $st.PendingTimer = $pTimer
            $pTimer.Start()
            Update-PendingBannerUi
            Add-WinForgeLogLine -Message "[PENDIENTE] $($st.PendingIds.Count) ajustes programados en segundo plano ($($st.PendingSecondsLeft / 60) min)."
            Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Tarea programada en 2º plano' -StepDetail "Se ejecutarán $($st.PendingIds.Count) ajustes automáticamente al finalizar la cuenta atrás."
            Invoke-MinimizedBackgroundMode
        }
        else {
            $st.PendingSecondsLeft = 0
            Update-PendingBannerUi
            Add-WinForgeLogLine -Message "[PENDIENTE] $($st.PendingIds.Count) ajustes guardados en cola ($($st.PendingFile)). Puedes ejecutarlos cuando vuelvas."
            Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Pendientes guardados' -StepDetail "Cola guardada con $($st.PendingIds.Count) ajustes. Pulsa 'Ejecutar' en Pendientes cuando estés listo."
        }
    })

    $syncHash.Controls['BtnRunPendingNow'].Add_Click({
        $st = $script:UiState
        if ($st.SyncHash.IsBusy -or $st.PendingIds.Count -eq 0) { return }

        if ($null -ne $st.PendingTimer) {
            $st.PendingTimer.Stop()
            $st.PendingTimer = $null
        }
        $st.PendingSecondsLeft = 0
        $batch = @($st.Tweaks | Where-Object { $st.PendingIds -contains $_.id -and $_.GuardStatus -ne 'Blocked' })
        if ($batch.Count -gt 0) {
            Start-BatchApplyTweaks -TweaksToApply $batch -CreateRestorePoint $st.PendingRestorePt -OriginLabel 'Cola_Pendiente'
        }
    })

    $syncHash.Controls['BtnCancelPending'].Add_Click({
        $st = $script:UiState
        if ($null -ne $st.PendingTimer) {
            $st.PendingTimer.Stop()
            $st.PendingTimer = $null
        }
        $st.PendingSecondsLeft = 0
        $st.PendingIds = @()
        Clear-WinForgePendingQueue -PendingFilePath $st.PendingFile
        Update-PendingBannerUi
        Add-WinForgeLogLine -Message '[PENDIENTE] Cola de pendientes cancelada y eliminada.'
    })

    $syncHash.Controls['BtnRollbackAll'].Add_Click({
        $st = $script:UiState
        if ($st.SyncHash.IsBusy) { return }

        $confirm = [System.Windows.MessageBox]::Show(
            "¿Deseas revertir los cambios aplicados y restaurar las claves de registro desde la última sesión de respaldo?",
            'Revertir Todo - WinForge Engine',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }

        Set-UiBusyState -SyncHash $st.SyncHash -Busy $true -StatusText 'Revirtiendo cambios...'
        Set-ProcessPanelState -SyncHash $st.SyncHash -Headline 'Rollback completo en curso' -StepDetail 'Paso actual: Restaurando valores originales y backups .reg...' -StatsText 'Procesando...'
        Update-WinForgeUi -SyncHash $st.SyncHash -Action {
            $pb = $st.SyncHash.Controls['MainProgressBar']
            if ($null -ne $pb) { $pb.IsIndeterminate = $true }
        }

        $backupRoot = $st.Config.BackupRoot
        Invoke-WinForgeAsync -RunspaceContext $st.RunspaceContext -ScriptBlock {
            param($SyncHash, $BackupRoot, $AllTweaks)

            $logCb = {
                param($msg)
                $ts = Get-Date -Format 'HH:mm:ss'
                if ($null -ne $SyncHash.LogQueue) {
                    $SyncHash.LogQueue.Enqueue("[$ts] $msg")
                }
            }

            $rbRes = @(Invoke-WinForgeRollback -BackupRoot $BackupRoot -AllTweaks $AllTweaks -LogCallback $logCb)
            foreach ($t in $AllTweaks) {
                if ($t.GuardStatus -ne 'Blocked' -and $t.category -ne 'Maintenance') {
                    $stItem = Get-WinForgeTweakStatus -Tweak $t
                    $t.IsApplied = $stItem.IsApplied
                    $t.DetectionState = $stItem.Label
                }
            }
            return $rbRes
        } -Parameters @{
            BackupRoot = $backupRoot
            AllTweaks  = $st.Tweaks
        } -OnComplete {
            param($rbRes)
            $state = $script:UiState
            foreach ($t in $state.Tweaks) {
                Update-TweakStatusBadge -SyncHash $state.SyncHash -Tweak $t
            }
            $count = @($rbRes).Count
            Set-ProcessPanelState -SyncHash $state.SyncHash -Headline 'Rollback finalizado' -StepDetail "Paso actual: Sistema restaurado ($count elementos procesados)." -StatsText "$count revertidos" -Percent 100
            Add-WinForgeLogLine -Message "[ROLLBACK] Finalizado ($count elementos procesados)."
            Set-UiBusyState -SyncHash $state.SyncHash -Busy $false -StatusText 'Estado: Listo'
        } -OnError {
            param($err)
            $state = $script:UiState
            Set-ProcessPanelState -SyncHash $state.SyncHash -Headline 'Error en Rollback' -StepDetail "Detalle: $err" -Percent 0
            Add-WinForgeLogLine -Message "[ERROR ROLLBACK] $err"
            Set-UiBusyState -SyncHash $state.SyncHash -Busy $false -StatusText 'Estado: Error'
        } | Out-Null
    })

    $window.Add_ContentRendered({
        $st = $script:UiState
        if ($null -eq $st) { return }

        Add-WinForgeLogLine -Message "[INIT] WinForge Engine v$($st.Config.Version) en $($st.HardwareProfile.ComputerName) | Tier sugerido: $($st.HardwareProfile.RecommendedTier)."

        if (Test-Path -LiteralPath $st.PendingFile) {
            try {
                $rawPend = [System.IO.File]::ReadAllText($st.PendingFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $pendIds = @($rawPend.TweakIds)
                if ($pendIds.Count -gt 0) {
                    $st.PendingIds = $pendIds
                    $st.PendingRestorePt = [bool]$rawPend.CreateRestorePoint
                    foreach ($tid in $pendIds) {
                        $chk = $st.SyncHash.TweakCheckBoxes[$tid]
                        if ($null -ne $chk -and $chk.IsEnabled) { $chk.IsChecked = $true }
                    }
                    Update-SelectedCounterUi -SyncHash $st.SyncHash
                    Update-PendingBannerUi
                    Add-WinForgeLogLine -Message "[PENDIENTE] Se recuperaron $($pendIds.Count) ajustes pendientes de tu sesión anterior. Pulsa 'Ejecutar' en Pendientes en Cola cuando quieras aplicarlos."
                }
            }
            catch { }
        }

        Start-AsyncStatusAudit
    })

    $window.Add_Closing({
        $st = $script:UiState
        if ($null -ne $st -and $null -ne $st.PendingTimer) {
            $st.PendingTimer.Stop()
            $st.PendingTimer = $null
        }
    })

    [void]$window.ShowDialog()
    $script:UiState = $null
}

Export-ModuleMember -Function @(
    'Start-WinForgeGui',
    'Get-FrozenBrush',
    'Add-WinForgeLogLine',
    'Set-ProcessPanelState',
    'Update-SelectedCounterUi',
    'Set-UiBusyState',
    'New-TweakCardElement',
    'Update-TweakStatusBadge',
    'Render-TweakList',
    'Render-StartupAppsList',
    'Show-GuidedWizardDialog',
    'Save-WinForgePendingQueue',
    'Clear-WinForgePendingQueue',
    'Update-PendingBannerUi',
    'Show-QueueLaterDialog',
    'Invoke-MinimizedBackgroundMode',
    'Start-AsyncStatusAudit',
    'Start-BatchApplyTweaks',
    'Invoke-SingleTweakRevert'
)
