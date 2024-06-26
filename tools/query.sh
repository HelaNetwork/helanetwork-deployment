#!/bin/bash
#

TX=
BLOCK=
TS=
FUNC=

NET=
WITH_TX=false
LAYER=runtime
BLK_TM=5
CURL="curl -s"

declare -A RPC_URL API_URL
RPC_URL[hela-mainnet]=https://mainnet-rpc.helachain.com
RPC_URL[hela-testnet]=https://testnet-rpc.helachain.com
RPC_URL[ihpc-tps]=http://10.10.10.100:3000

API_URL[hela-mainnet]=https://mainnet-api-scanner.helachain.com/chain
API_URL[hela-testnet]=https://testnet-api-scanner.helachain.com/chain
API_URL[ihpc-tps]=http://10.10.10.100:8081/chain

[ -f config ] && . config

init() {
    [ -z "$NET" ] && [ -L config ] && {
        local l=`readlink config`
        NET=${l%/*}
    }
    RPC_URL=${RPC_URL[$NET]}
    API_URL=${API_URL[$NET]}

    [ -z "$RPC_URL" -a -z "$API_URL" ] && exit 1
}

get_node() {
    local entity
    for entity in entity-[0123]?/entity.json ; do
        [ -f "$entity" ] || break
        local node_id=`jq -r .nodes[0] $entity`
        [ "$node_id" = "$1" ] && {
            echo "${ENTITY_COMPUTES[${entity%/*}]}${ENTITY_VALIDATORS[${entity%/*}]}"
            break
        }
    done
}

#{{{
consensus_get_tx() {
    local tx=`$CURL $API_URL/transaction/$1 | jq .data`

    [ "$tx" = null ] && {
        echo "$tx"
        return
    }

    eval "local raw=`echo $tx | jq .raw`"
    local id=`echo "$raw" | jq -r .signature.public_key`
    local node=`get_node $id`
    [ -n "$node" ] && {
        tx=`echo "$tx" | jq "._node = \"$node\""`
    }
    echo "$tx" | jq ".raw=$raw"
}

consensus_get_blk() {
    $CURL $API_URL/block/$1 | jq .data
}

consensus_get_latest_blk() {
    $CURL "$API_URL/blocks?start=0&size=1&page=1" | jq ".data.list[0]"
}

consensus_get_blk_txs() {
    $CURL $API_URL/transactions?height=$1 | jq .data.list
}

consensus_get_blk_ts() {
    get_blk "$1" | jq .timestamp
}

consensus_get_blk_height() {
    get_blk "$1" | jq .height
}

consensus_show_blk() {
    local blk=`get_blk "$1"`
    [ "$blk" = null ] && {
        echo "cannot find block $1"
        exit 1
    }
    $WITH_TX && {
        local txs=`echo "$blk" | jq .txs`
        [ "$txs" = 0 ] && {
            local height=`get_blk_height "$blk"`
            consensus_show_blk $((height+1))
            return
        }
        [ "$txs" != 0 ] && {
            blk=`echo "$blk" | jq '._txs=[]'`
            local tx
            while read tx ; do
                local tx_hash=`echo "$tx" | jq -r .txHash`
                tx=`get_tx $tx_hash`
                blk=`echo "$blk" | jq "._txs += [$tx]"`
            done < <(get_blk_txs $1 | jq -c .[])
        }
    }
    
    echo "$blk" | jq
    echo $(($1)) >&2
}
#}}}

#{{{
runtime_get_tx() {
    [ "$1" = "${1#0x}" ] && local tx_hash=0x$1 || local tx_hash=$1
    $CURL -X POST -H "Content-Type: application/json" \
      --data '{
        "jsonrpc":"2.0",
        "method":"eth_getTransactionByHash",
        "params":["'$tx_hash'"],
        "id": '$RANDOM'
      }' $RPC_URL | jq .result
}

runtime_get_blk() {
    local hex_blk=`printf "0x%x" $1`
    $CURL -X POST -H "Content-Type: application/json" \
      --data '{
        "jsonrpc": "2.0",
        "method": "eth_getBlockByNumber",
        "params": ["'$hex_blk'", false],
        "id": '$RANDOM'
      }' $RPC_URL | jq .result
}

runtime_get_latest_blk() {
    local no=`$CURL -X POST -H "Content-Type: application/json" \
      --data '{
        "jsonrpc": "2.0",
        "method": "eth_blockNumber",
        "params":[],
        "id": '$RANDOM'
    }' $RPC_URL | jq -r .result`
    get_blk $no
}

runtime_get_blk_txs() {
    get_blk "$1" | jq .transactions
}

runtime_get_blk_ts() {
    get_blk "$1" | jq -r .timestamp | ( read x; [ -t 1 ] && echo $((x)) || echo $x; )
}

runtime_get_blk_height() {
    get_blk "$1" | jq -r .number | ( read x; [ -t 1 ] && echo $((x)) || echo $x; )
}

runtime_show_blk() {
    local blk=`get_blk "$1"`
    [ "$blk" = null ] && {
        echo $blk
        exit 1
    }
    $WITH_TX && {
        blk=`echo "$blk" | jq '._txs=[]'`
        local tx_hash
        while read tx_hash ; do
            local tx=`get_tx $tx_hash`
            blk=`echo "$blk" | jq "._txs += [$tx]"`
        done < <(get_blk_txs $1 | jq -rc .[])
    }
    local txs=`echo "$blk" | jq ".transactions | length"`
    blk=`echo "$blk" | jq ".txs = $txs"`
    
    echo "$blk" | jq 'del(.transactions)'
}
#}}}

#{{{
get_tx() {
    ${LAYER}_${FUNCNAME} "$@"
}

get_blk() {
    if [ "${1:0:1}" != '{' ] ; then
        ${LAYER}_${FUNCNAME} "$@"
    else
        echo "$1"
    fi
}

get_latest_blk() {
    ${LAYER}_${FUNCNAME} "$@"
}

get_blk_txs() {
    ${LAYER}_${FUNCNAME} "$@"
}
get_blk_ts() {
    ${LAYER}_${FUNCNAME} "$@"
}
get_blk_height() {
    ${LAYER}_${FUNCNAME} "$@"
}

show_blk() {
    echo "===== block on $NET ======" >&2
    ${LAYER}_${FUNCNAME} "$@"
}

show_tx() {
    echo "===== TX on $NET ======" >&2
    get_tx "$@"
}
#}}}

while [ "$#" -gt 0 ] ; do
    case $1 in
    --net=?*)
        NET=${1#*=}
        ;;
    --tx=?*)
        TX=${1#*=}
        ;;
    --ts=?*)
        TS=${1#*=}
        ;;
    --block=?*|--blk=?*|--height=?*)
        BLOCK=${1#*=}
        ;;
    --runtime|--l2)
        LAYER=runtime
        ;;
    --consensus|--l1)
        LAYER=consensus
        ;;
    --with-tx)
        WITH_TX=true
        ;;
    -?*)
        echo "usage: $0 [--net={mainnet}] --tx=TX_HASH | --block=BLK_NO [--with-tx] [FUNC]..."
        exit 1
        ;;
    *)
        [ "$(type -t $1)" = function ] && {
            FUNC=$1
            break
        }
        ;;
    esac
    shift
done

init

[ -n "$BLOCK" ] && {
    show_blk $BLOCK
}

[ -n "$TX" ] && {
    show_tx $TX
}

#find block
[ -n "$TS" ] && {
    latest=`get_latest_blk`

    end_ts=`get_blk_ts "${latest}"`
    end_height=`get_blk_height "${latest}"`

    blks=$(( (end_ts-TS)/BLK_TM*5/3 ))

    start_height=$((end_height-blks))
    ((start_height<=0)) && start_height=1

    while :; do
        blk=$(( (start_height+end_height)/2 ))
        [ $blk = $start_height ] && break

        ts=`get_blk_ts $blk`
        if ((ts > TS)) ; then
            end_height=$blk
        elif ((ts < TS)) ; then
            start_height=$blk
        else
            break
        fi
    done
    show_blk $blk
}

[ -n "$FUNC" ] && {
    "$@"
}
