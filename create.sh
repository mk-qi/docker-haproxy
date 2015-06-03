#!/usr/bin/env bash
# createcontainer.sh
# create container for docker
# 
# DEFAULT VALUE 
set -e
# name; container name
#  img; docker images
#  cmd; contianer run command like "/bin/bash --login"

# gen uuid for default hostname
# uuid=$(LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 32 | fold -w 7 | head -n 1)
# default container name
# name="${name:=sh-${uuid}}"

# usage:  
# _c_conatainer 
# _c_conatainer $name "${options}"  "${img}" "${cmd}"
_c_conatainer(){
    host="$1";options="$2";
    img="$3";cmd="$4";volume="$5"

    # DEFAULT VALUE
    host=${host:="${name}"}
    cmd="${cmd:="/bin/bash --login"}"
    img="${img:="centos:6"}"
    options=${options:="--rm -it"}
   # make sure $name container is not running; 
    docker inspect --format="{{ .State.Running }}"\
        $host 2> /dev/null && {
        echo the name of ${host} is running, try a new one;
        exit 2;
    }
    # base dir of storage container's data
    base="/data/containers"

    # container's  home
    # /data/containers/$name/
    hostdir="${base}/${host}"
    mkdir -p "${hostdir}"/{logs,data}

    basevolume="
          -v ${hostdir}/data:/data/ \
          -v ${hostdir}/logs:/data/logs \
          "
    volume="${basevolume} ${volume}"
    # start up container with options
    docker run  --name=${host} -h ${host} ${volume} ${options} ${img} ${cmd}

}
# inspired from pipework
# create macvlan 
_set_ip_forcontainer(){
    ifname=$1; name=$2;ipaddr=$3
    IPADDR=$ipaddr
    
    [ ! -d /sys/class/net/$ifname ] && {
        echo "${ifname}  dose not exsit";
        exit 2;
    }
    # get container pid
    pid=$(sudo docker inspect -f '{{.State.Pid}}' $name 2> /dev/null);
    [  $? != 0 ] && {
        echo "No such image or container: ${name}";
        exit 3;
    }
    
    if [ "$IPADDR" = "dhcp" ]
    then
        # Check for first available dhcp client
        DHCP_CLIENT_LIST="udhcpc dhcpcd dhclient"
        for CLIENT in $DHCP_CLIENT_LIST; do
            which $CLIENT >/dev/null && {
                DHCP_CLIENT=$CLIENT
                break
            }
        done
        [ -z $DHCP_CLIENT ] && {
        	echo "You asked for DHCP; but no DHCP client could be found."
        	exit 1
        }
    else
        # Check if a subnet mask was provided.
        echo $IPADDR | grep -q / || {
    	echo "The IP address should include a netmask."
    	echo "Maybe you meant $IPADDR/24 ?"
    	exit 1
        }
        # Check if a gateway address was provided.
        if echo $IPADDR | grep -q @
        then
            GATEWAY=$(echo $IPADDR | cut -d@ -f2)
            IPADDR=$(echo $IPADDR | cut -d@ -f1)
        else
            GATEWAY=
        fi
    fi    
    
    # create a connecter between  host and container 
    [ ! -d /var/run/netns ] && mkdir -p /var/run/netns
    [ -f /var/run/netns/$pid ] && rm -f /var/run/netns/$pid
    ln -s /proc/$pid/ns/net /var/run/netns/$pid

    # set an ip for container
    # we need to create a veth pair first
    # lveth=>localhost veth
    # gveth=>guesthost veth
    guest_ifname="macvtap${pid}"
    c_ifname="${c_ifname:=eth0}"
    # create macvtap device
    ip link add link $ifname dev $guest_ifname mtu 1500 type macvlan mode bridge
    #ip link add link $ifname dev $guest_ifname  mtu 1500 type macvtap mode bridge
    # attache macvtap to container
    ip link set $guest_ifname netns $pid
    
    # name macvtap device  to namespace as eth0
    ip netns exec $pid ip link set $guest_ifname name eth0
  
    if [ "$IPADDR" = "dhcp" ]
    then
        if [ $DHCP_CLIENT = "dhclient"  ]
        then
            # kill dhclient after get ip address to prevent device be used after container close
            ip netns exec $pid $DHCP_CLIENT -pf "/var/run/dhclient.$pid.pid" $c_ifname
            kill "$(cat "/var/run/dhclient.$pid.pid")"
            rm "/var/run/dhclient.$pid.pid"
        fi
         [ $DHCP_CLIENT = "dhcpcd"  ] && ip netns exec $pid $DHCP_CLIENT -q $c_ifname -h $name
    else
        ip netns exec $pid ip addr add $IPADDR dev $c_ifname
        [ "$GATEWAY" ] && {
    	ip netns exec $pid ip route delete default >/dev/null 2>&1 && true
        }
        ip netns exec $pid ip link set $c_ifname up
        [ "$GATEWAY" ] && {
    	    ip netns exec $pid ip route get $GATEWAY >/dev/null 2>&1 || \
    		ip netns exec $pid ip route add $GATEWAY/32 dev $c_ifname
    	    ip netns exec $pid ip route replace default via $GATEWAY
        }
    fi
    # Give our ARP neighbors a nudge about the new interface
    if which arping > /dev/null 2>&1
    then
        IPADDR=$(echo $IPADDR | cut -d/ -f1)
        ip netns exec $pid arping -c 1 -A -I $c_ifname $IPADDR > /dev/null 2>&1 || true
    else
        echo "Warning: arping not found; interface may not be immediately reachable"
    fi
  
    # Remove $pid to avoid `ip netns` catch it.
    [ -f /var/run/netns/$pid ] && rm -f /var/run/netns/$pid
    exit 0
}

name=$1;ifname=$2;ipaddr=$3;fanli=$4
[ "$name" ] || {
    echo "usage:"
    echo " ${0} <containername> <hostinterface> <ipaddr>/<subnet>[@default_gateway] [haproxy|webdata]"
    echo " ${0} <containername> <hostinterface> dhcp [haproxy|webdata] "
    echo " ${0} <containername>" 
    exit 1
} 

[ "${fanli}" == "haproxy" ] && {
    [ "$ifname" ] &&  [ "$name" ] && [ "$ipaddr" ] && {
	volume=" -v /data/rodata/cfg_file/haproxy:/etc/haproxy"
        img="fanli:haproxy"  
        _c_conatainer $name '--net=none -itd'  ${img} '/bin/bash /usr/local/bin/bootstrap.sh' "${volume}"
        _set_ip_forcontainer $ifname $name $ipaddr
    }
} 
