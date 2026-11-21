# Marauders Offline: lore bible

A working reference for anyone writing in-world text for Marauders Offline: notes on desks, loading-screen lines,
radio crackle, trader patter, contract briefings. It gathers what the game says, what fans have guessed, and what this
project adds, and keeps the three apart.

Files in this folder:

- `README.md`: this bible.
- `fragments/`: short in-world documents, one per file, each with a front-matter block (`id`, `title`, `kind`,
  `canon`, `where`, `show_as`).
- `loading_lines.md`: one-line hints for loading screens and the minimap text panel.
- `contracts.md`: faction handlers' contract briefings, tied to real raid locations.

---

## Sources

| Source | Status | What we take from it |
|---|---|---|
| Marauders (Small Impact Games, 2023): the game itself, its opening speech, item and location names, NPC and trader names | **Official** | The setting, the three empires, the raid locations, the tone. |
| The Marauders wiki (marauders.fandom.com) | **Official-based** (a fan wiki summarising the game) | Earth destroyed, humanity in space, the location roster, the empires hiring and hating the pirates, Jupiter's store of rescued Earth logs. |
| "The complete timeline" post on r/MaraudersGame | **Fan theory** | Element A742, the Dudinka meteor, the Sites, wormhole tech, V3 rockets, the ceasefire, the exodus dates, the Red Baron's terraformer raid. Nothing in it is confirmed by the developers. |
| "The First Attack" by Ceeg (Substack, 2023) | **Fan story**, someone else's copyrighted work | Only the names Fletcher, Haney and Sledge, used as light nods in new documents. We never retell or quote it. Credit it whenever those names appear. |
| This project (Marauders Offline) | **New** | Everything marked `new` below and in the fragments: dates past the sources, named officers, ship names, prices, rumours. |

Rule of thumb: if a fragment leans on the timeline post, its `canon` is `fan-theory-based`. If it only uses what the
game shows (places, factions, items, the Baron), it is `official-based`. Anything we made up from whole cloth is `new`.

---

## The world in one page

Seventy years ago the Great War began, and it never really stopped; it just changed shape. The empires that fought
it learned to tear holes in the world with a strange element from a fallen star, and they used those holes for
supply lines, then for rockets, then for bombs. The soil soured, the rain went bad, and in the end the planet was
not worth fighting over. Everyone who could get a seat on a shuttle left.

Now humanity lives in tin: asteroid mines, orbital stations, colony cruisers on year-long hauls, prisons bolted to
rocks, terraformers coaxing wheat out of bad dirt, and missile bases that can crack a moon. Three empires carved up
the dark between them: the **Central Empire**, the **United Allies** and the **Kingdom Alliance**. None of them can
police it. Space is too big, wormhole gates too few, and every fleet is busy watching the other two.

In those gaps live the **Marauders**: pirates, deserters, ex-convicts, ex-miners, anyone who decided they owed
nothing to a king or a flag. They fly patched-up frigates out of the dark, cut their way through bulkheads with
blowtorches, take what they can carry and leave by the nearest space gate before the garrison wakes up. The empires
hate them, hunt them, and quietly hire them, because a marauder will do a job a soldier can't be seen doing. The
traders who buy their loot are on nobody's side but the till's.

It is a world of rivets, valves and analog dials, of crackling radio and paper forms in triplicate, of gas masks
and trench guns and things wound by hand. Nobody in it is clean. The empires are not villains and the pirates are
not heroes. Everyone is hungry, and the air is metered.

---

## Timeline

"Official" means the game or the wiki says it. "Fan theory" means the r/MaraudersGame timeline. "New" means this
project. Where the fan timeline and the game's "70 years" disagree, we keep both and flag it (see Open questions).

