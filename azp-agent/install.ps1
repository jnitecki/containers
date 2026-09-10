#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^[1-9][0-9]*\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$version,
	[Parameter(Mandatory=$false)][switch]$NoCache
);


# Find the latest version if not provided
if ([String]::IsNullOrEmpty($version)) {
	$response = Invoke-WebRequest -Uri "https://github.com/microsoft/azure-pipelines-agent/releases/latest" -UseBasicParsing;
	$match = [Regex]::Match($response.Content, '/microsoft/azure-pipelines-agent/releases/tag/v(\d+\.\d+\.\d+)"');
	if (-not $match.Success) {
		Write-Error "Release version is not detected";
		exit 1;
	}
	$version = $match.Groups[1].Value;
	Write-Host "Using version: $version";
}

Start-Process -NoNewWindow -FilePath podman -ArgumentList ("machine", "ssh", "--", "sudo", "podman", "run", "--rm", "--privileged", "docker.io/multiarch/qemu-user-static", "--reset", "-p", "yes") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "docker.io/jnitecki/azp-agent:latest", "docker.io/jnitecki/azp-agent:$version", "jnitecki/azp-agent:$version") -PassThru -Wait | Out-Null;
$buildArgs = @("build", "--platform", "linux/amd64,linux/arm64", "--squash", "-f", "dockerfile", "--manifest", "azp-agent:$version", "--manifest", "jnitecki/azp-agent:$version", "--build-arg", "AGENT_VERSION=$version", "--build-arg", "TARGETARCH=amd64");
if ($NoCache) {
	$buildArgs += "--no-cache";
}
$buildArgs += "build-context";

Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "azp-agent:$version", "docker.io/jnitecki/azp-agent:$version", "docker.io/jnitecki/azp-agent:latest") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/azp-agent:$version") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/azp-agent:latest") -PassThru -Wait | Out-Null;
