# Shared helpers for build-linux.ps1 / build-windows.ps1. Dot-source this file:
#   . "$PSScriptRoot/build-common.ps1"

# Maps each settings.ps1 Versions key to the dockerfile ARG it feeds, and which dockerfile(s) that
# ARG exists in (INSTALL_PODMAN, INSTALL_BUILD_ESSENTIAL, INSTALL_PYTHON_DEV and
# INSTALL_ANDROID_EMULATOR have no Windows counterpart).
$script:VersionArgMap = @(
    @{ Field = "installPodman";              Arg = "INSTALL_PODMAN";                Linux = $true; Windows = $false }
    @{ Field = "installBuildEssential";      Arg = "INSTALL_BUILD_ESSENTIAL";       Linux = $true; Windows = $false }
    @{ Field = "installPythonDev";           Arg = "INSTALL_PYTHON_DEV";            Linux = $true; Windows = $false }
    @{ Field = "installJava";                Arg = "INSTALL_JAVA";                  Linux = $true; Windows = $true }
    @{ Field = "installAndroid";             Arg = "INSTALL_ANDROID";               Linux = $true; Windows = $true }
    @{ Field = "androidCmdlineToolsVersion"; Arg = "ANDROID_CMDLINE_TOOLS_VERSION"; Linux = $true; Windows = $true }
    @{ Field = "installAndroidEmulator";     Arg = "INSTALL_ANDROID_EMULATOR";      Linux = $true; Windows = $false }
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

# Returns the settings.ps1 Versions toolchain keys as a flat --build-arg argument list, filtered to
# the ARGs that actually exist on the given OS's dockerfile (e.g. INSTALL_PODMAN is excluded
# for Windows). AGENT_VERSION is handled separately by the caller since it can be overridden
# per-invocation via -version.
function Get-ToolchainBuildArgs {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Linux", "Windows")][String]$Os,
        [Parameter(Mandatory = $true)][Hashtable]$Versions
    )

    $result = @()
    foreach ($entry in $script:VersionArgMap) {
        if (($Os -eq "Linux" -and -not $entry.Linux) -or ($Os -eq "Windows" -and -not $entry.Windows)) {
            continue
        }
        $result += "--build-arg"
        $result += "$($entry.Arg)=$([String]$Versions[$entry.Field])"
    }
    return $result
}
