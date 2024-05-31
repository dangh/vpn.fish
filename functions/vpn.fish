function vpn -a action name
    set -l args $argv

    if test -z "$argv" && test (count ~/.config/vpn/*/) -eq 1
        set -l name (path basename ~/.config/vpn/*/)
        vpn connect $name -v
        return
    end

    test -n "$action" || begin
        echo action is required
        return 1
    end
    test -n "$name" || begin
        echo name is required
        return 1
    end

    argparse -i 'p/port=?' 'c/cpu=?' 'd/disk=?' 'm/memory=?' -- $args
    set -l port 8888 && set -q _flag_port && set port $_flag_port
    set -l cpu 1 && set -q _flag_cpu && set cpu $_flag_cpu
    set -l disk 128M && set -q _flag_disk && set disk $_flag_disk
    set -l memory 256 && set -q _flag_memory && set memory $_flag_memory

    # Directory structure for profile `nasa'
    : '
    ~/.config/vpn/nasa
    ├── config
    ├── passwd
    ├── domains
    └── tinyproxy.conf

    ~/.local/state/vpn/nasa
    ├── etc
    │   ├── openvpn
    │   │   ├── config
    │   │   ├── passwd
    │   │   └── run.sh
    │   ├── resolve
    │   │   ├── domains
    │   │   ├── hosts
    │   │   └── run.sh
    │   └── tinyproxy
    │   │   ├── run.sh
    │       └── tinyproxy.conf
    └── var
        └── log
            ├── openvpn
            ├── resolve
            └── tinyproxy
    '

    set -l config ~/.config/vpn/$name
    set -l overlay ~/.local/state/vpn/$name
    test -d $config || begin
        echo Config not found. Please follow https://github.com/dangh/vpn.fish#configuration
        return 1
    end
    test -f $config/config || begin
        echo $config/config not found.
        return 1
    end
    test -f $config/passwd || begin
        echo $config/passwd not found.
        return 1
    end

    switch "$action"
        case connect
            mkdir -p $overlay/etc/{openvpn,resolve,tinyproxy} $overlay/var/log
            cp $config/{config,passwd} $overlay/etc/openvpn/
            test -f $config/domains && cp $config/domains $overlay/etc/resolve/
            : >$overlay/var/log/openvpn
            : >$overlay/var/log/resolve
            : >$overlay/var/log/tinyproxy
            : >$overlay/etc/resolve/hosts
            if test -f $config/tinyproxy.conf
                cp $config/tinyproxy.conf $overlay/etc/tinyproxy/
            else
                echo >$overlay/etc/tinyproxy/tinyproxy.conf "
Port $port
LogLevel Connect
DisableViaHeader Yes
"
            end
            echo >$overlay/etc/openvpn/run.sh \
                '#!/bin/sh

overlay=/mnt/$1
openvpn \
    --config $overlay/etc/openvpn/config \
    --askpass $overlay/etc/openvpn/passwd \
    --auth-nocache \
    --daemon \
    --log $overlay/var/log/openvpn \
    --mute-replay-warnings \
    --script-security 2 \
    --up /etc/openvpn/up.sh \
    --down /etc/openvpn/down.sh \
    --fast-io &

tail -f -n +1 $overlay/var/log/openvpn | while read LOGLINE
do
    echo $LOGLINE
    [[ "${LOGLINE}" == *"Initialization Sequence Completed"* ]] && pkill -P $$ -x tail
done
'
            echo >$overlay/etc/resolve/run.sh \
                '#!/bin/sh

overlay=/mnt/$1

exec &> >(tee -a $overlay/var/log/resolve)

