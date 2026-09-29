# monero — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Multi-arch build (`linux/amd64`, `linux/arm64`).

## Build

```sh
docker build -f dockerfile -t monero build-context
```

### Version pins

`build.ps1` resolves the latest `monerod` and P2Pool release versions automatically if `-daemonVersion`/`-poolVersion` aren't supplied, and passes them through as `--build-arg DAEMON_VERSION=...`/`--build-arg P2POOL_VERSION=...`. Building directly with `docker build`/`podman build` (bypassing the build script) falls back to the Dockerfile's own `ARG ...=<default>` values.

## Publish

`build.ps1` builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/monero`.

```sh
./build.ps1 -daemonVersion 0.18.3.4 -poolVersion 4.4
```

Pass `-NoCache` to force a clean rebuild.

On a successful push, `build.ps1` also syncs `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description; no `categories` set here — Docker Hub has no blockchain/crypto category to genuinely fit) to the Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. Before building anything, the script runs `Assert-DockerHubWriteAccess`, which checks that those credentials can actually update the repository and aborts right away if not, instead of failing only after the push. Pass `-SkipHubMetadata` to skip both that check and the sync (e.g. to publish with a token that can push but not edit repository metadata). The sync itself still only warns on failure; it never fails the build. To use a specific token instead of your existing login, pass `-HubToken` as a SecureString, e.g. `-HubToken (Read-Host -AsSecureString "Docker Hub token")`, optionally with `-HubUsername` (defaults to `jnitecki`, the repository namespace). It is then used for everything in that run — base image pulls, the image push, the write check and the metadata sync — through a temporary credential file outside the default location, passed explicitly to each podman/docker command and deleted when the script ends; your normal login is not touched and never sees it. A token that fails to log in aborts the script before anything is built.
