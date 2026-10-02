# azp-agent

Containerized self-hosted agent for Azure Pipelines / Azure DevOps, with optional build essentials and Python dev headers (Linux), Java, Android SDK (with emulator on Linux), PowerShell Core, .NET SDK, and Node.js toolchains.

| Variant | Image tag |
|---------|-----------|
| Linux   | `docker.io/jnitecki/azp-agent:latest` |
| Windows | `docker.io/jnitecki/azp-agent:windows-latest` |

## Run

Both variants expect the standard Azure Pipelines agent environment variables:

| Variable | Meaning |
|----------|---------|
| `AZP_URL` | Azure DevOps organization URL, e.g. `https://dev.azure.com/<org>`. |
| `AZP_TOKEN` | Personal access token with Agent Pools (read, manage) scope. |
| `AZP_POOL` | Agent pool name to register into (defaults to `Default`). |
| `AZP_AGENT_NAME` | Optional; defaults to the container's own hostname if unset. |
| `AZP_WORK` | Optional working directory (defaults to `_work`). |
| `AZP_RUN_ONCE` | Optional; `true` (default) runs a single job, then the agent deregisters and the container exits. `false` keeps the agent registered and taking jobs until the container is stopped. Also accepts `1`/`0` and `yes`/`no`. |

With the default `AZP_RUN_ONCE=true`, run the container with a restart policy (e.g. `--restart unless-stopped`, as `run.ps1` does) so a fresh agent registers after every job. Note that a restarted container keeps its filesystem, so to start each job from a clean environment, run a new container (e.g. `--rm` plus an external supervisor) instead of restarting the old one.

```sh
docker run -e AZP_URL=https://dev.azure.com/<org> \
           -e AZP_TOKEN=<pat> \
           -e AZP_POOL=<pool> \
           docker.io/jnitecki/azp-agent:latest
```

```powershell
docker run -e AZP_URL=https://dev.azure.com/<org> `
           -e AZP_TOKEN=<pat> `
           -e AZP_POOL=<pool> `
           docker.io/jnitecki/azp-agent:windows-latest
```

### Toolchain capabilities (Linux)

The Linux agent reports these variables as capabilities, so pipelines can `demand` them:

| Variable | Set when | Value |
|----------|----------|-------|
| `GCC` | gcc (`build-essential`) is installed | Full gcc version, e.g. `13.3.0` |
| `GCC_<major>` | gcc (`build-essential`) is installed | Path to gcc, e.g. `GCC_13=/usr/bin/gcc` |
| `PYTHON_DEV` | Python development headers (`python3-dev`) are installed | Python version the headers are for, e.g. `3.12` |
| `ANDROID_EMULATOR` | The Android emulator is installed **and** `emulator -accel-check` succeeds at container start | Path to the emulator, e.g. `/opt/android-sdk/emulator/emulator` |
| `ANDROID_EMULATOR_<api>` | As `ANDROID_EMULATOR`, one per installed emulator system image | Path to the emulator, e.g. `ANDROID_EMULATOR_36=/opt/android-sdk/emulator/emulator` |
| `PODMAN` | Podman is installed **and** the container runs `--privileged` | Path to podman, e.g. `/usr/bin/podman` |

```yaml
pool:
  name: <pool>
  demands:
  - GCC_13
  - PYTHON_DEV -equals 3.12
```

The emulator is only included in the amd64 image (Google publishes no Linux arm64 emulator). It needs hardware acceleration, so the container must be given access to KVM (e.g. `--device /dev/kvm`, or `--privileged` as `run.ps1` does) on a host that supports it. Without it, the emulator stays installed but `ANDROID_EMULATOR*` are not reported, so jobs that demand them won't be routed to this agent.

Nested Podman needs the container to run `--privileged` (as `run.ps1` does). At start the agent checks for that: full capability bounding set, no seccomp filter or AppArmor/SELinux confinement, writable `/proc/sys` and `/sys`, and host devices visible in `/dev`. If any check fails, it logs a warning naming the failed check and removes `PODMAN`.

If you have this repository cloned, `run.ps1` scripts the above: it pulls the current image, stops/removes any previous `azp-agent`/`azp-agent-NN` container(s), and starts fresh one(s). `-AzpUrl`/`-AzpToken`/`-AzpPool` are optional — if omitted, each falls back to the matching `AZP_URL`/`AZP_TOKEN`/`AZP_POOL` environment variable, then to a hardcoded default at the top of the script (empty by default; fill in locally, never commit real values), and the script fails fast if a value is still missing. `-RunOnce true|false` sets `AZP_RUN_ONCE` the same way (parameter, then environment variable), but if neither is given the image default applies.

```powershell
# Single Linux agent named after this host, using the latest image
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool>

# Three Linux agents: azp-agent-01..03, named <hostname>-01..03
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -InstanceCount 3

# Persistent agent that keeps taking jobs instead of exiting after one
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -RunOnce false

# Windows variant, explicit version
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -Os Windows -Version 4.248.0
```
