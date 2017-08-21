#!/bin/bash

# Copyright (c) 2017-present, Facebook, Inc.
# All rights reserved.

# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

# This is the pinger script. This will:
#	-Ensure uping can run in the env
#	-Parse options
#	-Retrieve Targets from Controller
#	-Ping with uping
#	-Process results
#	-Send results to TS DB

# HOW TO CALL ON CRONTAB
# */1 * * * * root /etc/OpenNetNorad/udppinger_collect_telegraf.sh -m 192.168.1.125 -l 192.168.1.125 -s 192.168.1.194 -c 'MY_CLUSTER_NAME' -r 'MY_RACK_NAME'

# Mandatory fields:
# -m master server to get the hosts
# -l log server to register the output of the pinger
# -src the ip that originates this ping (current machine making the ping)

# Needed by uping
ulimit -n 50000

# test getopt so we can use it later to parse options
getopt --test > /dev/null
if [[ $? -ne 4 ]]; then
    echo "I’m sorry, `getopt --test` failed in this environment."
    exit 1
fi

# Determine if the short or long option names were used
SHORT=m:,s:,l:,c:,r:,e:,
LONG=master:,src:,log:,cluster:,rack:,region:,

# Temporarily store output to be able to check for errors
# Activate advanced mode getopt quoting e.g. via “--options”
# Pass arguments only via   -- "$@"   to separate them correctly

PARSED=$(getopt --options $SHORT --longoptions $LONG --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    # e.g. $? == 1
    #  then getopt has complained about wrong arguments to stdout
    exit 2
fi

# use eval with "$PARSED" to properly handle the quoting
eval set -- "$PARSED"

# now enjoy the options in order and nicely split until we see --
while true; do
    case "$1" in
        -m|--master)
            master="$2"
            shift 2
            ;;
        -s|--src)
            src="$2"
            shift 2
            ;;
        -l|--log)
            log="$2"
            shift 2
            ;;
        -c|--cluster)
            cluster="$2"
            shift 2
            ;;
        -r|--rack)
            rack="$2"
            shift 2
            ;;
        -e|--region)
            region="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Programming error"
            exit 3
            ;;
    esac
done

# Check mandotory parameters are in
if [[ -z "${master// }" ]]; then
	echo "$0: The -m parameter is mandatory."
	echo "$0: You need to specify at least one single ipv4 master server ex: '-m 10.0.0.2'."
    exit 1
fi

if [[ -z "${log// }" ]]; then
    echo "$0: The -l / --log parameter is mandatory."
    echo "$0: You need to specify at least one single ipv4 log server ex: '-l 10.0.0.2' to record the ping result."
    exit 1
fi

if [[ -z "${region// }" ]]; then
    echo "$0: The -e / --region parameter is mandatory."
    echo "$0: You need to specify a region value for this Pinger instance."
    exit 1
fi

if [[ -z "${cluster// }" ]]; then
    echo "$0: The -c / --cluster parameter is mandatory."
    echo "$0: You need to specify a cluster value for this Pinger instance."
    exit 1
fi

if [[ -z "${rack// }" ]]; then
    echo "$0: The -r / --rack parameter is mandatory."
    echo "$0: You need to specify a rack value for this Pinger instance."
    exit 1
fi

# If the src IP isn't specific, retrieve it from ifconfig
if [[ -z "${src// }" ]]; then
	SRC_IP=$(ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p' | awk '{print$1; exit}')
else
	SRC_IP=$src
fi

# Connect to the controller for the targets
export PYTHONIOENCODING=utf8
HOSTS=`curl -s "http://$master:5000/" | python3 -c "import sys, json; hosts = ['{},{},{},{}'.format(i['host'],i['rack'],i['cluster'],i['region']) for i in json.load(sys.stdin)['json_list']]; print ('\n'.join(hosts));"`

# Check if controller provided targets
if [[ -z "${HOSTS// }" ]]; then
    echo "$0: There is no host registered at $master to ping."
    exit 1
fi

# Lets ping the targets received from the controller
for host in $HOSTS
do
    OUT=$(mktemp /tmp/output.XXXXXXXXXX) || { echo "Failed to create temp file"; exit 1; }
    IP_OUT=`echo $host | cut -d, -f1`
    RACK_OUT=`echo $host | cut -d, -f2`
    CLUSTER_OUT=`echo $host | cut -d, -f3`
    REGION_OUT=`echo $host | cut -d, -f4`
    echo "$IP_OUT" >> $OUT
    echo "Using target '$IP_OUT' in temp file: $OUT"

    UPING_RES=$(uping -srcIpv4 $SRC_IP -output_csv=true -target_file=$OUT)
    OUT_RES=$(mktemp /tmp/output.XXXXXXXXXX) || { echo "Failed to create temp file"; exit 1; }
    echo "$UPING_RES" >> $OUT_RES
    echo "Using temp file for uping: $OUT_RES"

    # Process results and post to TS DB
    PYTHON_PARSER_SRC=$(echo -e "import json, time; inp = '$OUT_RES'; post_msg = 'uping,host_pong={},host_ping={},region_pong={},region_ping={},cluster_pong={},cluster_ping={},rack_pong={},rack_ping={} rrt50={},loss_ratio={} {}'; epoch_ns = int(time.time()) * 1000000000; data = open(inp); dat = data.read(); content = dat.splitlines(); content = [x.strip() for x in content];\nif len(content) <= 0 or not content[0].strip():\n\taddress = '$IP_OUT';\n\tprint(post_msg.format(address, '$SRC_IP', '$REGION_OUT', '$region', '$CLUSTER_OUT', '$cluster', '$RACK_OUT', '$rack', float(-1), float(-1), epoch_ns));\n\texit();\naddress, rttP50, loss_ratio = content[0].split(','); print(post_msg.format(address, '$SRC_IP', '$REGION_OUT', '$region', '$CLUSTER_OUT', '$cluster', '$RACK_OUT', '$rack', float(rttP50), float(loss_ratio), epoch_ns));")
    POST_MSG=$(python3 -c "$PYTHON_PARSER_SRC")
    curl -i -XPOST "http://$log:8186/write" --data-binary "$POST_MSG"
    rm $OUT $OUT_RES
done
