#!/bin/bash
#
# description: BROKER server
#
# Start the service BROKER
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"
source ./config/.env.bash

mkdir -p logs
touch $LOGFILE

start() {
        rackup=`which rackup`
        cd $ROOT
        if (pgrep -f $ROOT/config.ru 1>/dev/null) ; then
            echo "Broker is already running!"
            exit 1
        else
            echo "Starting Broker server"
            $rackup  -o $IP -p $PORT $ROOT/config.ru >> $LOGFILE 2>&1 &
        fi
}

# Restart the service BROKER
stop() {
        echo "Stopping BROKER server "
        pkill -f  $ROOT/config.ru
        echo
        sleep 1
}
### main logic ###
case "$1" in
  start)
        start
        ;;
  stop)
        stop
        ;;
  status)
        status BROKER
        ;;
  restart|reload|condrestart)
        stop
        start
        ;;
  *)
        echo $"Usage: $0 {start|stop|restart|reload|status}"
        exit 1
esac
exit 0