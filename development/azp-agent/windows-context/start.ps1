# First-draft Windows entrypoint, not yet verified against a real Windows container host —
# in particular the cleanup-on-stop behavior below (see comment near the bottom) needs
# confirming on-target before this is treated as production-ready. See README.md.
$ErrorActionPreference = 'Stop'

function Write-Header($message) {
    Write-Host "`e[1;36m$message`e[0m"
}

function Invoke-Cleanup {
    if (Test-Path .\config.cmd) {
        Write-Header "Cleanup. Removing Azure Pipelines agent..."

        # If the agent has some running jobs, the configuration removal process will fail.
        # So, give it some time to finish the job.
        while ($true) {
            & .\config.cmd remove --unattended --auth PAT --token (Get-Content $env:AZP_TOKEN_FILE -Raw)
            if ($LASTEXITCODE -eq 0) { break }

            Write-Host "Retrying in 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
}

if (-not $env:AZP_URL) {
    Write-Error "missing AZP_URL environment variable"
    exit 1
}

if (-not $env:AZP_TOKEN_FILE) {
    if (-not $env:AZP_TOKEN) {
        Write-Error "missing AZP_TOKEN environment variable"
        exit 1
    }

    $env:AZP_TOKEN_FILE = "C:\azp\.token"
    Set-Content -Path $env:AZP_TOKEN_FILE -Value $env:AZP_TOKEN -NoNewline
}

Remove-Item Env:\AZP_TOKEN -ErrorAction SilentlyContinue

if ($env:AZP_WORK) {
    New-Item -ItemType Directory -Force -Path $env:AZP_WORK | Out-Null
}

# No AGENT_ALLOW_RUNASROOT here: that flag exists for a Linux/macOS root-user safeguard in the
# vsts-agent that has no Windows container equivalent.

# Some build tools (e.g. Gradle toolchains) auto-detect JDKs via JAVA_HOME_<version>_<arch>;
# derive it from JAVA_HOME the same way the Linux entrypoint does. No Windows-arm64 agent build
# exists, so the arch suffix is always X64.
if ($env:JAVA_HOME -and $env:INSTALL_JAVA) {
    Set-Item -Path "Env:JAVA_HOME_$($env:INSTALL_JAVA)_X64" -Value $env:JAVA_HOME
}

# Let the agent ignore the token env variables
$env:VSO_AGENT_IGNORE = "AZP_TOKEN,AZP_TOKEN_FILE"

Write-Header "1. Configuring Azure Pipelines agent..."

$agentName = if ($env:AZP_AGENT_NAME) { $env:AZP_AGENT_NAME } else { $env:COMPUTERNAME }
$pool = if ($env:AZP_POOL) { $env:AZP_POOL } else { "Default" }
$work = if ($env:AZP_WORK) { $env:AZP_WORK } else { "_work" }
$token = Get-Content $env:AZP_TOKEN_FILE -Raw

& .\config.cmd --unattended `
    --agent $agentName `
    --url $env:AZP_URL `
    --auth PAT `
    --token $token `
    --pool $pool `
    --work $work `
    --replace `
    --acceptTeeEula

Write-Header "2. Running Azure Pipelines agent..."

# Ctrl+C (SIGINT-equivalent) inside the container.
[Console]::CancelKeyPress.Add({
    param($sender, $eventArgs)
    Invoke-Cleanup
    exit 130
})

# NOTE: unlike start.sh's bash `trap ... EXIT INT TERM`, there is no single reliable PowerShell
# mechanism that covers an external `docker stop`/container-stop signal the way POSIX SIGTERM
# delivery does. The try/finally below covers normal completion and in-script errors, and
# CancelKeyPress above covers Ctrl+C, but whether `docker stop` actually reaches this process in
# time for Invoke-Cleanup to run (rather than being killed outright) has not been verified on a
# real Windows container host and must be checked before relying on this for graceful agent
# de-registration in production.
try {
    & .\run.cmd --once
} finally {
    Invoke-Cleanup
}
