#!/bin/sh
# Point nginx at the DNS server this container was itself given.
#
# nginx never reads /etc/resolv.conf, so a resolver has to be stated explicitly
# before any address can be looked up at request time. Pinning that address per
# environment breaks as soon as the container network is recreated on a
# different subnet, and a wrong resolver takes every backend lookup down at
# once rather than degrading. Reading it back out of resolv.conf keeps the two
# in step on both Docker (embedded DNS) and Podman (network gateway).
set -eu

output=/etc/nginx/conf.d/00-resolver.conf

nameserver=$(
  awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }' \
    /etc/resolv.conf
)

if [ -z "$nameserver" ]; then
  echo "$0: no IPv4 nameserver in /etc/resolv.conf" >&2
  exit 1
fi

# valid= bounds how long a backend can stay pinned to an address it has moved
# off. ipv6=off because backends are reachable over IPv4 on the container
# network, and the AAAA lookups would only add a failure to every request.
printf 'resolver %s valid=10s ipv6=off;\n' "$nameserver" > "$output"

echo "$0: resolver set to $nameserver"
