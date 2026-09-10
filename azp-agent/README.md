# azp-agent

Containerized self-hosted agent for Azure Pipelines / Azure DevOps, based on `ubuntu:24.04`. Supports nested (rootless) Podman for containerized pipeline jobs, plus optional Java, Android SDK, and PowerShell Core toolchains.

## Build

```sh
docker build -t azp-agent .
```

### Optional toolchains

Every toolchain is on by default, so a plain `docker build` produces a fully-loaded image. Each `INSTALL_*` arg (other than `INSTALL_PODMAN`, which is a plain boolean) doubles as its version pin — pass an empty string to skip that toolchain entirely:

| Build arg              | Default   | Description                                    |
|-------------------------|-----------|------------------------------------------------|
| `INSTALL_PODMAN`         | `true`    | Nested/rootless Podman for containerized jobs   |
| `INSTALL_JAVA`            | `17`      | OpenJDK version; empty = not installed          |
| `INSTALL_ANDROID`         | `34.0.0`  | Android build-tools version; empty = not installed. The platform (API) version is derived from its major component (`34.0.0` → platform `34`) |
| `INSTALL_POWERSHELL`      | `7.4.6`   | PowerShell Core (`pwsh`) version; empty = not installed |

> **Note:** `INSTALL_ANDROID` requires `INSTALL_JAVA` to be set as well — the Android `sdkmanager` needs a JDK.

Related version pin:

| Build arg                        | Default        | Notes                                              |
|-----------------------------------|----------------|-----------------------------------------------------|
| `ANDROID_CMDLINE_TOOLS_VERSION`    | `15859902`     | Cmdline-tools build number; independent of `INSTALL_ANDROID` (Google versions it separately) |

Also configurable: `AGENT_VERSION` (default `4.248.0`) — the Azure Pipelines agent version to download.

Example disabling everything but Podman:

```sh
docker build \
  --build-arg INSTALL_JAVA="" \
  --build-arg INSTALL_ANDROID="" \
  --build-arg INSTALL_POWERSHELL="" \
  -t azp-agent .
```

## Run

The container expects the standard Azure Pipelines agent environment variables (`AZP_URL`, `AZP_TOKEN`, `AZP_POOL`, etc. — see `start.sh`):

```sh
docker run -e AZP_URL=https://dev.azure.com/<org> \
           -e AZP_TOKEN=<pat> \
           -e AZP_POOL=<pool> \
           azp-agent
```

## Publish (`install.ps1`)

`install.ps1` builds a multi-arch (`linux/amd64,linux/arm64`) manifest with Podman and pushes it to `docker.io/jnitecki/azp-agent`. It resolves the latest `microsoft/azure-pipelines-agent` release automatically if `-version` is not supplied:

```sh
./install.ps1 -version 4.248.0
```
