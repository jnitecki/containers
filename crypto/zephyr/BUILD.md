# zephyr — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Multi-arch build (`linux/amd64`, `linux/arm64`).

## Build

```sh
docker build -f dockerfile --build-arg BASE_VERSION=2.3.0 --build-arg CLI_VERSION=2.3.0 -t zephyr build-context
```

### Version pins

Zephyr Protocol releases have occasionally shipped CLI zip assets whose embedded version lags one patch behind the release tag itself (e.g. tag `v2.1.0` shipped `zephyr-cli-linux-v2.1.1.zip`), so the release tag (`BASE_VERSION`, used to build the download URL) and the CLI asset version (`CLI_VERSION`, used in the filename and as the published image tag) are tracked and resolved independently rather than assumed equal.

`build.ps1` resolves both from the GitHub API's latest-release metadata automatically if `-baseVersion`/`-cliVersion` aren't supplied, and passes them through as `--build-arg BASE_VERSION=...`/`--build-arg CLI_VERSION=...`. The Dockerfile has no version defaults: building directly with `docker build`/`podman build` (bypassing the build script) requires `BASE_VERSION` and `CLI_VERSION` as `--build-arg`, and the build fails if either is missing.

## Publish

`build.ps1` builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/zephyr`, tagged with `CLI_VERSION`.

```sh
./build.ps1 -baseVersion 2.3.0 -cliVersion 2.3.0
```

Pass `-NoCache` to force a clean rebuild.

`-Squash none|mine|all` controls layer squashing: `none` keeps every layer, `mine` passes `--squash` (squashes only the layers this build adds; the default), `all` passes `--squash-all` (squashes the base image layers too).

### Settings

[settings.ps1](settings.ps1) holds the defaults `build.ps1` uses, in two parts. `Build` covers how the image is built and named: `Registry` and `Repository` (the image is pushed as `<Registry>/<Repository>`, and `Repository` is also the Docker Hub repository whose metadata is synced), `ImageName` (the local manifest name), `Platforms`, `Squash`, `NoCache`, `SkipHubMetadata` and `HubUsername`. `Versions` holds the component versions (`baseVersion`, `cliVersion`; empty = latest release). Parameters passed on the command line take precedence over these values, including `-NoCache:$false`/`-SkipHubMetadata:$false` over a `$true` setting. `Registry`, `Repository`, `ImageName` and `Platforms` can only be set in the file. `-HubToken` is deliberately not configurable there.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description; no `categories` set here — Docker Hub has no blockchain/crypto category to genuinely fit) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. Before building anything, the script runs `Assert-DockerHubWriteAccess`, which checks that those credentials can actually update the repository and aborts right away if not, instead of failing only after the push. Pass `-SkipHubMetadata` to skip both that check and the sync (e.g. to publish with a token that can push but not edit repository metadata). The sync itself still only warns on failure; it never fails the build. To use a specific token instead of your existing login, pass `-HubToken` as a SecureString, e.g. `-HubToken (Read-Host -AsSecureString "Docker Hub token")`, optionally with `-HubUsername` (defaults to `jnitecki`, the repository namespace). It is then used for everything in that run — base image pulls, the image push, the write check and the metadata sync — through a temporary credential file outside the default location, passed explicitly to each podman/docker command and deleted when the script ends; your normal login is not touched and never sees it. A token that fails to log in aborts the script before anything is built.
