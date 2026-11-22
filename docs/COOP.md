# Co-op: playing a raid together

**Status: early.** Two players can share a raid: one hosts, the other joins and comes aboard the host's ship in the
host's sector. You fly and fight together and extract through the gate together. It has been tested with two copies
of the game on one PC; across the internet it's lightly tested. Please tell us how it goes (#200, #214).

## Quick start

1. **Both players:** the same mod build (bottom right of the launcher), your own save, and a shared network
   (same house: nothing to do; anywhere else: ZeroTier or Hamachi, [step 1](#1-get-on-the-same-network)).
2. **Host:** launcher > **CO-OP** > tick **Host: friends can join my raids**. Note the address it lists for your
   friend. Close the box, press **PLAY**, then **START RAID**. Allow the game through Windows Firewall
   (Private **and** Public) the first time.
3. **Host:** tell your friend once you're **aboard in the raid** (not before: joining the lobby doesn't work).
4. **Joiner:** launcher > select your save > **CO-OP** > type the host's address > **JOIN**. The game starts and
   connects by itself from the title screen; you come aboard the host's ship about a minute later.
5. **Afterwards:** untick **Host** if you're going back to solo raids. It doesn't hurt solo play, but there's no
   reason to open a port nobody is using.

What's known not to work yet:
- Joining only works once the host is **in** a raid, not while they're still in the lobby.
- The joiner's side of flying, turrets and boarding is lightly tested (#214).
- Each player takes their own gear in and brings their own loot home: nothing is shared between saves.

## What each player needs

- Their own copy of the game and of this mod, **the same build** as the host (the launcher shows it bottom right).
- Their own save. Nothing is shared: you take your own gear in and bring your own loot home.
- A way to reach the host's PC (below).

## 1. Get on the same network

The host's game listens on **UDP port 7777**. The joiner has to be able to reach it.

| You are | Do this |
|---|---|
| In the same house | Nothing. Use the host's LAN address (the CO-OP box lists it, like `192.168.1.20`). |
| Anywhere else | Join a **ZeroTier** network together (recommended, below). |
| Comfortable with your router | The host forwards UDP 7777 to their PC instead. |

### ZeroTier (recommended)

ZeroTier puts your PCs on one private virtual network. Only the **host** needs a ZeroTier account (free); friends
don't. ZeroTier's free Personal plan allows **10 devices** on one network, which is plenty for a crew.

**The host, once:**
1. Make a free account at [my.zerotier.com](https://my.zerotier.com) and click **Create A Network**.
2. Copy the **Network ID** (16 characters, like `8056c2e21c000001`) and send it to your friends.
3. Install ZeroTier and join your own network (same steps as the friends, below).
4. On the network's page, under **Members**, tick **Auth** for each device that joined (yours too). Friends can't
   connect until you do. Each member gets an address there, like `10.147.17.5`.

**Everyone (host and friends):**

Windows, from the mod's folder:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\coop-zerotier.ps1 -Network 8056c2e21c000001 -Install
```

Linux:

```sh
sh linux/coop-zerotier.sh 8056c2e21c000001 --install
```

`-Install` / `--install` installs ZeroTier if it's missing (Windows: `winget`; Linux: ZeroTier's official install
script). The script then joins the network (Windows asks for admin rights once) and waits until the host has
authorised you, then prints **your ZeroTier address**. Run it again any time to see your address; `-Leave` /
`--leave` leaves the network.

Or do it by hand: install ZeroTier from [zerotier.com/download](https://www.zerotier.com/download/), then join from
its tray icon (Windows) or `sudo zerotier-cli join <network id>` (Linux).

**Steam Deck:** SteamOS's system folders are read-only, so ZeroTier's installer can't run there as it is. Not
covered yet; use desktop Linux or Windows for now, or tell us if you get it working.

### Other options

- **Tailscale** works the same way, but every player needs their own Tailscale account and an invite to the host's
  network.
- **LogMeIn Hamachi** (Windows) works too: everyone joins the host's Hamachi network and uses the host's `25.x.x.x`
  address.
- **Port forwarding:** the host forwards **UDP 7777** on their router to their PC and gives friends their public IP.

## 2. Host

1. In the launcher, click **CO-OP** and tick **Host: friends can join my raids**.
2. The box lists your addresses. Give your friends the one they can reach: your ZeroTier address (`10.x.x.x`, or
   whatever ZeroTier assigned) or your LAN address.
3. Close the box and press **PLAY**, then **START RAID** as usual.
4. **Windows Firewall:** the first time, Windows asks whether to allow the game on networks. Allow it, and tick
   **both** Private and Public: Windows often treats the ZeroTier network as Public. If you clicked Cancel, run once
   (as admin, from the mod's folder):

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\coop-zerotier.ps1 -Firewall
   ```

   It adds one inbound rule: UDP 7777, for the game's program only.

Friends can join once you're **in** the raid.

## 3. Join

1. Wait until the host says they're in the raid.
2. In the launcher, select your save, click **CO-OP**, type the host's address (like `10.147.17.5`) and press
   **JOIN**.
3. The game starts and connects by itself from the title screen a few seconds later. You spawn aboard your own ship,
   about a minute after connecting.

## Troubleshooting

- **The joiner stays on the title screen / goes back to it:** the host isn't in a raid yet, the address is wrong, or
  the firewall is blocking. Check the host can see the joiner on ZeroTier: `zerotier-cli peers` (or the network page
  on my.zerotier.com shows both members online and authorised). Then press JOIN again.
- **Kicked straight back:** the two of you are on different mod builds. Update both.
- **ZeroTier shows "ACCESS_DENIED" / no address:** the host hasn't ticked **Auth** for you yet.
- Something else: press **REPORT** in the launcher on **both** PCs and attach both files to an issue.

Co-op only connects your PCs to each other. Nothing reaches Marauders' own servers.