| Year | Event | Status |
|---|---|---|
| (c. 1914) | The Great War begins. Everything since happens "in its shadow". | Official (the opening speech counts 70 years from it) |
| 1932 | A meteor carrying Element A742 destroys Dudinka in Russia, leaving small, growing, radioactive black holes. Samples go to Site A (Yakutsk), Site B (Chita) and Site 3 (Samara). | Fan theory |
| 1932-33 | Sites A and B are lost to radiation and black-hole clusters. | Fan theory |
| 1933 | Germany and Russia (the Central Empire) split an A742 atom at Samara and hold the first stable black hole; they link holes between sites, making the first wormholes. The Court of International Justice objects. | Fan theory |
| 1934 | CE front-line depots supplied by wormhole. The United Allies raid Samara and steal a sample and scientists. The Kingdom Alliance sabotages a German site near the Swiss Alps. | Fan theory |
| 1935 | The UA and KA build their own A742 sites. | Fan theory |
| 1936 | A CE "V3" rocket with an A742 warhead destroys a UA site in France; France falls into chaos. The first unmanned V3 reaches space. | Fan theory |
| 1937-46 | V3s everywhere. Sabotage in Ireland and Ohio. A742 tests: a UA test over the Pacific poisons Hawaii; a Russian one leaves a quarter-mile black hole by the Chukchi Sea. | Fan theory |
| 1947 | Ohio evacuated. | Fan theory |
| 1948-50 | Peace talks refused. Cancer and failed harvests worldwide. | Fan theory |
| 1951 | Civilian rebels assassinate leaders on all sides. | Fan theory |
| 1952 | Ceasefire. Scientists give Earth 25 years. A multinational space organisation is founded on wormhole technology. | Fan theory |
| 1953 | The organisation is named the Joint Translunar Authority (JTA); its stamp is still on gate machinery. | New |
| 1955 | First space stations. | Fan theory |
| 1956 | First wormholes to other planets. | Fan theory |
| 1959 | Military colonies. | Fan theory |
| 1960 | Civilians begin to leave Earth. | Fan theory |
| 1961 | The JTA collapses when each empire seizes the gates on its own side. The gates keep their JTA serial plates. | New |
| 1965 | The empires claim sectors of space. | Fan theory |
| 1971 | The last shuttle leaves Earth. | Fan theory |
| 1973 | Earth declared uninhabitable. | Fan theory |
| (by c. 1984-92) | Earth is gone; humanity lives in mines, stations, ships, prisons, terraformers and military bases. Nobody can police space. | Official |
| 1976 | Resource skirmishes. The Red Baron raids the UA Terraformer near Proxima Centauri b, carries off its crops and its farmers as labour for a CE terraformer, and (allegedly) nukes it. The CE denies involvement. War over the off-world water plant follows. | Fan theory |
| 1976-90 | "The Age of Marauders". | Fan theory |
| 1979 | The Merchant Guilds' Accord: the traders agree, among themselves, not to ask where cargo came from. | New |
| 1981 | Penal Colony Beta 5 riot; the Warden's riot helmet becomes a prize among pirates. | New |
| 1984 | "Now" for most of our fragments: seventy years after the Great War began. | New (anchored to the official "70 years") |

---

## Factions

### Central Empire (CE)
- **Who:** Born of the German-Russian wartime alliance. Heavy industry, heavy artillery, heavy paperwork.
- **Tone:** Orderly, proud, impersonal. Losses are "adjustments", prisoners are "labour allocations". Believes it
  is the only adult in the room.
- **Symbols:** Black, iron grey and a dull red. A cogwheel around a split atom; the double-headed eagle cut down to
  something more industrial. Numbered everything.
- **How they talk:** Passive voice, decree numbers, ranks and units. "It is ordered." "The Directorate notes."
  Never apologises; issues corrections.

### United Allies (UA)
- **Who:** The transatlantic bloc: American and allied forces. The most Marines, the most cruisers, the most
  ration cards.
- **Tone:** Cheerful on the posters, tired in the barracks. Believes in volunteering, until it doesn't.
- **Symbols:** Navy blue, cream and red stripes; a star over an anchor; the 47th Marines' bulldog.
- **How they talk:** Slogans, acronyms, can-do optimism, "folks", "sir", "by the numbers". Morale officers and
  mimeographed notices. UA Marines, Medics and the Commander are the faces players shoot.

### Kingdom Alliance (KA)
- **Who:** The crowns and their old dominions. Fewer ships, better spies; the SAS are theirs.
- **Tone:** Dry, understated, faintly superior. Never admits to an operation. Prefers someone else to do the
  shooting, and often hires marauders to do it.
