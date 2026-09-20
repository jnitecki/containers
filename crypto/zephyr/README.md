# zephyr

Zephyr Protocol (`zephyrd`) daemon CLI node.

## Environment variables

| Variable | Meaning |
|----------|---------|
| `RPC_LOGIN` / `RPC_PASSWORD` | Enables authenticated RPC (`--rpc-login`) and exposes RPC on all interfaces. Omit both to keep RPC bound to localhost only. |
| `RPC_TLS` | Base filename (without extension) of a cert/key pair under `/etc/ssl/certs` / `/etc/ssl/private` to enable `--rpc-ssl` — see [TLS for RPC](#tls-for-rpc) below. |
| `EXTRA_PARAMS` | Additional flags appended verbatim to the `zephyrd` command line. |

## Volumes

| Path | Purpose |
|------|---------|
| `/zephyr-data` | `zephyrd` blockchain data directory. |
| `/logs` | `zephyrd` log files. |

```sh
docker run -d --name zephyr --restart unless-stopped \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -v /path/to/data:/zephyr-data \
           -v /path/to/logs:/logs \
           docker.io/jnitecki/zephyr:latest
```

## TLS for RPC

Set `RPC_TLS` to a name (e.g. `server`) and mount the matching cert/key pair; combine with the auth variables above:

```sh
docker run -d --name zephyr --restart unless-stopped \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -e RPC_TLS=server \
           -e EXTRA_PARAMS=<extra zephyrd flags> \
           -v /path/to/data:/zephyr-data \
           -v /path/to/logs:/logs \
           -v /path/to/fullchain.cer:/etc/ssl/certs/server.cer \
           -v /path/to/privkey.key:/etc/ssl/private/server.key \
           docker.io/jnitecki/zephyr:latest
```
