#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$baseVersion,
	[Parameter(Mandatory=$false)][ValidatePattern("^(0|[1-9][0-9]*)\.([1-9][0-9]*|0)+\.([1-9][0-9]*|0)$")][String]$cliVersion,
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
if ($settings.Versions.baseVersion) { $baseVersion = $settings.Versions.baseVersion; }
if ($settings.Versions.cliVersion) { $cliVersion = $settings.Versions.cliVersion; }
$NoCache = [bool]$settings.Build.NoCache;
$SkipHubMetadata = [bool]$settings.Build.SkipHubMetadata;
$HubUsername = $settings.Build.HubUsername;
$repository = $settings.Build.Repository;
$image = "$($settings.Build.Registry)/$($settings.Build.Repository)";
$imageName = $settings.Build.ImageName;

# With -HubToken, every Docker Hub operation below (pulls, pushes, metadata sync) uses that token
# instead of the existing login; Exit-DockerHubSession undoes it even when the script exits early.
# The build runs from the script's own directory, so the relative dockerfile/context paths below work
# wherever the script is started from; Pop-Location restores the caller's location, also on exit.
# Relative rather than $PSScriptRoot-based paths also keep Start-Process, which joins -ArgumentList
# with plain spaces, safe when the repository sits under a path containing spaces.
Push-Location -LiteralPath $PSScriptRoot;
try {
	Enter-DockerHubSession -Repository $repository -Tool podman -Username $HubUsername -Token $HubToken;

	# Check up front that the Docker Hub metadata sync at the end would be allowed, rather than
	# finding out only after the image has been built and pushed.
	if (-not $SkipHubMetadata) {
		Assert-DockerHubWriteAccess -Repository $repository;
	}

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
	Start-Process -noNewWindow -filePath podman -ArgumentList ("manifest", "rm", "-i", "${image}:latest", "${image}:$cliVersion", "${repository}:$cliVersion") -PassThru -Wait | Out-Null;
	$buildArgs = @("build") + (Get-DockerHubAuthArgs) + @("--platform", ($settings.Build.Platforms -join ","), "-f", "dockerfile", "--manifest", "${imageName}:$cliVersion", "--manifest", "${repository}:$cliVersion", "--build-arg", "BASE_VERSION=$baseVersion", "--build-arg", "CLI_VERSION=$cliVersion") + (Get-SquashArgs -Squash $settings.Build.Squash -Tool podman);
	if ($NoCache) {
		$buildArgs += "--no-cache";
	}
	$buildArgs += "build-context";

	Start-Process -noNewWindow -filePath podman -ArgumentList $buildArgs -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList ("tag", "${imageName}:$cliVersion", "${image}:$cliVersion", "${image}:latest") -PassThru -Wait | Out-Null;
	Start-Process -noNewWindow -filePath podman -ArgumentList (@("manifest", "push") + (Get-DockerHubAuthArgs) + @("${image}:$cliVersion")) -PassThru -Wait | Out-Null;
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
	Pop-Location;
}