cat $overlay/etc/resolve/domains | while read domain; do
    if [[ "$domain" = "#"* ]]; then
        continue
    fi
    echo Find best IP for domain $domain
    all_ips=$( nslookup $domain | grep \'Address:\' | grep -v \':53\' | cut -d\' \' -f2 )
    fastest_ip=$( echo "$all_ips" | head -n1 )
    if [[ "$( echo "$all_ips" | wc -l )" -gt 1 ]]; then
        fastest_ip=$(
            echo "$all_ips" | while read ip; do
                result=$( nmap -Pn -p 443 $ip )
                if [[ "$result" == *"1 host up"* ]]; then
                    sec=$( echo $result | sed \'s/.*scanned in //\' | sed \'s/ seconds//\' )
                    echo $ip $sec
                fi
            done | sort -k2 -n | head -n1 | cut -d\' \' -f1
        )
    fi
    if [[ -n "$fastest_ip" ]]; then
        echo Found best IP for domain $domain: $fastest_ip
        echo $fastest_ip $domain >> $overlay/etc/resolve/hosts
    fi
done | tee $overlay/var/log/resolve

# append resolved domains
cat $overlay/etc/resolve/hosts >> /etc/hosts
'
            echo >$overlay/etc/tinyproxy/run.sh \
                '#!/bin/sh

overlay=/mnt/$1
tinyproxy -d -c $overlay/etc/tinyproxy/tinyproxy.conf &> $overlay/var/log/tinyproxy &
'
            chmod +x $overlay/etc/{openvpn,resolve,tinyproxy}/run.sh
        case delete
            rm -rf $overlay
    end

    set -q vpn_container || begin
        if command -q docker
            set -f vpn_container docker
        else if command -q alpine
            set -f vpn_container alpine
        else if command -q colima
            set -f vpn_container colima
        else
            echo No container runtime! Please follow installation guide at https://github.com/dangh/vpn.fish/#installation
            return 1
        end
    end
    vpn-$vpn_container $args
end

function vpn-docker -a action name
    set -l args $argv[3..]
    set -l indent sed 's/^/  /'

    argparse -i v -- $args
    if set -q _flag_v
        set -f out /dev/stdout
    else
        set -f out /dev/null
    end

    argparse -i 'p/port=?' 'c/cpu=?' 'm/memory=?' -- $args
    set -l port 8888 && set -q _flag_port && set port $_flag_port
    set -l cpu 1 && set -q _flag_cpu && set cpu $_flag_cpu
    set -l memory 128 && set -q _flag_memory && set memory $_flag_memory

    set -l image alpine:latest

    switch "$action"
        case status
            set -l running (command docker container inspect -f '{{.State.Running}}' $name 2>&1)
            switch "$running"
                case true
                    echo Running
                case false
                    echo Stopped
                case \*
                    echo Missing
            end
        case connect
            if test (vpn-docker status $name) = Running
                vpn-docker disconnect $name $args
            end
            switch (vpn-docker status $name)
                case Missing
                    echo Starting $name
                    command docker pull $image
                    command docker run \
                        --name $name \
                        --cpus $cpu \
                        --memory {$memory}000000 \
                        --volume ~/.local/state/vpn/$name:/mnt/$name \
                        --publish $port:8888 \
                        --device /dev/net/tun \
                        --cap-add NET_ADMIN \
                        --tty \
                        --detach \
                        $image
                    command docker exec $name apk add --update --no-cache openvpn tinyproxy nmap 2>&1 | $indent >$out
                case Stopped
                    echo Starting $name
                    command docker start $name 2>&1 | $indent >$out
            end
            echo Starting tinyproxy
            command docker exec $name /mnt/$name/etc/tinyproxy/run.sh $name 2>&1 | $indent >$out
            echo Starting OpenVPN
            command docker exec $name /mnt/$name/etc/openvpn/run.sh $name 2>&1 | $indent >$out
            echo Resolving slow hosts
            command docker exec $name /mnt/$name/etc/resolve/run.sh $name 2>&1 | $indent >$out
            echo VPN is ready at http://localhost:$port
        case disconnect
            echo Disconnecting $name
            command docker kill $name 2>&1 | $indent >$out
        case delete
            echo Deleting $name
            command docker rm $name --force 2>&1 | $indent >$out
    end
end

function vpn-alpine -a action name
    set -l args $argv[3..]
    set -l indent sed 's/^/  /'

    argparse -i v -- $args
    if set -q _flag_v
        set -f out /dev/stdout
    else
        set -f out /dev/null
    end

    argparse -i 'p/port=?' 'c/cpu=?' 'd/disk=?' 'm/memory=?' -- $args
    set -l port 8888 && set -q _flag_port && set port $_flag_port
    set -l cpu 1 && set -q _flag_cpu && set cpu $_flag_cpu
    set -l disk 128M && set -q _flag_disk && set disk $_flag_disk
    set -l memory 256 && set -q _flag_memory && set memory $_flag_memory

    switch "$action"
        case status
            command alpine list | grep $name | read -l __ instance_status __
            test -n "$instance_status" || set instance_status Missing
            echo $instance_status
        case connect
            # health check
            command alpine ls &>/dev/null || begin
                rm -rf ~/.macpine/$name/alpine.pid
            end
            if test (vpn-alpine status $name) = Running
                vpn-alpine disconnect $name $args
            end
            switch (vpn-alpine status $name)
                case Missing
                    echo Creating $name
                    command alpine launch \
                        --name $name \
                        --cpu $cpu \
                        --disk $disk \
                        --memory $memory \
                        --port $port:8888 \
                        --mount ~/.local/state/vpn/$name 2>&1 | $indent >$out
                    echo Install packages
                    command alpine exec $name -- apk add --update --no-cache openvpn tinyproxy nmap 2>&1 | $indent >$out
                case Stopped
                    echo Starting $name
                    command alpine start $name 2>&1 | $indent >$out
            end
            echo Syncing time
            command alpine exec $name -- ntpd -d -q -n -p pool.ntp.org 2>&1 | $indent >$out
            echo Configuring network
            command alpine exec $name -- '
                mkdir -p /dev/net
                if [[ ! -c /dev/net/tun ]]; then
                    mknod /dev/net/tun c 10 200
                fi
            ' 2>&1 | $indent >$out
            echo Starting OpenVPN
            command alpine exec $name -- /mnt/$name/etc/openvpn/run.sh $name 2>&1 | $indent >$out
            echo Resolving slow hosts
            command alpine exec $name -- /mnt/$name/etc/resolve/run.sh $name 2>&1 | $indent >$out
            echo Starting tinyproxy
            command alpine exec $name -- /mnt/$name/etc/tinyproxy/run.sh $name 2>&1 | $indent >$out
            echo VPN is ready at http://localhost:$port
        case disconnect
            echo Disconnecting $name
            command alpine stop $name 2>&1 | $indent >$out
        case delete
            echo Deleting $name
            command alpine delete $name 2>&1 | $indent >$out
    end
end

function vpn-colima -a action name
    set -l args $argv[3..]

    set -q vpn_runtime || begin
        if command -q docker
            set -f vpn_runtime docker
        else
            set -f vpn_runtime containerd
        end
    end

    set -q vpn_vm_type || switch (arch)
        case arm64
            set -f vpn_vm_type vz
        case \*
            set -f vpn_vm_type qemu
    end

    set -l image huynhminhdang/openvpn-tinyproxy:latest
    set -l colima colima --profile $name-$vpn_runtime
    switch "$vpn_runtime"
        case docker
            set -f ctl docker
        case containerd
            set -f ctl $colima nerdctl --
    end

    switch "$action"
        case status
            command $colima list | grep $name | read -l __ instance_status __
            test -n "$instance_status" || set instance_status Missing
            echo $instance_status
        case connect
            # Stop running instance
            if test (vpn-colima status $name) = Running
                vpn-colima disconnect $name
            end

            # Create instance if not exist
            if test (vpn-colima status $name) != Running
                echo vpn: Creating $name
                argparse -i 'c/cpu=?' 'd/disk=?' 'm/memory=?' -- $args
                set -l cpu 1 && set -q _flag_cpu && set cpu $_flag_cpu
                set -l disk 1 && set -q _flag_disk && set disk $_flag_disk
                set -l memory 2 && set -q _flag_memory && set memory $_flag_memory
                command $colima start \
                    --runtime $vpn_runtime \
                    --vm-type $vpn_vm_type \
                    --cpu $cpu \
                    --disk $disk \
                    --memory $memory
            end

            # Pull image if not exist
            if not command $ctl images --quiet $image | test -n -
                echo vpn: Pulling image
                command $ctl pull $image
            end

            # Start vm
            echo vpn: Starting $name
            argparse -i 'p/port=?' -- $args
            set -l port 8888 && set -q _flag_port && set port $_flag_port
            switch "$vpn_runtime"
                case docker
                    command $ctl run \
                        --name $name \
                        --volume ~/.config/vpn/$name:/etc/openvpn/profile \
                        --volume ~/.config/vpn/$name:/etc/openvpn/hosts \
                        --publish $port:8888 \
                        --device /dev/net/tun \
                        --cap-add NET_ADMIN \
                        --rm \
                        --tty \
                        --detach \
                        $image
                case containerd
                    command $ctl run \
                        --name $name \
                        --volume ~/.config/vpn/$name:/etc/openvpn/profile \
                        --volume ~/.config/vpn/$name:/etc/openvpn/hosts \
                        --publish $port:8888 \
                        --device /dev/net/tun \
                        --cap-add NET_ADMIN \
                        --detach \
                        $image
            end
            echo VPN is ready at http://localhost:$port
        case disconnect
            echo vpn: Disconnecting $name
            switch "$vpn_runtime"
                case docker
                    command $ctl kill (command $ctl ps --quiet --filter "name=$name") 2>/dev/null
                case containerd
                    command $ctl ps --all | grep $image | read container_id _0 2>/dev/null
                    test -n "$container_id" &&
                        command $ctl rm --force $container_id
            end
        case update
            echo vpn: Updating $name
            if test (vpn-colima status $name) != Running
                vpn-colima create $name $args
            end
            command $ctl pull $image
        case delete
            echo vpn: Deleting $name
            command $colima delete
    end
end
