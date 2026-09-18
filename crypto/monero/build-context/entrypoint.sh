#!/bin/bash
set -m

RPC_ADDRESS=0.0.0.0
if [ -n "$RPC_LOGIN" ]; then
	CREDENTIALS="--rpc-login $RPC_LOGIN:$RPC_PASSWORD"
else
    RPC_ADDRESS=127.0.0.1
fi
if [ -n "$RPC_TLS" ]; then
	CERTIFICATES="--rpc-ssl enabled --rpc-ssl-certificate /etc/ssl/certs/$RPC_TLS.cer --rpc-ssl-private-key /etc/ssl/private/$RPC_TLS.key"
else
    RPC_ADDRESS=127.0.0.1
fi
if [ "$POOL_TYPE" != "none" ]; then
	RPC_ADDRESS=127.0.0.1
	CERTIFICATES=
fi

if [[ ("$POOL_TYPE" = "none") && (! -d /var/lib/tor/p2pool) ]]; then
	STARTUP=
else
    STARTUP=--detach
fi

# Filter priority nodes and assign to array
# Split the input into an array
IFS=',' read -r -a NODES <<< "$PRIORITY_NODES";

# Initialize an empty array to store valid --add-priority-node arguments
PRIORITY_NODES_ARRAY=()

# Loop through each node in the list
for NODE in "${NODES[@]}"; do
    # Extract the host (DNS name or IP) and port
    HOST=$(echo "$NODE" | cut -d ':' -f 1);
    PORT=$(echo "$NODE" | cut -d ':' -f 2);

    # Check if the host is resolvable (for DNS names) or is a valid IP address
    if [[ $HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # It's an IP address, assume it's valid
        PRIORITY_NODES_ARRAY+=("--add-priority-node=$HOST:$PORT");
    else
        # It's a DNS name, check if it resolves
        if nslookup "$HOST" > /dev/null 2>&1; then
            PRIORITY_NODES_ARRAY+=("--add-priority-node=$HOST:$PORT");
        else
            echo "Warning: Host '$HOST' is not resolvable. Skipping.";
        fi
    fi
done

# Join the valid --add-priority-node arguments into a single string
PRIORITY_NODES=$(IFS=" "; echo "${PRIORITY_NODES_ARRAY[*]}");

/monero-node/monerod --data-dir /monero-data --db-sync-mode safe --non-interactive --bootstrap-daemon-address auto --rpc-bind-ip $RPC_ADDRESS --confirm-external-bind $CREDENTIALS $CERTIFICATES --zmq-pub tcp://0.0.0.0:18083 --hide-my-port --out-peers 32 --in-peers 64 --no-igd $PRIORITY_NODES --disable-dns-checkpoints --enable-dns-blocklist --prune-blockchain --log-file /logs/bitmontero.log $STARTUP &
DEAMON_PID=$!

# Function to forward signals process
cleanup() {
    SIGNAL=$1
    echo "Received signal: $SIGNAL"
    kill -s "$SIGNAL" "$DEAMON_PID"
	if [ -n "$POOL_PID" ]; then
	  kill -s "$SIGNAL" "$POOL_PID"
	fi
}

# Trap SIGINT and SIGTERM, and forward them to process
trap 'cleanup SIGINT'  SIGINT
trap 'cleanup SIGTERM' SIGTERM

if [ -d /var/lib/tor/p2pool ]; then
  tor -f /etc/tor/torrc --User debian-tor &
  SOCKS="--socks5 127.0.0.1:9050"
fi

while (! /monero-node/monerod $CREDENTIALS status | grep 'Height:' > /dev/null 2>&1) && (pgrep -x monerod > /dev/null 2>&1) ; do
  sleep 10
done
if ! pgrep -x monerod > /dev/null 2>&1; then exit; fi

if [ "$POOL_TYPE" = "none" ]; then
  while kill -0 "$DEAMON_PID" 2>/dev/null; do
    wait "$DEAMON_PID"
  done
else
  if [ "$POOL_TYPE" = "mini" ]; then
    MINING_TYPE=--mini
  else
    MINING_TYPE=
  fi
  if [ -d /stats/p2pool ]; then
    STATS="--data-api /stats/p2pool --local-api"
  fi
  /p2pool/p2pool --host $RPC_ADDRESS $CREDENTIALS $MINING_TYPE --wallet $WALLET_ADDRESS $SOCKS --loglevel 1 $STATS --out-peers 10 --in-peers 40 --no-upnp 2>&1 | tee -a /logs/p2pool.log &
  POOL_PID=$!
  while kill -0 "$DEAMON_PID" 2>/dev/null; do
    wait "$DEAMON_PID"
  done
  while kill -0 "$POOL_PID" 2>/dev/null; do
    wait "$POOL_PID"
  done 
fi
 