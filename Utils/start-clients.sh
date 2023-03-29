#!/bin/bash
EXPECTED_ARGS=2
if [ $# -eq $EXPECTED_ARGS ] ; then
  numCONT=$1
  subnet=$2
else
  echo "Usage: $(basename $0) <number_of_containers> <target_subnet>"
  exit 1
fi

# Start warp clients 
ts=`date +'%y%m%d-%H%M'`
for i in `seq ${numCONT}` ; do
    warp client `ifconfig |grep $subnet |awk '{print$2}'`:800${i} &> /root/${ts}_client${i}.out & 
done

