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

	if ($script:DockerHubCredentialOverride) {
		return $script:DockerHubCredentialOverride;
	}

	if (-not [String]::IsNullOrEmpty($env:DOCKERHUB_USERNAME) -and -not [String]::IsNullOrEmpty($env:DOCKERHUB_TOKEN)) {
		return @{ Username = $env:DOCKERHUB_USERNAME; Password = $env:DOCKERHUB_TOKEN };
	}

	# Podman's own lookup order: REGISTRY_AUTH_FILE, then ${XDG_RUNTIME_DIR}/containers/auth.json
	# (where rootless `podman login` writes on Linux), then ~/.config/containers/auth.json (macOS and
	# Windows, where XDG_RUNTIME_DIR is normally unset); Docker's ~/.docker/config.json last.
	$configPaths = @();
	if (-not [String]::IsNullOrEmpty($env:REGISTRY_AUTH_FILE)) {
		$configPaths += $env:REGISTRY_AUTH_FILE;
	}
	if (-not [String]::IsNullOrEmpty($env:XDG_RUNTIME_DIR)) {
		$configPaths += (Join-Path $env:XDG_RUNTIME_DIR "containers/auth.json");
	}
	$configPaths += @(
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

# Set by Enter-DockerHubSession when a build*.ps1 is given -HubToken; Get-DockerHubCredential
# prefers it over every other credential source.
$script:DockerHubCredentialOverride = $null;
$script:DockerHubSessionState = $null;

# Prepares an explicitly supplied token for every Docker Hub operation of a build*.ps1 run -
# pulls and pushes by podman/docker as well as the Docker Hub API calls - instead of whatever
# is already logged in. The container tool is logged in (token via --password-stdin, never as a
# process argument) into a throwaway credential file in the temp directory, which no default
# lookup ever reads: nothing is exported via REGISTRY_AUTH_FILE/DOCKER_CONFIG, so only the
# commands given Get-DockerHubAuthArgs use it, and the user's normal podman/docker login is
# left untouched. The login also validates the token, so a bad one aborts before anything is
# built. No-op without -Token. Must be paired with Exit-DockerHubSession in a finally block,
# which also runs on `exit`.
function Enter-DockerHubSession {
	param(
		[Parameter(Mandatory=$true)][String]$Repository,
		[Parameter(Mandatory=$true)][ValidateSet("podman", "docker")][String]$Tool,
		[Parameter(Mandatory=$false)][String]$Username,
		[Parameter(Mandatory=$false)][SecureString]$Token
	)

	if (-not $Token) {
		return;
	}
	if ([String]::IsNullOrEmpty($Username)) {
		$Username = $Repository.Split('/')[0];
	}
	$plainToken = [System.Net.NetworkCredential]::new('', $Token).Password;

	$authDir = Join-Path ([System.IO.Path]::GetTempPath()) "dockerhub-auth-$([Guid]::NewGuid().ToString('N'))";
	New-Item -ItemType Directory -Path $authDir | Out-Null;
	if (-not $IsWindows) {
		chmod 700 $authDir;
	}
	# podman takes a credential file per command (--authfile, after the subcommand); docker has no
	# such flag, only a per-command config directory (--config, before the subcommand).
	if ($Tool -eq "podman") {
		$authArgs = @("--authfile", (Join-Path $authDir "auth.json"));
	} else {
		$authArgs = @("--config", $authDir);
	}
	$script:DockerHubSessionState = @{ AuthDir = $authDir; Tool = $Tool; AuthArgs = $authArgs };

	Write-Host "Logging $Tool in to docker.io as '$Username' with the supplied token (for this run only)...";
	if ($Tool -eq "podman") {
		$plainToken | & podman login @authArgs --username $Username --password-stdin docker.io;
	} else {
		$plainToken | & docker @authArgs login --username $Username --password-stdin docker.io;
	}
	if ($LASTEXITCODE -ne 0) {
		Write-Error "$Tool login to docker.io as '$Username' failed with the supplied -HubToken.";
		exit 1;
	}

	$script:DockerHubCredentialOverride = @{ Username = $Username; Password = $plainToken };
}

# Arguments that point one podman/docker invocation at the -HubToken credential file, or an empty
# list without -HubToken (so the invocation falls back to the normal login). Add them to every
# command that contacts the registry: for podman after the subcommand (build, push, manifest push,
# pull), for docker before it. Paths are pre-quoted when needed, since Start-Process joins
# -ArgumentList with plain spaces.
function Get-DockerHubAuthArgs {
	if (-not $script:DockerHubSessionState) {
		return @();
	}
	return @($script:DockerHubSessionState.AuthArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } });
}

