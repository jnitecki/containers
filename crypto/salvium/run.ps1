#!/usr/bin/env pwsh
param(
	[Parameter(Mandatory=$false)][String]$RpcLogin,
	[Parameter(Mandatory=$false)][String]$RpcPassword,
	[Parameter(Mandatory=$false)][String]$RpcTls,
	[Parameter(Mandatory=$false)][String]$DataPath,
	[Parameter(Mandatory=$false)][String]$LogsPath,
	[Parameter(Mandatory=$false)][String]$CertPath,
	[Parameter(Mandatory=$false)][String]$KeyPath,
	[Parameter(Mandatory=$false)][String]$Version = "latest"
);

# Local-only fallback values, used only when neither the matching parameter nor the matching
# RPC_LOGIN/RPC_PASSWORD/... environment variable is set. Do not commit real values here.
$DefaultRpcLogin = "";
$DefaultRpcPassword = "";
$DefaultDataPath = "";
$DefaultLogsPath = "";

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

$RpcLogin = Resolve-Config -Name "RpcLogin" -ParamValue $RpcLogin -EnvName "RPC_LOGIN" -DefaultValue $DefaultRpcLogin;
$RpcPassword = Resolve-Config -Name "RpcPassword" -ParamValue $RpcPassword -EnvName "RPC_PASSWORD" -DefaultValue $DefaultRpcPassword;
$DataPath = Resolve-Config -Name "DataPath" -ParamValue $DataPath -EnvName "SALVIUM_DATA_PATH" -DefaultValue $DefaultDataPath;
$LogsPath = Resolve-Config -Name "LogsPath" -ParamValue $LogsPath -EnvName "SALVIUM_LOGS_PATH" -DefaultValue $DefaultLogsPath;

# RPC_TLS (and its cert/key paths) is optional - only wired up when a name is supplied via
# -RpcTls or the RPC_TLS environment variable, since most local/dev runs skip TLS entirely.
if ([String]::IsNullOrEmpty($RpcTls)) {
	$RpcTls = [Environment]::GetEnvironmentVariable("RPC_TLS");
}
if (-not [String]::IsNullOrEmpty($RpcTls)) {
	$CertPath = Resolve-Config -Name "CertPath" -ParamValue $CertPath -EnvName "SALVIUM_CERT_PATH" -DefaultValue "";
	$KeyPath = Resolve-Config -Name "KeyPath" -ParamValue $KeyPath -EnvName "SALVIUM_KEY_PATH" -DefaultValue "";
}

$Image = "docker.io/jnitecki/salvium:$Version";

Write-Host "Pulling $Image using $tool...";
& $tool pull $Image;

$existing = & $tool ps -a --format "{{.Names}}" | Where-Object { $_ -eq 'salvium' };
if ($existing) {
	Write-Host "Stopping and removing existing container salvium...";
	& $tool stop salvium | Out-Null;
	& $tool rm salvium | Out-Null;
}

$runArgs = @("run", "-d", "--restart", "unless-stopped", "--name", "salvium");
$runArgs += @("-e", "RPC_LOGIN=$RpcLogin", "-e", "RPC_PASSWORD=$RpcPassword");
$runArgs += @("-v", "${DataPath}:/salvium-data", "-v", "${LogsPath}:/logs");
if (-not [String]::IsNullOrEmpty($RpcTls)) {
	$runArgs += @("-e", "RPC_TLS=$RpcTls");
	$runArgs += @("-v", "${CertPath}:/etc/ssl/certs/$RpcTls.cer", "-v", "${KeyPath}:/etc/ssl/private/$RpcTls.key");
}

Write-Host "Starting salvium...";
& $tool @runArgs $Image;
