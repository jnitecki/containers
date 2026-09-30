# Shared build-settings helpers for the per-container build*.ps1 scripts. Dot-source this file:
#   . "$PSScriptRoot/../../scripts/build-settings.ps1"

# Merges one part of settings.ps1: its top-level values, then (with -Section) that nested
# hashtable, e.g. Linux = @{...}; other nested hashtables are dropped.
function Merge-BuildSettingsPart {
	param(
		[Parameter(Mandatory=$true)][Hashtable]$Part,
		[Parameter(Mandatory=$false)][String]$Section
	)

	$merged = @{};
	foreach ($key in $Part.Keys) {
		if ($Part[$key] -isnot [Hashtable]) {
			$merged[$key] = $Part[$key];
		}
	}
	if (-not [String]::IsNullOrEmpty($Section) -and $Part[$Section] -is [Hashtable]) {
		foreach ($key in $Part[$Section].Keys) {
			$merged[$key] = $Part[$Section][$key];
		}
	}
	return $merged;
}

# Loads a container's settings.ps1, a script returning @{ Build = @{...}; Versions = @{...} }:
# Build holds how the image is built and named, Versions the versions of the components installed
# in it. Each part is merged with -Section (see Merge-BuildSettingsPart), then every key that was
# also passed as a parameter of the calling script takes the command-line value, so keys are named
# after the matching parameters and must be unique across both parts. Returns the merged
# @{ Build; Versions }. Invalid or incomplete settings abort the build (exit 1).
function Import-BuildSettings {
	param(
		[Parameter(Mandatory=$true)][String]$Path,
		[Parameter(Mandatory=$true)][Hashtable]$BoundParameters,
		[Parameter(Mandatory=$false)][String]$Section
	)

	if (-not (Test-Path $Path)) {
		Write-Error "Build settings file not found: $Path";
		exit 1;
	}
	$fileSettings = & $Path;
	if ($fileSettings -isnot [Hashtable] -or $fileSettings.Build -isnot [Hashtable] -or $fileSettings.Versions -isnot [Hashtable]) {
		Write-Error "Build settings file must return a hashtable with Build and Versions hashtables: $Path";
		exit 1;
	}

	$settings = @{
		Build = Merge-BuildSettingsPart -Part $fileSettings.Build -Section $Section;
		Versions = Merge-BuildSettingsPart -Part $fileSettings.Versions -Section $Section;
	};
	$duplicates = @($settings.Build.Keys | Where-Object { $settings.Versions.ContainsKey($_) });
	if ($duplicates) {
		Write-Error "Build settings in $Path define these keys in both Build and Versions: $($duplicates -join ', ')";
		exit 1;
	}

	foreach ($key in $BoundParameters.Keys) {
		$value = $BoundParameters[$key];
		if ($value -is [System.Management.Automation.SwitchParameter]) {
			$value = $value.IsPresent;
		}
		foreach ($part in @($settings.Build, $settings.Versions)) {
			if ($part.ContainsKey($key)) {
				$part[$key] = $value;
			}
		}
	}

	$missing = @("Registry", "Repository", "ImageName", "Squash") | Where-Object { [String]::IsNullOrEmpty([String]$settings.Build[$_]) };
	if ($missing) {
		Write-Error "Build settings in $Path are missing Build keys: $($missing -join ', ')";
		exit 1;
	}
	if (@("none", "mine", "all") -notcontains $settings.Build.Squash) {
		Write-Error "Build setting Squash must be none, mine or all, got '$($settings.Build.Squash)' ($Path)";
		exit 1;
	}

	return $settings;
}

# Translates a Squash setting into build flags. Podman: mine = --squash (only the layers this
# build adds), all = --squash-all (base image layers too). Docker has only --squash, which needs
# the daemon's experimental mode and always squashes just this build's layers, so "all" falls
# back to it with a warning.
function Get-SquashArgs {
	param(
		[Parameter(Mandatory=$true)][ValidateSet("none", "mine", "all")][String]$Squash,
		[Parameter(Mandatory=$true)][ValidateSet("podman", "docker")][String]$Tool
	)

	switch ($Squash) {
		"none" { return @(); }
		"mine" { return @("--squash"); }
		"all" {
			if ($Tool -eq "podman") {
				return @("--squash-all");
			}
			Write-Warning "docker has no squash-all; Squash 'all' is built with --squash (this build's layers only).";
			return @("--squash");
		}
	}
}
