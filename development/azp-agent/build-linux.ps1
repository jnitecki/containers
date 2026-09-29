#!/usr/bin/env pwsh
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
	Enter-DockerHubSession -Repository "jnitecki/azp-agent" -Tool podman -Username $HubUsername -Token $HubToken;

	# Check up front that the Docker Hub metadata sync at the end would be allowed, rather than
	# finding out only after the image has been built and pushed.
	if (-not $SkipHubMetadata) {
		Assert-DockerHubWriteAccess -Repository "jnitecki/azp-agent";
	}

	Assert-VersionsInSync;

	# Both platforms are always built, but no Android emulator exists for Linux arm64, so the arm64 image
	# silently skips it - say so up front rather than only inside the arm64 build step's log.
	$pins = Get-PinnedVersions;
	if (-not [String]::IsNullOrEmpty([String]$pins.installAndroidEmulator)) {
		Write-Warning "installAndroidEmulator is set ('$($pins.installAndroidEmulator)'), but no Android emulator exists for Linux arm64 - the linux/arm64 image will be built without it.";
	}
	$version = Resolve-AgentVersion -Version $version;

	# Register QEMU binfmt handlers so Podman can build for the non-native platform.
	# On Linux, Podman runs directly on the host; on Windows/macOS it runs inside the Podman Machine VM,
	# so the command must be run there instead. multiarch/qemu-user-static has no native arm64 image, which
	# causes an "Exec format error" on arm64 hosts (e.g. Apple Silicon); tonistiigi/binfmt is multi-arch and
	# is the maintained replacement.
	$binfmtArgs = ("run", "--rm", "--privileged", "docker.io/tonistiigi/binfmt", "--install", "all");
	if ($IsLinux) {
		Start-Process -NoNewWindow -FilePath sudo -ArgumentList (@("podman") + $binfmtArgs) -PassThru -Wait | Out-Null;
	} else {
		Start-Process -NoNewWindow -FilePath podman -ArgumentList (@("machine", "ssh", "--", "sudo", "podman") + $binfmtArgs) -PassThru -Wait | Out-Null;
	}
	Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "docker.io/jnitecki/azp-agent:latest", "docker.io/jnitecki/azp-agent:$version", "jnitecki/azp-agent:$version") -PassThru -Wait | Out-Null;
	$buildArgs = @("build") + (Get-DockerHubAuthArgs) + @("--platform", "linux/amd64,linux/arm64", "--squash", "-f", "Dockerfile.linux", "--manifest", "azp-agent:$version", "--manifest", "jnitecki/azp-agent:$version", "--build-arg", "AGENT_VERSION=$version") + (Get-ToolchainBuildArgs -Os Linux);
	if ($NoCache) {
		$buildArgs += "--no-cache";
	}
	$buildArgs += "linux-context";

	Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "azp-agent:$version", "docker.io/jnitecki/azp-agent:$version", "docker.io/jnitecki/azp-agent:latest") -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList (@("manifest", "push") + (Get-DockerHubAuthArgs) + @("docker.io/jnitecki/azp-agent:$version")) -PassThru -Wait | Out-Null;
	$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList (@("manifest", "push") + (Get-DockerHubAuthArgs) + @("docker.io/jnitecki/azp-agent:latest")) -PassThru -Wait;

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
