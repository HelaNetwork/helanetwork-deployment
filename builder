#!/bin/bash

# tools required: rsync, jq, yq, unzip

PATHS=
OP=nop
NETWORK=
SILENT=false
NO_START=false
INTERACT=true
DRY_RUN=false
LOCKED=false
MANUAL_SIGN=false
ENTITY=
SSH_KEY=
TO_HOME=
SELECTOR=
EPOCH=

SCRIPT=$0
SSH=`which ssh`
RSYNC=`which rsync`
EXCLUDE_ARGS="--exclude=runtimes --exclude=internal.sock --exclude=persistent-* --exclude=tendermint*"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=3"
RSYNC_EXEC="ssh $SSH_OPTS"
TOOLS="rsync jq yq unzip"
RMT_BIN_PATH=..
CONSENSUS_START_PORT=20000
WORKER_START_PORT=20100
APP_START_PORT=3000
TIMESTAMP=
declare -A SERVER_DEPLOY_USER

#{{{ common functions
HLMSG=$'\x1b'"[1;33m"
HLWRN=$'\x1b'"[0;35m"
HLERR=$'\x1b'"[1;31m"
HLEND=$'\x1b'"[0m"

# $* : [ARG_OF_echo] MSG
msg()
{
    $SILENT && return
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLMSG${@}$HLEND" >&2
}
wrn()
{
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLWRN${@}$HLEND" >&2
}
err()
{
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLERR${@}$HLEND" >&2
}
is_among() {
    local item t=$1
    shift
    for item in $* ; do
        [ "$t" = "$item" ] && return 0
    done
    return 1
}

