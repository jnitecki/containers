# Build defaults for build-linux.ps1 and build-windows.ps1. Parameters passed on the command line
# take precedence over these values; -HubToken is deliberately not configurable here.
@{
	# How the image is built and named.
	Build = @{
		Registry = "docker.io"
		Repository = "jnitecki/azp-agent"  # Docker Hub <namespace>/<name>, pushed as <Registry>/<Repository>
		ImageName = "azp-agent"  # local image/manifest name
		NoCache = $false
		SkipHubMetadata = $false
		HubUsername = ""  # only used with -HubToken; empty = the Repository namespace
		# Per-OS settings, merged over the ones above by the matching build script.
		Linux = @{
			Platforms = @("linux/amd64", "linux/arm64")
			Squash = "mine"  # none | mine (--squash) | all (--squash-all)
		}
		Windows = @{
			Squash = "none"  # none | mine | all; docker has only --squash (daemon experimental mode), used for mine and all
		}
	}
	# Versions of the components installed in the image. The dockerfiles have no defaults: every
	# value here is passed as a --build-arg (see build-common.ps1 for the key -> ARG mapping).
	Versions = @{
		version = ""  # Azure Pipelines agent release; empty = latest upstream
		# Toolchains: empty = not installed; see BUILD.md for which ones are Linux-only.
		installPodman = "true"  # Linux
		installBuildEssential = "true"  # Linux
		installPythonDev = "true"  # Linux; requires installBuildEssential
		installJava = "17"  # OpenJDK version
		installAndroid = "37.0.0"  # Android build-tools version; requires installJava
		androidCmdlineToolsVersion = "15859902"  # required when installAndroid is set
		installAndroidEmulator = "36"  # Linux amd64; API level or "true"; requires installAndroid
		installPowershell = "7.6.6"  # always installed on Windows, so required there
		installDotnet = "10.0"  # .NET SDK channel
		installNode = "24.21.0"
	}
}
