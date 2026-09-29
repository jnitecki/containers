# azp-agent — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Two buildable variants share the same feature set (Java, Android SDK, PowerShell Core, .NET SDK, Node.js toolchains) where the base OS allows it:

| Variant | Base image                              | Dockerfile          | Build context     | Build script       |
|---------|------------------------------------------|----------------------|--------------------|------------------------|
| Linux   | `ubuntu:24.04`                            | `Dockerfile.linux`   | `linux-context/`   | `build-linux.ps1`   |
| Windows | `mcr.microsoft.com/windows/servercore`    | `Dockerfile.windows` | `windows-context/` | `build-windows.ps1` |

> **Windows variant status:** first-draft, not yet build-verified against a real Windows container host — see [Verification](#verification) below before relying on it in production.

## Build

```sh
docker build -f Dockerfile.linux -t azp-agent linux-context
```

```powershell
docker build -f Dockerfile.windows -t azp-agent:windows windows-context
```

### Version pins

`versions.json` is the single source of truth for the agent version and every toolchain toggle — `build-linux.ps1` and `build-windows.ps1` both read it and pass its fields through as `--build-arg`s, and both Dockerfiles' `ARG ...=default` lines are kept identical to it (enforced by `Assert-VersionsInSync` in `build-common.ps1`, which the build scripts run before building). Building directly with `docker build`/`podman build` (bypassing the build scripts) falls back to those same Dockerfile defaults.

| `versions.json` field         | Meaning                                                                 | Linux | Windows |
|--------------------------------|--------------------------------------------------------------------------|:-----:|:-------:|
| `agentVersion`                  | Azure Pipelines agent version to download                               |   ✓   |    ✓    |
| `installPodman`                 | Nested/rootless Podman for containerized jobs                           |   ✓   |    —    |
| `installBuildEssential`         | Ubuntu `build-essential` (gcc, g++, make, libc dev headers) for native builds, e.g. npm native addons; `true` = installed | ✓ | — |
| `installPythonDev`              | Python development headers (`python3-dev`: `Python.h`, `python3-config`) for building native Python extensions; `true` = installed. Requires `installBuildEssential` = `true` — the build fails otherwise | ✓ | — |
| `installJava`                   | OpenJDK version; empty = not installed                                  |   ✓   |    ✓    |
| `installAndroid`                | Android build-tools version; empty = not installed. Platform (API) version is derived from its major component | ✓ | ✓ |
| `androidCmdlineToolsVersion`    | Android cmdline-tools build number; independent of `installAndroid`     |   ✓   |    ✓    |
| `installAndroidEmulator`        | Android emulator. An API level (e.g. `36`) installs the `emulator` package plus `system-images;android-<level>;default;x86_64`; `true` installs the emulator only, no system image; empty = not installed. Requires `installAndroid` to be set — the build fails otherwise. amd64 only: Google publishes no emulator for Linux arm64, so the arm64 image validates the value but skips the install, with a warning — shown by `build-linux.ps1` before the build starts and again inside the arm64 build step | ✓ | — |
| `installPowershell`             | PowerShell Core (`pwsh`) version; empty = not installed on Linux. Always installed on Windows (the entrypoint itself needs it), but still version-pinned by this field | ✓ | ✓ |
| `installDotnet`                 | .NET SDK channel; empty = not installed                                 |   ✓   |    ✓    |
| `installNode`                   | Node.js version; empty = not installed                                  |   ✓   |    ✓    |

`installPodman` has no Windows counterpart — rootless nested containers have no comparably mature Windows-container equivalent, so it's Linux-only. `installBuildEssential` is Linux-only too — it maps to an Ubuntu apt meta-package; a Windows equivalent (Visual Studio Build Tools) is not part of this image. `installPythonDev` depends on it and is Linux-only for the same reason. `installAndroidEmulator` is Linux-only because the emulator needs hardware acceleration (KVM), which Windows containers can't provide — and within Linux it only takes effect on amd64, since no Linux arm64 emulator exists.

Neither package is version-pinned (both come from Ubuntu's apt repo), so `entrypoint.sh` detects them at container start and exports `GCC` (full gcc version, from `gcc -dumpfullversion`), `GCC_<major>` (path to `gcc` as resolved on `PATH`, e.g. `GCC_13=/usr/bin/gcc`) and `PYTHON_DEV` (`<major>.<minor>` of the Python the headers belong to) before the agent captures its environment — the same way it derives `JAVA_HOME_<version>_<arch>`. A disabled toggle means the tool is absent, so its variable is simply not set.

The Android emulator is handled the same way, but installing it is not enough on its own: `entrypoint.sh` runs `$ANDROID_HOME/emulator/emulator -accel-check` at start and exports `ANDROID_EMULATOR` (path to the emulator binary) and `ANDROID_EMULATOR_<api>` (the same path, one per installed `system-images/android-<api>`) only if that check succeeds, i.e. only when the container can actually use hardware acceleration (`/dev/kvm`).

Example disabling everything but Podman on Linux:

```sh
docker build -f Dockerfile.linux \
  --build-arg INSTALL_BUILD_ESSENTIAL="" \
  --build-arg INSTALL_PYTHON_DEV="" \
  --build-arg INSTALL_JAVA="" \
  --build-arg INSTALL_ANDROID="" \
  --build-arg INSTALL_ANDROID_EMULATOR="" \
  --build-arg INSTALL_POWERSHELL="" \
  --build-arg INSTALL_DOTNET="" \
  --build-arg INSTALL_NODE="" \
  -t azp-agent linux-context
```

## Publish

- **Linux** (`build-linux.ps1`) can run on any host — it builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/azp-agent`.
- **Windows** (`build-windows.ps1`) can only run on a Windows host with Docker in Windows-containers mode — Windows containers cannot be cross-built from a Linux host the way Linux arm64/amd64 are emulated via QEMU. It builds a plain single-arch (amd64) image with `docker` and pushes it to `docker.io/jnitecki/azp-agent` tagged with a `-windows` suffix (e.g. `4.248.0-windows`, `windows-latest`) rather than folding it into the same manifest/tag as the Linux build.

Both scripts resolve the latest `microsoft/azure-pipelines-agent` release automatically if `-version` is not supplied, and share that lookup logic via `build-common.ps1`.

```sh
./build-linux.ps1 -version 4.248.0
```

```powershell
./build-windows.ps1 -version 4.248.0
```

On a successful push, both scripts also sync `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description + the `integration-and-delivery` category) to the shared `jnitecki/azp-agent` Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. Before building anything, the script runs `Assert-DockerHubWriteAccess`, which checks that those credentials can actually update the repository and aborts right away if not, instead of failing only after the push. Pass `-SkipHubMetadata` to skip both that check and the sync (e.g. to publish with a token that can push but not edit repository metadata). The sync itself still only warns on failure; it never fails the build. To use a specific token instead of your existing login, pass `-HubToken` as a SecureString, e.g. `-HubToken (Read-Host -AsSecureString "Docker Hub token")`, optionally with `-HubUsername` (defaults to `jnitecki`, the repository namespace). It is then used for everything in that run — base image pulls, the image push, the write check and the metadata sync — through a temporary credential file outside the default location, passed explicitly to each podman/docker command and deleted when the script ends; your normal login is not touched and never sees it. A token that fails to log in aborts the script before anything is built. The category update specifically is unconfirmed to actually persist (Docker Hub's API doesn't document this field at all) — check the Docker Hub UI after a real run, and set it there manually if it didn't take.

## Verification

The Windows variant (`Dockerfile.windows`, `windows-context/entrypoint.ps1`) was authored without access to a Windows container host and has not been build-tested. Before relying on it:

- Run `docker build -f Dockerfile.windows -t azp-agent:test-windows windows-context` on an actual Windows host with Windows containers mode enabled.
- Confirm the download URLs/asset-naming patterns used (Microsoft Build of OpenJDK Windows zip, Android `commandlinetools-win-*`, PowerShell MSI, `dotnet-install.ps1`, Node MSI, `vsts-agent-win-x64-*.zip`) still match the live vendor pages.
- Register the container against a real Azure DevOps org/PAT, then `docker stop` it and confirm `entrypoint.ps1`'s cleanup path (`config.cmd remove`) actually runs before the container is killed.