- **Symbols:** A crown over a lighthouse; bottle green and brass; regimental mottoes in Latin.
- **How they talk:** Courteous to the point of menace. "We would be most grateful." "Regrettably." Code names,
  initials, "Ministry" with no name after it.

### Minor factions
- **Merchant houses and the traders:** Greybeard, Overlord, Rosie, Wolff and the rest. Neutral as a scale.
  They buy from pirates and sell to garrisons, sometimes the same crate.
- **Mining concerns:** Chartered companies running the Iridium Asteroid Mine, the mini mines and the mining
  frigates under licence from whichever empire owns the sector. Miners are owned by debt more than by any flag.
- **Security contractors:** The "Security" outfits on stations and prisons, including Army and Prison detachments.
  Paid by the month, loyal by the month.
- **Colonists:** Civilians on cruisers and terraformers. They didn't choose a side; they chose a seat.

### Pirates / Marauders
- **Who:** Decentralised crews loyal only to themselves. Some flags have a dozen ships, most have one. The mod's
  own guild is simply called "Marauders".
- **Tone:** Grim, practical, funny in the way of people who expect to die on a Tuesday. Not rebels, not
  revolutionaries: they take, they sell, they drink.
- **Symbols:** Whatever they took. Crew marks scratched into helmets, painted gate tallies on hulls, the Baron's cap.
- **How they talk:** Short, slangy in a period way ("the dark", "a fat one", "tin can", "the take", "go loud",
  "gate out"), accents from everywhere: the player voices are English, French, Polish, Dutch, American, Romanian,
  Hungarian, Italian and Australian, and crews mix them.
- **Never:** heroes of a cause. A marauder who frees prisoners does it to sell them a ride.

### Rebels
- **Who:** The people who threw the Rebel Base together: deserters, freed convicts and colonists who refused
  every empire. Descended (they claim) from the 1951 rebels who shot the leaders.
- **Tone:** Earnest, hungry, armed with leaflets and stolen rifles. They do believe in a cause, and it hasn't fed
  them yet.
- **Relationship to pirates:** Customers, suppliers and occasional targets. Pirates find their sincerity
  embarrassing and their ammunition useful.

---

## Places

**Spaceport.** A civil transit hub where shuttles meet gate traffic: customs halls, cargo cranes, a bar that never
closes. Run by whichever empire holds the sector, policed by contracted Security. It moves people and freight, and
its customs cage is the richest room on the station. Grim detail: the lost-luggage office has a shelf of urns nobody
came back for.

**Navy Outpost.** A UA forward base: barracks, armoury, signal room, fuel bunkers, and Marines on rotations far too
long. It watches gate traffic and launches frigates. Grim detail: the duty roster is chalk on a slate, because names
get wiped off too often to bother with ink.

**Iridium Asteroid Mine.** A company mine bored into a rock: drill galleries, ore conveyors, refinery, bunkhouses.
Chartered under licence, guarded by Security. It digs iridium and anything else that pays, including A742-bearing ore
when they find it. Grim detail: miners pay rent on their own pressure suits.

**Mini Mine.** A one-shaft claim on a small rock, a handful of miners and a single guard post. Run by small
operators or by debtors working off a big company's loan. Grim detail: the claim board lists three owners; two are
crossed out in the same hand.

**Mining Frigate.** A ship that eats asteroids: grapples, crushers, ore holds and a crew who never go ashore. Company
owned, escorted when the company can afford it. Grim detail: the crusher's emergency stop is behind a padlock, and
the foreman has the key.

**Penal Colony (Beta 5 and its sisters).** A prison bolted to a dead rock. Cell blocks, work halls, the Warden's
tower. Prisoners mine, smelt and sew uniforms for the empire that jailed them. Run by the Warden and Prison Security.
Grim detail: release dates are written in pencil.

**Rebel Base.** A hidden station cobbled from wrecks, held by the Rebels. Workshops, a printing press, a radio room
that broadcasts on a stolen frequency. Grim detail: their armoury log counts bullets one by one.

**Fortress.** A KA stronghold: thick bulkheads, SAS garrison, vaults full of things the Ministry wants kept. Run by
an SAS Major on paper, by the Ministry in practice. Grim detail: the chapel's memorial plaque has empty lines already
riveted in place.

