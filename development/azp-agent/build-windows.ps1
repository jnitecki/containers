#!/usr/bin/env pwsh
# Windows variant publish script. Must run on a Windows host with Docker in Windows-containers
# mode (Podman's Windows-container build support is far less mature than Docker's, so this
# script uses `docker` rather than `podman` — deliberate, not an inconsistency with
# build-linux.ps1). Unlike the Linux script, there's no QEMU/binfmt setup and no manifest
# list: Windows containers are effectively amd64-only today, so this is a plain single-arch
# build/push.
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^[1-9][0-9]*\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$version,
	[Parameter(Mandatory=$false)][ValidateSet("none", "mine", "all")][String]$Squash,
	[Parameter(Mandatory=$false)][switch]$NoCache,
	[Parameter(Mandatory=$false)][switch]$SkipHubMetadata,
	[Parameter(Mandatory=$false)][String]$HubUsername,
	[Parameter(Mandatory=$false)][SecureString]$HubToken
);

# Windows images can only be built by Docker on a Windows host, so fail with a clear message rather
# than an obscure docker error elsewhere; build-linux.ps1 runs on Linux, macOS and Windows hosts.
if (-not $IsWindows) {
	Write-Error "build-windows.ps1 must run on a Windows host with Docker in Windows-containers mode.";
	exit 1;
}

. "$PSScriptRoot/build-common.ps1";
. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";
. "$PSScriptRoot/../../scripts/build-settings.ps1";

# Defaults come from settings.ps1; parameters passed on the command line take precedence.
$settings = Import-BuildSettings -Path "$PSScriptRoot/settings.ps1" -BoundParameters $PSBoundParameters -Section Windows;
if ($settings.Versions.version) { $version = $settings.Versions.version; }
$NoCache = [bool]$settings.Build.NoCache;
$SkipHubMetadata = [bool]$settings.Build.SkipHubMetadata;
$HubUsername = $settings.Build.HubUsername;
$repository = $settings.Build.Repository;
$image = "$($settings.Build.Registry)/$($settings.Build.Repository)";

# With -HubToken, every Docker Hub operation below (pulls, pushes, metadata sync) uses that token
# instead of the existing login; Exit-DockerHubSession undoes it even when the script exits early.
# The build runs from the script's own directory, so the relative dockerfile/context paths below work
# wherever the script is started from; Pop-Location restores the caller's location, also on exit.
# Relative rather than $PSScriptRoot-based paths also keep Start-Process, which joins -ArgumentList
# with plain spaces, safe when the repository sits under a path containing spaces.
Push-Location -LiteralPath $PSScriptRoot;
try {
	Enter-DockerHubSession -Repository $repository -Tool docker -Username $HubUsername -Token $HubToken;

	# Check up front that the Docker Hub metadata sync at the end would be allowed, rather than
	# finding out only after the image has been built and pushed.
	if (-not $SkipHubMetadata) {
		Assert-DockerHubWriteAccess -Repository $repository;
	}

	$version = Resolve-AgentVersion -Version $version;

	$buildArgs = (Get-DockerHubAuthArgs) + @("build", "-f", "dockerfile.windows", "-t", "${image}:$version-windows", "--build-arg", "AGENT_VERSION=$version") + (Get-ToolchainBuildArgs -Os Windows -Versions $settings.Versions) + (Get-SquashArgs -Squash $settings.Build.Squash -Tool docker);
	if ($NoCache) {
		$buildArgs += "--no-cache";
	}
	$buildArgs += "windows-context";

	Start-Process -NoNewWindow -FilePath docker -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
	Start-Process -NoNewWindow -FilePath docker -ArgumentList ("tag", "${image}:$version-windows", "${image}:windows-latest") -PassThru -Wait | Out-Null;
	Start-Process -NoNewWindow -FilePath docker -ArgumentList ((Get-DockerHubAuthArgs) + @("push", "${image}:$version-windows")) -PassThru -Wait | Out-Null;
	$pushResult = Start-Process -NoNewWindow -FilePath docker -ArgumentList ((Get-DockerHubAuthArgs) + @("push", "${image}:windows-latest")) -PassThru -Wait;

	if ($SkipHubMetadata) {
		Write-Host "Skipping Docker Hub README upload (-SkipHubMetadata).";
	} elseif ($pushResult.ExitCode -eq 0) {
		$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
		Publish-DockerHubRepository -Repository $repository -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
	} else {
		Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
	}
} finally {
	Exit-DockerHubSession;
	Pop-Location;
}
