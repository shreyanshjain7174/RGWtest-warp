#!/bin/bash
#
# POLL.sh
#   Polls ceph and logs stats and writes to LOGFILE
#

# Bring in other script files
myPath="${BASH_SOURCE%/*}"
if [[ ! -d "$myPath" ]]; then
    myPath="$PWD"
fi

# Variables
source "$myPath/../vars.shinc"

# Functions
# defines: 'get_' routines
source "$myPath/../Utils/functions.shinc"

# check for passed arguments
[ $# -ne 2 ] && error_exit "POLL.sh failed - wrong number of args"
[ -z "$1" ] && error_exit "POLL.sh failed - empty first arg"
[ -z "$2" ] && error_exit "POLL.sh failed - empty second arg"

interval=$1          # how long to sleep between polling
log=$2               # the logfile to write to
DATE='date +%Y/%m/%d-%H:%M:%S'

# update log file  
updatelog "** POLL started" $log

###########################################################
echo -e "\nceph config dump:" >> $log
ceph config dump >> $log

echo -e "\nceph versions:" >> $log
ceph versions >> $log

echo -e "" >> $log
warp --version >> $log

echo -e "\nceph balancer status:" >> $log
ceph balancer status >> $log

echo -e "\nulimits:" >> $log
ulimit -a >> $log

echo -e "\nsysctl tuning:" >> $log
sysctl -a|egrep 'vm.max_map_count|kernel.threads-max|vm.min_free_kbytes' >> $log

# log current RGW/OSD tunings
get_tuning
echo "" >> $log
updatelog "OSD Settings:  ${osdtuning}" $log
updatelog "RGW Settings:  ${rgwtuning}" $log

# add %RAW USED and GC status to LOGFILE
#get_pendingGC   # this call can be expensive
#echo -en "\nGC: " >> $log   # prefix line with GC label for parsing
get_rawUsed
echo "" >> $log
updatelog "%RAW USED ${rawUsed}; Pending GCs ${pendingGC}" $log
threshold="80.0"

# reset site2 sync counters
if [[ $multisite == "true" ]]; then
    # verify rgw_run_sync_thread settings
    echo "" >> $log
    for rgw in $RGWhosts1 ; do
        case $CEPHVER in
            luminous|nautilus)
                asokpath='$(ls /var/run/ceph/ceph-client.rgw*.asok|tail -1)'
                run_sync_thread=$(ssh $rgw "ceph daemon ${asokpath} config show |grep rgw_run_sync_thread")
                echo "$rgw  $run_sync_thread" >> $log
                ;;
            pacific|quincy)
                fsid=`ceph status |grep id: |awk '{print$2}'`
                asokpath="/var/run/ceph/${fsid}"
                run_sync_thread=$(ssh $rgw "cd ${asokpath} && ceph --admin-daemon ceph-client.rgw.*.asok config show |grep rgw_run_sync_thread")
                echo "$rgw  $run_sync_thread" >> $log
                ;;
            *)
                echo "unable to gather rgw_run_sync_thread setting ..."
                ;;
        esac
    done
    if [[ $syncPolling == "true" ]]; then
	echo "" >> $log
        updatelog "Resetting data-sync-from-site1 counters on site2 RGWs" $log
	case $CEPHVER in
            luminous|nautilus)
                for rgw in $RGWhosts2 ; do
                    ssh ${rgw} 'ceph daemon `ls /var/run/ceph/ceph-client.rgw*.asok|tail -1` perf reset data-sync-from-site1' >> $log
                done
	        ;;
	    pacific|quincy)
                fsid2=`ssh $RGWhostname2 "ceph status |grep id:" |awk '{print$2}'`
                for rgw in $RGWhosts2 ; do
                    ssh ${rgw} "cd /var/run/ceph/$fsid2 && ceph --admin-daemon ceph-client.rgw.rgws.*.asok perf reset data-sync-from-site1" &>> $log
                done
	        ;;
	    *)
                echo "unable to reset site1 sync counters, exit..."
                ;;
        esac
    fi
fi

# keep polling until cluster reaches 'threshold' % fill mark
#while (( $(awk 'BEGIN {print ("'$rawUsed'" < "'$threshold'")}') )); do
#while [ true ]; do
while (( $(echo "${rawUsed} < ${threshold}" | bc -l) )); do
    echo -e "\n-------------------------------------------------------------------------------\n" >> $log
    # RESHARD activity
    #echo -n "RESHARD: " >> $log
    get_pendingRESHARD
    updatelog "RESHARD Queue Length ${pendingRESHARD}" $log
    updatelog "RESHARD List ${reshardList}" $log
    
    # RGW system Load Average
