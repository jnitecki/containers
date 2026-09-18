#!/bin/bash
set -m

if [ -n "$SERVER_ADDRESS" ]; then
    MODE="-rpcconnect=$SERVER_ADDRESS"
else
    MODE="-server -disablewallet"
	if ! find /VRSC/blocks -maxdepth 1 -type f -name blk*.dat 2> /dev/null | grep -q . ; then 
		MODE="$MODE -bootstrap"
	fi
fi

RPC_ADDRESS=0.0.0.0
if [ -n "$RPC_LOGIN" ]; then
    CREDENTIALS="-rpcuser=$RPC_LOGIN -rpcpassword=$RPC_PASSWORD"
else
    RPC_ADDRESS=127.0.0.1
fi

if [ -z "$RPC_ALLOWIP" ]; then
    NETWORK_FILTER="-rpcallowip=0.0.0.0/0.0.0.0"
else
    NETWORK_FILTER="-rpcallowip=$RPC_ALLOWIP"
fi

exec /verus-cli/verusd -datadir=/VRSC -rpcbind=$RPC_ADDRESS $CREDENTIALS $NETWORK_FILTER $MODE

