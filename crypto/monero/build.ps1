#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)\.([1-9][0-9]*|0)$")][String]$daemonVersion,
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+$")][String]$poolVersion,
	[Parameter(Mandatory=$false)][ValidateSet("none", "mine", "all")][String]$Squash,
	[Parameter(Mandatory=$false)][switch]$NoCache,
	[Parameter(Mandatory=$false)][switch]$SkipHubMetadata,
	[Parameter(Mandatory=$false)][String]$HubUsername,
	[Parameter(Mandatory=$false)][SecureString]$HubToken
);

. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";
. "$PSScriptRoot/../../scripts/build-settings.ps1";

# Defaults come from settings.ps1; parameters passed on the command line take precedence.
$settings = Import-BuildSettings -Path "$PSScriptRoot/settings.ps1" -BoundParameters $PSBoundParameters;
if ($settings.Versions.daemonVersion) { $daemonVersion = $settings.Versions.daemonVersion; }
if ($settings.Versions.poolVersion) { $poolVersion = $settings.Versions.poolVersion; }
$NoCache = [bool]$settings.Build.NoCache;
$SkipHubMetadata = [bool]$settings.Build.SkipHubMetadata;
$HubUsername = $settings.Build.HubUsername;
$repository = $settings.Build.Repository;
$image = "$($settings.Build.Registry)/$($settings.Build.Repository)";
$imageName = $settings.Build.ImageName;

# With -HubToken, every Docker Hub operation below (pulls, pushes, metadata sync) uses that token
# instead of the existing login; Exit-DockerHubSession undoes it even when the script exits early.
try {
	Enter-DockerHubSession -Repository $repository -Tool podman -Username $HubUsername -Token $HubToken;

	# Check up front that the Docker Hub metadata sync at the end would be allowed, rather than
	# finding out only after the image has been built and pushed.
	if (-not $SkipHubMetadata) {
		Assert-DockerHubWriteAccess -Repository $repository;
	}

	# Find the latest daemon version if not provided
	if ([String]::IsNullOrEmpty($daemonVersion)) {
		$response = Invoke-WebRequest -Uri "https://www.getmonero.org/downloads/#cli" -UseBasicParsing;
		$match = [Regex]::Match($response.Content, '<h2 id="cli">.+Current Version:(?:</i>)? (\d+\.\d+\.\d+.\d+) - ',  [Text.RegularExpressions.RegexOptions]::Singleline);
		if (-not $match.Success) {
			Write-Error "Daemon version is not detected";
			exit 1;
		}
		$daemonVersion = $match.Groups[1].Value;
		Write-Host "Using daemon version: $daemonVersion";
	}

	# Find the latest pool version if not provided
	if ([String]::IsNullOrEmpty($poolVersion)) {
		$response = Invoke-WebRequest -Uri "https://github.com/SChernykh/p2pool/releases" -UseBasicParsing;
		$match = [Regex]::Match($response.Content, '/releases/tag/v(\d+\.\d+)"');
		if (-not $match.Success) {
			Write-Error "Pool version is not detected";
			exit 1;
		}
		$poolVersion = $match.Groups[1].Value;
		Write-Host "Using pool version: $poolVersion";
	}

	$tag = "${daemonVersion}_$poolVersion";

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
	Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "${image}:latest", "${image}:$tag", "${repository}:$tag") -PassThru -Wait | Out-Null;
	$buildArgs = @("build") + (Get-DockerHubAuthArgs) + @("--platform", ($settings.Build.Platforms -join ","), "-f", "dockerfile", "--manifest", "${imageName}:$tag", "--manifest", "${repository}:$tag", "--build-arg", "DAEMON_VERSION=$daemonVersion", "--build-arg", "P2POOL_VERSION=$poolVersion") + (Get-SquashArgs -Squash $settings.Build.Squash -Tool podman);
	if ($NoCache) {
		$buildArgs += "--no-cache";
	}
	$buildArgs += "build-context";

	Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "${imageName}:$tag", "${image}:$tag", "${image}:latest") -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList (@("manifest", "push") + (Get-DockerHubAuthArgs) + @("${image}:$tag")) -PassThru -Wait | Out-Null;
	$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList (@("manifest", "push") + (Get-DockerHubAuthArgs) + @("${image}:latest")) -PassThru -Wait;

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
}
