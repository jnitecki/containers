# verus — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Multi-arch build (`linux/amd64`, `linux/arm64`).

## Build

```sh
docker build -f dockerfile -t verus build-context
```

### Version pin

`build.ps1` resolves the latest VerusCoin CLI release automatically if `-version` isn't supplied, and passes it through as `--build-arg CLI_VERSION=...`. Building directly with `docker build`/`podman build` (bypassing the build script) falls back to the Dockerfile's own `ARG CLI_VERSION=<default>`.

## Publish

`build.ps1` builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/verus`.

```sh
./build.ps1 -version 1.2.17-6
```

Pass `-NoCache` to force a clean rebuild.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description; no `categories` set here — Docker Hub has no blockchain/crypto category to genuinely fit) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. This step only warns on failure; it never fails the build.