**Merchant Ship.** A trader's hauler running between gates: cargo holds, strongrooms, a captain's cabin with a good
carpet. Owned by a merchant house, crewed by whoever was cheap. Grim detail: the manifest has two versions, and the
second one is the true one.

**Colony Cruiser.** A huge, slow ship moving colonists and their Marine escort on year-long hauls, half the
passengers in hibernation. Labs grow food fungus. Run by the UA. Grim detail: the hibernation pods are numbered,
and the reserve pods are woken in order of usefulness.

**Terraformer.** A ship or platform that makes a planet grow food: atmosphere stacks, seed vaults, crop domes and the
farmers who work them. The most valuable thing an empire owns, because everybody eats. Grim detail: farmers are
counted on the manifest as "agricultural equipment".

**Planet Killer.** A nuclear launch site: silos, a launch control room with two keys, A742 warheads in shielded
cradles. Run by whoever built it, guarded by the best troops they have. It exists so that nobody uses the others.
Grim detail: the launch crew's bunks are inside the blast door; nobody tells them which side it is meant to protect.

**Moon Base.** A settlement dug into a moon: survey huts, regolith works, a pressure dome and a long, cold walk
between them. Grim detail: the cemetery is the only plot with real soil, brought up from Earth in sacks.

**Capital Ship.** An empire's flagship: admirals, officers' mess, chart rooms, the paymaster's safe. Too big to hide,
too proud to run. Grim detail: the officers' mess still sets places for officers killed last month, by regulation.

**Dreadnought.** A battleship: turrets, magazines, armour belt, a thousand ratings. Not a place you raid lightly.
Grim detail: the shell hoists are hand-cranked as a backup, and the backup is used daily.

**AI frigates (Scout, Strike, Assault Scout, Venture) and the Rustbucket.** The working ships of the dark: scouts
for spotting, strikes for hitting, ventures for hauling. The Rustbucket is the player's starter frigate, bought
fourth-hand. Grim detail: every frigate's previous owner's name is still under the paint.

**Space gates.** Stable wormhole mouths ringed with JTA machinery: how everyone gets in and out of a sector, and how
marauders extract. Pilots have superstitions about them. Grim detail: the gate doesn't care what's in its throat
when it closes.

**Escape pods, salvage wrecks and mines.** Pods hold whoever made it, and whatever they grabbed. Wrecks are
yesterday's fights, still worth a blowtorch. Small and nuclear space mines are sown on gate approaches; stations sow
anti-personnel mines in corridors. Vaults want keycards, or a lot of patience with a torch.

---

## People

**The Red Baron.** A pirate captain, the most famous name in the dark, in his coat and cap. Official: he's a boss
and a raider. Fan theory: he raided the UA Terraformer near Proxima Centauri b in 1976 and sold its farmers to the
CE. New: nobody agrees on what he looks like under the cap, several men have claimed to be him at once, and the
empires each pay a bounty on him while (rumour says) each also pays him. His cap is a trophy; recruits who wear it
get ribbed as "Rosco and his whole bloodline" (a mod joke, keep it light).

**The traders.**
- **Greybeard:** old, patient, cheap. Buys anything, pays little, remembers every face. New: claims to have
  been on the last shuttle from Earth; the date changes each time.
- **Overlord:** a merchant house more than a man; speaks through clerks and loudspeakers. Pays well, charges
  interest on everything, including goodwill.
- **Rosie:** bright, quick and sharp-tongued, runs a stall that's half shop, half gossip exchange. Knows which
  garrison is short on men this week.
- **Wolff:** a former CE quartermaster who went private. Weapons and ammunition, everything stamped, nothing
  signed for. Precise and humourless.
- **The Pirate Trader:** whoever's minding the stall on a pirate station this week.

**First Mate Calico.** The guild's shop keeper and keeper of the books for the Marauders guild. Never seen to leave
the counter. New: lost an eye to a ricochet from her own pistol and tells it as a lesson in humility.

**The Sledge / Fletcher / Haney nod.** "The First Attack" by Ceeg (Substack, 2023) imagines a first pirate attack on a
UA colony cruiser. We may name a Lt Cdr Sledge, a PFC Fletcher and a Pvt Haney of the UA 47th Marines on rosters,
commendations or service records, as people who exist in the world, without retelling or quoting the story.
Always credit it in the `canon` notes.

