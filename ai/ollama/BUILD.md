# ollama — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Single-arch build (`linux/arm64`) — the `dustynv/ollama:r36.4.0` base image targets NVIDIA Jetson (JetPack 6, L4T r36.x) and is published for `arm64` only.

## Build

```sh
docker build --network host --platform linux/arm64 -f dockerfile --build-arg OLLAMA_VERSION=0.24.0 -t ollama build-context
```

`build-context/` is intentionally empty (kept in git via `.gitkeep`) — the Dockerfile doesn't copy any files in; it installs Ollama over the base image with the official `install.sh`. `zstd` is installed just for that step (recent Ollama releases ship as `.tar.zst` archives) and purged again in the same `RUN` layer, so it doesn't end up in the final image.

### Version pins

`build.ps1` resolves the latest Ollama release version from the GitHub API automatically if `-ollamaVersion` isn't supplied, and passes it through as `--build-arg OLLAMA_VERSION=...`. The Dockerfile has no version defaults: building directly with `docker build`/`podman build` (bypassing the build script) requires `OLLAMA_VERSION` as `--build-arg`, and the build fails if it is missing.

The base image tag (`r36.4.0`) is pinned in the Dockerfile and is not resolved by the build script.

## Publish

`build.ps1` builds a `linux/arm64` manifest with Podman (with `--network host`), using QEMU (`tonistiigi/binfmt`) to cross-build when run on a non-arm64 host, and pushes it to `docker.io/jnitecki/ollama`, tagged with `OLLAMA_VERSION` and `latest`.

```sh
./build.ps1 -ollamaVersion 0.34.3
```

Pass `-NoCache` to force a clean rebuild.

`-Squash none|mine|all` controls layer squashing: `none` keeps every layer, `mine` passes `--squash` (squashes only the layers this build adds; the default), `all` passes `--squash-all` (squashes the base image layers too).

### Settings

[settings.ps1](settings.ps1) holds the defaults `build.ps1` uses, in two parts. `Build` covers how the image is built and named: `Registry` and `Repository` (the image is pushed as `<Registry>/<Repository>`, and `Repository` is also the Docker Hub repository whose metadata is synced), `ImageName` (the local manifest name), `Platforms`, `Squash`, `NoCache`, `SkipHubMetadata` and `HubUsername`. `Versions` holds the component versions (`ollamaVersion`; empty = latest release). Parameters passed on the command line take precedence over these values, including `-NoCache:$false`/`-SkipHubMetadata:$false` over a `$true` setting. `Registry`, `Repository`, `ImageName` and `Platforms` can only be set in the file. `-HubToken` is deliberately not configurable there.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description and the `machine-learning-and-ai` category) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. Before building anything, the script runs `Assert-DockerHubWriteAccess`, which checks that those credentials can actually update the repository and aborts right away if not, instead of failing only after the push. Pass `-SkipHubMetadata` to skip both that check and the sync (e.g. to publish with a token that can push but not edit repository metadata). The sync itself still only warns on failure; it never fails the build. To use a specific token instead of your existing login, pass `-HubToken` as a SecureString, e.g. `-HubToken (Read-Host -AsSecureString "Docker Hub token")`, optionally with `-HubUsername` (defaults to `jnitecki`, the repository namespace). It is then used for everything in that run — base image pulls, the image push, the write check and the metadata sync — through a temporary credential file outside the default location, passed explicitly to each podman/docker command and deleted when the script ends; your normal login is not touched and never sees it. A token that fails to log in aborts the script before anything is built.