#    echo "" >> $log
#    echo -n "LA: " >> $log        # prefix line with stats label
#    get_upTime
#    updatelog "${RGWhost} ${upTime}" $log

#    get_rgwMem
#    updatelog "${RGWhostname} ${rgwMem} ${rgwMemUsed}" $log

    # RGW radosgw PROCESS, MEM stats and load avgs
    echo -e "\n`date +%Y/%m/%d-%H:%M:%S`\nRGW stats:          proc   %cpu %mem  vsz    rss      memused        memlimit               load avg" >> $log        # stats titles
    for rgw in $RGWhosts1 ; do
        rgwMem=`ssh $rgw ps -eo comm,pcpu,pmem,vsz,rss | grep -w 'radosgw '` &> /dev/null
        rgwMemUsed=`ssh $rgw cat /sys/fs/cgroup/memory/memory.usage_in_bytes` &> /dev/null
        rgwMemLimit=`ssh $rgw cat /sys/fs/cgroup/memory/memory.limit_in_bytes` &> /dev/null
        loadAvg=`ssh $rgw uptime | awk -F'[a-z]:' '{print $2}'`
        echo $rgw"   "$rgwMem"   "$rgwMemUsed"   "$rgwMemLimit"   "$loadAvg >> $log
    done

    # Client load avgs, CPU and MEM stats
    echo -e "\n`date +%Y/%m/%d-%H:%M:%S`\nWarp client & haproxy stats:" >> $log
    for driver in $drivers ; do
        loadAvg=`ssh $driver uptime | awk -F'[a-z]:' '{print $2}'`
        haproxyMem=`ssh $driver ps -eo comm,pcpu,pmem,vsz,rss | grep -v "0.0  0.0" | grep -w 'haproxy '` &> /dev/null
        driverMem=`ssh $driver ps -eo comm,pcpu,pmem,vsz,rss | grep -w 'warp '` &> /dev/null
        echo -e "$driver  $loadAvg \n${haproxyMem}\n${driverMem}" >> $log
    done

    echo -e "\n`date +%Y/%m/%d-%H:%M:%S`\nController stats:" >> $log
    loadAvg=`uptime | awk -F'[a-z]:' '{print $2}'`
    haproxyMem=`ps -eo comm,pcpu,pmem,vsz,rss | grep -v "0.0  0.0" | grep -w 'haproxy '` &> /dev/null
    warpMem=`ps -eo comm,pcpu,pmem,vsz,rss | grep -w 'warp '` &> /dev/null
    monMem=`ps -eo comm,pcpu,pmem,vsz,rss | grep -w 'ceph-mon '` &> /dev/null
    echo -e `hostname -s`: "$loadAvg\n${haproxyMem}\n$warpMem\n$monMem" >> $log

    # ceph-osd PROCESS and MEM stats
    echo -e "\nOSD stats: " >> $log        # prefix line with stats label
    for rgw in $RGWhosts1 ; do
        osdMem=`ssh $rgw ps -eo comm,pcpu,pmem,vsz,rss,args | grep -w 'ceph-osd '|egrep -v 'init|grep'|awk '{print $8"   "$2"   "$3"   "$4"   "$5}'`
        updatelog "${rgw} ${osdMem}" $log
    done

    # ceph client stats
#    get_clientStats
#    echo -en "\nCeph Client I/O\nsite1: " >> $log
#    updatelog "site1 client IO:  ${site1client}" $log
#    echo -n "site2: " >> $log
#    updatelog "site2 client IO:  ${site2client}" $log
#    echo "" >> $log

# get bucket stats
    get_bucketStats
    #echo -e "\nSite1 buckets (swift):" >> $log
    #echo -e "\nSite1 buckets (swift):"
    #updatelog "${site1bucketsswift}" $log
    echo -e "\nSite1 buckets (rgw):" >> $log
    echo -e "\nSite1 buckets (rgw):"
    updatelog "${site1bucketsrgw}" $log

    if [[ $multisite == "true" ]]; then
        #echo -e "\nSite2 buckets (swift):" >> $log 
        #echo -e "\nSite2 buckets (swift):"
        #updatelog "${site2bucketsswift}" $log
        echo -e "\nSite2 buckets (rgw):" >> $log 
        updatelog "${site2bucketsrgw}" $log
        get_syncStatus
        echo -e "\nSite2 sync status:" >> $log       
        echo -e "\nSite2 sync status:" 
        updatelog "${syncStatus}" $log
        echo -e "\nSite2 buckets sync status:" >> $log
        echo -e "\nSite2 buckets sync status:"
        updatelog "${bucketSyncStatus}" $log
    fi

    if [[ $syncPolling == "true" ]]; then
