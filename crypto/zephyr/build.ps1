#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$baseVersion,
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$cliVersion,
	[Parameter(Mandatory=$false)][switch]$NoCache
);

. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";

# Zephyr Protocol releases have occasionally shipped CLI zip assets whose embedded version lags
# one patch behind the release tag itself (e.g. tag v2.1.0 shipped zephyr-cli-linux-v2.1.1.zip),
# so the release tag (BASE_VERSION, used to build the download URL) and the CLI asset version
# (CLI_VERSION, used in the filename and as the published image tag) are resolved independently
# from the GitHub API rather than assumed equal.
if ([String]::IsNullOrEmpty($baseVersion) -or [String]::IsNullOrEmpty($cliVersion)) {
	$release = Invoke-RestMethod -Uri "https://api.github.com/repos/ZephyrProtocol/zephyr/releases/latest" -UseBasicParsing;
	if ([String]::IsNullOrEmpty($baseVersion)) {
		$baseVersion = $release.tag_name -replace '^v', '';
		Write-Host "Using base version: $baseVersion";
	}
	if ([String]::IsNullOrEmpty($cliVersion)) {
		$asset = $release.assets | Where-Object { $_.name -match '^zephyr-cli-linux-v(.+)\.zip$' } | Select-Object -First 1;
		if (-not $asset) {
			Write-Error "CLI version is not detected";
			exit 1;
		}
		$cliVersion = [Regex]::Match($asset.name, '^zephyr-cli-linux-v(.+)\.zip$').Groups[1].Value;
		Write-Host "Using CLI version: $cliVersion";
	}
}

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
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "docker.io/jnitecki/zephyr:latest", "docker.io/jnitecki/zephyr:$cliVersion", "jnitecki/zephyr:$cliVersion") -PassThru -Wait | Out-Null;
$buildArgs = @("build", "--platform", "linux/amd64,linux/arm64", "--squash", "-f", "dockerfile", "--manifest", "zephyr:$cliVersion", "--manifest", "jnitecki/zephyr:$cliVersion", "--build-arg", "BASE_VERSION=$baseVersion", "--build-arg", "CLI_VERSION=$cliVersion");
if ($NoCache) {
	$buildArgs += "--no-cache";
}
$buildArgs += "build-context";

Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "zephyr:$cliVersion", "docker.io/jnitecki/zephyr:$cliVersion", "docker.io/jnitecki/zephyr:latest") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/zephyr:$cliVersion") -PassThru -Wait | Out-Null;
$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/zephyr:latest") -PassThru -Wait;

if ($pushResult.ExitCode -eq 0) {
	$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
	Publish-DockerHubRepository -Repository "jnitecki/zephyr" -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
} else {
	Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
}
