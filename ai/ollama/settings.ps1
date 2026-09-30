# Build defaults for build.ps1. Parameters passed on the command line take precedence over
# these values; -HubToken is deliberately not configurable here.
@{
	# How the image is built and named.
	Build = @{
		Registry = "docker.io"
		Repository = "jnitecki/ollama"  # Docker Hub <namespace>/<name>, pushed as <Registry>/<Repository>
		ImageName = "ollama"  # local image/manifest name
		Platforms = @("linux/arm64")
		Squash = "mine"  # none | mine (--squash) | all (--squash-all)
		NoCache = $false
		SkipHubMetadata = $false
		HubUsername = ""  # only used with -HubToken; empty = the Repository namespace
	}
	# Versions of the components installed in the image; empty = latest upstream release.
	Versions = @{
		ollamaVersion = ""  # Ollama release
	}
}
