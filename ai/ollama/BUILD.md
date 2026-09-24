# ollama — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Single-arch build (`linux/arm64`) — the `dustynv/ollama:r36.4.0` base image targets NVIDIA Jetson (JetPack 6, L4T r36.x) and is published for `arm64` only.

## Build

```sh
docker build --network host --platform linux/arm64 -f dockerfile -t ollama build-context
```

`build-context/` is intentionally empty (kept in git via `.gitkeep`) — the Dockerfile doesn't copy any files in; it installs Ollama over the base image with the official `install.sh`. `zstd` is installed just for that step (recent Ollama releases ship as `.tar.zst` archives) and purged again in the same `RUN` layer, so it doesn't end up in the final image.

### Version pins

`build.ps1` resolves the latest Ollama release version from the GitHub API automatically if `-ollamaVersion` isn't supplied, and passes it through as `--build-arg OLLAMA_VERSION=...`. Building directly with `docker build`/`podman build` (bypassing the build script) falls back to the Dockerfile's own `ARG OLLAMA_VERSION=<default>` value.

The base image tag (`r36.4.0`) is pinned in the Dockerfile and is not resolved by the build script.

## Publish

`build.ps1` builds a `linux/arm64` manifest with Podman (with `--network host`), using QEMU (`tonistiigi/binfmt`) to cross-build when run on a non-arm64 host, and pushes it to `docker.io/jnitecki/ollama`, tagged with `OLLAMA_VERSION` and `latest`.

```sh
./build.ps1 -ollamaVersion 0.34.3
```

Pass `-NoCache` to force a clean rebuild.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description and the `machine-learning-and-ai` category) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. This step only warns on failure; it never fails the build.
