# monero

Monero (`monerod`) daemon, optionally paired with a [P2Pool](https://github.com/SChernykh/p2pool) mining node run behind Tor for `.onion` peer connectivity.

## Environment variables

| Variable | Meaning |
|----------|---------|
| `POOL_TYPE` | `none` to run `monerod` standalone; `mini` for the P2Pool mini sidechain; anything else for the full P2Pool sidechain. |
| `WALLET_ADDRESS` | Payout wallet address passed to P2Pool. Required unless `POOL_TYPE=none`. |
| `RPC_LOGIN` / `RPC_PASSWORD` | Enables authenticated RPC (`--rpc-login`) and exposes RPC on all interfaces. Omit both to keep RPC bound to localhost only. |
| `RPC_TLS` | Base filename (without extension) of a cert/key pair under `/etc/ssl/certs` / `/etc/ssl/private` to enable `--rpc-ssl` — see [TLS for RPC](#tls-for-rpc) below. |
| `PRIORITY_NODES` | Comma-separated `host:port` list added as `--add-priority-node`. Unresolvable DNS names are skipped with a warning. |

## Volumes

| Path | Purpose |
|------|---------|
| `/monero-data` | `monerod` blockchain data directory. |
| `/logs` | `monerod` / P2Pool / Tor log files. |
| `/p2pool.cache` | P2Pool sidechain cache file — mount as a file, not a directory. Persists P2Pool's chain across restarts. Only relevant when P2Pool is running. |
| `/stats` | Optional. If `/stats/p2pool` exists, P2Pool's local stats API (`--data-api`) is enabled. |
| `/var/lib/tor/p2pool` | Tor hidden-service directory for the P2Pool `.onion` listener. Its presence is what starts the Tor sidecar — leave it unmounted (or mount elsewhere) to keep Tor off even with a pool `POOL_TYPE`. |

## Standalone node (no mining)

```sh
docker run -d --name monero --restart unless-stopped \
           -e POOL_TYPE=none \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -e PRIORITY_NODES=p2pmd.xmrvsbeast.com:18080,nodes.hashvault.pro:18080,node.moneroworld.com:18080 \
           -v /path/to/data:/monero-data \
           -v /path/to/logs:/logs \
           docker.io/jnitecki/monero:latest
```

## Mining (P2Pool over Tor)

```sh
docker run -d --name monero --restart unless-stopped \
           -p 3333:3333 \
           -e POOL_TYPE=mini \
           -e WALLET_ADDRESS=<address> \
           -e PRIORITY_NODES=p2pmd.xmrvsbeast.com:18080,nodes.hashvault.pro:18080,node.moneroworld.com:18080 \
           -v /path/to/data:/monero-data \
           -v /path/to/logs:/logs \
           -v /path/to/p2pool.cache:/p2pool.cache \
           -v /path/to/stats:/stats \
           -v /path/to/tor-service:/var/lib/tor/p2pool \
           docker.io/jnitecki/monero:latest
```

## TLS for RPC

Set `RPC_TLS` to a name (e.g. `server`) and mount the matching cert/key pair:

```sh
-e RPC_TLS=server \
-v /path/to/fullchain.pem:/etc/ssl/certs/server.cer \
-v /path/to/privkey.pem:/etc/ssl/private/server.key \
```

This can be combined with either mode above.
