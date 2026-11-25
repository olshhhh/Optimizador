<#
.SYNOPSIS
    WinForge Engine - RunspaceManager.
.DESCRIPTION
    Motor de ejecución asíncrona basado en RunspacePool y Synchronized Hashtable ($syncHash)
    con soporte thread-safe para Dispatcher de WPF. Evita bloqueos del hilo de interfaz.
#>

Set-StrictMode -Version Latest

function Initialize-WinForgeRunspacePool {
    [CmdletBinding()]
    param(
        [int]$MinThreads = 1,
        [int]$MaxThreads = 4,
        [string[]]$ModulePaths = @()
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ($ModulePaths.Count -gt 0) {
        $iss.ImportPSModule($ModulePaths)
    }

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($MinThreads, $MaxThreads, $iss, $Host)
    $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $pool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $pool.Open()

    $syncHash = [hashtable]::Synchronized(@{
        Window       = $null
        Controls     = [hashtable]::Synchronized(@{})
        IsBusy       = $false
        CancelFlag   = $false
        ActiveJobs   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        RunspacePool = $pool
    })

    return [PSCustomObject]@{
        Pool     = $pool
        SyncHash = $syncHash
        Timer    = $null
    }
}

function Update-WinForgeUi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SyncHash,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $window = $SyncHash.Window
    if ($null -eq $window) {
        return
    }

    if ($window.Dispatcher.HasShutdownStarted -or $window.Dispatcher.HasShutdownFinished) {
        return
    }

    if ($window.Dispatcher.CheckAccess()) {
        & $Action
    }
    else {
        $window.Dispatcher.Invoke([Action]$Action, [System.Windows.Threading.DispatcherPriority]::Normal)
    }
}

function Start-WinForgeJobMonitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RunspaceContext
    )

    if ($null -ne $RunspaceContext.Timer) {
        return
    }

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)

    $syncHash = $RunspaceContext.SyncHash

    $timer.Add_Tick({
        $jobs = $syncHash.ActiveJobs
        if ($jobs.Count -eq 0) {
            return
        }

        $completedIndices = [System.Collections.Generic.List[int]]::new()

        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $job = $jobs[$i]
            if ($job.Handle.IsCompleted) {
                $completedIndices.Add($i)
            }
        }

        for ($j = $completedIndices.Count - 1; $j -ge 0; $j--) {
            $idx = $completedIndices[$j]
            $job = $jobs[$idx]
            $jobs.RemoveAt($idx)

            try {
                $output = $job.PowerShell.EndInvoke($job.Handle)
                $streamErrors = $job.PowerShell.Streams.Error

                if ($streamErrors.Count -gt 0 -and $null -ne $job.OnError) {
                    $errMessages = ($streamErrors | ForEach-Object { $_.ToString() }) -join "`n"
                    & $job.OnError $errMessages
                }
                elseif ($null -ne $job.OnComplete) {
                    & $job.OnComplete $output
                }
            }
            catch {
                if ($null -ne $job.OnError) {
                    & $job.OnError $_.Exception.Message
                }
            }
            finally {
                $job.PowerShell.Dispose()
            }
        }
    }.GetNewClosure())

    $timer.Start()
    $RunspaceContext.Timer = $timer
}

function Invoke-WinForgeAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RunspaceContext,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters = @{},

        [scriptblock]$OnComplete = $null,

        [scriptblock]$OnError = $null
    )

    if ($null -eq $RunspaceContext.Timer) {
        Start-WinForgeJobMonitor -RunspaceContext $RunspaceContext
    }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $RunspaceContext.Pool

    [void]$ps.AddScript($ScriptBlock)
    [void]$ps.AddParameter('SyncHash', $RunspaceContext.SyncHash)

    foreach ($key in $Parameters.Keys) {
        [void]$ps.AddParameter($key, $Parameters[$key])
    }

    $handle = $ps.BeginInvoke()

    $jobEntry = [PSCustomObject]@{
        Id         = [Guid]::NewGuid().ToString('N')
        PowerShell = $ps
        Handle     = $handle
        OnComplete = $OnComplete
        OnError    = $OnError
        StartedAt  = [DateTime]::Now
    }

    [void]$RunspaceContext.SyncHash.ActiveJobs.Add($jobEntry)
    return $jobEntry.Id
}

function Close-WinForgeRunspacePool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RunspaceContext
    )

    try {
        if ($null -ne $RunspaceContext.Timer) {
            $RunspaceContext.Timer.Stop()
            $RunspaceContext.Timer = $null
        }

        if ($null -ne $RunspaceContext.SyncHash) {
            $RunspaceContext.SyncHash.CancelFlag = $true
            foreach ($job in @($RunspaceContext.SyncHash.ActiveJobs)) {
                try {
                    $job.PowerShell.Stop()
                    $job.PowerShell.Dispose()
                }
                catch { }
            }
            $RunspaceContext.SyncHash.ActiveJobs.Clear()
        }

        if ($null -ne $RunspaceContext.Pool) {
            $RunspaceContext.Pool.Close()
            $RunspaceContext.Pool.Dispose()
        }
    }
    catch { }
}

Export-ModuleMember -Function @(
    'Initialize-WinForgeRunspacePool',
    'Update-WinForgeUi',
    'Start-WinForgeJobMonitor',
    'Invoke-WinForgeAsync',
    'Close-WinForgeRunspacePool'
)
