while [[ `pgrep -a warp|grep -v "client "|grep -v warp.sh` ]] ; do sleep 31 ; done
touch /rdu-nfs/twilkins/tmp/warp-`hostname -s`
