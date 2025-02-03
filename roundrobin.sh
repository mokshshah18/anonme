#!/usr/bin/env bash

#starts to change the DNS on a roundrobin
while true; do
    FIRST_SERVER="${DNS_SERVERS[0]}"
    DNS_SERVERS=("${DNS_SERVERS[@]:1}" "$FIRST_SERVER") # Rotate the array

    # Rewrite /etc/resolv.conf with the rotated order
    > /etc/resolv.conf
    for SERVER in "${DNS_SERVERS[@]}"; do
        echo "nameserver $SERVER" >> /etc/resolv.conf
    done

    echo "Reordered /etc/resolv.conf with round-robin DNS: ${DNS_SERVERS[@]}"
    sleep 30 # Wait for 30 seconds before reordering again
done
