# azp-agent — Build & Publish

Internal build/publish documentation — not part of the Docker Hub description. See [README.md](README.md) for usage.

Two buildable variants share the same feature set (Java, Android SDK, PowerShell Core, .NET SDK, Node.js toolchains) where the base OS allows it:

| Variant | Base image                              | Dockerfile          | Build context     | Build script       |
|---------|------------------------------------------|----------------------|--------------------|------------------------|
| Linux   | `ubuntu:24.04`                            | `dockerfile.linux`   | `linux-context/`   | `build-linux.ps1`   |
| Windows | `mcr.microsoft.com/windows/servercore`    | `dockerfile.windows` | `windows-context/` | `build-windows.ps1` |

`build-linux.ps1` runs on Linux, macOS and Windows hosts (Podman; on macOS/Windows through the Podman machine). `build-windows.ps1` needs a Windows host with Docker in Windows-containers mode and aborts on any other host. Both can be started from any directory, e.g. `./build-linux.ps1` here or `development/azp-agent/build-linux.ps1` from the repository root.

> **Windows variant status:** first-draft, not yet build-verified against a real Windows container host — see [Verification](#verification) below before relying on it in production.

## Build

```sh
docker build -f dockerfile.linux --build-arg AGENT_VERSION=4.248.0 -t azp-agent linux-context
```

```powershell
docker build -f dockerfile.windows --build-arg AGENT_VERSION=4.248.0 --build-arg INSTALL_POWERSHELL=7.6.6 -t azp-agent:windows windows-context
```

### Version pins

The `Versions` part of [settings.ps1](settings.ps1) holds the agent version and every toolchain toggle. `build-linux.ps1` and `build-windows.ps1` both pass its values through as `--build-arg`s (see `$script:VersionArgMap` in `build-common.ps1` for the key → ARG mapping). The Dockerfiles have no defaults for any of them. Building directly with `docker build`/`podman build` (bypassing the build scripts) requires `AGENT_VERSION` (and on Windows `INSTALL_POWERSHELL`, which is always installed there) and fails fast without it. Toolchains that aren't passed are not installed. `ANDROID_CMDLINE_TOOLS_VERSION` is required whenever `INSTALL_ANDROID` is set.

| `Versions` key                | Meaning                                                                 | Linux | Windows |
|--------------------------------|--------------------------------------------------------------------------|:-----:|:-------:|
| `version`                       | Azure Pipelines agent version to download; empty = latest release, resolved by the build script. Overridden by `-version` |   ✓   |    ✓    |
| `installPodman`                 | Nested/rootless Podman for containerized jobs                           |   ✓   |    —    |
| `installBuildEssential`         | Ubuntu `build-essential` (gcc, g++, make, libc dev headers) for native builds, e.g. npm native addons; `true` = installed | ✓ | — |
| `installPythonDev`              | Python development headers (`python3-dev`: `Python.h`, `python3-config`) for building native Python extensions; `true` = installed. Requires `installBuildEssential` = `true` — the build fails otherwise | ✓ | — |
| `installJava`                   | OpenJDK version; empty = not installed                                  |   ✓   |    ✓    |
| `installAndroid`                | Android build-tools version; empty = not installed. Platform (API) version is derived from its major component | ✓ | ✓ |
| `androidCmdlineToolsVersion`    | Android cmdline-tools build number; required when `installAndroid` is set |   ✓   |    ✓    |
| `installAndroidEmulator`        | Android emulator. An API level (e.g. `36`) installs the `emulator` package plus `system-images;android-<level>;default;x86_64`; `true` installs the emulator only, no system image; empty = not installed. Requires `installAndroid` to be set — the build fails otherwise. amd64 only: Google publishes no emulator for Linux arm64, so the arm64 image validates the value but skips the install, with a warning — shown by `build-linux.ps1` before the build starts and again inside the arm64 build step | ✓ | — |
| `installPowershell`             | PowerShell Core (`pwsh`) version; empty = not installed on Linux. Always installed on Windows (the entrypoint itself needs it), but still version-pinned by this field | ✓ | ✓ |
| `installDotnet`                 | .NET SDK channel; empty = not installed                                 |   ✓   |    ✓    |
| `installNode`                   | Node.js version; empty = not installed                                  |   ✓   |    ✓    |

`installPodman` has no Windows counterpart — rootless nested containers have no comparably mature Windows-container equivalent, so it's Linux-only. `installBuildEssential` is Linux-only too — it maps to an Ubuntu apt meta-package; a Windows equivalent (Visual Studio Build Tools) is not part of this image. `installPythonDev` depends on it and is Linux-only for the same reason. `installAndroidEmulator` is Linux-only because the emulator needs hardware acceleration (KVM), which Windows containers can't provide — and within Linux it only takes effect on amd64, since no Linux arm64 emulator exists.

Neither package is version-pinned (both come from Ubuntu's apt repo), so `entrypoint.sh` detects them at container start and exports `GCC` (full gcc version, from `gcc -dumpfullversion`), `GCC_<major>` (path to `gcc` as resolved on `PATH`, e.g. `GCC_13=/usr/bin/gcc`) and `PYTHON_DEV` (`<major>.<minor>` of the Python the headers belong to) before the agent captures its environment — the same way it derives `JAVA_HOME_<version>_<arch>`. A disabled toggle means the tool is absent, so its variable is simply not set.

The Android emulator is handled the same way, but installing it is not enough on its own: `entrypoint.sh` runs `$ANDROID_HOME/emulator/emulator -accel-check` at start and exports `ANDROID_EMULATOR` (path to the emulator binary) and `ANDROID_EMULATOR_<api>` (the same path, one per installed `system-images/android-<api>`) only if that check succeeds, i.e. only when the container can actually use hardware acceleration (`/dev/kvm`).

Podman is different: the Dockerfile sets `PODMAN` (path to podman, `/usr/bin/podman`) whenever `installPodman` is set, and `entrypoint.sh` keeps it only if the container runs `--privileged`, since nested Podman doesn't work reliably otherwise. The checks are: `CapBnd` in `/proc/self/status` holds every capability up to `/proc/sys/kernel/cap_last_cap` (`CapBnd`, not `CapEff`, which is 0 for a non-root user either way); `Seccomp` is `0`; `/proc/self/attr/current` shows no AppArmor `(enforce)`/`(complain)` profile or SELinux `container_t` label; neither `/proc/sys` nor `/sys` is mounted `ro`; and `/dev` has at least 30 entries (host devices are exposed). The first failed check is logged as a warning and `PODMAN` is unset.

To disable a toolchain for the published image, set its `Versions` key to `""`. Example direct `docker build` with Podman as the only toolchain (toolchain ARGs that aren't passed are not installed):

```sh
docker build -f dockerfile.linux \
  --build-arg AGENT_VERSION=4.248.0 \
  --build-arg INSTALL_PODMAN=true \
  -t azp-agent linux-context
```

### Settings

[settings.ps1](settings.ps1) holds the defaults both scripts use, in two parts. `Build` covers how the image is built and named: `Registry` and `Repository` (images are pushed as `<Registry>/<Repository>`, and `Repository` is also the Docker Hub repository whose metadata is synced), `ImageName` (the local manifest name), `NoCache`, `SkipHubMetadata` and `HubUsername`. Its `Linux` and `Windows` sections hold per-OS values (`Platforms` and `Squash` for Linux, `Squash` for Windows), merged over the shared ones by the matching script. `Versions` holds the component versions described under [Version pins](#version-pins). Parameters passed on the command line take precedence over these values, including `-NoCache:$false`/`-SkipHubMetadata:$false` over a `$true` setting. `Registry`, `Repository`, `ImageName`, `Platforms` and the toolchain keys can only be set in the file. `-HubToken` is deliberately not configurable there.

On a successful push, both scripts also sync `README.md` and [hub-metadata.yml](hub-metadata.yml) (short description + the `integration-and-delivery` category) to the shared `jnitecki/azp-agent` Docker Hub repository, reusing your existing `podman login`/`docker login` credentials — see [scripts/dockerhub-common.ps1](../../scripts/dockerhub-common.ps1) and `docs/CONTEXT.md` for details. Before building anything, the script runs `Assert-DockerHubWriteAccess`, which checks that those credentials can actually update the repository and aborts right away if not, instead of failing only after the push. Pass `-SkipHubMetadata` to skip both that check and the sync (e.g. to publish with a token that can push but not edit repository metadata). The sync itself still only warns on failure; it never fails the build. To use a specific token instead of your existing login, pass `-HubToken` as a SecureString, e.g. `-HubToken (Read-Host -AsSecureString "Docker Hub token")`, optionally with `-HubUsername` (defaults to `jnitecki`, the repository namespace). It is then used for everything in that run — base image pulls, the image push, the write check and the metadata sync — through a temporary credential file outside the default location, passed explicitly to each podman/docker command and deleted when the script ends; your normal login is not touched and never sees it. A token that fails to log in aborts the script before anything is built. The category update specifically is unconfirmed to actually persist (Docker Hub's API doesn't document this field at all) — check the Docker Hub UI after a real run, and set it there manually if it didn't take.

## Verification

The Windows variant (`dockerfile.windows`, `windows-context/entrypoint.ps1`) was authored without access to a Windows container host and has not been build-tested. Before relying on it:

- Run `docker build -f dockerfile.windows -t azp-agent:test-windows windows-context` on an actual Windows host with Windows containers mode enabled.
- Confirm the download URLs/asset-naming patterns used (Microsoft Build of OpenJDK Windows zip, Android `commandlinetools-win-*`, PowerShell MSI, `dotnet-install.ps1`, Node MSI, `vsts-agent-win-x64-*.zip`) still match the live vendor pages.
- Register the container against a real Azure DevOps org/PAT, then `docker stop` it and confirm `entrypoint.ps1`'s cleanup path (`config.cmd remove`) actually runs before the container is killed.