**New named minor characters** (keep consistent): Warden Harlan Mott (Penal Colony Beta 5); Shift Foreman Ivo Brandt
(Iridium mine); Directorate Inspector K. Volkova (CE); Major Ffoulkes (SAS, the Fortress); Captain Agnes Petrie
(merchant ship *Faithful Margaret*); "Tick" Dunmore, a gate pilot; Father Ilie, a Romanian ship's chaplain gone pirate.

---

## Element A742 and the black holes

Official: the game has nuclear material, a Planet Killer, and a world wrecked by war. Fan theory supplies the rest:
A742 came down on Dudinka in 1932; its atoms can be split into tiny stable black holes; two holes linked become a
wormhole, which is what the space gates are. The same element made the V3 rockets and the bombs that finished Earth.

House rules (new) for writing about it:
- It is handled, not understood. Nobody in the world explains the physics; they follow the card on the wall.
- It's heavy, warm to the touch through the shielding, and makes compasses and clocks drift.
- Exposure signs: nosebleeds, a metallic taste, hair loss, then the cancers. Talk about it the way dock workers talk
  about asbestos.
- Loose A742 makes "tennis balls", tiny black holes that grow if fed. The worst thing you can do is drop a sample on
  something heavy.
- In game terms the `NuclearMaterial` item is A742 in a lead canister. Never make it glow green or hum with magic.

---

## Style guide

**Voice.** Write as someone in the world writing for someone else in the world: a clerk, a Marine, a convict, a
trader. They don't explain what everyone knows. Short sentences, concrete nouns, numbers. Let the grim joke land
once and move on.

**Period tech.** 1930s-1990s dieselpunk: rivets, valves, pressure gauges, typewriters, carbon copies, punch cards at
the very most, reel-to-reel tape, crystal radios, Morse, slide rules, hand cranks, gas masks, trench guns, Thompsons,
1911s. Computers are room-sized and called "the machine". Display is a dial or a lamp.

**Spelling.** British or neutral English in narration. A UA document may use American spellings ("armor", "color")
because that's who wrote it; a KA document should be British.

**Never:**
- modern slang, memes, internet speak, "vibes", "literally";
- lasers, energy shields, aliens, psychic powers, magic, glowing crystals, AI;
- real-world modern politics, real living politicians, real modern parties or slogans;
- one empire as the clear villain: all three lie, all three starve their people, all three have decent soldiers;
- pirates as heroes of a moral cause: they can be likeable, brave and loyal to each other, never righteous;
- quoting the game's opening speech, the fan timeline or Ceeg's story at length;
- gore for its own sake: imply.

**Do:** name things (ships, people, rooms, decree numbers); give prices; date things; let documents contradict each
other where people would lie.

---

## Open questions for the maintainers

1. **The "now".** The opening speech's "70 years in the shadow of the Great War" suggests ~1984 if the war is 1914;
   the wiki has humanity in space "by ~1992"; the fan timeline ends the Age of Marauders in 1990. We used 1984. OK?
2. **How much fan theory?** A742, the Sites and V3s are not official. Are we happy to show fan-theory text in game,
   perhaps only in optional readable notes, never on loading screens? (Our loading lines lean on official facts and
   mark the fan-theory ones.)
3. **The JTA** (the 1950s multinational space body) is our name for the fan timeline's unnamed organisation. Keep,
   rename, or drop?
4. **Ceeg's names.** Do we want to ask Ceeg before using Fletcher, Haney and Sledge at all, even as nods?
5. **The Baron's identity.** We keep him a rumour (several Barons, nobody sure). Does the boss in game contradict
   that?
6. **Calico's gender and backstory** (we wrote her as a woman) and the traders' personalities: does any game voice
   line contradict them?
7. **Rebels as a faction.** The game has a Rebel Base map; we gave the Rebels a 1951 lineage from the fan timeline.
   Fine?
8. **Where Jupiter fits.** The wiki's store of Earth logs on Jupiter (for small-arms stocks) is used in one fragment
   as a Jovian timber depot. Too literal?
