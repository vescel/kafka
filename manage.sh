#!/bin/bash

if [[ -z ${CONSUL} ]]; then
  fatal "Missing CONSUL environment variable"
  exit 1
fi

zkAddrs() {
  CONFIGDIR="/opt/kafka/config/"
  $(consul-template -consul $CONSUL:8500 -template "${CONFIGDIR}zkconnect.ctmpl:${CONFIGDIR}zkconnect.txt" -once)
  ADDR_PORT="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\:[0-9]+\:[0-9]+"
  export ZKADDRS=$(grep -E -o $ADDR_PORT ${CONFIGDIR}zkconnect.txt | awk -F":" '{print $1":2181"}' | paste -s -d, -)
}

brokerId() {
    # if myid file exists, load it
    if [ -e $BROKDERIDFILE ]; then
        echo "${BROKDERIDFILE} exists..."
        export KAFKAID=$(<$BROKDERIDFILE)

    # else calculate it based on kafkakid value stored in consul
    else
        echo "KAFKAID has not been set..."
        # get session with consul
        CONSUL_SESSION=$(curl -s -X PUT http://{$CONSUL}:8500/v1/session/create  | jq .ID | tr -d '"')

        # lock on kafka/countlock
        LOCK=$(curl -s -X PUT -d "locked" http://${CONSUL}:8500/v1/kv/kafka/countlock?acquire=${CONSUL_SESSION})

        if [ "$LOCK" = false ]; then  
          echo "kafkaid owned by another, waiting for countlock..."
          while [ "$LOCK" = false ]; do
            sleep 1
            LOCK=$(curl -s -X PUT -d "locked" http://${CONSUL}:8500/v1/kv/kafka/countlock?acquire=${CONSUL_SESSION})
          done
        fi
        echo "countlock retained..."

        # get current value of kafkaid key
        export KAFKAID=$(curl -s -X GET http://{$CONSUL}:8500/v1/kv/kafka/kafkaid?raw)
        if [ -z "$KAFKAID" ]; then
            # zero, so no keys, first server up
            export KAFKAID=1
        else
            # take the next server id
            export KAFKAID=$((KAFKAID+1))
        fi
        
        # attempt to PUT our KAFKAID into consul with our session          
        echo "KAFKAID:$KAFKAID, LOCK:$LOCK CONSUL_SESSION:$CONSUL_SESSION"
        curl -s -X PUT -d $KAFKAID http://${CONSUL}:8500/v1/kv/kafka/kafkaid
        
        # release countlock
        curl -s -X PUT -d "unlocked" http://${CONSUL}:8500/v1/kv/kafka/countlock?release=$CONSUL_SESSION
        echo "${KAFKAID}" > $BROKDERIDFILE
    fi
    echo "KAFKAID is set to:${KAFKAID}"
}

generateConfig() {
  debug "Generating config"

  #generate broker id, put it into CONFIGWITHID
  if [ ! -e $CONFIGWITHBID ]; then
    brokerId
    # sleep $KAFKAID
    search='%%KAFKAID%%'
    sed  "s/${search}/${KAFKAID}/g"  /opt/kafka/config/default.server.properties > $CONFIGWITHBID
  fi

  # update the advertised.listener 
  search='%%ADVERTISEDLISTENER%%' 
  sed -i "s/%%ADVERTISEDLISTENER%%/${IP_ADDRESS}:9092/g" $CONFIGWITHBID

  # generate list of addrs, put them into config
  zkAddrs

  # generate the configuration file 
  search='%%ZKADDRS%%'
  sed  "s/${search}/${ZKADDRS}/g"  $CONFIGWITHBID > $CONFIGFILE

  debug "----------------- Configuration -----------------"
  debug $(cat $CONFIGFILE)
  debug "-----------------------------------------------------"
}

reload() {
  current_config=$(cat $CONFIGFILE)

  generateConfig

  new_config=$(cat $CONFIGFILE)

  if [ "$current_config" != "$new_config" ]; then
    info "******* Rebooting kafka *******"
    debug "******* myid:$(cat $KAFKAPIDFILE) ******* "

    if [ -f $KAFKAPIDFILE ]; then
      kill -SIGTERM $(cat $KAFKAPIDFILE)
    fi
  else
    debug "Configs are identical. No need to reload."
  fi
}

health() {
  set -euo pipefail

  TOPIC_LIST="vdb-logs vdb-service-start vdb-service-stop vdb-service-terminate vdb-docker-events vdb-service-events"

  echo "Checking topic list..."
  zkAddrs
  list=$(bin/kafka-topics.sh --zookeeper $ZKADDRS --list)
  echo "Checking topic list : $list"
  for topic in $TOPIC_LIST
  do
    if [[ $list =~ ^.*$topic ]]; then
      echo "$topic exists"
    else
      echo "Creating topic $topic..."
      bin/kafka-topics.sh --zookeeper $ZKADDRS --create --partitions=1 --replication-factor=1 --topic $topic
      echo "Creating topic $topic Done"
    fi
  done
  #touch /tmp/kafka-topics

}

start() {
  info "Bootstrapping kafka..."
  generateConfig

  # kafka doesn't have a hot-reload mechanism.
  # This hackery allows us to restart kafka without killing the container.
  # The `/bin/manage.sh reload` function will kill kafka if it detects new configuration.
  while true; do

    # check if zookeeper is already running
    pid=$(pgrep 'java')

    # If it's not running then start it
    if [ -z "$pid" ]; then

      info "******* Starting kafka *******"

      exec /opt/kafka/bin/kafka-server-start.sh ${CONFIGFILE}
      sleep 3s
      echo $(pgrep 'java') > $KAFKAPIDFILE

      exitcode=$?
      if [ $exitcode -gt 0 ]; then
        exit $exitcode
      fi
    fi

    sleep 1s
  done
}

cleanup() {
  # decrement kafkaid key by 1 if it is greater > 0
  KAFKAID=$(curl -s -X GET http://{$CONSUL}:8500/v1/kv/kafka/kafkaid?raw)
  if [ ! -z "$KAFKAID" ]; then
      # non-zero value or null, so decrement
      KAFKAID=$((KAFKAID-1))
      if [ "$KAFKAID" -gt "0" ] ]; then
        curl -s -X PUT -d ${KAFKAID} http://${CONSUL}:8500/v1/kv/kafka/kafkaid
      fi
  fi
}

debug() {
  if [ ! -z "$DEBUG" ]; then
    echo "=======> DEBUG: $@"
  fi
}

info() {
  echo "=======> INFO: $@"
}

fatal() {
  echo "=======> FATAL: $@"
}

# make variables available for all processes/sub-processes called from manage
# get my external (within the datacenter....) IP_ADDRESS
export IP_ADDRESS=$(ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
export CONFIGWITHBID="/opt/kafka/config/server.withbid.properties"
export CONFIGFILE="/opt/kafka/config/server.properties"
export KAFKAPIDFILE="/opt/kafka/server.pid"
export BROKDERIDFILE="/opt/zookeeper/brokerid"


export DEBUG=true

# do whatever the arg is
$1