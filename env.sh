#!/bin/bash

# get network info from consul and poll it for liveness
> _env
if [ -z "$1" ]; then
    CONSUL_IP=$(sdc-listmachines --name consul_consul_1 | json -a ips.1)
else
    CONSUL_IP=${CONSUL_IP:-$(docker-machine ip default)}
    echo LOCAL=true > _env
fi
echo CONSUL=$CONSUL_IP >> _env
