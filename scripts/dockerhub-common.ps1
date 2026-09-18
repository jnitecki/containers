# Shared Docker Hub helpers for the per-container build*.ps1 scripts. Dot-source this file:
#   . "$PSScriptRoot/../../scripts/dockerhub-common.ps1"

# Resolves credentials for $Registry (default docker.io) without ever prompting: checks
# DOCKERHUB_USERNAME/DOCKERHUB_TOKEN first (useful for CI), then the same auth files
# `podman login`/`docker login` already wrote when the image was pushed - so if the push in
# this same script succeeded, this should always find something. Returns $null if nothing is
# found, rather than failing, since the caller treats a missing README upload as non-fatal.
function Get-DockerHubCredential {
	param(
		[Parameter(Mandatory=$false)][String]$Registry = "docker.io"
	)

	if (-not [String]::IsNullOrEmpty($env:DOCKERHUB_USERNAME) -and -not [String]::IsNullOrEmpty($env:DOCKERHUB_TOKEN)) {
		return @{ Username = $env:DOCKERHUB_USERNAME; Password = $env:DOCKERHUB_TOKEN };
	}

	$configPaths = @(
		(Join-Path $HOME ".config/containers/auth.json"),
		(Join-Path $HOME ".docker/config.json")
	);

	foreach ($configPath in $configPaths) {
		if (-not (Test-Path $configPath)) {
			continue;
		}
		$config = Get-Content $configPath -Raw | ConvertFrom-Json;
		if (-not $config.auths) {
			continue;
		}

		$entry = $null;
		foreach ($key in @($Registry, "https://index.docker.io/v1/", "https://$Registry/v1/")) {
			if ($config.auths.PSObject.Properties.Name -contains $key) {
				$entry = $config.auths.$key;
				break;
			}
		}
		if (-not $entry) {
			continue;
		}

		if (-not [String]::IsNullOrEmpty($entry.auth)) {
			$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.auth));
			$parts = $decoded.Split(':', 2);
			return @{ Username = $parts[0]; Password = $parts[1] };
		}

		# No plaintext auth field - this registry's credential lives in an OS credential
		# store/keychain instead (Docker Desktop-style credsStore/credHelpers).
		$helperName = $null;
		if ($config.credHelpers -and $config.credHelpers.PSObject.Properties.Name -contains $Registry) {
			$helperName = $config.credHelpers.$Registry;
		} elseif (-not [String]::IsNullOrEmpty($config.credsStore)) {
			$helperName = $config.credsStore;
		}
		if ($helperName) {
			$helper = "docker-credential-$helperName";
			if (Get-Command $helper -ErrorAction SilentlyContinue) {
				$result = $Registry | & $helper get | ConvertFrom-Json;
				return @{ Username = $result.Username; Password = $result.Secret };
			}
		}
	}

	return $null;
}

# Exchanges stored credentials for a Docker Hub access token via the official
# POST /v2/auth/token endpoint. Never fatal to the caller.
function Get-DockerHubToken {
	param(
		[Parameter(Mandatory=$true)][String]$Username,
		[Parameter(Mandatory=$true)][String]$Password
	)

	$response = Invoke-RestMethod -Uri "https://hub.docker.com/v2/auth/token" -Method Post -ContentType "application/json" -Body (@{ identifier = $Username; secret = $Password } | ConvertTo-Json);
	return $response.access_token;
}

# The full slug list from GET https://hub.docker.com/v2/categories/ (an undocumented but public,
# unauthenticated endpoint), captured 2026-09-18. There is no crypto/blockchain category - a
# container that doesn't genuinely fit one of these should just omit `categories` from its
# hub-metadata.yml rather than forcing a weak match; categories can always be set later through
# the Docker Hub web UI instead.
$script:DockerHubCategorySlugs = @(
	"networking", "security", "languages-and-frameworks", "integration-and-delivery",
	"message-queues", "api-management", "internet-of-things", "machine-learning-and-ai",
	"developer-tools", "data-science", "web-servers", "operating-systems",
	"content-management-system", "databases-and-storage", "monitoring-and-observability",
	"web-analytics"
);

