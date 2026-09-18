# verus

Verus (VRSC) daemon (`verusd`) CLI node.

## Environment variables

| Variable | Meaning |
|----------|---------|
| `SERVER_ADDRESS` | If set, runs as an RPC client against a remote node (`-rpcconnect=<address>`) instead of a local full server. |
| `RPC_LOGIN` / `RPC_PASSWORD` | Enables authenticated RPC and binds RPC to all interfaces. Omit both to keep RPC bound to localhost only. |
| `RPC_ALLOWIP` | CIDR allowed to reach RPC (`-rpcallowip`) — defaults to `0.0.0.0/0.0.0.0` (open) when unset. |

## Volumes

| Path | Purpose |
|------|---------|
| `/VRSC` | Blockchain data directory (`-datadir`). If empty on first start (no `blk*.dat` files under `/VRSC/blocks`), `-bootstrap` is added automatically. |
| `/logs` | Daemon log files. |

This image doesn't declare an `EXPOSE` port; add `-p` mappings for whatever RPC/P2P ports your `verusd` configuration expects if remote access is needed.

```sh
docker run -d --name verus --restart unless-stopped \
           -e RPC_LOGIN=<user> \
           -e RPC_PASSWORD=<password> \
           -v /path/to/data:/VRSC \
           -v /path/to/logs:/logs \
           docker.io/jnitecki/verus:latest
```
