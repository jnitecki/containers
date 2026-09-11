# Shared helpers for install-linux.ps1 / install-windows.ps1. Dot-source this file:
#   . "$PSScriptRoot/install-common.ps1"

# Maps each versions.json field to the Dockerfile ARG it feeds, and which Dockerfile(s) that
# ARG is expected to exist in (INSTALL_PODMAN has no Windows counterpart).
$script:VersionArgMap = @(
    @{ Field = "installPodman";              Arg = "INSTALL_PODMAN";                Linux = $true; Windows = $false }
    @{ Field = "installJava";                Arg = "INSTALL_JAVA";                  Linux = $true; Windows = $true }
    @{ Field = "installAndroid";             Arg = "INSTALL_ANDROID";               Linux = $true; Windows = $true }
    @{ Field = "androidCmdlineToolsVersion"; Arg = "ANDROID_CMDLINE_TOOLS_VERSION"; Linux = $true; Windows = $true }
    @{ Field = "installPowershell";          Arg = "INSTALL_POWERSHELL";            Linux = $true; Windows = $true }
    @{ Field = "installDotnet";              Arg = "INSTALL_DOTNET";                Linux = $true; Windows = $true }
    @{ Field = "installNode";                Arg = "INSTALL_NODE";                  Linux = $true; Windows = $true }
)

function Resolve-AgentVersion {
    param([Parameter(Mandatory = $false)][String]$Version)

    if (-not [String]::IsNullOrEmpty($Version)) {
        return $Version
    }

    $response = Invoke-WebRequest -Uri "https://github.com/microsoft/azure-pipelines-agent/releases/latest" -UseBasicParsing
    $match = [Regex]::Match($response.Content, '/microsoft/azure-pipelines-agent/releases/tag/v(\d+\.\d+\.\d+)"')
    if (-not $match.Success) {
        Write-Error "Release version is not detected"
        exit 1
    }
    $resolved = $match.Groups[1].Value
    Write-Host "Using version: $resolved"
    return $resolved
}

function Get-PinnedVersions {
    $versionsPath = Join-Path $PSScriptRoot "versions.json"
    return Get-Content $versionsPath -Raw | ConvertFrom-Json
}

function Get-DockerfileArgDefault {
    param(
        [Parameter(Mandatory = $true)][String]$DockerfilePath,
        [Parameter(Mandatory = $true)][String]$ArgName
    )

    $match = Select-String -Path $DockerfilePath -Pattern "^ARG\s+$ArgName=(.*)$" | Select-Object -First 1
    if (-not $match) {
        return $null
    }
    return $match.Matches[0].Groups[1].Value.Trim()
}

# Fails the build if either Dockerfile's ARG defaults have drifted from versions.json, so a
# plain `docker build`/`podman build` without --build-arg stays consistent between OSes and
# with the pinned versions this repo publishes.
function Assert-VersionsInSync {
    $pins = Get-PinnedVersions
    $linuxDockerfile = Join-Path $PSScriptRoot "Dockerfile.linux"
    $windowsDockerfile = Join-Path $PSScriptRoot "Dockerfile.windows"
    $mismatches = @()

    foreach ($entry in $script:VersionArgMap) {
        $pinned = [String]$pins.($entry.Field)

        if ($entry.Linux) {
            $actual = Get-DockerfileArgDefault -DockerfilePath $linuxDockerfile -ArgName $entry.Arg
            if ($actual -ne $pinned) {
                $mismatches += "Dockerfile.linux: ARG $($entry.Arg) default is '$actual', versions.json has '$pinned'"
            }
        }
        if ($entry.Windows) {
            $actual = Get-DockerfileArgDefault -DockerfilePath $windowsDockerfile -ArgName $entry.Arg
            if ($actual -ne $pinned) {
                $mismatches += "Dockerfile.windows: ARG $($entry.Arg) default is '$actual', versions.json has '$pinned'"
            }
        }
    }

    $pinnedAgentVersion = [String]$pins.agentVersion
    $linuxAgentDefault = Get-DockerfileArgDefault -DockerfilePath $linuxDockerfile -ArgName "AGENT_VERSION"
    $windowsAgentDefault = Get-DockerfileArgDefault -DockerfilePath $windowsDockerfile -ArgName "AGENT_VERSION"
    if ($linuxAgentDefault -ne $pinnedAgentVersion) {
        $mismatches += "Dockerfile.linux: ARG AGENT_VERSION default is '$linuxAgentDefault', versions.json has '$pinnedAgentVersion'"
    }
    if ($windowsAgentDefault -ne $pinnedAgentVersion) {
        $mismatches += "Dockerfile.windows: ARG AGENT_VERSION default is '$windowsAgentDefault', versions.json has '$pinnedAgentVersion'"
    }

    if ($mismatches.Count -gt 0) {
        Write-Error "versions.json is out of sync with Dockerfile ARG defaults:`n$($mismatches -join "`n")"
        exit 1
    }
}

# Returns the versions.json toolchain fields as a flat --build-arg argument list, filtered to
# the ARGs that actually exist on the given OS's Dockerfile (e.g. INSTALL_PODMAN is excluded
# for Windows). AGENT_VERSION is handled separately by the caller since it can be overridden
# per-invocation via -version.
function Get-ToolchainBuildArgs {
    param([Parameter(Mandatory = $true)][ValidateSet("Linux", "Windows")][String]$Os)

    $pins = Get-PinnedVersions
    $result = @()
    foreach ($entry in $script:VersionArgMap) {
        if (($Os -eq "Linux" -and -not $entry.Linux) -or ($Os -eq "Windows" -and -not $entry.Windows)) {
            continue
        }
        $result += "--build-arg"
        $result += "$($entry.Arg)=$([String]$pins.($entry.Field))"
    }
    return $result
}
