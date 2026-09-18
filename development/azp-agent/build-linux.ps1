#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^[1-9][0-9]*\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$version,
	[Parameter(Mandatory=$false)][switch]$NoCache
);

. "$PSScriptRoot/build-common.ps1";
. "$PSScriptRoot/../../scripts/dockerhub-common.ps1";

Assert-VersionsInSync;
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
$buildArgs = @("build", "--platform", "linux/amd64,linux/arm64", "--squash", "-f", "Dockerfile.linux", "--manifest", "azp-agent:$version", "--manifest", "jnitecki/azp-agent:$version", "--build-arg", "AGENT_VERSION=$version") + (Get-ToolchainBuildArgs -Os Linux);
if ($NoCache) {
	$buildArgs += "--no-cache";
}
$buildArgs += "linux-context";

Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "azp-agent:$version", "docker.io/jnitecki/azp-agent:$version", "docker.io/jnitecki/azp-agent:latest") -PassThru -Wait | Out-Null;
Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/azp-agent:$version") -PassThru -Wait | Out-Null;
$pushResult = Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "push", "docker.io/jnitecki/azp-agent:latest") -PassThru -Wait;

if ($pushResult.ExitCode -eq 0) {
	$hubMetadata = Import-HubMetadata -Path "$PSScriptRoot/hub-metadata.yml";
	Publish-DockerHubRepository -Repository "jnitecki/azp-agent" -ReadmePath "$PSScriptRoot/README.md" -Description $hubMetadata.ShortDescription -Categories $hubMetadata.Categories;
} else {
	Write-Warning "Skipping Docker Hub README upload because the image push failed (exit code $($pushResult.ExitCode)).";
}
