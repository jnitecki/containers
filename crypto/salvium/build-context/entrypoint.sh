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

/salvium-node/salviumd --data-dir /salvium-data --db-sync-mode safe --non-interactive --bootstrap-daemon-address auto --rpc-bind-ip $RPC_ADDRESS --confirm-external-bind $CREDENTIALS $CERTIFICATES --zmq-pub tcp://0.0.0.0:18083 --hide-my-port --out-peers 32 --in-peers 64 --no-igd --disable-dns-checkpoints --enable-dns-blocklist --prune-blockchain --log-file /logs/salvium.log &
DAEMON_PID=$!

# Function to forward signals process
cleanup() {
    SIGNAL=$1
    echo "Received signal: $SIGNAL"
    kill -s "$SIGNAL" "$DAEMON_PID"
}

# Trap SIGINT and SIGTERM, and forward them to process
trap 'cleanup SIGINT'  SIGINT
trap 'cleanup SIGTERM' SIGTERM

while (! /salvium-node/salviumd $CREDENTIALS status | grep 'Height:' > /dev/null 2>&1) && (pgrep -x salviumd > /dev/null 2>&1) ; do
  sleep 10
done
if ! pgrep -x salviumd > /dev/null 2>&1; then exit; fi

while kill -0 "$DAEMON_PID" 2>/dev/null; do
  wait "$DAEMON_PID"
done
