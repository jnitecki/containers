#!/usr/bin/env pwsh
# Windows variant publish script. Must run on a Windows host with Docker in Windows-containers
# mode (Podman's Windows-container build support is far less mature than Docker's, so this
# script uses `docker` rather than `podman` — deliberate, not an inconsistency with
# build-linux.ps1). Unlike the Linux script, there's no QEMU/binfmt setup and no manifest
# list: Windows containers are effectively amd64-only today, so this is a plain single-arch
# build/push.
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^[1-9][0-9]*\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$version,
	[Parameter(Mandatory=$false)][switch]$NoCache,
	[Parameter(Mandatory=$false)][switch]$SkipHubMetadata,
	[Parameter(Mandatory=$false)][String]$HubUsername,
	[Parameter(Mandatory=$false)][SecureString]$HubToken
);

. "$PSScriptRoot/build-common.ps1";
. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";

# With -HubToken, every Docker Hub operation below (pulls, pushes, metadata sync) uses that token
# instead of the existing login; Exit-DockerHubSession undoes it even when the script exits early.
try {
	Enter-DockerHubSession -Repository "jnitecki/azp-agent" -Tool docker -Username $HubUsername -Token $HubToken;

	# Check up front that the Docker Hub metadata sync at the end would be allowed, rather than
	# finding out only after the image has been built and pushed.
	if (-not $SkipHubMetadata) {
		Assert-DockerHubWriteAccess -Repository "jnitecki/azp-agent";
	}

	Assert-VersionsInSync;
	$version = Resolve-AgentVersion -Version $version;

	$buildArgs = (Get-DockerHubAuthArgs) + @("build", "-f", "Dockerfile.windows", "-t", "docker.io/jnitecki/azp-agent:$version-windows", "--build-arg", "AGENT_VERSION=$version") + (Get-ToolchainBuildArgs -Os Windows);
	if ($NoCache) {
		$buildArgs += "--no-cache";
	}
	$buildArgs += "windows-context";

	Start-Process -NoNewWindow -FilePath docker -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
	Start-Process -NoNewWindow -FilePath docker -ArgumentList ("tag", "docker.io/jnitecki/azp-agent:$version-windows", "docker.io/jnitecki/azp-agent:windows-latest") -PassThru -Wait | Out-Null;
	Start-Process -NoNewWindow -FilePath docker -ArgumentList ((Get-DockerHubAuthArgs) + @("push", "docker.io/jnitecki/azp-agent:$version-windows")) -PassThru -Wait | Out-Null;
	$pushResult = Start-Process -NoNewWindow -FilePath docker -ArgumentList ((Get-DockerHubAuthArgs) + @("push", "docker.io/jnitecki/azp-agent:windows-latest")) -PassThru -Wait;

	if ($SkipHubMetadata) {
		Write-Host "Skipping Docker Hub README upload (-SkipHubMetadata).";
	} elseif ($pushResult.ExitCode -eq 0) {
		$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
		Publish-DockerHubRepository -Repository "jnitecki/azp-agent" -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
	} else {
		Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
	}
} finally {
	Exit-DockerHubSession;
}