# Undoes Enter-DockerHubSession: deletes the throwaway credential file and forgets the token.
# Safe to call when no session was entered.
function Exit-DockerHubSession {
	$script:DockerHubCredentialOverride = $null;
	if (-not $script:DockerHubSessionState) {
		return;
	}
	Remove-Item -Path $script:DockerHubSessionState.AuthDir -Recurse -Force -ErrorAction SilentlyContinue;
	$script:DockerHubSessionState = $null;
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

# Fails fast - before anything is built or pushed - if the metadata sync that Publish-DockerHubRepository
# runs at the end of a build*.ps1 would be refused. Token scopes can't be read back reliably, so this
# probes the real permission instead: it re-PATCHes the repository's current short description with
# that same value, which only succeeds with write access and leaves the repository unchanged. A
# repository that doesn't exist yet (first publish, created by the push) can't be probed, so that
# case only warns and lets the build proceed. Callers skip this together with the final sync via
# their -SkipHubMetadata switch.
function Assert-DockerHubWriteAccess {
	param(
		[Parameter(Mandatory=$true)][String]$Repository
	)

	$skipHint = "Fix the credential and rerun, or pass -SkipHubMetadata to build and push without syncing README.md/hub-metadata.yml.";

	$credential = Get-DockerHubCredential;
	if (-not $credential) {
		Write-Error "No Docker Hub credentials found (checked DOCKERHUB_USERNAME/DOCKERHUB_TOKEN, REGISTRY_AUTH_FILE, `$XDG_RUNTIME_DIR/containers/auth.json, ~/.config/containers/auth.json, ~/.docker/config.json). Run 'podman login docker.io', or pass -HubToken, with a Personal Access Token that has Read & Write scope. $skipHint";
		exit 1;
	}

	try {
		$token = Get-DockerHubToken -Username $credential.Username -Password $credential.Password;
	} catch {
		Write-Error "Failed to authenticate to Docker Hub as '$($credential.Username)': $_ $skipHint";
		exit 1;
	}

	$uri = "https://hub.docker.com/v2/repositories/$Repository";
	$headers = @{ Authorization = "Bearer $token" };
	try {
		$repositoryInfo = Invoke-RestMethod -Uri $uri -Headers $headers;
	} catch {
		if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
			Write-Warning "Docker Hub repository $Repository doesn't exist yet - write access for the metadata sync can't be checked before the first push.";
			return;
		}
		Write-Error "Failed to read Docker Hub repository $Repository`: $_ $skipHint";
		exit 1;
	}

	try {
		Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -ContentType "application/json" -Body (@{ description = [String]$repositoryInfo.description } | ConvertTo-Json) | Out-Null;
	} catch {
		Write-Error "Docker Hub credential '$($credential.Username)' can't update $Repository (the metadata sync would fail after the push): $_ The token must be a Personal Access Token with Read & Write scope. $skipHint";
		exit 1;
	}

	Write-Host "Docker Hub write access to $Repository confirmed.";
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
		Write-Warning "No Docker Hub credentials found (checked DOCKERHUB_USERNAME/DOCKERHUB_TOKEN, REGISTRY_AUTH_FILE, `$XDG_RUNTIME_DIR/containers/auth.json, ~/.config/containers/auth.json, ~/.docker/config.json) - skipping Docker Hub metadata update. The credential's password must be a Docker Hub Personal Access Token with Read & Write scope.";
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
