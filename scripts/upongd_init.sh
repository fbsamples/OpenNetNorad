#!/bin/sh

# Copyright (c) 2017-present, Facebook, Inc.
# All rights reserved.

# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

### BEGIN INIT INFO
# Provides:          upongdaemon
# Required-Start:    $local_fs $network $syslog
# Required-Stop:     $local_fs $network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Upong daemon
# Description:       Upong start-stop-daemon - Debian
### END INIT INFO

NAME="upongd"
PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
APPDIR="/tmp"
LOG_SERVER="192.168.1.125"
REGION="MY_PONG_REGION"
CLUSTER="MY_PONG_CLUSTER"
RACK="MY_PONG_RACK"
REGISTER_START="/usr/bin/wget -O - --post-data=region=$REGION&cluster=$CLUSTER&rack=$RACK http://$LOG_SERVER:5000/servers/create"
REGISTER_STOP="/usr/bin/wget -O - --post-data=is_active=0 http://$LOG_SERVER:5000/servers/update"
APPBIN="/usr/local/bin/upong"
USER="root"
GROUP="root"

# Include functions
set -e
. /lib/lsb/init-functions

start() {
  printf "Starting '$NAME'... "
  echo $REGISTER_START
  REG_RES=`$REGISTER_START`
  start-stop-daemon --start --chuid "$USER:$GROUP" --background --make-pidfile --pidfile /var/run/$NAME.pid --chdir "$APPDIR" --exec "$APPBIN" -- "" || true
  printf "done\n"
}

#We need this function to ensure the whole process tree will be killed
killtree() {
    local _pid=$1
    local _sig=${2-TERM}
    for _child in $(ps -o pid --no-headers --ppid ${_pid}); do
        killtree ${_child} ${_sig}
    done
    kill -${_sig} ${_pid}
}

stop() {
  printf "Stopping '$NAME'... "
  UNREG_RES=`$REGISTER_STOP`
  [ -z `cat /var/run/$NAME.pid 2>/dev/null` ] || \
  while test -d /proc/$(cat /var/run/$NAME.pid); do
    killtree $(cat /var/run/$NAME.pid) 15
    sleep 0.5
  done
  [ -z `cat /var/run/$NAME.pid 2>/dev/null` ] || rm /var/run/$NAME.pid
  printf "done\n"
}

status() {
  status_of_proc -p /var/run/$NAME.pid "" $NAME && exit 0 || exit $?
}

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $NAME {start|stop|restart|status}" >&2
    exit 1
    ;;
esac

exit 0
