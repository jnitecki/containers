# Build defaults for build.ps1. Parameters passed on the command line take precedence over
# these values; -HubToken is deliberately not configurable here.
@{
	# How the image is built and named.
	Build = @{
		Registry = "docker.io"
		Repository = "jnitecki/zephyr"  # Docker Hub <namespace>/<name>, pushed as <Registry>/<Repository>
		ImageName = "zephyr"  # local image/manifest name
		Platforms = @("linux/amd64", "linux/arm64")
		Squash = "mine"  # none | mine (--squash) | all (--squash-all)
		NoCache = $false
		SkipHubMetadata = $false
		HubUsername = ""  # only used with -HubToken; empty = the Repository namespace
	}
	# Versions of the components installed in the image; empty = latest upstream release.
	Versions = @{
		baseVersion = ""  # Zephyr release tag
		cliVersion = ""  # Zephyr CLI asset version
	}
}
