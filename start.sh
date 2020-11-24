#!/bin/bash

# Custom startup script for the lazycast Miracast server. This script is meant
# for use for the Wi-Fi Direct mode only (i.e., no support for Miracast over
# Infrastructure).
#
# Authored by maxonthegit
# Original lazycast project from https://github.com/homeworkc/lazycast

# For a rather comprehensive documentation of Wi-Fi Direct, see https://hsc.com/DesktopModules/DigArticle/Print.aspx?PortalId=0&ModuleId=1215&Article=221



DEBUG=0
PIN=$(cat PIN)




[ "$DEBUG" = "1" ] && set -x

# Query wpa_supplicant for a list of available interfaces
# Sample output:
#    Selected interface 'p2p-dev-wlan0'
#    Available interfaces:
#    p2p-dev-wlan0
#    wlan0
list_wifi_interfaces() {
	sudo wpa_cli interface
}

# Query wpa_supplicant for a list of available P2P networks
# Sample output:
#    1       DIRECT-xg
#    2       DIRECT-DT
#    3       DIRECT-B9
#    4       DIRECT-bu
list_p2p_networks() {
	sudo wpa_cli -i $1 list_networks | grep 'DISABLED.*P2P-PERSISTENT' | awk '{print $1,$2}'
}

# Output text only if debugging mode is active
debug_log() {
	[ "$DEBUG" = "1" ] && echo "$@"
}

clear_everything() {
	debug_log "Cleaning up..."
	sudo pkill busybox
	sudo wpa_cli -i ${P2P_DEV_INTERFACE} p2p_group_remove ${P2P_INTERFACE}
	pkill -f d2.py
	exit
}

trap clear_everything INT

ALL_INTERFACES=$(list_wifi_interfaces)

if echo "${ALL_INTERFACES}" | grep -q 'p2p-wlan'; then
	echo "P2P WLAN interface already active. Exiting"
	exit 1
fi


P2P_DEV_INTERFACE=$(echo "${ALL_INTERFACES}" | grep 'p2p-dev' | tail -n 1)
WLAN_INTERFACE=$(echo ${P2P_DEV_INTERFACE} | awk -F- '{print $NF}')

debug_log "Found P2P  interface: " ${P2P_DEV_INTERFACE}
debug_log "Found WLAN interface: " ${WLAN_INTERFACE}
debug_log "Setting parameters..."

while read WPA_COMMAND; do
	sudo wpa_cli -i ${P2P_DEV_INTERFACE} $(echo $WPA_COMMAND | sed 's/#.*//')
done << EOF
p2p_find type=progessive
set device_name $(hostname)		# Set reported P2P device name
set device_type 7-0050F204-1		# Set device type as documented in https://web.mit.edu/freebsd/head/contrib/wpa/wpa_supplicant/README-P2P. Some device types are documented in https://web.mit.edu/freebsd/head/contrib/wpa/wpa_supplicant/wpa_supplicant.conf
wfd_subelem_set 0 000600111c44012c
wfd_subelem_set 1 0006000000000000
wfd_subelem_set 6 000700000000000000
EOF

# Persistent groups are such that "the devices forming the group store network
# credentials and the assigned P2P GO and Client roles for subsequent
# re-instantiations of the P2P group. Specifically, after the Discovery phase,
# if a P2P Device recognizes to have formed a persistent group with the
# corresponding peer in the past, any of the two P2P devices can use the
# Invitation Procedure (a two-way handshake) to quickly re-instantiate the
# group."

debug_log "Creating P2P group as Group Owner..."

# Multiple attempts are required here because device creation sometimes fails
# (see also https://github.com/raspberrypi/linux/issues/2740 and
# https://www.raspberrypi.org/forums/viewtopic.php?t=273660)

until list_wifi_interfaces | grep -q "^p2p-${WLAN_INTERFACE}"; do
	# Make multiple attempts, then check if a stable interface has
	# been created
	for ((i=1; i<=3; i++)); do
		sudo wpa_cli -i ${P2P_DEV_INTERFACE} p2p_group_add persistent ht40
		sleep 1
	done
	sleep 3
done


# Start DHCP server

P2P_INTERFACE=$(list_wifi_interfaces | grep "^p2p-${WLAN_INTERFACE}")
sudo ip addr add dev ${P2P_INTERFACE} 192.168.173.1/24
cat >udhcpd.conf <<EOF
start	192.168.173.80
end	192.168.173.80
interface	$P2P_INTERFACE
option subnet 255.255.255.0
option lease 10
EOF
sudo busybox udhcpd udhcpd.conf

echo "Miracast server ready - PIN code: $PIN"



# Main loop (repeatedly attempts a connection to the streaming station, i.e., the device
# which is connecting to this Raspberry)

while : ; do
	sudo wpa_cli -i ${P2P_DEV_INTERFACE} wps_pin any $PIN >/dev/null
	./d2.py
done

