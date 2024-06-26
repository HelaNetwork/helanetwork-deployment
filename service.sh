#!/bin/bash

[ -z "$BASE_DIR" ] && pushd ${0%/*}/ >/dev/null && BASE_DIR=$PWD && popd >/dev/null
cd "$BASE_DIR"

op=$1
service_dir=$2
user=${3:-`whoami`}
[ -x hela-node ] && exec=hela-node || exec=oasis-node

service=${service_dir%/}
service=${service##*/}

args="--config ../$service/config.yml"

[ -z "$op" -o -z "$service" ] && {
    echo "Usage: $0 <install | uninstall | start | stop> <SERVICE DIR>"
    exit 1
}

[ -f genesis.json ] && grep "\"debug_" genesis.json >/dev/null && {
    args="$args --debug.dont_blame_oasis"
}

[ "$service" != "${service#w3-gateway-}" ] && {
    [ -x hela-web3-gateway ] && exec=hela-web3-gateway || exec=oasis-web3-gateway
    args="--config ../$service/config.yml"
}
[ "$service" != "${service#envoy-}" ] && {
    exec=envoy
    args="-c ../$service/config.yml --log-path node.log"
}

#{{{
HLMSG=$'\x1b'"[1;32m"
HLWRN=$'\x1b'"[1;35m"
HLERR=$'\x1b'"[1;31m"
HLEND=$'\x1b'"[0m"

# $* : [ARG_OF_echo] MSG
msg()
{
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLMSG${1}$HLEND"
}
wrn()
{
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLWRN${1}$HLEND"
}
err()
{
    local arg
    [ "$1" != "${1#-}" ] && { arg=$1; shift; }
    echo $arg "$HLERR${1}$HLEND"
}
#}}}

do_install() { #{{{
    systemctl is-active $service >/dev/null && {
        msg "Stop current running service $service..."
        sudo systemctl stop $service
        sleep 0.1
    }

    systemctl is-active $service >/dev/null && {
        err "Stop running service $service failed"
    }

    msg "Generate Unit file for service $service..."
    cat >$service.service <<EOF
[Unit]
Description=Hela $service
After=syslog.target network.target

[Service]
WorkingDirectory=$BASE_DIR/$service
ExecStart=$BASE_DIR/$exec $args
User=$user
KillMode=process
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    
    [ $exec != ${exec%-node} ] && {
        sed -i '
            /^ExecStart=/i ExecStartPre=-'$BASE_DIR'/check_upgrade
        ' $service.service
    }

    msg "Install service $service..."
    sudo mv $service.service /etc/systemd/system/ || {
        err "Install service $service failed"
        exit 1
    }

    sudo systemctl daemon-reload

    msg "Enable service $service..."
    sudo systemctl enable $service || {
        err "Enable service $service failed"
        exit 1
    }

    #msg "Start service $service..."
    #sudo systemctl start $service || {
    #    err "Start service $service failed"
    #    exit 1
    #}
    #
    #msg "Check status of service $service..."
    #sleep 1
    #systemctl status --no-pager $service
    #systemctl is-active $service >/dev/null || {
    #    err "Srvice $service is not running after start"
    #    exit 1
    #}
} #}}}

do_uninstall() { #{{{
    systemctl is-active $service >/dev/null && {
        msg "Stop current running service $service..."
        sudo systemctl stop $service
        sleep 1
    }

    systemctl is-active $service >/dev/null && {
        err "Stop running service $service failed"
        exit 1
    }

    msg "Disable service $service..."
    sudo systemctl disable $service || {
        err "Disable service $service failed"
        exit 1
    }

    msg "Uninstall service $service..."
    sudo rm -f /etc/systemd/system/$service.service || {
        err "Uninstall service $service failed"
        exit 1
    }

    sudo systemctl daemon-reload
} #}}}

do_start() { #{{{
    systemctl is-active $service >/dev/null && {
        wrn "Service $service is running"
        exit 0
    }

    msg "Start service $service..."
    sudo systemctl start $service || {
        err "Start service $service failed"
        exit 1
    }

    msg "Check status of service $service..."
    sleep 0.5
    systemctl status --no-pager $service
} #}}}

do_stop() { #{{{
    msg "Stop service $service..."
    sudo systemctl stop $service || {
        err "Stop service $service failed"
        exit 1
    }

    msg "Check status of service $service..."
    sleep 0.1
    systemctl status --no-pager $service
} #}}}

do_$op
