# zephyr — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Multi-arch build (`linux/amd64`, `linux/arm64`).

## Build

```sh
docker build -f dockerfile -t zephyr build-context
```

### Version pins

Zephyr Protocol releases have occasionally shipped CLI zip assets whose embedded version lags one patch behind the release tag itself (e.g. tag `v2.1.0` shipped `zephyr-cli-linux-v2.1.1.zip`), so the release tag (`BASE_VERSION`, used to build the download URL) and the CLI asset version (`CLI_VERSION`, used in the filename and as the published image tag) are tracked and resolved independently rather than assumed equal.

`build.ps1` resolves both from the GitHub API's latest-release metadata automatically if `-baseVersion`/`-cliVersion` aren't supplied, and passes them through as `--build-arg BASE_VERSION=...`/`--build-arg CLI_VERSION=...`. Building directly with `docker build`/`podman build` (bypassing the build script) falls back to the Dockerfile's own `ARG ...=<default>` values.

## Publish

`build.ps1` builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/zephyr`, tagged with `CLI_VERSION`.

```sh
./build.ps1 -baseVersion 2.3.0 -cliVersion 2.3.0
```

Pass `-NoCache` to force a clean rebuild.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description; no `categories` set here — Docker Hub has no blockchain/crypto category to genuinely fit) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. This step only warns on failure; it never fails the build.
