# salvium

Salvium (`salviumd`) daemon CLI node.

## Environment variables

| Variable | Meaning |
|----------|---------|
| `RPC_LOGIN` / `RPC_PASSWORD` | Enables authenticated RPC (`--rpc-login`) and exposes RPC on all interfaces. Omit both to keep RPC bound to localhost only. |
| `RPC_TLS` | Base filename (without extension) of a cert/key pair under `/etc/ssl/certs` / `/etc/ssl/private` to enable `--rpc-ssl` — see [TLS for RPC](#tls-for-rpc) below. |

## Volumes

| Path | Purpose |
|------|---------|
| `/salvium-data` | `salviumd` blockchain data directory. |
| `/logs` | `salviumd` log files. |

```sh
docker run -d --name salvium --restart unless-stopped \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -v /path/to/data:/salvium-data \
           -v /path/to/logs:/logs \
           docker.io/jnitecki/salvium:latest
```

## TLS for RPC

Set `RPC_TLS` to a name (e.g. `server`) and mount the matching cert/key pair; combine with the auth variables above:

```sh
docker run -d --name salvium --restart unless-stopped \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -e RPC_TLS=server \
           -v /path/to/data:/salvium-data \
           -v /path/to/logs:/logs \
           -v /path/to/fullchain.cer:/etc/ssl/certs/server.cer \
           -v /path/to/privkey.key:/etc/ssl/private/server.key \
           docker.io/jnitecki/salvium:latest
```

## Running via run.ps1

If you have this repository cloned, `run.ps1` scripts the above: it pulls the current image, stops/removes any previous `salvium` container, and starts a fresh one. `-RpcLogin`/`-RpcPassword`/`-DataPath`/`-LogsPath` are optional — if omitted, each falls back to the matching `RPC_LOGIN`/`RPC_PASSWORD`/`SALVIUM_DATA_PATH`/`SALVIUM_LOGS_PATH` environment variable, then to a hardcoded default at the top of the script (empty by default; fill in locally, never commit real values), and the script fails fast if a value is still missing. `-RpcTls`/`-CertPath`/`-KeyPath` are only required when TLS is wanted.

```powershell
# No TLS
./run.ps1 -RpcLogin <user> -RpcPassword <password> -DataPath /path/to/data -LogsPath /path/to/logs

# With TLS
./run.ps1 -RpcLogin <user> -RpcPassword <password> -RpcTls server `
          -DataPath /path/to/data -LogsPath /path/to/logs `
          -CertPath /path/to/fullchain.cer -KeyPath /path/to/privkey.key
```
