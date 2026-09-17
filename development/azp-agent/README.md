# azp-agent

Containerized self-hosted agent for Azure Pipelines / Azure DevOps. Two buildable variants share the same feature set (Java, Android SDK, PowerShell Core, .NET SDK, Node.js toolchains) where the base OS allows it:

| Variant | Base image                              | Dockerfile          | Build context     | Publish script       |
|---------|------------------------------------------|----------------------|--------------------|------------------------|
| Linux   | `ubuntu:24.04`                            | `Dockerfile.linux`   | `linux-context/`   | `install-linux.ps1`   |
| Windows | `mcr.microsoft.com/windows/servercore`    | `Dockerfile.windows` | `windows-context/` | `install-windows.ps1` |

> **Windows variant status:** first-draft, not yet build-verified against a real Windows container host — see [Verification](#verification) below before relying on it in production.

## Build

```sh
docker build -f Dockerfile.linux -t azp-agent linux-context
```

```powershell
docker build -f Dockerfile.windows -t azp-agent:windows windows-context
```

### Version pins

`versions.json` is the single source of truth for the agent version and every toolchain toggle — `install-linux.ps1` and `install-windows.ps1` both read it and pass its fields through as `--build-arg`s, and both Dockerfiles' `ARG ...=default` lines are kept identical to it (enforced by `Assert-VersionsInSync` in `install-common.ps1`, which the publish scripts run before building). Building directly with `docker build`/`podman build` (bypassing the publish scripts) falls back to those same Dockerfile defaults.

| `versions.json` field         | Meaning                                                                 | Linux | Windows |
|--------------------------------|--------------------------------------------------------------------------|:-----:|:-------:|
| `agentVersion`                  | Azure Pipelines agent version to download                               |   ✓   |    ✓    |
| `installPodman`                 | Nested/rootless Podman for containerized jobs                           |   ✓   |    —    |
| `installJava`                   | OpenJDK version; empty = not installed                                  |   ✓   |    ✓    |
| `installAndroid`                | Android build-tools version; empty = not installed. Platform (API) version is derived from its major component | ✓ | ✓ |
| `androidCmdlineToolsVersion`    | Android cmdline-tools build number; independent of `installAndroid`     |   ✓   |    ✓    |
| `installPowershell`             | PowerShell Core (`pwsh`) version; empty = not installed on Linux. Always installed on Windows (the entrypoint itself needs it), but still version-pinned by this field | ✓ | ✓ |
| `installDotnet`                 | .NET SDK channel; empty = not installed                                 |   ✓   |    ✓    |
| `installNode`                   | Node.js version; empty = not installed                                  |   ✓   |    ✓    |

`installPodman` has no Windows counterpart — rootless nested containers have no comparably mature Windows-container equivalent, so it's Linux-only.

Example disabling everything but Podman on Linux:

```sh
docker build -f Dockerfile.linux \
  --build-arg INSTALL_JAVA="" \
  --build-arg INSTALL_ANDROID="" \
  --build-arg INSTALL_POWERSHELL="" \
  --build-arg INSTALL_DOTNET="" \
  --build-arg INSTALL_NODE="" \
  -t azp-agent linux-context
```

## Run

Both variants expect the standard Azure Pipelines agent environment variables (`AZP_URL`, `AZP_TOKEN`, `AZP_POOL`, etc. — see `linux-context/start.sh` / `windows-context/start.ps1`):

```sh
docker run -e AZP_URL=https://dev.azure.com/<org> \
           -e AZP_TOKEN=<pat> \
           -e AZP_POOL=<pool> \
           azp-agent
```

```powershell
docker run -e AZP_URL=https://dev.azure.com/<org> `
           -e AZP_TOKEN=<pat> `
           -e AZP_POOL=<pool> `
           docker.io/jnitecki/azp-agent:windows-latest
```

`run.ps1` scripts the above: it pulls the current image, stops/removes any previous `azp-agent`/`azp-agent-NN` container(s), and starts fresh one(s). `-AzpUrl`/`-AzpToken`/`-AzpPool` are optional — if omitted, each falls back to the matching `AZP_URL`/`AZP_TOKEN`/`AZP_POOL` environment variable, then to a hardcoded default at the top of the script (empty by default; fill in locally, never commit real values), and the script fails fast if a value is still missing.

```powershell
# Single Linux agent named after this host, using the latest image
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool>

# Three Linux agents: azp-agent-01..03, named <hostname>-01..03
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -InstanceCount 3

# Windows variant, explicit version
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -Os Windows -Version 4.248.0
```

## Publish

- **Linux** (`install-linux.ps1`) can run on any host — it builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman, using QEMU (`tonistiigi/binfmt`) to cross-build the non-native architecture, and pushes it to `docker.io/jnitecki/azp-agent`.
- **Windows** (`install-windows.ps1`) can only run on a Windows host with Docker in Windows-containers mode — Windows containers cannot be cross-built from a Linux host the way Linux arm64/amd64 are emulated via QEMU. It builds a plain single-arch (amd64) image with `docker` and pushes it to `docker.io/jnitecki/azp-agent` tagged with a `-windows` suffix (e.g. `4.248.0-windows`, `windows-latest`) rather than folding it into the same manifest/tag as the Linux build.

Both scripts resolve the latest `microsoft/azure-pipelines-agent` release automatically if `-version` is not supplied, and share that lookup logic via `install-common.ps1`.

```sh
./install-linux.ps1 -version 4.248.0
```

```powershell
./install-windows.ps1 -version 4.248.0
```

## Verification

The Windows variant (`Dockerfile.windows`, `windows-context/start.ps1`) was authored without access to a Windows container host and has not been build-tested. Before relying on it:

- Run `docker build -f Dockerfile.windows -t azp-agent:test-windows windows-context` on an actual Windows host with Windows containers mode enabled.
- Confirm the download URLs/asset-naming patterns used (Microsoft Build of OpenJDK Windows zip, Android `commandlinetools-win-*`, PowerShell MSI, `dotnet-install.ps1`, Node MSI, `vsts-agent-win-x64-*.zip`) still match the live vendor pages.
- Register the container against a real Azure DevOps org/PAT, then `docker stop` it and confirm `start.ps1`'s cleanup path (`config.cmd remove`) actually runs before the container is killed.
