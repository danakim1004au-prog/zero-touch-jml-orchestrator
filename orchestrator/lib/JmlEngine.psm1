#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    JmlEngine — a small pipeline engine for identity-lifecycle runs.

    A step is a hashtable:
        Name     : string  (unique within the pipeline)
        Test     : scriptblock → $true if already done (step is skipped; idempotency)
        Action   : scriptblock (the work)
        Rollback : scriptblock (how to undo Action), optional
    All scriptblocks receive a single $Context hashtable (shared, mutable —
    steps can stash IDs for later steps and for their own rollback).
#>

$script:LogPath = $null

function Start-JmlRun {
    <#
    .SYNOPSIS
        Initialises a run: creates the JSONL log file, returns the run id.
    #>
    [CmdletBinding()]
    param([string]$LogDirectory = "$PSScriptRoot/../../logs")

    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $runId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath = Join-Path $LogDirectory "jml-$runId.jsonl"
    Write-JmlEvent -Subject 'run' -Step 'start' -Outcome 'started'
    $runId
}

function Write-JmlEvent {
    <#
    .SYNOPSIS
        Appends one structured event to the run's JSONL audit log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,   # usually the UPN
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Outcome,   # started|succeeded|skipped|failed|rolled-back|rollback-failed
        [string]$Detail = '',
        [int]$DurationMs = 0
    )

    $evt = [ordered]@{
        ts         = (Get-Date).ToString('o')
        subject    = $Subject
        step       = $Step
        outcome    = $Outcome
        detail     = $Detail
        durationMs = $DurationMs
    } | ConvertTo-Json -Compress

    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $evt }

    $color = switch ($Outcome) {
        'succeeded' { 'Green' } 'skipped' { 'DarkGray' }
        'failed' { 'Red' } 'rolled-back' { 'Yellow' } 'rollback-failed' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host ("[{0,-15}] {1,-28} {2}" -f $Outcome, $Step, $Detail) -ForegroundColor $color
}

function Invoke-JmlAction {
    <#
    .SYNOPSIS
        Runs a scriptblock with retry/backoff on Graph throttling (429/5xx).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][hashtable]$Context,
        [int]$MaxAttempts = 4
    )

    for ($attempt = 1; ; $attempt++) {
        try { return & $Action $Context }
        catch {
            $statusProp = $_.Exception.PSObject.Properties['ResponseStatusCode']
            $status = if ($statusProp) { [int]$statusProp.Value } else { 0 }
            $retryable = $status -in 429, 502, 503, 504
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            $delay = [math]::Pow(2, $attempt)   # 2, 4, 8s
            Write-Verbose "Throttled ($status), retrying in ${delay}s (attempt $attempt/$MaxAttempts)"
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-JmlPipeline {
    <#
    .SYNOPSIS
        Executes an ordered list of steps for one subject, with skip-if-done
        semantics and reverse-order rollback on failure.
    .DESCRIPTION
        Returns $true if the pipeline completed, $false if it failed (after
        rolling back). Rollback failures are logged and do not stop the rest
        of the unwind — partial cleanup is better than none, and the log
        records exactly what manual cleanup remains.
    .EXAMPLE
        Invoke-JmlPipeline -Subject $upn -Steps $steps -Context $ctx -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][object[]]$Steps,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $rollbackStack = [System.Collections.Generic.Stack[object]]::new()

    foreach ($step in $Steps) {
        if (-not $PSCmdlet.ShouldProcess($Subject, $step.Name)) {
            Write-JmlEvent -Subject $Subject -Step $step.Name -Outcome 'skipped' -Detail '(WhatIf)'
            continue
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($step.Test -and (& $step.Test $Context)) {
                Write-JmlEvent -Subject $Subject -Step $step.Name -Outcome 'skipped' -Detail 'already in desired state' -DurationMs $sw.ElapsedMilliseconds
                continue
            }

            Invoke-JmlAction -Action $step.Action -Context $Context | Out-Null
            if ($step.ContainsKey('Rollback') -and $step.Rollback) { $rollbackStack.Push($step) }
            Write-JmlEvent -Subject $Subject -Step $step.Name -Outcome 'succeeded' -DurationMs $sw.ElapsedMilliseconds
        }
        catch {
            Write-JmlEvent -Subject $Subject -Step $step.Name -Outcome 'failed' -Detail "$_" -DurationMs $sw.ElapsedMilliseconds

            while ($rollbackStack.Count -gt 0) {
                $undo = $rollbackStack.Pop()
                try {
                    & $undo.Rollback $Context | Out-Null
                    Write-JmlEvent -Subject $Subject -Step $undo.Name -Outcome 'rolled-back'
                }
                catch {
                    Write-JmlEvent -Subject $Subject -Step $undo.Name -Outcome 'rollback-failed' -Detail "$_ — MANUAL CLEANUP REQUIRED"
                }
            }
            return $false
        }
    }
    $true
}

Export-ModuleMember -Function Start-JmlRun, Write-JmlEvent, Invoke-JmlAction, Invoke-JmlPipeline