#        cmdStart=$SECONDS
#        get_dataLog
#        dataLog_duration=$(($SECONDS - $cmdStart))
#        echo -e "\nsite1 data log list ---------------------------------------------------- " >> $DATALOG
#        echo "dataLog response time: $dataLog_duration" >> $DATALOG
#        updatelog "${dataLog}" $DATALOG
        # multisite sync status
        get_SyncStats
        echo -en "\nCeph Client I/O\nsite1: " >> $log
        updatelog "site1:  ${site1io}" $log
        echo -n "site2: " >> $log
        updatelog "site2:  ${site2io}" $log
        echo -en "\nSite2 Sync Counters:\n">> $log
        cat /tmp/syncCtrs >> $log
    fi

    echo -e "\nCluster status" >> $log
    ceph status >> $log

    get_df-detail
    updatelog "ceph df detail ${dfdetail}" $log

    # Record specific pool stats
    echo -e "\nSite1 pool details:" >> $log
    ceph osd pool ls detail >> $log
    get_buckets_df
    echo -e "\nSite1 buckets df"
    echo -e "Site1 buckets df" >> $log
    updatelog "${buckets_df}" $log
    if [[ $multisite == "true" ]]; then
        echo -e "\nSite2 buckets df"
        echo -e "\nSite2 buckets df" >> $log
        updatelog "${buckets_df2}" $log
    fi

    echo "" >> $log
    rgw_free=`get_rgwfree`
    updatelog "${rgw_free}" $log

    echo "" >> $log
    host_free=`get_hostfree`
    updatelog "${host_free}" $log

#    get_osddf
#    echo -e "\nCeph OSD df:" >> $log
#    updatelog "${osddf}" $log

#    get_osd_memory_targets
#    echo -e "\nosd_memory_targets:" >> $log
#    updatelog "${targets}" $log

    # Record the %RAW USED and pending GC count
# NOTE: this may need to be $7 rather than $4 <<<<<<<<
#    get_rawUsed
#    get_pendingGC
#    echo -en "\nGC: " >> $log
#    updatelog "%RAW USED ${rawUsed}; Pending GCs ${pendingGC}" $log

    # monitor for large omap objs 
#    echo "" >> $log
#    site1omapCount=`ceph health detail |grep 'large obj'`
#    updatelog "Large omap objs (site1): $site1omapCount" $log
#    if [[ $multisite == "true" ]]; then
#        site2omapCount=`ssh $MONhostname2 ceph health detail |grep 'large obj'`
#        updatelog "Large omap objs (site2): $site2omapCount" $log
#    fi

    echo -e "\nPG Autoscale:" >> $log
    ceph osd pool autoscale-status >> $log

    # poll for RGW debug info &&& remove later
    echo -e "\nRGW netstat & qlen/qactive ..." >> $log
    for rgw in $RGWhosts1 ; do
        echo ${rgw} >> $log
        ssh $rgw "netstat -tnlp |egrep 'PID|rados'" >> $log
        case $CEPHVER in
            luminous|nautilus)
                ssh $rgw "ceph --admin-daemon /var/run/ceph/ceph-client.rgw.*.asok perf dump | egrep 'qlen|qactive'" >> $log
                ;;
            pacific|quincy)
                fsid=`ceph status |grep id: |awk '{print$2}'`
                ssh $rgw "cd /var/run/ceph/$fsid && ceph --admin-daemon ceph-client.rgw.rgws.*.asok perf dump | egrep 'qlen|qactive'" >> $log
                ;;
            *)
                echo "unable to collect RGW netstat & qlen/qactive"
                ;;
        esac
    done

    # Sleep for the poll interval
    sleep "${interval}"
done

# verify any rgw lifecycle policies ... &&& one-off testing, remove later
#echo -e "\nCheck buckets for LC policies ..." >> $log
#for i in `seq 6` ; do echo mycontainers$i >> $log ; s3cmd getlifecycle s3://mycontainers$i >> $log ; done

echo -n "POLL.sh: " >> $log   # prefix line with label for parsing
updatelog "** ${threshold}% fill mark hit: POLL ending" $log

# DONE
