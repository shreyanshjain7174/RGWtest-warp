#!/bin/bash
#
# runIOworkload.sh <workload.xml>
# Requires one argument (COSbench workload.xml file)
#####################################################################
EXPECTED_ARGS=1
if [ $# -eq $EXPECTED_ARGS ] ; then
  operation=$1
else
  echo "Usage: $(basename $0) {fill,hybrid,hybrid-ext,delwrite}"
  exit 1
fi

# Bring in other script files
myPath="${BASH_SOURCE%/*}"
if [[ ! -d "$myPath" ]]; then
    myPath="$PWD" 
fi

# Variables
source "$myPath/vars.shinc"

# Functions
source "$myPath/Utils/functions.shinc"

# Parse cmdline args - we need ONE, the COSbench workload file
#[ $# -ne 1 ] && error_exit "runIOworkload.sh failed - wrong number of args"
#[ -z "$1" ] && error_exit "runIOworkload.sh failed - empty first arg"

# Create log file - named in vars.shinc
if [ ! -d $RESULTSDIR ]; then
  mkdir -p $RESULTSDIR || \
    error_exit "$LINENO: Unable to create RESULTSDIR."
fi
touch $LOGFILE || error_exit "$LINENO: Unable to create LOGFILE."
updatelog "${PROGNAME} - Created logfile: $LOGFILE" $LOGFILE

# log runtime env settings
print_Runtime $LOGFILE

# Record STARTING cluster capacity stats
if [[ $multisite == "true" ]]; then
    var1=`echo; $execMON ceph df|egrep 'USE|TOT|site'`
else
    var1=`echo; $execMON ceph df|egrep 'USE|TOT|def'`
fi
updatelog "$var1" $LOGFILE
# Record GC stats
get_pendingGC
echo -n "GC: " >> $LOGFILE
updatelog "Pending GC's == $pendingGC" $LOGFILE

if [[ $disabledeepscrubs == "true" ]]; then
    # disable deep-scrubbing
    updatelog "disabling OSD deep-scrubs" $LOGFILE
    ssh $MONhostname ceph osd set nodeep-scrub
    #ssh $MONhostname2 ceph osd set nodeep-scrub
fi

# Poll ceph statistics (in a bkrgd process) 
updatelog "START: poll backgrd process" $LOGFILE
Utils/poll.sh ${pollinterval} ${LOGFILE} &
PIDpoll=$!
# VERIFY it successfully started
sleep 2
if ! ps -p $PIDpoll > /dev/null; then
    error_exit "poll.sh FAILED. Exiting"
fi
updatelog "POLL backgrd processID $PIDpoll" $LOGFILE

if [[ $dataLogPolling == "true" ]]; then
    # Poll data log list at a greater poll interval
    updatelog "START: data log list backgrd poll" $LOGFILE
    dataloginterval=$(($pollinterval * $pollmultiplier))
    Utils/pollDataLog.sh ${dataloginterval} ${DATALOG} &
    dataLogPIDpoll=$!
    # VERIFY it successfully started
    sleep 2
    if ! ps -p $dataLogPIDpoll > /dev/null; then
        error_exit "pollDataLog.sh FAILED. Exiting"
    fi
    updatelog "data log POLL backgrd processID $dataLogPIDpoll" $LOGFILE
    updatelog "START: data log poll backgrd process" $DATALOG
fi

if [[ $bsV2Polling == "true" ]]; then
    # get pool details
    get_pooldetail
    echo -e "Pool Details (pre workload) \n ${pooldetails}" > $POOLDETAIL
    #updatelog "Pool Details (pre workload) ${pooldetails}" > $POOLDETAIL

    # snapshot PG dump
    ceph pg dump --format json-pretty &> $PGDUMPPRE

    # osd bluestore allocator score & block dump
    fsid=`ceph status |grep id: |awk '{print$2}'`
    for i in `cat ~/rgws.list` ; do
        osd=`ssh $i "ls -d /var/lib/ceph/${fsid}/osd.* |head -1|cut -d. -f2"`
        ceph tell osd.$osd bluestore allocator score bluefs-db >> /root/RGWtest/RESULTS/osd.${osd}_bsdump-pre_${ts}.log
        ceph tell osd.$osd bluestore allocator dump block >> /root/RGWtest/RESULTS/osd.${osd}_bsdump-pre_${ts}.log
    done

#    for i in `cat ~/rgws.list` ; do
#        fsid=`ceph status |grep id: |awk '{print$2}'`
#        osd=`ssh $i 'ls /var/lib/ceph/osd |head -1|cut -d\- -f2'`
#        ssh $i "ceph daemon osd.$osd bluestore allocator score bluefs-db ; ceph daemon osd.$osd bluestore allocator dump block" > /root/RGWtest/RESULTS/osd.${osd}_bsdumps-pre_${ts}.log
#    done

    # Poll BSV2 stats at a greater poll interval
    updatelog "START: BSV2 perf stat background poll" $LOGFILE
    bsv2loginterval=$(($pollinterval * $pollmultiplier))
#    Utils/pollbsv2stats.sh ${bsv2loginterval} ${ts} &
    Utils/pollbsv2stats.sh 585 ${ts} &
    bsv2LogPIDpoll=$!
    # VERIFY it successfully started
    sleep 2
    if ! ps -p $bsv2LogPIDpoll > /dev/null; then
        error_exit "pollbsv2stats.sh FAILED. Exiting"
    fi
    updatelog "bsv2 stat POLL background processID $bsv2LogPIDpoll" $LOGFILE
fi

# Run the Warp workload
jobID=`cat ./jobID`
updatelog "START: warp (${jobID}) launched" $LOGFILE
./Utils/warp.sh $operation $LOGFILE
#pbench-user-benchmark --config=warptest -- ./Utils/warp.sh $operation $LOGFILE
updatelog "FINISH: warp (${jobID}) completed" $LOGFILE

# Now kill off the POLL background process
kill $PIDpoll; kill $PIDpoll
updatelog "Stopped POLL bkgrd process" $LOGFILE

# Record ENDING cluster capacity stats
if [[ $multisite == "true" ]]; then
    var1=`echo; $execMON ceph df|egrep 'USE|TOT|site'`
else
    var1=`echo; $execMON ceph df|egrep 'USE|TOT|def'`
fi
updatelog "$var1" $LOGFILE

# log end Cgroup CPU number throttled (if containerized)
#if [ $runmode == "containerized" ]; then
#    nt_end=$(ssh $RGWhostname 'bash -s' < Utils/thr_time.sh)
#    updatelog "$nt_end" $LOGFILE
#fi

# Record GC stats
get_pendingGC
echo -n "GC: " >> $LOGFILE
updatelog "Pending GC's == $pendingGC" $LOGFILE

# append final bucket obj counts to log
get_bucketStats
echo -e "\nSite1 buckets (rgw):\n${site1bucketsrgw}" >> $LOGFILE
#for i in `seq 5` ; do echo -n bucket$i"  " >> $LOGFILE ; radosgw-admin bucket stats --bucket bucket1 |egrep '\''bucket"|num_objects' >> $LOGFILE ; done

if [[ $postPolling == "true" ]]; then
    #updatelog "Starting site2 RGWs for syncing" $LOGFILE
    #ssh $MONhostname2 "ansible -o -m shell -a 'systemctl start ceph-radosgw.target' rgws"
    # Poll post job ceph statistics (in a bkrgd process) 
    updatelog "START: post poll background process" $LOGFILE
#    Utils/postpoll.sh_datalog ${postpollinterval} ${LOGFILE} ${DATALOG} 
    Utils/postpoll.sh ${postpollinterval} ${LOGFILE}
#    PIDpostpoll=$!
#    # verify successfull start
#    sleep 2
#    if ! ps -p $PIDpostpoll > /dev/null; then
#        error_exit "postpoll.sh FAILED. Exiting"
#    fi
#    updatelog "POST POLL processID: $PIDpostpoll" $LOGFILE
#    # wait for postpoll.sh to complete
##    while ps -p $PIDpostpoll &>/dev/null; do sleep 1m ; done
#    sleep $postPollDur
#    # kill the POST POLL background process
#    kill $PIDpostpoll; kill $PIDpostpoll
    updatelog "End POST POLL process" $LOGFILE
fi

# if there's no post-polling, start & enable deep-scrubs
if [[ $disabledeepscrubs == "true" && $postPolling == "false" ]]; then
    # start manual deep-scrub of all PGs
    updatelog "start manual deep-scrubbing" $LOGFILE
    updatelog "start manual deep-scrubbing" $DATALOG
    if [[ $multisite == "true" ]]; then
        ssh $MONhostname 'for pool in site1.rgw.log site1.rgw.buckets.index ; do for pg in `ceph pg ls-by-pool $pool |grep , |cut -d" " -f1` ; do ceph pg deep-scrub $pg &> /dev/null ; done ; done'
    else
        ssh $MONhostname 'for pool in default.rgw.log default.rgw.buckets.index ; do for pg in `ceph pg ls-by-pool $pool |grep , |cut -d" " -f1` ; do ceph pg deep-scrub $pg &> /dev/null ; done ; done'
    fi
    # enable deep-scrubbing
    updatelog "enabling deep-scrubs" $LOGFILE
    updatelog "enabling deep-scrubs" $DATALOG
    ssh $MONhostname ceph osd unset nodeep-scrub
#    ssh $MONhostname2 ceph osd unset nodeep-scrub
fi

###################
# OPTIONAL: waits for number of pending GCs to reach 1
# Utils/completedGC.sh "${pollinterval}" "${LOGFILE}"
# Record FINAL cluster capacity stats
#var1=`echo; $execMON ceph df | head -n 5`
#var2=`echo; $execMON ceph df | grep rgw.buckets.data`
#updatelog "$var1 $var2" $LOGFILE
###################

if [[ $bsV2Polling == "true" ]]; then
    # kill the BSV2 perf stat POLL background process
    updatelog "STOP: BSV2 perf stat background poll" $LOGFINAL
    kill $bsv2LogPIDpoll; kill $bsv2LogPIDpoll

    # post snapshot PG dump
    ceph pg dump --format json-pretty &> $PGDUMPPOST

    # osd bluestore allocator score & block dump
    for i in `cat ~/rgws.list` ; do     # pacific
        osd=`ssh $i "ls -d /var/lib/ceph/${fsid}/osd.* |head -1|cut -d. -f2"`
        ceph tell osd.$osd bluestore allocator score bluefs-db >> /root/RGWtest/RESULTS/osd.${osd}_bsdump-post_${ts}.log
        ceph tell osd.$osd bluestore allocator dump block >> /root/RGWtest/RESULTS/osd.${osd}_bsdump-post_${ts}.log
    done

#    for i in `cat ~/rgws.list` ; do  # nautilus
#        osd=`ssh $i 'ls /var/lib/ceph/osd |head -1|cut -d\- -f2'`
#        ssh $i "ceph daemon osd.$osd bluestore allocator score bluefs-db ; ceph daemon osd.$osd bluestore allocator dump block" > /root/RGWtest/RESULTS/osd.${osd}_bsdumps-post_${ts}.log
#    done

    # rename logs to prepend jobId
#    PGDUMPPRE2="${RESULTSDIR}/${jobId}_pgdump-pre_${ts}.log"
#    PGDUMPPOST2="${RESULTSDIR}/${jobId}_pgdump-post_${ts}.log"
#    POOLDETAIL2="${RESULTSDIR}/${jobId}_poolDetails_${ts}.log"
#    mv $PGDUMPPRE $PGDUMPPRE2
#    mv $PGDUMPPOST $PGDUMPPOST2
#    mv $POOLDETAIL $POOLDETAIL2
fi

# END
