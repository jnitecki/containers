# azp-agent

Containerized self-hosted agent for Azure Pipelines / Azure DevOps, with optional Java, Android SDK, PowerShell Core, .NET SDK, and Node.js toolchains.

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

If you have this repository cloned, `run.ps1` scripts the above: it pulls the current image, stops/removes any previous `azp-agent`/`azp-agent-NN` container(s), and starts fresh one(s). `-AzpUrl`/`-AzpToken`/`-AzpPool` are optional — if omitted, each falls back to the matching `AZP_URL`/`AZP_TOKEN`/`AZP_POOL` environment variable, then to a hardcoded default at the top of the script (empty by default; fill in locally, never commit real values), and the script fails fast if a value is still missing.

```powershell
# Single Linux agent named after this host, using the latest image
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool>

# Three Linux agents: azp-agent-01..03, named <hostname>-01..03
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -InstanceCount 3

# Windows variant, explicit version
./run.ps1 -AzpUrl https://dev.azure.com/<org> -AzpToken <pat> -AzpPool <pool> -Os Windows -Version 4.248.0
```
