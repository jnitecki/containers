#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][String]$AzpUrl,
	[Parameter(Mandatory=$false)][String]$AzpToken,
	[Parameter(Mandatory=$false)][String]$AzpPool,
	[Parameter(Mandatory=$false)][ValidateSet("Linux", "Windows")][String]$Os = "Linux",
	[Parameter(Mandatory=$false)][String]$Version = "latest",
	[Parameter(Mandatory=$false, Position=0)][ValidateRange(1, 10)][int]$InstanceCount
);

# Local-only fallback values, used only when neither -AzpUrl/-AzpToken/-AzpPool nor the matching
# AZP_URL/AZP_TOKEN/AZP_POOL environment variable is set. Do not commit real values here.
$DefaultAzpUrl = "";
$DefaultAzpToken = "";
$DefaultAzpPool = "";

function Resolve-Config {
	param(
		[Parameter(Mandatory=$true)][String]$Name,
		[Parameter(Mandatory=$true)][AllowEmptyString()][String]$ParamValue,
		[Parameter(Mandatory=$true)][String]$EnvName,
		[Parameter(Mandatory=$true)][AllowEmptyString()][String]$DefaultValue
	)

	if (-not [String]::IsNullOrEmpty($ParamValue)) {
		return $ParamValue;
	}
	$envValue = [Environment]::GetEnvironmentVariable($EnvName);
	if (-not [String]::IsNullOrEmpty($envValue)) {
		return $envValue;
	}
	if (-not [String]::IsNullOrEmpty($DefaultValue)) {
		return $DefaultValue;
	}

	Write-Error ("Missing {0} - provide -{0}, set the {1} environment variable, or fill in `$Default{0} in this script." -f $Name, $EnvName);
	exit 1;
}

function Resolve-ContainerTool {
	if (Get-Command docker -ErrorAction SilentlyContinue) {
		return "docker";
	}
	if (Get-Command podman -ErrorAction SilentlyContinue) {
		return "podman";
	}
	Write-Error "Neither docker nor podman was found on PATH.";
	exit 1;
}

$tool = Resolve-ContainerTool;

$AzpUrl = Resolve-Config -Name "AzpUrl" -ParamValue $AzpUrl -EnvName "AZP_URL" -DefaultValue $DefaultAzpUrl;
$AzpToken = Resolve-Config -Name "AzpToken" -ParamValue $AzpToken -EnvName "AZP_TOKEN" -DefaultValue $DefaultAzpToken;
$AzpPool = Resolve-Config -Name "AzpPool" -ParamValue $AzpPool -EnvName "AZP_POOL" -DefaultValue $DefaultAzpPool;

# Windows publish tags are irregular: versioned tags get a "-windows" suffix (e.g. "4.248.0-windows"),
# but the default tag is "windows-latest" rather than "latest-windows" - see build-windows.ps1/README.md.
if ($Os -eq "Windows") {
	$tag = if ($Version -eq "latest") { "windows-latest" } else { "$Version-windows" };
} else {
	$tag = $Version;
}
$Image = "docker.io/jnitecki/azp-agent:$tag";

Write-Host "Pulling $Image using $tool...";
& $tool pull $Image;

$existing = & $tool ps -a --format "{{.Names}}" | Where-Object { $_ -match '^azp-agent(-\d+)?$' };
foreach ($name in $existing) {
	Write-Host "Stopping and removing existing container $name...";
	& $tool stop $name | Out-Null;
	& $tool rm $name | Out-Null;
}

$hostName = ([System.Net.Dns]::GetHostName()).ToUpper();

$runArgs = @("run", "-d", "--restart", "unless-stopped");
if ($Os -eq "Linux") {
	# Windows containers have no equivalent to these Linux cgroup/capability flags.
	$runArgs += @("--privileged");
}
$runArgs += @("-e", "AZP_URL=$AzpUrl", "-e", "AZP_TOKEN=$AzpToken", "-e", "AZP_POOL=$AzpPool");

if ($PSBoundParameters.ContainsKey('InstanceCount')) {
	for ($i = 1; $i -le $InstanceCount; $i++) {
		$suffix = "{0:D2}" -f $i;
		$name = "azp-agent-$suffix";
		Write-Host "Starting $name...";
		& $tool @runArgs -e "AZP_AGENT_NAME=$hostName-$suffix" --name $name $Image;
	}
} else {
	Write-Host "Starting azp-agent...";
	& $tool @runArgs -e "AZP_AGENT_NAME=$hostName" --name azp-agent $Image;
}
