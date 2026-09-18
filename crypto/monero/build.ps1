#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)\.([1-9][0-9]*|0)$")][String]$daemonVersion,
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+$")][String]$poolVersion,
	[Parameter(Mandatory=$false)][switch]$NoCache
);

. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";

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
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "docker.io/jnitecki/monero:latest", "docker.io/jnitecki/monero:$tag", "jnitecki/monero:$tag") -PassThru -Wait | Out-Null;
$buildArgs = @("build", "--platform", "linux/amd64,linux/arm64", "--squash", "-f", "dockerfile", "--manifest", "monero:$tag", "--manifest", "jnitecki/monero:$tag", "--build-arg", "DAEMON_VERSION=$daemonVersion", "--build-arg", "P2POOL_VERSION=$poolVersion");
if ($NoCache) {
	$buildArgs += "--no-cache";
}
$buildArgs += "build-context";

Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "monero:$tag", "docker.io/jnitecki/monero:$tag", "docker.io/jnitecki/monero:latest") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/monero:$tag") -PassThru -Wait | Out-Null;
$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/monero:latest") -PassThru -Wait;

if ($pushResult.ExitCode -eq 0) {
	$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
	Publish-DockerHubRepository -Repository "jnitecki/monero" -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
} else {
	Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
}