# Parses the restricted YAML subset used by hub-metadata.yml:
#   short_description: "..."
#   categories:
#     - some-slug
# Returns @{ ShortDescription = <string or $null>; Categories = <string[]> }. Missing file or
# missing keys just come back empty - this is a convenience reader, not a validator, so it never
# throws; Publish-DockerHubRepository is what decides what to do with an invalid slug.
function Import-HubMetadata {
	param(
		[Parameter(Mandatory=$true)][String]$Path
	)

	$result = @{ ShortDescription = $null; Categories = @() };
	if (-not (Test-Path $Path)) {
		return $result;
	}

	$inCategories = $false;
	foreach ($line in Get-Content $Path) {
		if ([String]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
			continue;
		}
		if ($line -match '^short_description:\s*(.*)$') {
			$result.ShortDescription = $Matches[1].Trim().Trim('"');
			$inCategories = $false;
			continue;
		}
		if ($line -match '^categories:\s*$') {
			$inCategories = $true;
			continue;
		}
		if ($inCategories -and $line -match '^\s+-\s*(.+)$') {
			$result.Categories += $Matches[1].Trim().Trim('"');
			continue;
		}
		if ($line -match '^\S') {
			$inCategories = $false;
		}
	}

	return $result;
}

# PATCHes a repository's short description and/or full description (from README.md). Never
# fatal to the caller - a build/push that already succeeded shouldn't be treated as failed
# just because this metadata sync couldn't run.
#
# Categories are sent as a SEPARATE, isolated PATCH call, not bundled into the same request as
# full_description/description. Docker Hub's "categories" field is absent from every write
# operation in the official spec (docs.docker.com/reference/api/hub only exposes GET/HEAD on a
# repository) and from every community tool that automates this (e.g.
# peter-evans/dockerhub-description). Other automation has sent it speculatively on the classic
# PATCH /v2/repositories/{namespace}/{repo}/ endpoint alongside description fields, but by their
# own account never confirmed the server actually persists it rather than silently dropping it.
# Keeping it as its own call means that uncertainty can't jeopardize the description/
# full_description update, which IS confirmed working.
#
# Invalid category slugs are warned about and filtered out here (not a ValidateSet on the
# parameter), specifically so a typo in a hand-edited hub-metadata.yml degrades to a warning
# instead of a terminating parameter-binding error that would crash the whole build script after
# the image push already succeeded.
function Publish-DockerHubRepository {
	param(
		[Parameter(Mandatory=$true)][String]$Repository,
		[Parameter(Mandatory=$false)][String]$ReadmePath,
		[Parameter(Mandatory=$false)][ValidateLength(0, 100)][String]$Description,
		[Parameter(Mandatory=$false)][String[]]$Categories
	)

	$body = @{};
	if (-not [String]::IsNullOrEmpty($ReadmePath)) {
		if (Test-Path $ReadmePath) {
			$body.full_description = Get-Content $ReadmePath -Raw;
		} else {
			Write-Warning "README not found at $ReadmePath - skipping full_description update.";
		}
	}
	if (-not [String]::IsNullOrEmpty($Description)) {
		$body.description = $Description;
	}

	$validCategories = @($Categories | Where-Object {
		if ($script:DockerHubCategorySlugs -contains $_) {
			return $true;
		}
		Write-Warning "'$_' is not a known Docker Hub category slug - skipping it. Known slugs: $($script:DockerHubCategorySlugs -join ', ')";
		return $false;
	});

	if ($body.Count -eq 0 -and $validCategories.Count -eq 0) {
		return;
	}

	$credential = Get-DockerHubCredential;
	if (-not $credential) {
		Write-Warning "No Docker Hub credentials found (checked DOCKERHUB_USERNAME/DOCKERHUB_TOKEN, ~/.config/containers/auth.json, ~/.docker/config.json) - skipping Docker Hub metadata update. The credential's password must be a Docker Hub Personal Access Token with Read & Write scope.";
		return;
	}

	try {
		$token = Get-DockerHubToken -Username $credential.Username -Password $credential.Password;
	} catch {
		Write-Warning "Failed to authenticate to Docker Hub for metadata update: $_";
		return;
	}

	if ($body.Count -gt 0) {
		Write-Host "Updating Docker Hub description for $Repository...";
		try {
			Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$Repository" -Method Patch -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body ($body | ConvertTo-Json) | Out-Null;
		} catch {
			Write-Warning "Failed to update Docker Hub description: $_";
		}
	}

	if ($validCategories.Count -gt 0) {
		Write-Host "Updating Docker Hub categories for $Repository...";
		try {
			Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$Repository" -Method Patch -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body (@{ categories = $validCategories } | ConvertTo-Json) | Out-Null;
		} catch {
			Write-Warning "Failed to update Docker Hub categories: $_";
		}
	}
}
