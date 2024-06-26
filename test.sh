#!/bin/bash


MIN_ENTITY=400
MAX_ENTITY=3600

THREADS=

FROM_ENTITY=400
TO_ENTITY=800

START_TM=
TEST_DUR=60

ENVOY_ENDPOINTS=(
    http://10.9.9.153:3000
)

while [ $# -gt 0 ] ; do
    case $1 in
    --threads=?*)
        THREADS=${1#*=}
        ;;
    --from=?*)
        FROM_ENTITY=${1#*=}
        ;;
    --to=?*)
        TO_ENTITY=${1#*=}
        ;;
    --start-tm=?*)
        START_TM=${1#*=}
        ;;
    --dur=?*)
        TEST_DUR=${1#*=}
        ;;
    *)
        echo "usage: $0 --threads=... --from=... --to=... --start-tm=...  --dur=..." >&2
        exit 1
    esac
    shift
done

[ -z "$THREADS" ] && ((THREADS=TO_ENTITY-FROM_ENTITY))

((TO_ENTITY-FROM_ENTITY < THREADS)) || ((FROM_ENTITY >= TO_ENTITY)) || ((FROM_ENTITY < MIN_ENTITY)) || ((TO_ENTITY > MAX_ENTITY)) && {
    echo "Wrong parameters!" >&2
    exit 1
}

get_id() {
    local _k _v
    while read _k _v ; do
        [ "$_k" = \"id\": ] && {
          _v=${_v#\"}
          _v=${_v%\"*}
          break
        }
    done <$1/entity.json
    eval "$2=$_v"
}
get_key() {
    local _v _l
    while read _l ; do
        [ "$_l" = "${_l#-}" ] && {
          _v="$_v$_l"
        }
    done <$1/entity.pem
    eval "$2=$_v"
}
get_addr() {
    [ -f $1/entity.addr ] && {
        read $2 <$1/entity.addr
        return
    }

    read $2 < <(./builder exec -s -- get_entity_address $1)
}

get_name() {
    local _name
    (($1<10)) && _name=entity-0$1 || _name=entity-$1
    eval "$2=$_name"
}

gen_entity() {
    ./builder exec -- generate_entity $1
    ./builder exec -- transfer_token entity-51 $1 10
}


for ((i=MIN_ENTITY; i<MAX_ENTITY; i++)) ; do
    get_name $i name
    [ -d $name ] || {
        gen_entity $name
        get_addr $name addr
    }
done

echo "press enter to start..."
read


ENVOYS_NUM=${#ENVOY_ENDPOINTS[*]}

t=$THREADS
echo "@@@@@@@@@@ Testing by $t threads..." >&2

src=(`python3 -c "import random; print(random.sample(range($FROM_ENTITY, $((TO_ENTITY))), $t))" | sed 's/\[//;s/\]//;s/,//g'`)
dst=()

for ((i=0; i<t; i++)) ; do
    while :; do
        d=$((RANDOM%(TO_ENTITY - FROM_ENTITY) + FROM_ENTITY))
        ((d != ${src[i]})) && break
    done
    dst[i]=$d
done

echo ${src[*]} >&2
echo ${dst[*]} >&2

for ((i=0; i<${#src[*]}; i++)) ; do
    get_name ${src[$i]} entity
    [ -d "$entity" ] || gen_entity $entity
    get_key $entity src[$i]

    get_name ${dst[$i]} entity
    [ -d "$entity" ] || gen_entity $entity
    get_addr $entity dst[$i]
done

[ -z "$START_TM" ] && {
    START_TM=`date +%s`
    (( START_TM += 119 ))
    (( START_TM = START_TM - (START_TM%60) ))
}

now=`date +%s`
echo "            now is `date -d @$now`"
echo "test will start at `date -d @$START_TM`, $((START_TM-now))s later."

set -x
for ((i=0; i<${#src[*]}; i++)) ; do
    node test.mjs ${src[$i]} ${dst[$i]} $START_TM $TEST_DUR ${ENVOY_ENDPOINTS[$((i%ENVOYS_NUM))]} >test-$i.log 2>&1 &
    set +x
done

#ps x -H | grep -v grep | grep "node test.mjs" >&2
wait

total_tx=0
success_tx=0
error_tx=0

for ((i=0; i<${#src[*]}; i++)) ; do
    tx=`sed -n 's/.*,submit tx,\([^,]\+\),.*/\1/p' test-$i.log`
    success=`sed -n 's/.*,success,\([^,]\+\),.*/\1/p' test-$i.log`
    errors=`sed -n 's/.*,errors,\([^,]\+\),.*/\1/p' test-$i.log`

    [ -z "$tx" ] && {
        echo "#$((i+1)) test unit unknown error:" >&2
        cat test-$i.log >&2
    } || {
        ((total_tx += tx)) 
        ((success_tx += success)) 
        ((error_tx += errors)) 

        ((errors>0)) && {
            last_error_happen=`sed -n 's/.*,last error happend,\([^,]\+\),.*/\1/p' test-$i.log`
            last_error_msg=`sed -n 's/.*,last error msg,\([^,]\+\),.*/\1/p' test-$i.log`
            echo "#$((i+1)) test unit last error: @$last_error_happen, $last_error_msg" >&2
        }
    }

    rm -f test-$i.log
done

echo "entities,$t,duration,$TEST_DUR,total tx,$total_tx,success tx,$success_tx,error tx,$error_tx"
echo >&2
