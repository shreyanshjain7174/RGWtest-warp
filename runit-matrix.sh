#!/bin/bash
cd /root/RGWtest-warp

#egrep 'duration=|concurrent|objsize' vars.shinc
#time ./runit-fill.sh 5h-512M-con1

#sed -i -e 's/duration=5h/duration=7h/' vars.shinc
#sed -i -e 's/objsize=512MiB/objsize=256MiB/' vars.shinc
#egrep 'duration=|concurrent|objsize' vars.shinc
#./resetRGW.sh ; sleep 8m ; time ./runit-fill.sh 7h-256M-con1

#sed -i -e 's/duration=7h/duration=5h/' vars.shinc
#egrep 'duration=|concurrent|objsize' vars.shinc
#./resetRGW.sh ; sleep 8m ; time ./runit-fill.sh 5h-256M-con1

#ceph config set global rgw_max_concurrent_requests 1024

#sed -i -e 's/duration=5h/duration=7h/' vars.shinc
#sed -i -e 's/objsize=256MiB/objsize=512MiB/' vars.shinc
#egrep 'duration=|concurrent|objsize' vars.shinc
#./resetRGW.sh ; sleep 8m ; time ./runit-fill.sh 7h-512M-con1-1024req

ceph config set global rgw_max_concurrent_requests 2048
sed -i -e 's/duration=5h/duration=7h/' vars.shinc
sed -i -e 's/concurrent=5/concurrent=2/' vars.shinc
egrep 'duration=|concurrent|objsize' vars.shinc
./resetRGW.sh ; sleep 8m ; time ./runit-fill.sh 7h-256M-con2

sed -i -e 's/concurrent=2/concurrent=3/' vars.shinc
egrep 'duration=|concurrent|objsize' vars.shinc
./resetRGW.sh ; sleep 8m ; time ./runit-fill.sh 7h-256M-con3