rsync() {
    local arg args
    while [ $# -gt 0 ] ; do
        arg="$1"
        [ "$arg" != "${arg#$DEPLOY_USER@}" ] && {
            local server=${arg#$DEPLOY_USER@}
            server=${server%%:*}
            [ -n "${SERVER_DEPLOY_USER[$server]}" ] && {
                arg="${SERVER_DEPLOY_USER[$server]}@${arg#*@}"
            }
        }

        args="$args${args:+ }\"${arg//\"/\\\"}\""
        shift
    done

    if $DRY_RUN ; then
        eval "echo $RSYNC $args"
        return
    fi

    local i=0
    for ((i=0; i<3; i++)) ; do
        eval "$RSYNC -e \"$RSYNC_EXEC${SSH_KEY:+ -i }$SSH_KEY\" $args" && return
        sleep 0.2
    done
    return 1
}
ssh() {
    local arg args force=false
    while [ $# -gt 0 ] ; do
        arg="$1"
        [ "$arg" = --force ] && {
            force=true
            shift
            continue
        }

        [ "$arg" != "${arg#$DEPLOY_USER@}" ] && {
            local server=${arg#$DEPLOY_USER@}
            [ -n "${SERVER_DEPLOY_USER[$server]}" ] && {
                arg="${SERVER_DEPLOY_USER[$server]}@${arg#*@}"
            }
        }

        args="$args${args:+ }\"${arg//\"/\\\"}\""
        shift
    done

    if $DRY_RUN && ! $force ; then
        eval "echo $SSH $args"
        return
    fi

    local i=0
    for ((i=0; i<3; i++)) ; do
        eval "$SSH $SSH_OPTS ${SSH_KEY:+-i} $SSH_KEY $args"
        local r=$?
        [ $r = 255 ] || return $r
        sleep 0.1
    done
    return 1
}

remote_run() {
    local hosts=$HOSTS host
    local login_param
    local silent=false
    local ssh_args="-q $SSH_OPTS ${SSH_KEY:+-i} $SSH_KEY"

    [ -t 1 ] && ssh_args="$ssh_args -t"

    while [ $# -gt 0 ] ; do
        case "$1" in
        -l)
            login_param=$1
            ;;
        -s)
            silent=true
            ;;
        -h)
            shift
            hosts=$1
            ;;
        *)
            break
        esac
        shift
    done

    local tmp_file=`mktemp -u -p /dev/shm tmp.XXXXXX.sh`
    local ssh=`which ssh`

    for host in $hosts ; do
        $silent || $SILENT || echo -e "\n=========== Running in $host(${HOST_MAP[$host]}) : <<<\n$@\n>>>" >&2
        echo "$@" | $ssh $ssh_args $DEPLOY_USER@$host "cat >$tmp_file" &&
        $ssh $ssh_args $DEPLOY_USER@$host "trap 'rm -f $tmp_file' EXIT; bash $login_param $tmp_file"
    done
}

script() {
    local arg args force=false
    while [ $# -gt 0 ] ; do
        arg="$1"
        [ "$arg" = --force ] && {
            force=true
            shift
            continue
        }

        args="$args${args:+ }\"${arg//\"/\\\"}\""
        shift
    done

    if $DRY_RUN && ! $force ; then
        args="--dry-run $args"
    fi
    eval "$SCRIPT ${SSH_KEY:+--ssh-key=}$SSH_KEY $args"
}
#}}}

#{{{ application functions

check_tools() {
    local tool
    for tool in $TOOLS ; do
        [ $tool = jq -a -x ./jq ] && {
            export PATH=.:$PATH
        }
        which $tool >/dev/null || {
            err "Please install $tool!"
            exit 1
        }
    done
}

get_service_ip() {
    local ip
    for ip in ${!SERVICES[*]} ; do
        is_among $1 ${SERVICES[$ip]} && {
            echo $ip
            break
        }
    done
}

get_ip_services() {
    echo "${SERVICES[$1]}"
}

get_service_access_ip() {
    [ -n "${SERVICE_ACCESS_IP[$1]}" ] && {
        echo ${SERVICE_ACCESS_IP[$1]}
        return
    }
    local ip=`get_service_ip $1`
    [ -n "${SERVICE_ACCESS_IP[$ip]}" ] && {
        echo ${SERVICE_ACCESS_IP[$ip]}
        return
    }
    echo $ip
}

get_conn_ip() {
    local ip=`get_service_ip $1`
    [ -n "${SERVER_CONN_IP[$ip]}" ] && echo "${SERVER_CONN_IP[$ip]}" || echo $ip
}

# node port_var
get_consensus_port() {
    local node=$1 pre_port=$2
    local svc ip=`get_service_ip $node`
    [ -z "$pre_port" ] && pre_port=${CONSENSUS_START_PORT} || ((pre_port++))
    for svc in ${SERVICES[$ip]} ; do
        [ $svc = $node ] && continue
        [ -f $NETWORK/$svc/config.yml ] && {
            local port=`yq -r '.consensus.tendermint.core.listen_address//0' $NETWORK/$svc/config.yml | sed 's/.*://'`
            ((port>=$pre_port)) && pre_port=$((port+1))
            port=`yq -r '.consensus.listen_address//0' $NETWORK/$svc/config.yml | sed 's/.*://'`
            ((port>=$pre_port)) && pre_port=$((port+1))
        }
    done
    echo $pre_port
}
get_worker_port() {
    local node=$1 pre_port=$2
    local svc ip=`get_service_ip $node`
    [ -z "$pre_port" ] && pre_port=${WORKER_START_PORT} || ((pre_port++))
    for svc in ${SERVICES[$ip]} ; do
        [ $svc = $node ] && continue
        [ -f $NETWORK/$svc/config.yml ] && {
            local port=`yq -r '.worker.sentry.control.port//0' $NETWORK/$svc/config.yml`
            ((port>=$pre_port)) && pre_port=$((port+1))
            port=`yq -r '.worker.client.port//0' $NETWORK/$svc/config.yml`
            ((port>=$pre_port)) && pre_port=$((port+1))
            port=`yq -r '.worker.p2p.port//0' $NETWORK/$svc/config.yml`
            ((port>=$pre_port)) && pre_port=$((port+1))
            port=`yq -r '.p2p.port//0' $NETWORK/$svc/config.yml`
            ((port>=$pre_port)) && pre_port=$((port+1))
        }
    done
    echo $pre_port
}
get_app_port() {
    local node=$1 pre_port=$2
    local svc ip=`get_service_ip $node`
    local new_port exist_ports port
    [ -z "$pre_port" ] && new_port=${APP_START_PORT} || ((new_port=pre_port+1))

    for svc in ${SERVICES[$ip]} ; do
        [ $svc = $node ] && continue
        [ -f $NETWORK/$svc/config.yml ] && {
            port=`yq -r '.gateway.http.port//0' $NETWORK/$svc/config.yml`
            exist_ports="$exist_ports $port"
            port=`yq -r '.gateway.ws.port//0' $NETWORK/$svc/config.yml`
            exist_ports="$exist_ports $port"
            port=`yq -r '.gateway.monitoring.port//0' $NETWORK/$svc/config.yml`
            exist_ports="$exist_ports $port"
            port=`yq -r '.static_resources.listeners[0].address.socket_address.port_value//0' $NETWORK/$svc/config.yml`
            exist_ports="$exist_ports $port"
            port=`yq -r '.metrics.address//0' $NETWORK/$svc/config.yml`
            port=${port#*:}
            exist_ports="$exist_ports $port"
        }
    done
    while is_among $new_port $exist_ports ${OCCUPIED_PORTS[$ip]} ; do 
        ((new_port++))
    done
    echo $new_port
}

list_service_host_ports() {
    local svc ip
    for ip in $SERVERS ; do
        echo -e "\nhost $ip:"
        for svc in ${SERVICES[$ip]} ; do
            [ -f $NETWORK/$svc/config.yml ] && {
                yq -r '.consensus.tendermint.core.listen_address//0' $NETWORK/$svc/config.yml | sed "s/.*://;/^0$/d;s/\$/ $svc/"
                yq -r '.worker.sentry.control.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r '.worker.client.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r '.worker.p2p.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r '.gateway.http.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r '.gateway.ws.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r '.gateway.monitoring.port//0' $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
                yq -r ".static_resources.listeners[0].address.socket_address.port_value//0" $NETWORK/$svc/config.yml | sed "/^0$/d;s/$/ $svc/"
            }
        done | sort
    done
}

list_envoy_endpoints() {
    local ip envoy port
    for envoy in `get_all_envoys` ; do
        ip=`get_service_ip $envoy`
        port=`yq -r '.static_resources.listeners[0].address.socket_address.port_value' $envoy/config.yml`
        echo "http://$ip:$port"
    done
}

get_validator_entity() {
    local entity
    for entity in ${!ENTITY_VALIDATORS[*]} ; do
        is_among $1 ${ENTITY_VALIDATORS[$entity]} && {
            echo $entity
            break
        }
    done
}

get_compute_entity() {
    local entity
    for entity in ${!ENTITY_COMPUTES[*]} ; do
        is_among $1 ${ENTITY_COMPUTES[$entity]} && {
            echo $entity
            break
        }
    done
}
get_compute_runtime() {
    local runtime
    for runtime in ${!RUNTIME_COMPUTES[*]} ; do
        is_among $1 ${RUNTIME_COMPUTES[$runtime]} && {
            echo $runtime
            break
        }
    done
}

get_client_runtime() {
    local runtime
    for runtime in ${!RUNTIME_CLIENTS[*]} ; do
        is_among $1 ${RUNTIME_CLIENTS[$runtime]} && {
            echo $runtime
            break
        }
    done
}

get_runtime_servers() {
    local x ip servers
    for x in ${RUNTIME_COMPUTES[$1]} ${RUNTIME_CLIENTS[$1]} ; do
        ip=`get_service_ip $x`
        is_among $ip $servers || {
            servers="$servers${servers:+ }$ip"
        }
    done
    echo $servers
}

get_runtime_orc() {
    local runtime=${1#runtime-}
    runtime=${runtime//-/_}
    eval "echo \$${runtime^^}_RUNTIME_ORC"
}

# $1: paths
get_extra_paths() {
    # validator => entity
    # compute => entity
    local svc ret
    for svc in $* ; do
        [ "$svc" != "${svc/\/}" ] && continue

        [ "$svc" != "${svc#validator-}" ] && {
            local entity=`get_validator_entity $svc`
            is_among $entity/entity.json $ret || ret="$ret${ret:+ }$entity/entity.json"
        }
        [ "$svc" != "${svc#compute-}" ] && {
            local entity=`get_compute_entity $svc`
            is_among $entity/entity.json $ret || ret="$ret${ret:+ }$entity/entity.json"
        }
        #[ "$svc" != "${svc#client-}" ] && {
        #    local runtime=`get_client_runtime $svc`
        #    is_among $runtime $ret || ret="$ret${ret:+ }$runtime"
        #}
    done
    echo $ret
}

get_w3_gateway_runtime() {
    local runtime
    for runtime in ${!RUNTIME_W3_GATEWAYS[*]} ; do
        is_among $1 ${RUNTIME_W3_GATEWAYS[$runtime]} && {
            echo $runtime
            break
        }
    done
}

get_w3_gateway_client() {
    [ -n "${W3_GATEWAY_CLIENT[$1]}" ] && {
        echo "${W3_GATEWAY_CLIENT[$1]}"
        return
    }
    local runtime=`get_w3_gateway_runtime $1`
    local ip=`get_service_ip $1`
    local client
    for client in ${RUNTIME_CLIENTS[$runtime]} ; do
        is_among $client ${SERVICES[$ip]} && {
            echo $client
            break
        }
    done
}

get_envoy_ep_node() {
    local node ip=`get_service_ip $1`
    for node in ${SERVICES[$ip]} ; do
        [ "$node" != "${node#client-}" ] && {
            echo $node
            return
        }
    done
    for node in ${SERVICES[$ip]} ; do
        [ "$node" != "${node#non-validator-}" ] && {
            echo $node
            return
        }
    done
    for node in ${SERVICES[$ip]} ; do
        [ "$node" != "${node#validator-}" ] && {
            echo $node
            return
        }
    done
    err "cannot get envoy $1 endpoint node!"
    return 1
}

update_symbolic_links() {
    local x target tmp_f=`mktemp -u -p /dev/shm`
    $network_by_default || {
        for x in * ; do
            [ -L "$x" ] && {
                [ -e "$x" ] || rm -f $x
            }
            [ -L "$x" ] && {
                #target=`readlink $x`
                readlink $x >$tmp_f
                read target <$tmp_f
                [ "$target" = "${target#$NETWORK/}" ] && rm -f $x
                is_among ${target#$NETWORK/} $IGNORED_SERVICES && rm -f $x
            }
        done
    }
    for x in $NETWORK/* ; do
        [ -L ${x#$NETWORK/} ] && continue
        [ -e ${x#$NETWORK/} ] && {
            err "cannot create symbolic for $x!"
            exit 1
        }
        is_among ${x#$NETWORK/} $IGNORED_SERVICES && continue
        ln -snf $x
    done
    [ -f $tmp_f ] && rm -f $tmp_f
}

do_unlink() {
    local x target tmp_f=`mktemp -u -p /dev/shm`
    for x in * ; do
        [ -L "$x" ] && {
            [ -e "$x" ] || rm -f $x
        }
        [ -L "$x" ] && {
            readlink $x >$tmp_f
            read target <$tmp_f
            [ "$target" != "${target#$NETWORK/}" ] && rm -f $x
        }
    done
    [ -f $tmp_f ] && rm -f $tmp_f
}

do_compile() {
    local cwd=$(pushd ${SCRIPT%/*} >/dev/null; pwd; popd >/dev/null)
    local root=${cwd%/*}
    local dir
    [ -f $root/Makefile ] || ln -snf deployment/Makefile $root/
    [ $# = 0 ] && set -- ""
    for dir in "$@" ; do
        dir=${dir#../}
        dir=${dir%/}
        make -C $root -f ./deployment/Makefile $dir || return
    done
}

do_lock() {
    touch $NETWORK/.lock
}
do_unlock() {
    [ -f $NETWORK/.lock ] && rm -f $NETWORK/.lock
}

get_all_seeds() {
    local x ret
    for x in ${SERVICES[*]} ; do
        [ "$x" = "${x#seed-}" ] && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_entities() {
    local x ret
    for x in ${!ENTITY_VALIDATORS[*]} ${!ENTITY_COMPUTES[*]} ${RUNTIME_ENTITY[*]} \
             $GENESIS_ENTITIES $GENESIS_SUPPLY_ENTITY $FAUCEL_ENTITY $EXTRA_ENTITIES; do
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_runtimes() {
    local x ret
    for x in ${!RUNTIME_COMPUTES[*]} ${!RUNTIME_CLIENTS[*]} ${!RUNTIME_ENTITY[*]} ${!RUNTIME_W3_GATEWAYS[*]} $GENESIS_RUNTIMES ; do
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_validators() {
    local x ret
    for x in ${SERVICES[*]} ${ENTITY_VALIDATORS[*]} $GENESIS_NODES ; do
        [ "$x" = "${x#validator-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_non_validators() {
    local x ret
    for x in ${SERVICES[*]} ; do
        [ "$x" = "${x#non-validator-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_sentries() {
    local x ret
    for x in ${SERVICES[*]} ${VALIDATOR_SENTRIES[*]} $GENESIS_NODES ; do
        [ "$x" = "${x#sentry-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_computes() {
    local x ret
    for x in ${SERVICES[*]} ${ENTITY_COMPUTES[*]} ${RUNTIME_COMPUTES[*]} $GENESIS_NODES ; do
        [ "$x" = "${x#compute-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_clients() {
    local x ret
    for x in ${SERVICES[*]} ${RUNTIME_CLIENTS[*]} ${W3_GATEWAY_CLIENT[*]} ; do
        [ "$x" = "${x#client-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_w3_gateways() {
    local x ret
    for x in ${SERVICES[*]} ${RUNTIME_W3_GATEWAYS[*]} ${!W3_GATEWAY_CLIENT[*]} ; do
        [ "$x" = "${x#w3-gateway-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}
get_all_envoys() {
    local x ret
    for x in ${SERVICES[*]} ; do
        [ "$x" = "${x#envoy-}" ] && continue
        is_among "$x" $IGNORED_SERVICES && continue
        is_among $x $ret || ret="$ret${ret:+ }$x"
    done
    echo $ret
}

get_entity_id() {
    local entity=$1

    if [ "$entity" = "${entity#entity-}" ] ; then
        entity=`get_compute_entity $entity``get_validator_entity $entity`
        [ -t 1 ] && echo -n "$1 - $entity: " >&2
    fi

    jq -r .id $NETWORK/$entity/entity.json
}

get_entity_address() {
    local entity=$1

    if [ "$entity" = "${entity#entity-}" ] ; then
        entity=`get_compute_entity $entity``get_validator_entity $entity`
        [ -t 1 ] && echo -n "$1 - $entity: " >&2
    fi

    [ -f $NETWORK/$entity/entity.addr ] || {
        local id=`get_entity_id $entity`
        $HELA_NODE stake pubkey2address --public_key $id >$NETWORK/$entity/entity.addr
    }
    cat $NETWORK/$entity/entity.addr
}

get_entity_key() {
    sed -n '2h;3H;${x; s/\n//; p}' $NETWORK/$1/entity.pem
}

get_node_address() {
    local node=$1

    [ -f $NETWORK/$node/identity_pub.pem ] && {
        local id=`sed -n 2p $NETWORK/$node/identity_pub.pem`
        $HELA_NODE stake pubkey2address --public_key $id
    }
}

get_seed_endpoints() {
    [ -n "$SEED_ADDRESSES" ] && {
        echo $SEED_ADDRESSES
        return
    }
    local sub_cmd=tendermint
    [ "$HELA_NODE_VER_MAJOR" = 23 ] && sub_cmd=cometbft

    local seed
    for seed in `get_all_seeds` ; do
        [ -f $NETWORK/$seed/config.yml ] || continue
        local ip=`get_conn_ip $seed`
        local port=`yq -r '.consensus.tendermint.core.listen_address' $NETWORK/$seed/config.yml | sed 's/.*://'`
        local tendermint_id=`$HELA_NODE identity $sub_cmd show-node-address --datadir $NETWORK/$seed`
        SEED_ADDRESSES="$SEED_ADDRESSES $tendermint_id@$ip:$port"
    done

    echo $SEED_ADDRESSES
}

get_seed_endpoints.23() {
    [ -n "$SEED_ADDRESSES" ] && {
        echo $SEED_ADDRESSES
        return
    }

    local seed
    for seed in `get_all_seeds` ; do
        [ -f $NETWORK/$seed/config.yml ] || continue
        local ip=`get_conn_ip $seed`
        local port=`yq -r '.consensus.external_address' $NETWORK/$seed/config.yml | sed 's/.*://'`
        local p2p_id=`sed -n 2p $NETWORK/$seed/p2p_pub.pem`
        SEED_ADDRESSES="$SEED_ADDRESSES $p2p_id@$ip:$port"
    done

    echo $SEED_ADDRESSES
}

get_w3_url() {
    local w3
    for w3 in `get_all_w3_gateways` ; do
        [ "`get_service_ip $1`" = "`get_service_ip $w3`" ] || continue
        local ip=`get_service_access_ip $w3`
        local port=`yq .gateway.http.port $w3/config.yml`
        echo "http://$ip:$port"
        break
    done
}

get_all_w3_urls() {
    local w3
    for w3 in `get_all_w3_gateways` ; do
        local ip=`get_service_access_ip $w3`
        local port=`yq .gateway.http.port $w3/config.yml`
        echo "http://$ip:$port"
    done
}

get_hela_node_version() {
    $HELA_NODE --version | sed -n 's/^Software version: \([0-9.]\+\)-.*/\1/p'
}

get_orc_id() {
    unzip -p ${1:-$HELA_EVM_RUNTIME_ORC} META-INF/MANIFEST.MF | jq -r .id
}

# ret: major.minor.patch
get_orc_version() {
    unzip -p $1 META-INF/MANIFEST.MF | jq -j '.version.major, ".", .version.minor//0, ".", .version.patch//0'
}

version_value() {
    local ary=(${1//./ })
    local i v=0
    for ((i=0;i<3;i++)) ; do
        ((v*=1000))
        ((v+=${ary[i]}))
    done
    echo $v
}

get_version_major() {
    echo ${1%%.*}
}

exponent_value() {
    local i v=1
    for ((i=0; i<$1; i++)) ; do
        ((v*=10))
    done
    echo $v
}

current_network() {
    echo $NETWORK
}

#}}}

#{{{ batch op functions

do_clean() { #{{{
    local input x

    $LOCKED && return

    if $INTERACT ; then
        echo -ne "Are you sure to clean all local generated files for **\x1b[1;31m$NETWORK\x1b[0m**? [$NETWORK to confirm] "
        read input
        [ "$input" != $NETWORK ] && return 1
    else
        echo -ne "You are going to clean all files for network **\x1b[1;31m$NETWORK\x1b[0m**! [0/3] "
        for x in 1 2 3 ; do
            sleep 1
            echo -ne "\b\b\b\b\b\b[$x/3] "
        done
        echo
    fi

    for x in `get_all_seeds` `get_all_validators` `get_all_non_validators` `get_all_sentries` `get_all_computes` `get_all_clients` \
             `get_all_entities` `get_all_runtimes` `get_all_w3_gateways` `get_all_envoys` genesis.json ; do
        [ -e $NETWORK/$x ] && rm -fr $NETWORK/$x
    done
    network_by_default=false update_symbolic_links
} #}}}

do_generate() { #{{{
    $LOCKED && return

    [ -f "$NETWORK/genesis.json" ] && {
        wrn "network $NETWORK ever generated!"
    }

    [ -x $HELA_NODE ] || {
        err "$HELA_NODE not existing!"
        exit 1
    }

    local oasis_node=`readlink -f $HELA_NODE`

    local entity seed validator compute client w3_gateway envoy runtime node ip port p2p_port addr name id content value generated
    local -A runtime_ids runtime_versions

    # entity {{{
    for entity in `get_all_entities` ; do
        [ -f $NETWORK/$entity/entity.json ] && {
            wrn "$entity already generated, ignored"
            continue
        }

        msg "generating $entity..."

        mkdir -p -m 700 $NETWORK/$entity

        $HELA_NODE registry entity init --signer.dir $NETWORK/$entity
    done #}}}

    # seed {{{
    for seed in `get_all_seeds` ; do
        [ -f $NETWORK/$seed/config.yml ] && {
            wrn "$seed already generated, ignored"
            continue
        }

        msg "generating $seed..."

        ip=`get_conn_ip $seed`
        port=`get_consensus_port $seed`

        mkdir -p -m 700 $NETWORK/$seed

        $HELA_NODE identity init --datadir $NETWORK/$seed

        cp template/seed-config.yml $NETWORK/$seed/config.yml
        yq -yi ".consensus.tendermint.core.listen_address=\"tcp://0.0.0.0:$port\"" $NETWORK/$seed/config.yml
        yq -yi ".consensus.tendermint.core.external_address=\"tcp://$ip:$port\"" $NETWORK/$seed/config.yml

        [ "$HELA_NODE_VER_MAJOR" = 23 ] && {
            $oasis_node config migrate --in $NETWORK/$seed/config.yml --out $NETWORK/$seed/config_23.yml >/dev/null
            mv $NETWORK/$seed/config_23.yml $NETWORK/$seed/config.yml
        }
    done #}}}

    # validator {{{
    for validator in `get_all_validators` ; do
        [ -f $NETWORK/$validator/config.yml ] && {
            wrn "$validator already generated, ignored"
            continue
        }

        msg "generating $validator..."

        ip=`get_conn_ip $validator`
        entity=`get_validator_entity $validator`
        port=`get_consensus_port $validator`

        mkdir -p -m 700 $NETWORK/$validator

        local entity_id=`get_entity_id $entity`
        pushd $NETWORK/$validator >/dev/null
        $oasis_node registry node init \
          --node.entity_id $entity_id \
          --node.consensus_address $ip:$port \
          --node.p2p_address $ip:$port \
          --node.role validator
        popd >/dev/null

        cp template/validator-config.yml $NETWORK/$validator/config.yml
        yq -yi ".worker.registration.entity=\"../$entity/entity.json\"" $NETWORK/$validator/config.yml
        yq -yi ".consensus.tendermint.core.listen_address=\"tcp://0.0.0.0:$port\"" $NETWORK/$validator/config.yml
        yq -yi ".consensus.tendermint.core.external_address=\"tcp://$ip:$port\"" $NETWORK/$validator/config.yml

        for addr in `get_seed_endpoints` ; do
            yq -yi ".consensus.tendermint.p2p.seed += [\"$addr\"]" $NETWORK/$validator/config.yml
        done

        [ "$HELA_NODE_VER_MAJOR" = 23 ] && {
            $oasis_node config migrate --in $NETWORK/$validator/config.yml --out $NETWORK/$validator/config_23.yml >/dev/null
            mv $NETWORK/$validator/config_23.yml $NETWORK/$validator/config.yml
            port=`get_worker_port $validator`
            yq -yi ".p2p.port=$port" $NETWORK/$validator/config.yml
            yq -yi ".p2p.registration.addresses=[]" $NETWORK/$validator/config.yml
            yq -yi ".p2p.registration.addresses += [\"$ip:$port\"]" $NETWORK/$validator/config.yml
            yq -yi "del(.registration.rotate_certs)" $NETWORK/$validator/config.yml
            yq -yi ".p2p.seeds=[]" $NETWORK/$validator/config.yml
            for addr in `get_seed_endpoints.23` ; do
                yq -yi ".p2p.seeds += [\"$addr\"]" $NETWORK/$validator/config.yml
            done
        }
    done #}}}

    # update validator to entity {{{
    for entity in `get_all_entities` ; do
        local all=
        for validator in ${ENTITY_VALIDATORS[$entity]} ; do
            all="$all${all:+,}$NETWORK/$validator/node_genesis.json"
        done
        [ -n "$all" ] && {
            msg "updating $entity validators..."
            $HELA_NODE registry entity update --signer.dir $NETWORK/$entity --entity.node.descriptor $all
        }
    done #}}}

    # non-validator {{{
    for node in `get_all_non_validators` ; do
        [ -f $NETWORK/$node/config.yml ] && {
            wrn "$node already generated, ignored"
            continue
        }

        msg "generating $node..."

        ip=`get_conn_ip $node`
        port=`get_consensus_port $node`

        mkdir -p -m 700 $NETWORK/$node

        $HELA_NODE identity init --datadir $NETWORK/$node

        cp template/non-validator-config.yml $NETWORK/$node/config.yml
        yq -yi ".consensus.tendermint.core.listen_address=\"tcp://0.0.0.0:$port\"" $NETWORK/$node/config.yml
        yq -yi ".consensus.tendermint.core.external_address=\"tcp://$ip:$port\"" $NETWORK/$node/config.yml
        for addr in `get_seed_endpoints` ; do
            yq -yi ".consensus.tendermint.p2p.seed += [\"$addr\"]" $NETWORK/$node/config.yml
        done

        is_among $node $METRICS_NODES && {
            port=`get_app_port $node`
            yq -yi ".metrics.mode=\"pull\" | .metrics.address=\"0.0.0.0:$port\"" $NETWORK/$node/config.yml
        }
    done #}}}

    # runtime {{{
    for runtime in `get_all_runtimes` ; do
        # runtime id
        local orc_file=`get_runtime_orc $runtime`
        runtime_ids[$runtime]=`get_orc_id $orc_file`
        runtime_versions[$runtime]=`get_orc_version $orc_file`

        [ -z "${runtime_ids[$runtime]}" ] && {
            err "cannot get runtime $runtime id!"
            exit 1
        }
    done

    for runtime in `get_all_runtimes` ; do
        [ -f $NETWORK/$runtime/runtime_genesis.json ] && {
            wrn "$runtime already generated, ignored"
            generated=true
        } || generated=false

        $generated && continue

        name=${runtime#runtime-}

        [ -f template/$name-genesis.json -o -f $NETWORK/.template/$name-genesis.json ] || {
            err "runtime $name template file $name-genesis.json not existing!"
            exit 1
        }

        msg "generating $runtime..."

        mkdir -p -m 700 $NETWORK/$runtime

        [ -f $NETWORK/.template/genesis.json ] && {
            cp $NETWORK/.template/$name-genesis.json $NETWORK/$runtime/runtime_genesis.json
        } || {
            cp template/$name-genesis.json $NETWORK/$runtime/runtime_genesis.json
        }

        local major=${runtime_versions[$runtime]%%.*}
        local minor=${runtime_versions[$runtime]%.*}; minor=${minor#*.}; minor=${minor#0}
        local patch=${runtime_versions[$runtime]##*.}; patch=${patch#0}
        content=`jq "
            .id = \"${runtime_ids[$runtime]}\" |
            .deployments[0].version.major = $major |
            ${minor:+.deployments[0].version.minor = $minor |}
            ${patch:+.deployments[0].version.patch = $patch |}
            .deployments[0].valid_from = 0
        " $NETWORK/$runtime/runtime_genesis.json`

        echo "$content" >$NETWORK/$runtime/runtime_genesis.json

        # entity id
        id=`get_entity_id ${RUNTIME_ENTITY[$runtime]}`
        content=`jq ".entity_id=\"$id\"" $NETWORK/$runtime/runtime_genesis.json`
        echo "$content" >$NETWORK/$runtime/runtime_genesis.json
    done #}}}

    # compute #{{{
    for compute in `get_all_computes` ; do
        [ -f $NETWORK/$compute/config.yml ] && {
            wrn "$compute already generated, ignored"
            continue
        }
        msg "generating $compute..."

        ip=`get_conn_ip $compute`
        entity=`get_compute_entity $compute`
        runtime=`get_compute_runtime $compute`

        mkdir -p -m 700 $NETWORK/$compute
 
        [ -f $NETWORK/$compute/identity.pem ] || $HELA_NODE identity init --datadir $NETWORK/$compute

        [ -f $NETWORK/.template/compute-config.yml ] && {
            cp $NETWORK/.template/compute-config.yml $NETWORK/$compute/config.yml
        } || {
            cp template/compute-config.yml $NETWORK/$compute/config.yml
        }

        #is_among $entity $GENESIS_ENTITIES && value=0 || value=1
        yq -yi ".worker.registration.rotate_certs=0" $NETWORK/$compute/config.yml
        yq -yi ".worker.registration.entity=\"../$entity/entity.json\"" $NETWORK/$compute/config.yml
        port=`get_worker_port $compute`
        yq -yi ".worker.client.port=$port" $NETWORK/$compute/config.yml
        port=`get_worker_port $compute $port`
        yq -yi ".worker.p2p.port=$port" $NETWORK/$compute/config.yml
        yq -yi ".worker.p2p.addresses=[\"$ip:$port\"]" $NETWORK/$compute/config.yml
        local filename=${runtime#runtime-}-runtime-${runtime_versions[$runtime]//./-}.orc
        yq -yi ".runtime.paths += [\"../$runtime/$filename\"]" $NETWORK/$compute/config.yml
        port=`get_consensus_port $compute`
        yq -yi ".consensus.tendermint.core.listen_address=\"tcp://0.0.0.0:$port\"" $NETWORK/$compute/config.yml
        yq -yi ".consensus.tendermint.core.external_address=\"tcp://$ip:$port\"" $NETWORK/$compute/config.yml
        for addr in `get_seed_endpoints` ; do
            yq -yi ".consensus.tendermint.p2p.seed += [\"$addr\"]" $NETWORK/$compute/config.yml
        done
        [ "$HELA_NODE_VER_MAJOR" = 23 ] && {
            $oasis_node config migrate --in $NETWORK/$compute/config.yml --out $NETWORK/$compute/config_23.yml >/dev/null
            mv $NETWORK/$compute/config_23.yml $NETWORK/$compute/config.yml
            yq -yi "del(.registration.rotate_certs)" $NETWORK/$compute/config.yml
            yq -yi ".p2p.seeds=[]" $NETWORK/$compute/config.yml
            for addr in `get_seed_endpoints.23` ; do
                yq -yi ".p2p.seeds += [\"$addr\"]" $NETWORK/$compute/config.yml
            done
        }
    done #}}}

    # update computes to entity {{{
    for entity in `get_all_entities` ; do
        local all=
        for compute in ${ENTITY_COMPUTES[$entity]} ; do
            all="$all${all:+,}`sed -n 2p $NETWORK/$compute/identity_pub.pem`"
        done
        [ -n "$all" ] && {
            msg "updating $entity computes..."
            $HELA_NODE registry entity update --signer.dir $NETWORK/$entity --entity.node.id $all
        }
    done #}}}

    # client #{{{
    for client in `get_all_clients` ; do
        [ -f $NETWORK/$client/config.yml ] && {
            wrn "$client already generated, ignored"
            continue
        }

        msg "generating $client..."

        ip=`get_conn_ip $client`
        runtime=`get_client_runtime $client`

        mkdir -p -m 700 $NETWORK/$client
 
        [ -f $NETWORK/$client/identity.pem ] || $HELA_NODE identity init --datadir $NETWORK/$client

        [ -f $NETWORK/.template/client-config.yml ] && {
            cp $NETWORK/.template/client-config.yml $NETWORK/$client/config.yml
        } || {
            cp template/client-config.yml $NETWORK/$client/config.yml
        }

        port=`get_worker_port $client`
        yq -yi ".worker.p2p.port=$port" $NETWORK/$client/config.yml
        yq -yi ".worker.p2p.addresses=[\"$ip:$port\"]" $NETWORK/$client/config.yml
        local filename=${runtime#runtime-}-runtime-${runtime_versions[$runtime]//./-}.orc
        yq -yi ".runtime.paths += [\"../$runtime/$filename\"]" $NETWORK/$client/config.yml
        yq -yi ".runtime.config |= with_entries(.key = \"${runtime_ids[$runtime]}\")" $NETWORK/$client/config.yml
        port=`get_consensus_port $client`
        yq -yi ".consensus.tendermint.core.listen_address=\"tcp://0.0.0.0:$port\"" $NETWORK/$client/config.yml
        yq -yi ".consensus.tendermint.core.external_address=\"tcp://$ip:$port\"" $NETWORK/$client/config.yml
        for addr in `get_seed_endpoints` ; do
            yq -yi ".consensus.tendermint.p2p.seed += [\"$addr\"]" $NETWORK/$client/config.yml
        done
        [ "$HELA_NODE_VER_MAJOR" = 23 ] && {
            $oasis_node config migrate --in $NETWORK/$client/config.yml --out $NETWORK/$client/config_23.yml >/dev/null
            mv $NETWORK/$client/config_23.yml $NETWORK/$client/config.yml
            yq -yi ".p2p.seeds=[]" $NETWORK/$client/config.yml
            for addr in `get_seed_endpoints.23` ; do
                yq -yi ".p2p.seeds += [\"$addr\"]" $NETWORK/$client/config.yml
            done
        }
    done #}}}

    # w3-gateway #{{{
    for w3_gateway in `get_all_w3_gateways` ; do
        [ -f $NETWORK/$w3_gateway/config.yml ] && {
            wrn "$w3_gateway already generated, ignored"
            continue
        }

        msg "generating $w3_gateway..."

        runtime=`get_w3_gateway_runtime $w3_gateway`
        client=`get_w3_gateway_client $w3_gateway`

        mkdir -p -m 700 $NETWORK/$w3_gateway
 
        cp template/w3-gateway-config.yml $NETWORK/$w3_gateway/config.yml

        yq -yi ".runtime_id=\"${runtime_ids[$runtime]}\"" $NETWORK/$w3_gateway/config.yml
        yq -yi ".node_address=\"unix:../$client/internal.sock\"" $NETWORK/$w3_gateway/config.yml
        yq -yi ".database.db=\"${w3_gateway//-/_}\"" $NETWORK/$w3_gateway/config.yml
        name=${runtime#*-}
        name=${name//-/_}
        eval "id=\$${name^^}_CHAIN_ID"
        [ -n "$id" ] &&
        yq -yi ".gateway.chain_id=$id" $NETWORK/$w3_gateway/config.yml
        port=`get_app_port $w3_gateway`
        yq -yi ".gateway.http.port=$port" $NETWORK/$w3_gateway/config.yml
        port=`get_app_port $w3_gateway $port`
        yq -yi ".gateway.ws.port=$port" $NETWORK/$w3_gateway/config.yml
        port=`get_app_port $w3_gateway $port`
        yq -yi ".gateway.monitoring.port=$port" $NETWORK/$w3_gateway/config.yml
    done #}}}

    # envoy #{{{
    for envoy in `get_all_envoys` ; do
        [ -f $NETWORK/$envoy/config.yml ] && {
            wrn "$envoy already generated, ignored"
            continue
        }

        msg "generating $envoy..."

        node=`get_envoy_ep_node $envoy`

        mkdir -p -m 700 $NETWORK/$envoy
 
        cp template/envoy-config.yml $NETWORK/$envoy/config.yml

        yq -yi ".static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.pipe.path=\"../$node/internal.sock\"" $NETWORK/$envoy/config.yml
        port=`get_app_port $envoy`
        yq -yi ".static_resources.listeners[0].address.socket_address.port_value=$port" $NETWORK/$envoy/config.yml

        local _key=".static_resources.listeners[0].filter_chains[0].transport_socket"
        if is_among $envoy $SSL_ENVOYS ; then
            yq -yi "${_key}.typed_config.common_tls_context.tls_certificates[0].certificate_chain.filename=\"../$envoy.cert\"" $NETWORK/$envoy/config.yml
            yq -yi "${_key}.typed_config.common_tls_context.tls_certificates[0].private_key.filename=\"../$envoy.key\"" $NETWORK/$envoy/config.yml
        else
            yq -yi "del($_key)" $NETWORK/$envoy/config.yml
        fi
    done #}}}

    # genesis.json {{{

    [ -f $NETWORK/genesis.json ] && {
        wrn "genesis.json already generated, ignored"
    } || {
        msg "generating genesis.json..."

        [ -f $NETWORK/.template/genesis.json ] && {
            cp $NETWORK/.template/genesis.json $NETWORK/genesis.json
        } || {
            cp template/genesis.json $NETWORK/genesis.json
        }
        chmod 600 $NETWORK/genesis.json

        # genesis_time
        jq ".genesis_time=\"`date +%Y-%m-%dT%H:%M:%S.%N%:z`\"" $NETWORK/genesis.json > $NETWORK/genesis.tmp
        mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        # add entities
        for entity in ${GENESIS_ENTITIES} ; do
            jq ".registry.entities += [`jq -c . $NETWORK/$entity/entity_genesis.json`]" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        done
        # add validators nodes
        for validator in ${GENESIS_NODES} ; do
            jq ".registry.nodes += [`jq -c . $NETWORK/$validator/node_genesis.json`]" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        done
        # add runtimes
        for runtime in ${GENESIS_RUNTIMES} ; do
            jq ".registry.runtimes += [`jq -c . $NETWORK/$runtime/runtime_genesis.json`]" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        done

        #staking

        local ledger_tmpl_key=`jq -r ".staking.ledger | to_entries[] | .key" $NETWORK/genesis.json`
        local ledger_tmpl_val=`jq -r ".staking.ledger | to_entries[] | .value" $NETWORK/genesis.json`

        # token symbol and exponent
        jq ".staking.token_symbol = \"$GENESIS_TOKEN_SYMBOL\" |
            .staking.token_value_exponent = $GENESIS_TOKEN_EXPONENT" $NETWORK/genesis.json >$NETWORK/genesis.tmp
        mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        # total supply
        jq ".staking.total_supply = \"$GENESIS_TOKEN_SUPPLY\"" $NETWORK/genesis.json >$NETWORK/genesis.tmp
        mv $NETWORK/genesis.tmp $NETWORK/genesis.json

        local sum=0

        # entity general balance
        for entity in ${!GENESIS_GENERAL_BALANCE[@]} ; do
            addr=`get_entity_address $entity`
            ((sum+=GENESIS_GENERAL_BALANCE[$entity]))
            jq ".staking.ledger.$addr = $ledger_tmpl_val | 
                .staking.ledger.$addr.general.balance = \"${GENESIS_GENERAL_BALANCE[$entity]}\"
                " $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        done
        # entity escrow balance
        for entity in ${!GENESIS_ESCROW_BALANCE[@]} ; do
            addr=`get_entity_address $entity`
            ((sum+=GENESIS_ESCROW_BALANCE[$entity]))
            jq ".staking.ledger |= (
                if .$addr then . else .$addr=$ledger_tmpl_val end | 
                .$addr.escrow.active.balance = \"${GENESIS_ESCROW_BALANCE[$entity]}\" |
                .$addr.escrow.active.total_shares = \"${GENESIS_ESCROW_BALANCE[$entity]}\")
                " $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
            # delegations
            jq ".staking.delegations.$addr = {} |
                .staking.delegations.$addr.$addr = {} |
                .staking.delegations.$addr.$addr.shares = \"${GENESIS_ESCROW_BALANCE[$entity]}\"
                " $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        done

        if ((sum>GENESIS_TOKEN_SUPPLY)) ; then
            err "total staking tokens > token supply!"
            exit 1
        elif ((sum == GENESIS_TOKEN_SUPPLY)) ; then
            jq "del(.staking.ledger.$ledger_tmpl_key)" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        else
            addr=`get_entity_address $GENESIS_SUPPLY_ENTITY`
            local val=$((GENESIS_TOKEN_SUPPLY-sum))
            [ `jq ".staking.ledger.$addr.general.balance | . != \"0\" and . != \"$val\" and . != null" $NETWORK/genesis.json` = true ] && {
                err "supply entity $GENESIS_SUPPLY_ENTITY has wrong general balance set"
                exit 1
            }

            jq ".staking.ledger |= (
                if has(\"$addr\") then 
                    del(.$ledger_tmpl_key) 
                else 
                    with_entries(
                      if .key == \"$ledger_tmpl_key\" then
                          .key=\"$addr\"
                      else
                          .
                      end
                    )
                end |
                .$addr.general.balance = \"$val\")
                " $NETWORK/genesis.json >$NETWORK/genesis.tmp
            mv $NETWORK/genesis.tmp $NETWORK/genesis.json

            #jq ".staking.governance_deposits = \"$val\"" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            #mv $NETWORK/genesis.tmp $NETWORK/genesis.json
        fi
    } #}}}

    update_symbolic_links
} #}}}

do_deploy() { #{{{

    local ip runtime path paths deploy_paths
    local -A orc_up w3g_up envoy_up basic_up

    $LOCKED && return

    for ip in $HOSTS ; do
      [ -z "$PATHS" ] && paths=${SERVICES[$ip]} || paths=$PATHS
      deploy_paths=

      for path in $paths ; do
        [ "`get_service_ip $path`" != $ip ] && continue

        deploy_paths="$deploy_paths${deploy_paths:+ }$path"

        # runtime orc
        runtime="`get_compute_runtime $path``get_client_runtime $path`"
        [ -n "$runtime" -a -z "${orc_up[$ip-$runtime]}" ] && {
            local orc_file=`get_runtime_orc $runtime`
            [ -f "$orc_file" ] || {
                err "$orc_file not found!"
                exit 1
            }
            local runtime_version=`get_orc_version $orc_file`
            local filename=${runtime#runtime-}-runtime-${runtime_version//./-}.orc
            local runtime_id=`get_orc_id $orc_file`
            local genesis_id=`jq -r ".id" $runtime/runtime_genesis.json`
            [ "$runtime_id" != "$genesis_id" ] && {
                err "Runtime id not match!"
                exit 1
            }

            #{{{
            #local major=${runtime_version%%.*}
            #local minor=${runtime_version%.*}; minor=${minor#*.}; minor=${minor#0}
            #local patch=${runtime_version##*.}; patch=${patch#0}

            #local content=`jq "
            #    del(.deployments[]) |
            #    .deployments += [{
            #        \"version\": {
            #            \"major\": $major
            #            ${minor:+,\"minor\": $minor}
            #            ${patch:+,\"patch\": $patch}
            #        },
            #        \"valid_from\": 0
            #    }]
            #" $runtime/runtime_genesis.json`

            #[ -n "$content" ] && {
            #    echo "$content" >$runtime/runtime_genesis.json
            #    is_among $runtime ${GENESIS_RUNTIMES} && {
            #        jq "del(.registry.runtimes[] | select(.id == \"$runtime_id\")) | .registry.runtimes += [$content]" $NETWORK/genesis.json >$NETWORK/genesis.tmp
            #        mv $NETWORK/genesis.tmp $NETWORK/genesis.json
            #    }
            #}
            #}}}

            yq -yi "del(.runtime.paths[]) | .runtime.paths += [\"../$runtime/$filename\"]" $path/config.yml

            msg "### Syncing runtime orc to $ip:$REMOTE_DEPLOY_PATH/$runtime/$filename ..."
            rsync --rsync-path "mkdir -p $REMOTE_DEPLOY_PATH/$runtime && /usr/bin/rsync" -Lt \
                $orc_file $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/$runtime/$filename
            orc_up[$ip-$runtime]=true
        }

        #w3
        [ "${path#w3-}" != $path -a -z "${w3g_up[$path]}" ] && {
            local pass=`yq -r .database.password $path/config.yml`
            ssh -qt $DEPLOY_USER@$ip which psql >/dev/null || {
                msg "Installing postgresql on $ip..."
                ssh -qt $DEPLOY_USER@$ip "sudo apt-get update; sudo apt-get install -y postgresql" || {
                    err "Install postgresql failed on $ip!"
                    exit 1
                }
                ssh -qt $DEPLOY_USER@$ip sudo -u postgres -i psql -c "\"ALTER USER postgres PASSWORD '$pass';\"" || {
                    err "Set DB user postgres password failed on $ip!"
                    exit 1
                }
            }

            script run --host=$ip . -- PGPASSWORD=$pass psql -U postgres -h 127.0.0.1 -c "'drop database ${path//-/_};'"
            script run --host=$ip . -- PGPASSWORD=$pass psql -U postgres -h 127.0.0.1 -c "'create database ${path//-/_};'"

            rsync -Lt service.sh $HELA_WEB3_GATEWAY $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/
            w3g_up[$path]=true
        }

        #envoy
        [ "${path#envoy-}" != $path -a -z "${envoy_up[$ip]}" ] && {
            rsync -Lt service.sh $ENVOY $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/
            envoy_up[$ip]=true
        }

        #basic
        is_among ${path%%-*} seed validator non-validator compute client sentry && [ -z "${basic_up[$ip]}" ] && {
            ssh --force -q $DEPLOY_USER@$ip test -f $REMOTE_DEPLOY_PATH/genesis.json || {
                rsync -Lt service.sh check_upgrade genesis.json $HELA_NODE $HELA_CLI $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/
            }
            basic_up[$ip]=true
        }
      done #paths

      script up $deploy_paths --host=$ip

      script install $deploy_paths --host=$ip || {
          err "Install $deploy_paths failed!"
          return
      }
      $NO_START || script start $deploy_paths --host=$ip

    done #HOSTS
} #}}}

do_undeploy() { #{{{
    local input ip t

    $LOCKED && return

    if $INTERACT ; then
        echo -ne "Are you sure to stop and remove remote network **\x1b[1;31m$NETWORK\x1b[0m**? [$NETWORK to confirm] "
        read input
        [ "$input" != $NETWORK ] && return 1
    else
        echo -ne "You are going to stop and remove remote network **\x1b[1;31m$NETWORK\x1b[0m**! [0/3] "
        for t in 1 2 3 ; do
            sleep 1
            echo -ne "\b\b\b\b\b\b[$t/3] "
        done
        echo
    fi

    for ip in $HOSTS ; do
        script uninstall --host=$ip $PATHS
        if [ -z "$PATHS" ] ; then
            script run . --host=$ip -- rm -fr \
                "entity-*" "validator-*" "sentry-*" "compute-*" "client-*" "seed-*" "runtime-*" "w3-gateway-*" "envoy-*" \
                genesis.json service.sh check_upgrade \
                ${HELA_NODE##*/} ${HELA_CLI##*/} ${HELA_WEB3_GATEWAY##*/} ${ENVOY##*/}
        else
            script run . --host=$ip -- rm -fr $PATHS
        fi
    done
} #}}}

do_entity() { #{{{
    local entity id account client
    for client in `get_all_clients` ; do
        break
    done
    [ -z "$PATHS" ] && PATHS=`get_all_entities`

    for entity in $PATHS ; do

        msg -e "\n################ $entity ################\n"
        id=`get_entity_id $entity`
        echo "id:         $id"

        [ -n "${ENTITY_VALIDATORS[$entity]}" ] &&
        echo "validators: ${ENTITY_VALIDATORS[$entity]}"

        [ -n "${ENTITY_COMPUTES[$entity]}" ] &&
        echo "computes:   ${ENTITY_COMPUTES[$entity]}"

        account=`get_entity_address $entity`
        echo "account:    $account"
        echo --
        script run -s $client -- $RMT_BIN_PATH/${HELA_NODE##*/} stake account info -a unix:./internal.sock \
            --stake.account.address $account
    done
} #}}}

do_status() { #{{{
    local node host id port ip
    local nodes="$PATHS"

    [ -z "$nodes" ] && {
        [ -n "$HOSTS" ] && {
            for host in $HOSTS ; do
                nodes="$nodes ${SERVICES[$host]}"
            done
        }
    }

    #for node in `get_all_validators` `get_all_non_validators` `get_all_sentries` `get_all_computes` `get_all_clients` `get_all_seeds` `get_all_w3_gateways` `get_all_envoys`; do
    for node in $nodes; do
        [ -n "$PATHS" ] && {
            is_among $node $PATHS || continue
        }

        ip=`get_service_ip $node`

        msg -e "\n################ $node ################\n"

        {
            echo "ip:              $ip"
        }

        [ "$node" != "${node#validator-}" -o "$node" != "${node#non-validator-}" -o "$node" != "${node#sentry-}" -o "$node" != "${node#compute-}" -o "$node" != "${node#client-}" -o "$node" != "${node#seed-}" ] && {
            id=`sed -n 2p $node/identity_pub.pem`
            echo "id:              $id"
            port=`yq -r .consensus.tendermint.core.listen_address $node/config.yml`
            echo "consensus port:  ${port##*:}"
            [ "$node" != "${node#compute-}" -o "$node" != "${node#client-}" ] &&
            echo "worker p2p port: `yq -r .worker.p2p.port $node/config.yml`"
        }
        [ "$node" != "${node#w3-gateway-}" ] && {
            echo "chain id:        `yq -r .gateway.chain_id $node/config.yml`"
            echo "http port:       `yq -r .gateway.http.port $node/config.yml`"
            echo "websocket port:  `yq -r .gateway.ws.port $node/config.yml`"
            echo "monitor port:    `yq -r .gateway.monitoring.port $node/config.yml`"
        }
        [ "$node" != "${node#envoy-}" ] && {
            echo "ingress ep:      unix:`yq -r '.static_resources.clusters[0].load_assignment.endpoints[0].lb_endpoints[0].endpoint.address.pipe.path' $node/config.yml`"
            echo "egress ep:       htpp://$ip:`yq -r '.static_resources.listeners[0].address.socket_address.port_value' $node/config.yml`"
        }

        [ "$node" != "${node#validator-}" -o "$node" != "${node#non-validator-}" -o "$node" != "${node#sentry-}" -o "$node" != "${node#compute-}" -o "$node" != "${node#client-}" -o "$node" != "${node#seed-}" ] && {
            echo --
            script run -s $node -- $RMT_BIN_PATH/${HELA_NODE##*/} control status -a unix:./internal.sock | sed 's/\r$//' | jq ${SELECTOR:-.}
        }

        echo --
        script run -s $node -- systemctl --no-pager status $node
    done
} #}}}

do_setup() { #{{{
    local runtime client entity runtime_id priv_key orc_file finished
    
    for runtime in `get_all_runtimes` ; do
        local paraname=${runtime#runtime-}
        local netname=$NETWORK-$paraname

        for client in ${PATHS:+${RUNTIME_COMPUTES[$runtime]}} ${RUNTIME_CLIENTS[$runtime]} ; do
            [ -n "$PATHS" ] && {
                is_among $client $PATHS || continue
            }
            script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} runtime rm ${netname//-/_} ${paraname//-/_}

            script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} network rm ${netname//-/_}
            script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} network add-local ${netname//-/_} unix:$REMOTE_DEPLOY_PATH/$client/internal.sock \
                                        --desc "theNet" --symbol $GENESIS_TOKEN_SYMBOL --exponent $GENESIS_TOKEN_EXPONENT
            script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} network set-default ${netname//-/_}

            orc_file=`get_runtime_orc $runtime`
            runtime_id=`get_orc_id $orc_file`
            script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} runtime add ${netname//-/_} ${paraname//-/_} $runtime_id \
                                        --desc "theNet" --symbol HLUSD --exponent 18

            is_among $client $finished && continue

            for entity in `get_all_entities` ; do
                [ -z "$PATHS" ] && break
                [ -n "$ENTITY" -a "$ENTITY" = "$entity" ] || continue

                [ -f $entity/entity.pem ] || continue

                script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} wallet rm ${entity/-/_} --yes
                priv_key=`sed -n '2h;3{H;x;s/\n//;p}' $entity/entity.pem`
                script run $client -s -- $RMT_BIN_PATH/${HELA_CLI##*/} wallet import ${entity/-/_} --ed25519-priv $priv_key
                [ $entity = $GENESIS_SUPPLY_ENTITY ] &&
                script run $client -- $RMT_BIN_PATH/${HELA_CLI##*/} wallet set-default ${entity/-/_}
            done

            finished="$finished $client"
        done
    done
} #}}}

# $1: runtime
upgrade_runtime() { #{{{
    local runtime=${1}
    local exist_id exist_version version orc_file client node ip
    local genesis_bak

    $LOCKED && return 1

    orc_file=`get_runtime_orc $runtime`
    version=`get_orc_version $orc_file`
    id=`get_orc_id $orc_file`
    exist_id=`jq -r ".id" $runtime/runtime_genesis.json`

    [ "$id" != "$exist_id" ] && {
        err "orc file $orc_file runtime id not matched!"
        exit 1
    }

    while read exist_version ; do
        [ `version_value $version` -le `version_value $exist_version` ] && {
            err "version $version existing or expired!"
            exit 1
        }
    done < <(jq -j '.deployments[].version | .major,".",.minor//0,".",.patch//0,"\n"' $runtime/runtime_genesis.json)

    genesis_bak=`cat $runtime/runtime_genesis.json`

    msg "Upgrading $runtime to $version..."

    for client in ${RUNTIME_COMPUTES[$runtime]} ; do
        break
    done

    # upgrade runtime descriptor file


    local major=${version%%.*}
    local minor=${version%.*}; minor=${minor#*.}; minor=${minor#0}
    local patch=${version##*.}; patch=${patch#0}

    local epoch=`script --force run -s $client -- $RMT_BIN_PATH/${HELA_NODE##*/} control status -a unix:./internal.sock | jq .consensus.latest_epoch`

    local max_epoch=`jq ".deployments | max_by(.valid_from) | .valid_from//0" $runtime/runtime_genesis.json`
    local up_epoch=$((EPOCH>=epoch?EPOCH:(epoch+(EPOCH>0?EPOCH:1))))
    [ "$up_epoch" -le "$epoch" ] && {
        err "Upgrade epoch $up_epoch is not greater than current epoch $epoch!"
        exit 1
    }

    content=`jq "
        del(.deployments[] | select(.valid_from != $max_epoch)) |
        .deployments += [{
            \"version\": {
                \"major\": $major
                ${minor:+,\"minor\": $minor}
                ${patch:+,\"patch\": $patch}
            },
            \"valid_from\": ${up_epoch}
        }]
    " $runtime/runtime_genesis.json`
    echo "$content" >$runtime/runtime_genesis.json

    # submit transaction to register new version

    local entity=${RUNTIME_ENTITY[$runtime]}
    local once=`script entity -s ${entity} | sed -n 's/^Nonce: \([0-9]\+\)\s*$/\1/p'`
    local tmp_file=`mktemp -u`
    tmp_file=${tmp_file##*/}

    if $MANUAL_SIGN ; then
        msg "Run blow command and copy file upgrade_hela_evm.tx to ./$client/$tmp_file:"
        echo "    $HELA_NODE registry runtime gen_register \\
            --debug.dont_blame_oasis true \\
            --genesis.file ./genesis.json \\
            --signer.backend file \\
            --signer.dir ./${entity} \\
            --runtime.descriptor ./$runtime/runtime_genesis.json \\
            --transaction.file ./upgrade_hela_evm.tx \\
            --transaction.fee.gas 2000 \\
            --transaction.fee.amount 1 \\
            --transaction.nonce $once \\
            -y"
        while ! [ -f ./$client/$tmp_file ] ; do
            msg -n "Press enter to continue: "
            read
        done
    else
      set -x
      $HELA_NODE registry runtime gen_register \
        --debug.dont_blame_oasis true \
        --genesis.file ./genesis.json \
        --signer.backend file \
        --signer.dir ./${entity} \
        --runtime.descriptor ./$runtime/runtime_genesis.json \
        --transaction.file ./$client/$tmp_file \
        --transaction.fee.gas 2000 \
        --transaction.fee.amount 1 \
        --transaction.nonce $once 
      set +x
    fi

    script up  $client/$tmp_file
    script run $client -- $RMT_BIN_PATH/${HELA_NODE##*/} consensus submit_tx -a unix:./internal.sock --transaction.file ${tmp_file}
    local tx_ret=$?

    script run $client -- rm -f ./${tmp_file}
    rm -f ./$client/${tmp_file}

    [ $tx_ret != 0 ] && {
        echo "$genesis_bak" >$runtime/runtime_genesis.json
        err "Failed to register new $runtime version!"
        exit 1
    }

    # upload new descriptor and orc

    local filename=${runtime#runtime-}-runtime-${version//./-}.orc
    for ip in `get_runtime_servers $runtime` ; do
        script up --host=$ip $runtime/runtime_genesis.json
        rsync -Lt $orc_file $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/$runtime/$filename
    done

    # restart node with new config file
    for node in ${RUNTIME_COMPUTES[$runtime]} ${RUNTIME_CLIENTS[$runtime]} ; do
        yq -yi ".runtime.paths += [\"../$runtime/$filename\"]" $NETWORK/$node/config.yml
        script up    $node/config.yml
        #script stop  $node
        #script start $node
    done
} #}}}

update_oasis_node_binary() { #{{{
    local ip node ips
    local -A nodes

    $LOCKED && return 1

    for node in `get_all_validators` `get_all_computes` `get_all_clients` `get_all_non_validators` `get_all_sentries` `get_all_seeds` ; do
        ip=`get_service_ip $node`
        [ -n "$HOSTS" ] && {
            is_among $ip $HOSTS || continue
        }
        is_among $ip $ips || ips="$ips${ips:+ }$ip"
        nodes[$ip]="${nodes[$ip]}${nodes[$ip]:+ }$node"
        #script stop $node
    done

    for ip in $ips ; do
        #for node in ${nodes[$ip]} ; do
        #    script stop $node
        #done

        msg "## Syncing hela-node to $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}}) $REMOTE_DEPLOY_PATH ..."
        rsync -Lvt $HELA_NODE $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/${HELA_NODE##*/}.upgrade${TIMESTAMP:+.}$TIMESTAMP

        #for node in ${nodes[$ip]} ; do
        #    [ "$1" = --clean-log ] && script run $node -- rm -f "./node.log"
        #    script start $node
        #
        #    while :; do
        #        local cs=`script run -s $node -- $RMT_BIN_PATH/${HELA_NODE##*/} control status -a unix:./internal.sock | jq -r .consensus.status 2>/dev/null`
        #        [ "$cs" = ready ] && break
        #        sleep 2
        #    done
        #
        #    while [ "$node" != "${node#client-}" -o "$node" != "${node#compute-}" ]; do
        #        local cs=`script run -s $node -- $RMT_BIN_PATH/${HELA_NODE##*/} control status -a unix:./internal.sock | jq -r ".runtimes.[].committee.status" 2>/dev/null`
        #        [ "$cs" = ready ] && break
        #        sleep 2
        #    done
        #done
    done
} #}}}

update_web3_gateway_binary() { #{{{
    local ip node ips nodes

    $LOCKED && return 1

    for node in `get_all_w3_gateways` ; do
        ip=`get_service_ip $node`
        [ -n "$HOSTS" ] && {
            is_among $ip $HOSTS || continue
        }
        is_among $ip $ips || ips="$ips${ips:+ }$ip"
        nodes="$nodes${nodes:+ }$node"
        script stop $node
    done

    for ip in $ips ; do
        rsync -Lvt $HELA_WEB3_GATEWAY $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/
    done

    for node in $nodes ; do
        [ "$1" = --clean-log ] && script run $node -- rm -f "./node.log"
        script start $node
    done
} #}}}

update_cli() { #{{{
    local server ip node

    $LOCKED && return 1

    for server in $SERVERS ; do
        [ -n "$HOSTS" ] && {
            is_among $server $HOSTS || continue
        }
        [ -n "$PATHS" ] && {
            local find=false
            for node in $PATHS ; do
                ip=`get_service_ip $node`
                [ "$ip" = "$server" ] && find=true
            done
            $find || continue
        }
        rsync -Lvt $HELA_CLI $DEPLOY_USER@$server:$REMOTE_DEPLOY_PATH/
    done
} #}}}

# $1: runtime
register_runtime() { #{{{
    local runtime=${1}
    local exist_version version orc_file epoch client node ip

    orc_file=`get_runtime_orc $runtime`
    version=`get_orc_version $orc_file`

    msg "Registering $runtime to $version..."

    for client in ${RUNTIME_CLIENTS[$runtime]} ; do
        break
    done

    # upgrade runtime descriptor file

    epoch=`script run -s $client -- $RMT_BIN_PATH/${HELA_NODE##*/} control status -a unix:./internal.sock | jq .consensus.latest_epoch`

    local major=${version%%.*}
    local minor=${version%.*}; minor=${minor#*.}; minor=${minor#0}
    local patch=${version##*.}; patch=${patch#0}

    content=`jq "
        del(.deployments[]) |
        .deployments += [{
            \"version\": {
                \"major\": $major
                ${minor:+,\"minor\": $minor}
                ${patch:+,\"patch\": $patch}
            },
            \"valid_from\": $((epoch-10))
        }]
    " $runtime/runtime_genesis.json`
    echo "$content" >$runtime/runtime_genesis.json

    # submit transaction to register new version

    local once=`script entity -s ${RUNTIME_ENTITY[$runtime]} | sed -n 's/^Nonce: \([0-9]\+\)\s*$/\1/p'`
    local tmp_file=`mktemp -u`
    tmp_file=${tmp_file##*/}

    set -x
    $HELA_NODE registry runtime gen_register \
        --debug.dont_blame_oasis true \
        --genesis.file ./genesis.json \
        --signer.backend file \
        --signer.dir ./${RUNTIME_ENTITY[$runtime]} \
        --runtime.descriptor ./$runtime/runtime_genesis.json \
        --transaction.file ./$client/$tmp_file \
        --transaction.fee.gas 1000 \
        --transaction.fee.amount 1 \
        --transaction.nonce $once \
        -y
    set +x

    script up $client/$tmp_file
    script run $client -- $RMT_BIN_PATH/${HELA_NODE##*/} consensus submit_tx -a unix:./internal.sock --transaction.file ${tmp_file}
    local tx_ret=$?

    script run $client -- rm -f ./${tmp_file}
    rm -f ./$client/${tmp_file}

    [ $tx_ret != 0 ] && {
        err "Failed to register new $runtime version!"
        exit 1
    }

    # upload new descriptor and orc

    local filename=${runtime#runtime-}-runtime-${version//./-}.orc
    for ip in `get_runtime_servers $runtime` ; do
        script up --host=$ip $runtime/runtime_genesis.json
        rsync -Lt $orc_file $DEPLOY_USER@$ip:$REMOTE_DEPLOY_PATH/$runtime/$filename
    done

    # restart node with new config file
    for node in ${RUNTIME_COMPUTES[$runtime]} ${RUNTIME_CLIENTS[$runtime]} ; do
        yq -yi ".runtime.paths = [] | .runtime.paths += [\"../$runtime/$filename\"]" $NETWORK/$node/config.yml
        script up $node/config.yml
        script stop $node
        script start $node
    done
} #}}}

# from to amount
transfer_token() { #{{{
    local from_entity=$1 to_entity=$2 amount=$3
    local to_addr client

    [ "${to_entity}" != "${to_entity#oasis1}" ] && {
        to_addr=$to_entity
    } || {
        to_addr=`get_entity_address $to_entity`
    }

    amount=$((amount * `exponent_value $GENESIS_TOKEN_EXPONENT`))

    msg "Trasfer $amount $GENESIS_TOKEN_SYMBOL from $from_entity to $to_entity..."

    for client in `get_all_clients` ; do
        break
    done

    local once=`script entity -s $from_entity | sed -n 's/^Nonce: \([0-9]\+\)\s*$/\1/p'`
    local tmp_file=`mktemp -u`
    tmp_file=${tmp_file##*/}

    set -x
    $HELA_NODE stake account gen_transfer \
        --debug.dont_blame_oasis true \
        --genesis.file ./genesis.json \
        --signer.backend file \
        --signer.dir ./$from_entity \
        --stake.transfer.destination $to_addr \
        --stake.amount $amount \
        --transaction.file ./$client/$tmp_file \
        --transaction.fee.gas 1500 \
        --transaction.fee.amount 2000 \
        --transaction.nonce $once \
        -y
    set +x

    script up -s $client/$tmp_file
    script run $client -- $RMT_BIN_PATH/${HELA_NODE##*/} consensus submit_tx -a unix:./internal.sock --transaction.file ${tmp_file}
    local tx_ret=$?

    script run -s $client -- rm -f ./${tmp_file}
    rm -f ./$client/${tmp_file}

    [ $tx_ret = 0 ] || {
        err "Failed to submit tx!"
        return 1
    }
} #}}}

# entity amount
stake_escrow() { #{{{
    local entity=$1 amount=$2
    local addr client

    addr=`get_entity_address $entity`
    amount=$((amount * `exponent_value $GENESIS_TOKEN_EXPONENT`))

    msg "Stack $amount $GENESIS_TOKEN_SYMBOL from $entity to escrow..."

    for client in `get_all_clients` ; do
        break
    done

    local once=`script entity -s $entity | sed -n 's/^Nonce: \([0-9]\+\)\s*$/\1/p'`
    local tmp_file=`mktemp -u`
    tmp_file=${tmp_file##*/}

    set -x
    $HELA_NODE stake account gen_escrow \
        --debug.dont_blame_oasis true \
        --genesis.file ./genesis.json \
        --signer.backend file \
        --signer.dir ./$entity \
        --stake.escrow.account $addr \
        --stake.amount $amount \
        --transaction.file ./$client/$tmp_file \
        --transaction.fee.gas 1000 \
        --transaction.fee.amount 2000 \
        --transaction.nonce $once \
        -y
    set +x

    script up -s $client/$tmp_file
    script run $client -- $RMT_BIN_PATH/${HELA_NODE##*/} consensus submit_tx -a unix:./internal.sock --transaction.file ${tmp_file}
    local tx_ret=$?

    script run -s $client -- rm -f ./${tmp_file}
    rm -f ./$client/${tmp_file}

    [ $tx_ret = 0 ] || {
        err "Failed to submit tx!"
        return 1
    }
} #}}}

# entity
register_entity() { #{{{
    local entity=$1
    local client

    msg "Register $entity ..."

    for client in `get_all_clients` ; do
        break
    done

    local once=`script entity -s $entity | sed -n 's/^Nonce: \([0-9]\+\)\s*$/\1/p'`
    local tmp_file=`mktemp -u`
    tmp_file=${tmp_file##*/}

    set -x
    $HELA_NODE registry entity gen_register \
        --debug.dont_blame_oasis true \
        --genesis.file ./genesis.json \
        --signer.backend file \
        --signer.dir ./$entity \
        --transaction.file ./$client/$tmp_file \
        --transaction.fee.gas 4000 \
        --transaction.fee.amount 4000 \
        --transaction.nonce $once \
        -y
    set +x

    script up -s $client/$tmp_file
    script run $client -- $RMT_BIN_PATH/${HELA_NODE##*/} consensus submit_tx -a unix:./internal.sock --transaction.file ${tmp_file}
    local tx_ret=$?

    script run -s $client -- rm -f ./${tmp_file}
    rm -f ./$client/${tmp_file}

    [ $tx_ret = 0 ] || {
        err "Failed to submit tx!"
        return 1
    }
} #}}}

list_entity_registry() { #{{{
   local id entity client

    for client in `get_all_clients` ; do
        break
    done

    while read id ; do
        id=${id%$'\r'}
        for entity in `get_all_entities` ; do
            [ "`get_entity_id $entity`" = "$id" ] && echo "$entity: $id"
        done
    done < <(script run -s $client -- $RMT_BIN_PATH/${HELA_NODE##*/} registry entity list -a unix:./internal.sock)
} #}}}

list_runtime_registry() { #{{{
    local client
    for client in `get_all_clients` ; do
        break
    done

    script run -s $client -- $RMT_BIN_PATH/${HELA_NODE##*/} registry runtime list $* -a unix:./internal.sock
} #}}}

generate_entity() { #{{{
    local entity=$1

    [ -d $NETWORK/$entity ] && {
        wrn "$entity existing!"
        return 1
    }

    msg "generating $entity..."

    mkdir -p -m 700 $NETWORK/$entity

    $HELA_NODE registry entity init --signer.dir $NETWORK/$entity
    ln -snf $NETWORK/$entity
} #}}}

#}}}


#{{{ parse arguments
while [ "$#" -gt 0 ] ; do
    case $1 in
    up|down|diff|run|exec|install|uninstall|start|stop|shell|generate|clean|deploy|undeploy|entity|status|setup|unlink|compile|lock|unlock)
        OP=$1
        ;;
    --network=?*)
        NETWORK=${1#*=}
        ;;
    --host=?*|--hosts=?*)
        HOSTS=${1#*=}
        HOSTS="${HOSTS//,/ }"
        ;;
    --entity=?*)
        ENTITY=${1#*=}
        ;;
    --ssh-key=?*)
        SSH_KEY=${1#*=}
        ;;
    --selector=?*)
        SELECTOR=${1#*=}
        ;;
    --epoch=?*)
        EPOCH=${1#*=}
        ;;
    --app-port=?*)
        APP_START_PORT=${1#*=}
        ;;
    --ts=?*)
        TIMESTAMP=${1#*=}
        ;;
    --manual-sign)
        MANUAL_SIGN=true
        ;;
    --silent|-s)
        SILENT=true
        ;;
    -y|--no-interact)
        INTERACT=false
        ;;
    --no-start)
        NO_START=true
        ;;
    --dry-run)
        DRY_RUN=true
        ;;
    --to-home|--home)
        TO_HOME=.
        ;;
    --)
        shift
        break
        ;;
    *)
        path=${1%/}
        path=${path#./}
        [ -e "$path" -o $OP = down ] && [ -n "${1%/}" ] && PATHS="$PATHS${PATHS:+ }$path" || {
            echo "usage: $0 generate|clean|deploy|undeploy|unlink|compile [--network=...] [PATHS...]"
            echo "       $0 up|down|diff|run|exec|install|uninstall|start|stop [--network=...] [--host=...] [PATHS...]"
            exit 1
        }
        ;;
    esac
    shift
done
#}}}

#{{{ decide NETWORK
[ -f .default ] && DEF_NEWORK=`sed -n 's/^NETWORK=\(.*\)/\1/p' .default`
[ -z "$NETWORK" -a -n "$DEF_NEWORK" ] && {
    NETWORK=$DEF_NEWORK
    network_by_default=true
} || network_by_default=false
NETWORK=${NETWORK%/}
[ -n "$NETWORK" ] || {
    err "Please specifyd network!"
    exit 1
}
[ "$NETWORK" != "$DEF_NEWORK" ] && {
    [ -f .default ] || echo > .default
    sed -i "/^NETWORK=/ { s/.*/NETWORK=$NETWORK/; h; }
            $ { x; /./{x; b;}; x
                a NETWORK=$NETWORK
            }
    " .default
}
[ -d $NETWORK -a -f $NETWORK/config ] || {
    err "Network config not existing!"
    exit 1
}

# get values from config 
[ -f $NETWORK/config ] || {
    err "cannot find network config file!"
    exit 1
}
. $NETWORK/config
#}}}

#{{{ check parameters

_SERVERS=
for server in $SERVERS ; do
    [ "$server" != "${server/@}" ] && {
        SERVER_DEPLOY_USER[${server#*@}]=${server%@*}
        _SERVERS="$_SERVERS ${server#*@}"
    } || {
        _SERVERS="$_SERVERS ${server}"
    }
done
SERVERS="$_SERVERS"

declare -A HOST_MAP

# --host=service => host
_HOSTS=
[ -n "$HOSTS" ] && {
    for host in $HOSTS ; do
        [ -n "${host//[0-9.]}" ] && {
            ip=`get_service_ip ${host%/}`
            [ -z "$ip" ] && {
                echo "host $host not defined!"
                exit 1
            }
            HOST_MAP[$ip]=$host
            host=$ip
        }
        is_among $host $_HOSTS || _HOSTS="$_HOSTS${_HOSTS:+ }$host"
    done
    HOSTS="$_HOSTS"
}

#[ -n "$HOSTS" -a -n "$PATHS" ] && {
#    for path in $PATHS ; do
#        ip=`get_service_ip ${path%%/*}`
#        [ -n "$ip" ] && ! is_among $ip $HOSTS && {
#            echo "$path not under any host!"
#            exit 1
#        }
#    done
#}

# PATHS => HOSTS
[ -z "$HOSTS" ] && {
    # from PATHS
    [ -n "$PATHS" ] && {
        for path in $PATHS ; do
            ip=`get_service_ip ${path%%/*}`
            [ -z "$ip" ] || is_among "$ip" $HOSTS && continue
            HOST_MAP[$ip]=$path
            HOSTS="$HOSTS${HOSTS:+ }$ip"
        done
    }
}

[ -z "$HOSTS" ] && HOSTS="$SERVERS"

[ -f $NETWORK/.lock ] && {
    LOCKED=true
    is_among $OP clean deploy undeploy && DRY_RUN=true
}

#}}}

update_symbolic_links

check_tools

HELA_NODE_VER=`get_hela_node_version 2>/dev/null`
HELA_NODE_VER_MAJOR=`get_version_major $HELA_NODE_VER`

# app op
case $OP in
generate|clean|deploy|undeploy|entity|status|setup|unlink|compile|lock|unlock)
    do_$OP "$@"
    exit
    ;;
exec)
    msg "### Executing: $@" >&2
    "$@"
    exit
    ;;
nop)
    exit
    ;;
esac

# system op
ret_code=0
for ip in $HOSTS ; do

    case $OP in
    install|uninstall|start|stop)
        [ -z "$PATHS" ] && paths="${SERVICES[$ip]}" || paths="$PATHS"
        ;;
    up|down|diff)
        [ -z "$PATHS" ] && paths="${SERVICES[$ip]}" || paths="$PATHS"
        paths="$paths `get_extra_paths $paths`"
        ;;
    shell|run)
        [ -z "$PATHS" ] && paths=. || paths="$PATHS"
        ;;
    esac

    for path in $paths ; do

        svc_ip=`get_service_ip ${path%%/*}`
        [ -n "$svc_ip" -a "$svc_ip" != $ip ] && continue

        [ "$path" != "${path/\/}" ] && path_dir=${path%/*}/ || path_dir=
        [ -n "$TO_HOME" ] && path_dir=

        case $OP in
        up)
            msg "### Syncing $path to $ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path_dir ..."
            rsync -rLt $EXCLUDE_ARGS $path $DEPLOY_USER@$ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path_dir
            ((ret_code |= $?))
            echo
            ;;
        down)
            msg "### Syncing $ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path to ./$path ..."
            rsync -rLt $EXCLUDE_ARGS $DEPLOY_USER@$ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path ./$path
            ((ret_code |= $?))
            echo
            ;;
        diff)
            msg "### Diffing $path to $ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path ..."
            rsync -rLcv --dry-run $EXCLUDE_ARGS $path $DEPLOY_USER@$ip:${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path_dir
            ((ret_code |= $?))
            echo
            ;;

        shell)
            msg "### Login shell to $ip ..."
            ssh $DEPLOY_USER@$ip
            ;;
        run)
            [ "$*" != "${*/unix:}" -a "${path#w3-gateway}" != "${path}" ] && continue
            [ -n "$TO_HOME" ] && TO_HOME="~"
            msg "### Running <<<$HLWRN$@$HLMSG>>> @ $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}}):${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path:"
            #ssh -qt $DEPLOY_USER@$ip bash -lc "\"cd ${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path; ${@//_SERVICE_/${path##*/}}\""
            remote_run -l -s -h $ip "cd ${TO_HOME:-$REMOTE_DEPLOY_PATH}/$path; ${@//_SERVICE_/${path##*/}}"
            ((ret_code |= $?))
            echo
            ;;

        install)
            msg "### Installing $path on $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}})..."
            ssh -qt $DEPLOY_USER@$ip bash -lc "\"$REMOTE_DEPLOY_PATH/service.sh install $path\""
            ((ret_code |= $?))
            echo
            ;;
        uninstall)
            msg "### Uninstalling $path on $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}})..."
            ssh -t $DEPLOY_USER@$ip bash -lc "\"$REMOTE_DEPLOY_PATH/service.sh uninstall $path\""
            ((ret_code |= $?))
            echo
            ;;
        start)
            msg "### Starting $path on $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}})..."
            ssh -qt $DEPLOY_USER@$ip bash -lc "\"$REMOTE_DEPLOY_PATH/service.sh start $path\""
            ((ret_code |= $?))
            echo
            ;;
        stop)
            msg "### Stopping $path on $ip (${HOST_MAP[$ip]:-${SERVICES[$ip]}})..."
            ssh -qt $DEPLOY_USER@$ip bash -lc "\"$REMOTE_DEPLOY_PATH/service.sh stop $path\""
            ((ret_code |= $?))
            echo
            ;;

        *)
            err "Unknown operation"
            ;;
        esac
    done
done

exit $ret_code
