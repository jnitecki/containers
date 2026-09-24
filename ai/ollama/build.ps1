#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$ollamaVersion,
	[Parameter(Mandatory=$false)][switch]$NoCache
);

. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";

# Find the latest Ollama version if not provided
if ([String]::IsNullOrEmpty($ollamaVersion)) {
	$release = Invoke-RestMethod -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -UseBasicParsing;
	$match = [Regex]::Match($release.tag_name, '^v(\d+\.\d+\.\d+)$');
	if (-not $match.Success) {
		Write-Error "Ollama version is not detected";
		exit 1;
	}
	$ollamaVersion = $match.Groups[1].Value;
	Write-Host "Using Ollama version: $ollamaVersion";
}

# The dustynv/ollama base image targets NVIDIA Jetson (L4T r36.x), which is arm64-only, so this is a
# single-platform build rather than the amd64/arm64 pair used by the other containers.
# Register QEMU binfmt handlers so Podman can build for the non-native platform (i.e. on amd64 hosts).
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
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "docker.io/jnitecki/ollama:latest", "docker.io/jnitecki/ollama:$ollamaVersion", "jnitecki/ollama:$ollamaVersion") -PassThru -Wait | Out-Null;
$buildArgs = @("build", "--platform", "linux/arm64", "--network", "host", "--squash", "-f", "$PSScriptRoot/dockerfile", "--manifest", "ollama:$ollamaVersion", "--manifest", "jnitecki/ollama:$ollamaVersion", "--build-arg", "OLLAMA_VERSION=$ollamaVersion");
if ($NoCache) {
	$buildArgs += "--no-cache";
}
$buildArgs += "$PSScriptRoot/build-context";

Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "ollama:$ollamaVersion", "docker.io/jnitecki/ollama:$ollamaVersion", "docker.io/jnitecki/ollama:latest") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/ollama:$ollamaVersion") -PassThru -Wait | Out-Null;
$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/ollama:latest") -PassThru -Wait;

if ($pushResult.ExitCode -eq 0) {
	$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
	Publish-DockerHubRepository -Repository "jnitecki/ollama" -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
} else {
	Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
}
