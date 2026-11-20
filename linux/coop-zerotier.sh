#!/bin/sh
# Co-op over ZeroTier (#202, docs/COOP.md): joins a ZeroTier network and prints your address on it.
#   sh linux/coop-zerotier.sh <16-char network id> [--install]
#   sh linux/coop-zerotier.sh <network id> --leave
#   sh linux/coop-zerotier.sh                       lists the networks you're on and your addresses
# --install runs ZeroTier's official installer (https://install.zerotier.com) when zerotier-cli is missing; nothing is
# installed without it. ZeroTier's commands need sudo. Steam Deck: SteamOS is read-only, the installer doesn't work
# there as is (docs/COOP.md).
net=""; install=0; leave=0
for a in "$@"; do
    case "$a" in
        --install) install=1 ;;
        --leave) leave=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) net="$a" ;;
    esac
done
if [ -n "$net" ] && ! printf '%s' "$net" | grep -Eq '^[0-9a-fA-F]{16}$'; then
    echo "A ZeroTier network ID is 16 characters, 0-9 and a-f (got '$net')." >&2
    exit 1
fi
net=$(printf '%s' "$net" | tr 'A-F' 'a-f')

if ! command -v zerotier-cli >/dev/null 2>&1; then
    if [ "$install" -ne 1 ]; then
        echo "ZeroTier isn't installed. Run again with --install, or see https://www.zerotier.com/download/" >&2
        exit 1
    fi
    if [ -f /etc/os-release ] && grep -q '^ID=steamos' /etc/os-release; then
        echo "SteamOS: ZeroTier's installer can't write to the read-only system. Not supported yet (docs/COOP.md)." >&2
        exit 1
    fi
    echo "Installing ZeroTier with its official installer (asks for your password)..."
    curl -fsSL https://install.zerotier.com | sudo bash || { echo "The ZeroTier install failed." >&2; exit 1; }
fi

# "<id> <status> <first IPv4 or ->" per network, from the JSON listing
networks() {
    sudo zerotier-cli -j listnetworks | python3 -c '
import json, sys
for n in json.load(sys.stdin):
    ips = [a.split("/")[0] for a in n.get("assignedAddresses", []) if "." in a]
    print(n.get("nwid", "?"), n.get("status", "?"), ips[0] if ips else "-", n.get("name", ""))
'
}

if [ -z "$net" ]; then
    out=$(networks)
    [ -n "$out" ] && echo "$out" || echo "Not on any ZeroTier network."
    exit 0
fi

if [ "$leave" -eq 1 ]; then
    sudo zerotier-cli leave "$net" >/dev/null && echo "Left $net."
    exit $?
fi

sudo zerotier-cli join "$net" >/dev/null || exit 1
echo "Joined $net. Waiting for the host to authorise you (Members > Auth on my.zerotier.com)..."
end=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$end" ]; do
    line=$(networks | grep "^$net ")
    status=$(echo "$line" | awk '{print $2}')
    ip=$(echo "$line" | awk '{print $3}')
    if [ "$status" = "OK" ] && [ "$ip" != "-" ] && [ -n "$ip" ]; then
        echo "Connected. Your ZeroTier address: $ip"
        echo "Hosting? Give this address to your friends. Joining? Type the HOST's address in the launcher's CO-OP box."
        exit 0
    fi
    if [ "$status" = "NOT_FOUND" ]; then
        echo "No ZeroTier network $net. Check the ID with the host." >&2
        exit 1
    fi
    sleep 3
done
echo "Still waiting after 5 minutes. Ask the host to tick Auth for you, then run this again."
exit 1
