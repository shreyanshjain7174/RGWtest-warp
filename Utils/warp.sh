#!/bin/bash
EXPECTED_ARGS=2
if [ $# -eq $EXPECTED_ARGS ] ; then
  operation=$1
  log=$2
else
  echo "Usage: $(basename $0) {fill,hybrid-new,hybrid-48hr,hybrid-aged,delwrite} <logfile>"
  exit 1
fi

# Bring in other script files
myPath="${BASH_SOURCE%/*}"
if [[ ! -d "$myPath" ]]; then
    myPath="$PWD"
fi

# Variables
source "$myPath/../vars.shinc"

# Functions
source "$myPath/../Utils/functions.shinc"

# timestamp for output files
ts=`date +'%y%m%d-%H%M'`
tmplog=/tmp/${ts}_warp.out

# Start warp clients 
updatelog "Starting warp clients" $log
for driver in $drivers ; do
   ssh $driver "bash -s" < $myPath/../Utils/start-clients.sh ${numCONT} ${clientsubnet}
done
sleep 10

# Execute warp job
case $operation in
    fill)

        echo -e "\nWarp commands:\n-----------------" > $tmplog
        if [ $servermode == "distributed" ]; then
            # distribute the ${numCONT} server jobs across the drivers
            i=1
            for driver in $drivers ; do
                if [ $i -le $numCONT ] ; then  #  limit warp servers to desired bucket count
                    echo -e "\nwarp put --obj.size ${minobjsize},${maxobjsize} --duration=$fillduration --concurrent=$concurrent --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out" >> $tmplog
                    ssh $driver warp put --obj.size "${minobjsize},${maxobjsize}" --duration=$fillduration --concurrent=$concurrent --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out &
                    i=$(($i+1))
                fi
            done
    	    # watch NFS mount for distributed jobs to complete
            i=1
            for driver in $drivers ; do
                if [ $i -le $numCONT ] ; then  #  limit warp watchers to desired bucket count
                    ssh $driver "bash -s" < $myPath/../Utils/warp-watcher.sh &
                    i=$(($i+1))
                fi
            done
            sleep 10

           # wait for warp jobs to finish
            while [[ `ls ${nfspath}/warp-* |wc -l` != ${numCONT} ]] ; do sleep 61 ; done &>/dev/null

	elif [ $servermode == "local" ]; then
	    # execute all $numCONT server jobs locally
            for i in `seq ${numCONT}` ; do
                echo -e "\nwarp put --obj.size ${minobjsize},${maxobjsize} --duration=$fillduration --concurrent=$concurrent --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out" >> $tmplog
                warp put --obj.size "${minobjsize},${maxobjsize}" --duration=$fillduration --concurrent=$concurrent --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out &
            done
    
            # wait for warp jobs to finish
            sleep 10
            while [[ `pgrep -a warp |grep -v "client " |grep -v warp.sh` ]] ; do sleep 30 ; done
            sleep 1m
	else
	    echo "Invalid servermode provided, exit..."
	fi

	if [ $postAnalysis == "true" ]; then
            # analyze *.zst files and add results of each run to log
            for i in `seq ${numCONT}` ; do
		warp analyze ${ts}_${operation}-${i}.csv.zst --no-color > ${ts}_warp${i}.out
	    done
	fi
        # add the existing results of each run to log
        echo "" >> $tmplog
        for i in `seq ${numCONT}` ; do
            echo -e "-----------------------\nBucket${i}" >> $tmplog
            grep -A2 PUT ${ts}_warp${i}.out  >> $tmplog
 	    toterr=`grep "Total Errors:" ${ts}_warp${i}.out | cut -d: -f2 |cut -d. -f1 |awk '{sum+=$1};END{print sum}'`
            echo "Total Errors: $toterr " >> $tmplog
        done

        # aggregate the individual run totals and append to log
        echo -e "\n==============================\nOperation Totals:" >> $tmplog
        grep "* Average" $tmplog | awk 'BEGIN {printf("%s","PUT: ")}{sum+=$3;sum1+=$5}END{print sum" "$4sum1" "$6}' >> $tmplog
        grep "Total Errors:" $tmplog | awk 'BEGIN {printf("%s","ERRORS: ")}{sum+=$3}END{print sum" "$4}' >> $tmplog
        echo -e "==============================\n" >> $tmplog
        cat $tmplog >> $log
        ;;

    hybrid-new|hybrid-aged)

        echo -e "\nWarp commands:\n-----------------" > $tmplog

        if [ $servermode == "distributed" ]; then
	    # distribute the ${numCONT} server jobs across the drivers
            i=1
            for driver in $drivers ; do
                if [ $i -le ${numCONT} ] ; then  #  limit warp servers to desired bucket count
                    if [ $i -le 3 ] ; then  # the first 3 drivers will do puts & deletes
                        echo -e "\nwarp mixed --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size "${minobjsize},${maxobjsize}" --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out" >> $tmplog
                        ssh $driver warp mixed --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size "${minobjsize},${maxobjsize}" --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out &
                    else	# the remaining drivers will do gets & stats
                        echo -e "\nwarp mixed --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size ${minobjsize},${maxobjsize} --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out" >> $tmplog
                        ssh $driver warp mixed --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size "${minobjsize},${maxobjsize}" --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp${i}.out &
                    fi
                    i=$(($i+1))
	        fi
	    done
            # wait for distributed warp jobs to finish
            i=1
            for driver in $drivers ; do
                if [ $i -le $numCONT ] ; then  #  limit warp watchers to desired bucket count
                    ssh $driver "bash -s" < $myPath/../Utils/warp-watcher.sh &
                    i=$(($i+1))
                fi
            done
            # for distributed server jobs, use NFS mount for completion confirmation
            while [[ `ls ${nfspath}/warp-* |wc -l` != ${numCONT} ]] ; do sleep 1m ; done &>/dev/null

	elif [ $servermode == "local" ]; then
            # execute all $numCONT server jobs locally
            for i in `seq ${numCONT}` ; do
                if [ $i -le 3 ] ; then  # the first 3 jobs will do puts & deletes
                    echo -e "\nwarp mixed --obj.size ${minobjsize},${maxobjsize} --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp${i}.out" >> $tmplog
                    warp mixed --obj.size "${minobjsize},${maxobjsize}" --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp${i}.out &
                else        # the remaining jobs will do gets & stats
                    echo -e "\nwarp mixed --obj.size ${minobjsize},${maxobjsize} --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp${i}.out" >> $tmplog
                    warp mixed --obj.size "${minobjsize},${maxobjsize}" --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp${i}.out &
                fi
            done
    
            # wait for warp jobs to finish
            sleep 10
            while [[ `pgrep -a warp |grep -v "client " |grep -v warp.sh` ]] ; do sleep 30 ; done
            sleep 1m

	else
	    echo "Invalid servermode provided, exit..."
	fi

	if [ $postAnalysis == "true" ]; then
            # analyze *.zst files and add results of each run to log
            for i in `seq ${numCONT}` ; do
		warp analyze ${ts}_${operation}-${i}.csv.zst --no-color > ${ts}_${operation}-warp${i}.out
	    done
	fi
        # add the existing results of each run to log
        echo "" >> $tmplog
        for i in `seq ${numCONT}` ; do
            echo -e "-----------------------\nBucket${i}" >> $tmplog
            if [ $i -le 3 ] ; then  # the first 3 buckets have puts & deletes
                grep -A2 PUT ${ts}_${operation}-warp${i}.out >> $tmplog
                grep -A2 DELETE ${ts}_${operation}-warp${i}.out >> $tmplog
            else    # the remaining buckets have gets & stats
                grep -A2 GET ${ts}_${operation}-warp${i}.out >> $tmplog
                grep -A2 STAT ${ts}_${operation}-warp${i}.out >> $tmplog
            fi
            toterr=`grep "Total Errors:" ${ts}_${operation}-warp${i}.out | cut -d: -f2 |cut -d. -f1 |awk '{sum+=$1};END{print sum}'`
            echo "Total Errors: $toterr " >> $tmplog
        done

        # aggregate the individual run totals and append to log
        echo -e "\n==============================\nOperation Totals:" >> $tmplog
        grep -A2 PUT $tmplog | grep Thro | awk 'BEGIN {printf("%s","PUT: ")}{sum+=$3;sum1+=$5}END{print sum" "$4sum1" "$6}' >> $tmplog
        grep -A2 DELETE $tmplog |grep Thro | awk 'BEGIN {printf("%s","DELETE: ")}{sum+=$3}END{print sum" "$4}' >> $tmplog
        grep -A2 GET $tmplog | grep Thro | awk 'BEGIN {printf("%s", "GET: ")}{sum+=$3;sum1+=$5}END{print sum" "$4sum1" "$6}' >> $tmplog
        grep -A2 STAT $tmplog | grep Thro | awk 'BEGIN {printf("%s","STAT: ")}{sum+=$3}END{print sum" "$4}' >> $tmplog
        grep "Total Errors:" $tmplog | awk 'BEGIN {printf("%s","ERRORS: ")}{sum+=$3}END{print sum" "$4}' >> $tmplog
	echo -e "==============================\n" >> $tmplog
        cat $tmplog >> $log
        ;;

    hybrid-48hr)

        echo -e "\nWarp commands:\n-----------------" > $tmplog

	for job in `seq ${agingHours}` ; do 
	    if [ $servermode == "distributed" ]; then
	        # distribute the ${numCONT} server jobs across the drivers
                i=1
                for driver in $drivers ; do
                    if [ $i -le ${numCONT} ] ; then  #  limit warp servers to desired bucket count
                        if [ $i -le 3 ] ; then  # the first 3 drivers will do puts & deletes
                            echo -e "\nwarp mixed --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size ${minobjsize},${maxobjsize} --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp-${job}-${i}.out" >> $tmplog
                            ssh $driver warp mixed --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size "${minobjsize},${maxobjsize}" --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp-${job}-${i}.out &
                        else	# the remaining drivers will do gets & stats
                            echo -e "\nwarp mixed --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size ${minobjsize},${maxobjsize} --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp-${job}-${i}.out" >> $tmplog
                            ssh $driver warp mixed --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.size "${minobjsize},${maxobjsize}" --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_warp-${job}-${i}.out &
                        fi
                        i=$(($i+1))
                    fi
                done
    	        # watch NFS mount for distributed jobs to complete
                i=1
                for driver in $drivers ; do
                    if [ $i -le $numCONT ] ; then  #  limit warp watchers to desired bucket count
                        ssh $driver "bash -s" < $myPath/../Utils/warp-watcher.sh &
                        i=$(($i+1))
                    fi
                done
                sleep 10
    
               # wait for warp jobs to finish
                while [[ `ls ${nfspath}/warp-* |wc -l` != ${numCONT} ]] ; do sleep 61 ; done &>/dev/null
    
	    elif [ $servermode == "local" ]; then
                # execute all $numCONT server jobs locally
                for i in `seq ${numCONT}` ; do
                    if [ $i -le 3 ] ; then  # the first 3 jobs will do puts & deletes
                        echo -e "\nwarp mixed --obj.size ${minobjsize},${maxobjsize} --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out" >> $tmplog
                        warp mixed --obj.size "${minobjsize},${maxobjsize}" --duration=$testduration --concurrent=$concurrent --put-distrib $putdist --delete-distrib $deletedist --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out &
                    else        # the remaining jobs will do gets & stats
                        echo -e "\nwarp mixed --obj.size ${minobjsize},${maxobjsize} --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out" >> $tmplog
                        warp mixed --obj.size "${minobjsize},${maxobjsize}" --duration=$testduration --concurrent=$concurrent --put-distrib 0 --delete-distrib 0 --get-distrib $getdist --stat-distrib $statdist --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out &
                    fi
                done
    
                # wait for warp jobs to finish
                sleep 10
                while [[ `pgrep -a warp |grep -v "client " |grep -v warp.sh` ]] ; do sleep 30 ; done
                sleep 1m
	    else
	        echo "Invalid servermode provided, exit..."
	    fi
        done
    
	if [ $postAnalysis == "true" ]; then
            # analyze *.zst files and add results of each run to log
	    for job in `seq ${agingHours}` ; do
                for i in `seq ${numCONT}` ; do
		    warp analyze ${ts}_${operation}-${job}-${i}.csv.zst --no-color > ${ts}_${operation}-warp-${job}-${i}.out
	        done
	    done
	fi

        # add the output of each run to log
        echo "" >> $tmplog
	for job in `seq ${agingHours}` ; do
            for i in `seq ${numCONT}` ; do
                echo -e "-----------------------\nRun ${job} Bucket${i}" >> $tmplog
                if [ $i -le 3 ] ; then  # the first 3 buckets have puts & deletes
                    grep -A2 PUT ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                    grep -A2 DELETE ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                else    # the remaining buckets have gets & stats
                    grep -A2 GET ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                    grep -A2 STAT ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                fi
                toterr=`grep "Total Errors:" $i | cut -d: -f2 |cut -d. -f1 |awk '{sum+=$1};END{print sum}'`
                echo "Total Errors: $toterr " >> $tmplog
            done
        done

        # aggregate the individual run totals and append to log
        echo -e "\n==============================\nOperation Totals:" >> $tmplog
	grep -A2 PUT $tmplog | grep Thro | awk -v divisor="$agingHours" 'BEGIN {printf("PUT: ")} {sum+=$3;sum1+=$5} END{print sum/divisor" "sum1/divisor" "$6}' >> $tmplog
        grep -A2 DELETE $tmplog |grep Thro | awk -v divisor="$agingHours" 'BEGIN {printf("%s","DELETE: ")}{sum+=$3}END{print sum/divisor" "$4}' >> $tmplog
	grep -A2 GET $tmplog | grep Thro | awk -v divisor="$agingHours" 'BEGIN {printf("GET: ")} {sum+=$3;sum1+=$5} END{print sum/divisor" "sum1/divisor" "$6}' >> $tmplog
	grep -A2 STAT $tmplog | grep Thro | awk -v divisor="$agingHours" 'BEGIN {printf("STAT: ")} {sum+=$3;sum1+=$5} END{print sum/divisor" "sum1/divisor" "$6}' >> $tmplog
        grep "Total Errors:" $tmplog | awk 'BEGIN {printf("%s","ERRORS: ")}{sum+=$3}END{print sum" "$4}' >> $tmplog
	echo -e "==============================\n" >> $tmplog
        cat $tmplog >> $log
        ;;

    delwrite)

        echo -e "\nWarp commands:\n-----------------" > $tmplog
	for job in `seq ${delWriteHours}` ; do 
	    if [ $servermode == "distributed" ]; then
	        # distribute the ${numCONT} server jobs across the drivers
                i=1
                for driver in $drivers ; do
                    if [ $i -le ${numCONT} ] ; then  #  limit warp servers to desired bucket count
                        echo -e "\nwarp mixed --duration=120m0s --concurrent=$concurrent --obj.size ${minobjsize},${maxobjsize} --put-distrib 80 --delete-distrib 20 --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out" >> $tmplog
                        ssh $driver warp mixed --duration=120m0s --concurrent=$concurrent --obj.size "${minobjsize},${maxobjsize}" --put-distrib 80 --delete-distrib 20 --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out &
                        i=$(($i+1))
                    fi
                done
    	        # watch NFS mount for distributed jobs to complete
                i=1
                for driver in $drivers ; do
                    if [ $i -le $numCONT ] ; then  #  limit warp watchers to desired bucket count
                        ssh $driver "bash -s" < $myPath/../Utils/warp-watcher.sh &
                        i=$(($i+1))
                    fi
                done
                sleep 10
    
               # wait for warp jobs to finish
                while [[ `ls ${nfspath}/warp-* |wc -l` != ${numCONT} ]] ; do sleep 61 ; done &>/dev/null
    
	    elif [ $servermode == "local" ]; then
                # execute all $numCONT server jobs locally
                for i in `seq ${numCONT}` ; do
                    echo -e "\nwarp mixed --obj.size ${minobjsize},${maxobjsize} --duration=$testduration --concurrent=$concurrent --put-distrib 80 --delete-distrib 20 --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out" >> $tmplog
                    warp mixed --obj.size "${minobjsize},${maxobjsize}" --duration=$testduration --concurrent=$concurrent --put-distrib 80 --delete-distrib 20 --get-distrib 0 --stat-distrib 0 --warp-client=${warpClients[$(($i-1))]} --host=$warpHosts --access-key=$access --secret-key=$secret --obj.randsize --bucket bucket${i} --benchdata ${ts}_${operation}-${job}-${i} --host-select=$hostSelect --noclear --no-color --debug &> ${ts}_${operation}-warp-${job}-${i}.out &
                done
    
                # wait for warp jobs to finish
                sleep 10
                while [[ `pgrep -a warp |grep -v "client " |grep -v warp.sh` ]] ; do sleep 30 ; done
                sleep 1m
	    else
	        echo "Invalid servermode provided, exit..."
	    fi
	done

	if [ $postAnalysis == "true" ]; then
            # analyze *.zst files and add results of each run to log
	    for job in `seq ${delWriteHours}` ; do
                for i in `seq ${numCONT}` ; do
		    warp analyze ${ts}_${operation}-${job}-${i}.csv.zst --no-color > ${ts}_${operation}-warp-${job}-${i}.out
	        done
	    done
	fi
        # add the existing results of each run to log
        echo "" >> $tmplog
	for job in `seq ${delWriteHours}` ; do
            for i in `seq ${numCONT}` ; do
                echo -e "-----------------------\nRun ${job} Bucket${i}" >> $tmplog
                grep -A2 PUT ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                grep -A2 DELETE ${ts}_${operation}-warp-${job}-${i}.out >> $tmplog
                toterr=`grep "Total Errors:" ${ts}_${operation}-warp-${job}-${i}.out | cut -d: -f2 |cut -d. -f1 |awk '{sum+=$1};END{print sum}'`
                echo "Total Errors: $toterr " >> $tmplog
                i=$(($i+1))
            done
        done

        # aggregate the individual run totals and append to log
        echo -e "\n==============================\nOperation Totals:" >> $tmplog
	grep -A2 PUT $tmplog | grep Thro | awk -v divisor="$delWriteHours" 'BEGIN {printf("PUT: ")} {sum+=$3;sum1+=$5} END{print sum/divisor" "sum1/divisor" "$6}' >> $tmplog
        grep -A2 DELETE $tmplog |grep Thro | awk -v divisor="$delWriteHours" 'BEGIN {printf("%s","DELETE: ")}{sum+=$3}END{print sum/divisor" "$4}' >> $tmplog
        echo -e "==============================\n" >> $tmplog
        cat $tmplog >> $log
        ;;

    *)
        echo "Invalid warp operation provided, exit..."
        ;;
esac

# Stop warp clients
ansible drivers -m command -a "pkill warp"
