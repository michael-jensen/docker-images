# setup
$ErrorActionPreference = "STOP"

Import-Module WebAdministration

function Wait-WebItemState
{
    param(
        [ValidateNotNullOrEmpty()]
        [string]$IISPath
        ,
        [ValidateSet("Started", "Stopped")]
        [string]$State
    )

    while ($true)
    {
        Write-Host "### Waiting on item '$IISPath' state to be '$State'..."

        try
        {
            $item = Get-Item -Path $IISPath

            if ($null -ne $item -and $item.State -ne $State)
            {
                if ($State -eq "Started")
                {
                    $item = Start-WebItem -PSPath $IISPath -Passthru -ErrorAction "SilentlyContinue"
                }
                elseif ($State -eq "Stopped")
                {
                    $item = Stop-WebItem -PSPath $IISPath -Passthru -ErrorAction "SilentlyContinue"
                }
            }
        }
        catch
        {
            $item = $null
        }

        if ($null -ne $item -and $item.State -eq $State)
        {
            Write-Host "### Waiting on item '$IISPath' completed."

            break
        }

        Start-Sleep -Milliseconds 500
    }
}

# print start message
Write-Host ("### Sitecore Development ENTRYPOINT, starting...")

# wait for w3wp to stop
while ($true)
{
    $processName = "w3wp"

    Write-Host "### Waiting for process '$processName' to stop..."

    $running = [array](Get-Process -Name $processName -ErrorAction "SilentlyContinue").Length -gt 0

    if ($running)
    {
        Stop-Process -Name $processName -Force -ErrorAction "SilentlyContinue"
    }
    else
    {
        Write-Host "### Process '$processName' stopped..."

        break;
    }

    Start-Sleep -Milliseconds 500
}

# wait for application pool to stop
Wait-WebItemState -IISPath "IIS:\AppPools\DefaultAppPool" -State "Stopped"

# check to see if we should start the msvsmon.exe
$useVsDebugger = (Test-Path -Path "C:\remote_debugger\x64\msvsmon.exe" -PathType "Leaf") -eq $true

if ($useVsDebugger)
{
    # start msvsmon.exe in background
    & "C:\remote_debugger\x64\msvsmon.exe" /noauth /anyuser /silent /nostatus /noclrwarn /nosecuritywarn /nofirewallwarn /nowowwarn /timeout:2147483646

    Write-Host ("### Started 'msvsmon.exe'.")
}
else
{
    Write-Host ("### Skipping start of 'msvsmon.exe', to enable you should mount the Visual Studio Remote Debugger directory into 'C:\remote_debugger'.")
}

# check to see if we should start the Watch-Directory.ps1 script
$useWatchDirectory = (Test-Path -Path "C:\src" -PathType "Container") -eq $true

if ($useWatchDirectory)
{
    # start Watch-Directory.ps1 in background, kill foreground process if it fails
    Start-Job -Name "WatchDirectory.ps1" {
        try
        {
            # TODO: Handle additional Watch-Directory params, use param splattering?

            & "C:\tools\scripts\Watch-Directory.ps1" -Path "C:\src" -Destination "C:\inetpub\wwwroot" -ExcludeFiles "Web.config"
        }
        finally
        {
            Get-Process -Name "filebeat" | Stop-Process -Force
        }
    } | ForEach-Object {
        Write-Host ("### Started '$($_.Name)'.")
    }
}
else
{
    Write-Host ("### Skipping start of 'WatchDirectory.ps1', to enable you should mount a directory into 'C:\src'.")
}

if (Test-Path -Path "C:\inetput\wwwroot\App_Config\Include") {
    # inject Sitecore config files
    Copy-Item -Path (Join-Path $PSScriptRoot "\*.config") -Destination "C:\inetpub\wwwroot\App_Config\Include"
}

# start ServiceMonitor.exe in background, kill foreground process if it fails
Start-Job -Name "ServiceMonitor.exe" {
    try
    {
        & "C:\ServiceMonitor.exe" "w3svc"
    }
    finally
    {
        Get-Process -Name "filebeat" | Stop-Process -Force
    }
} | Out-Null

# wait for the ServiceMonitor.exe process is running
while ($true)
{
    $processName = "ServiceMonitor"

    Write-Host "### Waiting for process '$processName' to start..."

    $running = [array](Get-Process -Name $processName -ErrorAction "SilentlyContinue").Length -eq 1

    if ($running)
    {
        Write-Host "### Process '$processName' started..."

        break;
    }

    Start-Sleep -Milliseconds 500
}

# wait for application pool to start
Wait-WebItemState -IISPath "IIS:\AppPools\DefaultAppPool" -State "Started"

# print ready message
Write-Host ("### Sitecore ready!")

# start filebeat.exe in foreground
& "C:\tools\bin\filebeat\filebeat.exe" -c (Join-Path $PSScriptRoot "\filebeat.yml")