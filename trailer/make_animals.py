"""Public test trailer, cut to Architects "Animals" (95 BPM).

    python trailer/make_animals.py            full render  -> trailer/marauders_public_test.mp4 (1080p60)
    python trailer/make_animals.py --draft    quick 30 fps preview -> trailer/marauders_public_test_draft.mp4
    python trailer/make_animals.py --list     shot list with timecodes, and which clips are still missing

Footage: trailer/footage/<name>.mp4 (rec.sh), trailer/footage/<name>.mkv (orec.sh) or trailer/session/<name>.mkv (session.sh). A shot whose clip isn't
recorded yet uses its stand-in from the first trailer, or a grey slate naming the shot.

Song: the whole of it, uncut (4:04). Trailer beat k = song beat k, at 0.030 + k * 0.6316 s (beat 0.6316 s). Sections
(song beats): 0-16 intro | 16-48 first riff | 48-80 verse | 80-112 chorus | 112-144 verse | 144-176 chorus | 176-184 quiet
break | 184-214 verse | 214-232 breakdown A | 232-248 | 248-252 silence | 252-280 breakdown B | 280-284 silence |
284-332 the drop | 332-348 last chorus, the stop at 346 | 348-380 final phrase | ring-out.
"""
import os
import subprocess
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw

import make_trailer as MT  # text styles, zoom, vignette, clip reader

HERE = os.path.dirname(os.path.abspath(__file__))
SONG = "E:/Downloads/Y2Mate.is - Architects - _Animals_.mp3"
DRAFT = "--draft" in sys.argv
OUT = os.path.join(HERE, "marauders_public_test_draft.mp4" if DRAFT else "marauders_public_test.mp4")
W, H = MT.W, MT.H
FPS = 30 if DRAFT else 60
SR = 48000
BEAT, PH = 0.63160, 0.030
PARTS = [(0, None)]  # song beat ranges: the whole song
# Joins that need more than the 12 ms crossfade, by the index of the incoming part: dict(quiet, rise, boom) = beats of
# silence, beats of fade-in, seconds of impact ring. None now that the song plays uncut.
JOINS = {}


def impact(n_sec, sr):
    """A low trailer hit: a falling sub sine plus a short filtered noise burst, both decaying."""
    t = np.arange(int(n_sec * sr)) / sr
    f = 32 + 30 * np.exp(-t * 9)
    sub = np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-t * 2.6)
    rng = np.random.default_rng(7)
    nz = rng.standard_normal(len(t))
    k = int(sr / 900)  # crude low-pass: moving average
    nz = np.convolve(nz, np.ones(k) / k, mode="same") * np.exp(-t * 7) * 0.9
    y = sub * 0.55 + nz * 0.25
    y[: int(0.003 * sr)] *= np.linspace(0, 1, int(0.003 * sr))
    return np.stack([y, y], axis=1).astype(np.float32)


def T(k):
    """Trailer time of trailer beat k."""
    return PH + k * BEAT


END = 244.27  # the song's own end, ring-out included
HITS = [T(16), T(284), T(348)]

# -----------------------------------------------------------------------------------------------------------------
# Shot list. (beats, clip, what it shows, stand-in (old clip, in) or None, options, caption)
#   clip prefixes: a_ = AI shot recorded with the trailer camera, fp_ = your first-person play, m_ = menus / lobby
F, P = dict(flash=True), dict(punch=True)
SHOTS = []   # (k0, beats, clip, desc, standin, opts, caption)
TEXT = []    # (t0, t1, kind, lines)


def run(k, shots):
    for nb, clip, desc, standin, o, cap in shots:
        SHOTS.append((k, nb, clip, desc, standin, o, cap))
        if cap:
            TEXT.append((T(k) + 0.15, T(k + nb) - 0.05, "cap", cap))
        k += nb
    return k


# Cold open, k 0-16: the quiet intro.
run(0, [
    (6, "a_open", "a ship gliding past a huge asteroid, orange nebula behind", ("s01_myship", 0.8), dict(zoom=(1.0, 1.08), fadein=1.5), None),
    (5, "m_lobby_crew", "lobby: your hired crew on their stands, slow push in", None, dict(zoom=(1.4, 1.48), focus=(0.45, 0.45)), None),
    (5, "a_dock_arrive", "a rival ship sliding into a station berth", ("s07_docked", 1.0), dict(zoom=(1.0, 1.05)), None),
])
TEXT += [(T(0.5), T(5.5), "card", ["SOMEWHERE OUT THERE"]),
         (T(7), T(15.5), "card", ["A CREW IS COMING FOR YOUR SHIP."])]

# k16: the drop. Title, then ship combat.
TEXT.append((T(16), T(20), "title", ["MARAUDERS", "OFFLINE  PvE"]))
run(20, [
    (4, "a_chase1", "chase cam behind a rival, turrets firing", ("s02_chase1", 0.5), F, ["RIVAL CREWS", "AI PIRATES FLYING THEIR OWN SHIPS"]),
    (4, "a_duel1", "duel: over one ship's shoulder at another, shells crossing", ("s06_duel2", 2.5), P, ["26 SHIP DESIGNS", "WORKING WEAPONS, WORKING DAMAGE"]),
    (4, "a_orbit_fight", "a ship battle, wide: a line of ships trading fire", ("t_fight", 0.5), P, ["SHIP BATTLES", "AI CREWS FIGHT EACH OTHER, NOT JUST YOU"]),
    (4, "fp_gunseat", "you in the turret seat, shells hitting a rival", ("c_c2", 1.5), P, ["MAN THE GUNS", "TAKE A TURRET SEAT YOURSELF"]),
    (2, "a_rockets", "a ship taking rocket and cannon hits, explosions bursting round it", ("t_fight3", 5.0), P, None),
    (2, "a_hit", "a ship hit hard: fire, smoke, drifting", ("t_fight3", 6.6), P, None),
    (4, "a_burn", "a rival ship burning under fire", None, P, None),
    (2, "a_chase2", "behind a gunship flying into the fight, a ship exploding ahead", ("s05_duel1", 0.3), P, None),
    (2, "a_breach_ship", "a rival ship pulling up to breach a station", ("s08_defender", 0.5), P, None),
])

# k48-80: first verse. The world, then rivals living their own raids.
run(48, [
    (4, "a_map1", "map flyby: a station from outside, slow drift", None, dict(zoom=(1.0, 1.05)), ["6 MAPS", "EVERY CREW MAP, PLAYABLE SOLO"]),
    (4, "a_map2", "map flyby: a second map's station", None, dict(zoom=(1.0, 1.05)), None),
    (4, "a_map3", "map flyby: a third station type", None, dict(zoom=(1.0, 1.05)), ["STATIONS TO RAID", "MINES, PRISONS, SPACEPORTS, CAPITAL SHIPS"]),
    (4, "a_map4", "map flyby: a fourth station type", None, dict(zoom=(1.0, 1.05)), None),
    (4, "a_rival_dock", "a rival ship docking at a station", ("s07_docked", 3.0), F, ["RIVALS RAID TOO", "THEY DOCK, LOOT AND EXTRACT LIKE YOU"]),
    (4, "a_rival_extract", "a rival ship flying into the space gate", None, P, None),
    (4, "a_pods", "rival pods streaking at another rival's ship", None, P, ["RIVALS BOARD EACH OTHER", "AND KEEP THE SHIPS THEY TAKE"]),
    (4, "a_captured", "the captured ship turning away under its new crew", None, P, None),
])

# k80-112: first chorus. You board them.
run(80, [
    (4, "fp_pod_launch", "you launching a drop pod from your ship", None, F, ["BOARD BY POD", "LAUNCH STRAIGHT AT THEIR HULL"]),
    (2, "a_pod_player", "your pod streaking at a rival ship (trailer cam)", None, P, None),
    (2, "fp_pod_impact", "the pod hitting their hull", None, P, None),
    # the breach cut at 2 beats: a crewmate pops in right in front of you just after it (board3 ~32.2)
    (2, "fp_board_breach", "breaching into the rival ship, first step in", None, F, None),
    (2, "fp_board_entry", "a soldier in their red-lit room, shot down in the smoke", None, P, None),
    (2, "fp_board_fight", "fighting the crew inside it", None, P, None),
    (2, "fp_board_fight2", "fighting through their ship, another room", None, P, None),
    (2, "fp_board_fight3", "close kill inside their ship", None, P, None),
    (2, "fp_board_clear", "last of their crew down", None, P, None),
    (4, "fp_board_helm", "walking up to their helm and taking it", None, F, ["TAKE THE HELM", "CLEAR THE CREW AND THE SHIP IS YOURS"]),
    (4, "fp_steal_fly", "flying the stolen ship away", None, P, ["KEEP IT", "FLY THEIR SHIP AS YOUR OWN"]),
    (4, "a_stolen_leave", "the stolen ship pulling away (trailer cam)", None, P, None),
])

TEXT.append((T(88) + 0.15, T(92) - 0.05, "cap", ["BOARD THEIR SHIP", "FIGHT THE CREW ON THEIR OWN DECKS"]))

# k112-144: second verse. They board you, you fight them off.
run(112, [
    (4, "a_pods_incoming", "rival pods streaking at your ship (trailer cam)", None, F, ["BOARDERS", "RIVAL PODS BREACH YOUR HULL"]),
    (4, "fp_breach_alarm", "the breach alarm on your ship, turning to face it", None, P, None),
    (4, "fp_repel1", "fighting boarders in your own corridors", None, P, ["REPEL THEM", "HOLD YOUR SHIP, ROOM BY ROOM"]),
    (4, "fp_repel2", "a boarder rounding a corner, you drop them", None, P, None),
    (4, "a_repel_crew", "your crew fighting boarders on your ship (trail cam)", None, P, ["ALL HANDS", "YOUR CREW DEFENDS THE SHIP WITH YOU"]),
    (4, "fp_repel3", "close fight with a boarder", None, P, None),
    (4, "fp_repel_last", "the last boarder down, ship quiet", None, P, None),
    (4, "a_ship_ok", "your ship turning back into the fight, wide", None, P, None),
])

# k144-176: second chorus. Progression.
run(144, [
    (4, "m_contracts", "the contracts screen, a contract picked", ("s13_loot2", 2.0), F, ["CONTRACTS", "JOBS AT EVERY STATION, PAID WHEN YOU GET OUT"]),
    (4, "m_minimap", "the task map overview with a route drawn", None, P, ["TASK MAP", "A ROUTE TO EVERY CONTRACT"]),
    (4, "m_traders", "buying from a trader", None, P, ["TRADERS", "BUY, SELL AND GEAR UP BETWEEN RAIDS"]),
    (4, "m_shipshop", "the ship shop, buying a new hull", None, P, ["BIGGER SHIPS", "BUY A NEW HULL WITH YOUR EARNINGS"]),
    (4, "m_level", "level / XP going up after a raid", None, dict(punch=True, zoom=(1.4, 1.45)), ["LEVEL UP", "XP FROM EVERY RAID AND CONTRACT"]),
    (4, "m_stash", "the stash, reasonably full, hovering items", None, dict(punch=True, zoom=(1.8, 1.85), focus=(0.78, 0.35)), ["YOUR STASH", "WHAT YOU EXTRACT, YOU KEEP"]),
    (4, "a_rival_geared", "a heavily geared rival up close", None, P, ["THE STAKES RISE", "RIVALS GEAR UP AS YOU LEVEL"]),
    (4, "fp_raid_start", "raid loading screen into launch", None, P, None),
])

# k176-184: the song's quiet break. Female characters.
run(176, [
    (8, "m_female_orbit", "slow orbit around a woman in the lobby / character screen", None, dict(zoom=(1.5, 1.58), focus=(0.5, 0.45), flash=True),
     ["PLAY AS HER", "WOMEN'S VERSIONS OF EVERY OUTFIT"]),
])

# k184-214: back in. Stations and AI firefights.
run(184, [
    (4, "a_rival_airlock", "rivals coming through an airlock (trail cam)", None, F, ["STATIONS UNDER ATTACK", "RIVAL CREWS DOCK AND BREACH"]),
    (4, "a_inf_fight1", "guards vs rivals firefight (duel cam)", None, P, ["THREE-WAY FIGHTS", "STATION GUARDS AND RIVAL CREWS AT WAR"]),
    (8, "a_inf_cover", "AI leaning out from a pillar, firing, ducking back", None, P, ["SMARTER AI", "LEANS OUT, FIRES, DUCKS BACK INTO COVER"]),
    (4, "a_inf_search", "AI moving in on a noise, searching", None, P, ["THEY HUNT YOU", "THEY HEAR SHOTS AND COME LOOKING"]),
    (7, "a_aif14", "a raider running and shooting down a corridor (AI vs AI)", None, P, None),
    (3, "fp_fight3", "you in a station firefight", None, P, None),
])

# k214-232: breakdown A. Two-beat lead-in, then one hard cut on every stab (16).
k = run(214, [(2, "fp_fight2", "you peeking a corner", None, P, None)])
STAB_A = ["fp_kill1", "a_kill1", "fp_kill2", "a_kill2", "fp_kill3", "a_kill6", "fp_kill4", "a_kill3",
          "fp_kill5", "a_aif12", "fp_kill6", "a_kill4", "fp_kill7", "a_kill5", "fp_kill8", "fp_killlist"]
for i, c in enumerate(STAB_A):
    k = run(k, [(1, c, "a kill / hit, cut on the stab", None, dict(punch=True), None)])
TEXT.append((T(228), T(232) - 0.05, "cap", ["KILL LIST", "EVERY CREW YOU TAKE DOWN, TRACKED"]))

# k232-248: crew.
run(232, [
    (4, "m_hire", "hiring page: picking a crew member", None, F, ["HIRE A CREW", "PICK WHO FLIES WITH YOU"]),
    (4, "fp_crew_follow", "your crew moving with you through a station", None, P, ["YOUR CREW", "THEY FOLLOW YOU AND FIGHT BESIDE YOU"]),
    (4, "a_crew_fight", "trail cam behind your crew in a firefight", None, P, ["THEY RANK UP", "AND WHEN THEY DIE, THEY'RE GONE"]),
    (4, "a_crew_gunner", "chase cam on your ship, your gunner firing", ("c_b1", 9.4), P, ["CREW GUNNERS", "THEY MAN YOUR TURRETS WHILE YOU FLY"]),
])

# k248-252: silence.
TEXT.append((T(248.2), T(252) - 0.05, "card", ["WHAT YOU TAKE..."]))

# k252-280: breakdown B, cut on its accents (k 252 253 254 | 258 259 260 261 262.5 | 266 | 268 | 270 | 274 275 276 | 278).
# The raid loop as one-word stabs; the screens themselves get their own shots in the second chorus.
def stab(k0, k1, clip, desc, standin, word, o=None):
    SHOTS.append((k0, k1 - k0, clip, desc, standin, dict(punch=True, **(o or {})), None))
    if word:
        TEXT.append((T(k0), T(k1) - 0.03, "stab", [word]))


stab(252, 253, "fp_loot_body", "looting a body", ("s12_loot", 1.0), None)
stab(253, 254, "fp_loot_crate", "opening a container", ("s13_loot2", 1.0), None)
stab(254, 258, "fp_extract_gate", "flying into the space gate", ("escaped", 0.2), None, dict(cin=2.8))
stab(258, 259, "m_stash", "stash grid", None, None, dict(zoom=(1.8, 1.8), focus=(0.78, 0.35), cin=2.6))
stab(259, 260, "m_stash", "stash, other corner", None, None, dict(zoom=(2.0, 2.1), focus=(0.72, 0.25), cin=3.4))
stab(260, 261, "m_stash", "stash, item hover", None, None, dict(zoom=(2.2, 2.3), focus=(0.88, 0.3), cin=4.2))
stab(261, 262.5, "m_stash", "stash, wide", None, None, dict(cin=5.0))
stab(262.5, 266, "m_level", "level / XP going up after a raid", None, None, dict(zoom=(1.4, 1.4), cin=2.6))
stab(266, 268, "m_traders", "selling to a trader", None, None, dict(cin=3.0))
stab(268, 270, "m_traders", "buying from a trader", None, None, dict(cin=5.0))
stab(270, 274, "m_craft", "crafting", None, None)
stab(274, 275, "m_inspect", "inspecting a weapon", None, None)
stab(275, 276, "m_loadout", "loadout and stash", None, None)
stab(276, 280, "x_two2", "ships over the planet, sun behind: back out there", None, None)

TEXT.append((T(261), T(262.5) - 0.05, "card", ["...YOU KEEP"]))

# k280-284: silence.
TEXT.append((T(280.2), T(284) - 0.05, "card", ["PUBLIC TEST"]))

# k284: the drop. One-beat cuts, then half-beat cuts.
DROP = [("x_duel_n4a", 0), ("x_obs255", 0), ("x_obs_pod200", 0), ("x_st69", 0), ("x_orbit_n3a", 0),
        ("x_steal_fire", 0), ("x_steal_boom", 0), ("x_b2f", 0)]
k = 284
for i, (c, cin) in enumerate(DROP):
    SHOTS.append((k, 1, c, "drop montage", None, dict(punch=True, cin=cin), None))
    k += 1
DROP2 = [("x_duel_n2a", 0), ("x_f1a", 0), ("x_hit2a", 0), ("x_st165", 0), ("x_c_c4", 0), ("x_obs117", 0),
         ("x_obs_pod88", 0), ("x_e266", 0), ("x_duel_n1a", 0), ("x_st216", 0), ("x_chase3b", 0), ("x_obs266", 0),
         ("x_tfight2", 0), ("x_aif17a", 0), ("x_obs_breach", 0), ("x_st184", 0)]
for i, (c, cin) in enumerate(DROP2):
    SHOTS.append((k, 0.5, c, "drop montage", None, dict(cin=cin), None))
    k += 0.5
TEXT.append((T(284), T(288) - 0.05, "cap", ["PUBLIC TEST", "OUT NOW"]))

# k300-332: still loud after the drop. The scale of it, then your rules and your saves.
run(300, [
    (4, "a_battle_wide", "a big battle, wide: many ships, pods crossing", ("t_fight", 1.0), F, ["UP TO 11 RIVAL CREWS", "SHARING EVERY RAID WITH YOU"]),
    (2, "a_pods2", "pods crossing the battle", None, P, None),
    (2, "a_burn2", "a ship breaking up", None, P, None),
    (2, "a_chase3", "chase cam through the battle", None, P, None),
    (2, "a_battle_top", "the battle from above", None, P, None),
    # credit where it's due (CREDITS.md): the bot personalities and difficulty modifiers are adapted from SAIN's defaults
    (4, "m_ai_menu", "the AI menu (F3): difficulty presets row, tabs", None, dict(flash=True, zoom=(2.0, 2.08), focus=(0.22, 0.25)),
     ["121 AI SETTINGS", "PERSONALITIES ADAPTED FROM SAIN BY SOLARINT"]),
    (4, "m_ai_presets", "the My presets tab: saving one", None, dict(punch=True, zoom=(2.0, 2.08), focus=(0.22, 0.25)),
     ["YOUR RULES", "4 DIFFICULTIES, OR SAVE YOUR OWN"]),
    (4, "m_launcher", "launcher: your saves", None, F, ["NO SERVERS NEEDED", "YOUR SAVES, ON YOUR PC"]),
    (4, "m_newsave", "the new-save dialog, stash size typed in", None, P, ["SAVE SLOTS", "PICK YOUR STASH SIZE, 10 TO 25 ROWS"]),
    # the repo (goes public at release): README scrolling from the folder map into the setup steps
    (4, "gh_readme", "the GitHub repo: README folder map into setup", None, dict(flash=True, zoom=(1.45, 1.55), focus=(0.56, 0.5)),
     ["OPEN SOURCE, ANYONE CAN CONTRIBUTE", "GITHUB.COM/HAYWIREHAYLEY/MARAUDERS-PVE"]),
])

# k332-348: last chorus, the stop at k346.
run(332, [
    (4, "fp_extract_gate", "the gate jump, full", ("escaped", 0.2), F, ["EXTRACT", "REACH THE GATE WITH YOUR LOOT"]),
    (4, "a_drift", "your ship leaving, wide", ("s01_myship", 6.0), P, None),
    (4, "x_steal_cruise", "the stolen ship cruising", None, P, None),
    (2, "a_battle_high", "one last look at the battle, from above", ("t_fight", 3.0), dict(zoom=(1.0, 1.1)), None),
])
# k346-348: black. k348: title slam, then the final phrase.
TEXT.append((T(348), T(356), "title", ["MARAUDERS", "OFFLINE  PvE"]))
FINAL = ["x_duel_n2b", "x_f1b", "x_obs_pod203", "x_st71", "x_orbit_n3b", "x_steal_fire2", "x_duel_n4b", "x_e272",
         "x_hit2b", "x_aif17b", "x_steal_pod", "x_f1c", "x_duel_n1b", "x_obs70", "x_chase_n6", "x_obs249",
         "x_orbit_n3c", "x_duel_n3", "x_geared", "x_b2f2", "x_b3fly", "x_hit2c", "x_chase_n7", "a_drift"]
for i, c in enumerate(FINAL):
    SHOTS.append((356 + i, 1, c, "final phrase", None, dict(punch=True, cin=1.0 + (i % 3)), None))
assert 356 + len(FINAL) == 380
TEXT.append((T(380), END - 0.3, "end", ["MARAUDERS", "OFFLINE  PvE", "PUBLIC TEST  -  OUT NOW"]))

# Stand-ins from the first trailer, for when a clip turns up later in the edit without its own entry.
STANDIN = {}
for _k, _nb, _c, _d, _s, _o, _cap in SHOTS:
    if _s and _c not in STANDIN:
        STANDIN[_c] = _s
# first-person fights from the first trailer's play session (trailer/session/play_0937_*), until new ones exist
_P1, _P2 = "play_0937_01", "play_0937_02"
for _c, _s in {"fp_fight1": (_P2, 140.6), "fp_fight2": (_P2, 45.0), "fp_kill1": (_P2, 17.0), "fp_kill2": (_P2, 165.0),
               "fp_kill3": (_P1, 268.0), "fp_kill4": (_P1, 150.0), "fp_kill5": (_P2, 55.5), "fp_kill6": (_P1, 120.0),
               "fp_kill7": (_P2, 60.0), "fp_kill8": (_P2, 141.2), "fp_killlist": (_P2, 46.0),
               "fp_board_fight": (_P1, 28.0), "fp_board_breach": (_P1, 58.0), "fp_crew_follow": (_P1, 85.0)}.items():
    STANDIN.setdefault(_c, _s)


# -----------------------------------------------------------------------------------------------------------------
def clip_path(name):
    for p in (os.path.join(MT.FOOT, name + ".mp4"), os.path.join(MT.FOOT, name + ".mkv"),
              os.path.join(HERE, "session", name + ".mkv")):
        if os.path.exists(p):
            return p
    return None


# Where the good part of each recorded clip starts (seconds); a shot's own cin is added on top (montage variety).
CIN = {"a_duel1": 0.5, "a_chase1": 4.3, "a_chase2": ("c_c5", 2.8), "a_duel2": ("c_b2", 5.0),
       "a_duel3": ("c_b2", 1.0), "a_hit": 6.0, "a_drift": ("a_battle_duel2", 0.5), "a_orbit_fight": ("a_battle_wide", 0.3),
       "a_rockets": ("c_c1", 2.3), "a_burn": ("c_b2", 7.2), "a_battle_high": 0.5}
# Fortress firefight, 14 Nov (play_1947_00 from 19:47:42, play_1947_01 from 19:52:42): soldiers using cover
_F0, _F1 = "play_1947_00", "play_1947_01"
# a_chase1, a_duel1, a_pods_incoming and s08_defender were recorded while the game hitched (frames update every
# 0.3-1 s); use the clean takes of the same shots instead (checked with a frame-repeat scan)
CIN.update({"a_chase1": ("s02_chase1", 0.5), "a_duel1": ("s06_duel2", 2.5), "a_pods_incoming": ("a_pods_incoming2", 0.5),
            "a_breach_ship": ("s07_docked", 3.1), "a_rival_dock": ("s07_docked", 0.5),
            "a_battle_high": 1.6})
CIN.update({"fp_fight1": (_F1, 0.0),     # soldier walking up the corridor at you
            "a_inf_cover": (_F1, 13.0),   # soldiers crouched behind the barricade, then moving between cover
            "a_inf_peek": (_F1, 15.6),    # soldier stepping out from behind the pillar
            "fp_fight3": (_F1, 4.0),      # several soldiers firing from among the crates
            "fp_kill2": (_F0, 271.8), "a_kill2": (_F1, 2.3), "fp_kill4": (_F0, 287.8), "a_kill3": (_F0, 275.9),
            "fp_kill6": (_F1, 25.8), "a_kill4": (_F1, 53.8), "a_kill5": (_F1, 20.5)})
# the earlier raid's red-room fight (play_1936_00 from 19:36:00)
_E = "play_1936_00"
CIN.update({"fp_fight2": (_E, 266.0),     # soldier coming through the door at you
            "fp_kill1": (_E, 214.9),      # soldier peeking from the pillar drops
            "fp_kill3": (_E, 240.0), "fp_kill5": (_E, 210.8), "fp_kill7": (_E, 273.0)})
# pod cam takes, 14 Nov evening, picked by eye: a rival's pods flying at and breaching another rival's ship (n11 6-10 s),
# pods breaching your ship (incoming_n5 6-9 s, incoming_n7 12-15 s, a red forcefield in shot)
CIN.update({"a_pods": ("a_pods_n11", 6.0), "a_pods_incoming": ("a_pods_incoming_n5", 5.5),
            "a_pods2": ("a_pods_incoming_n7", 12.5),
            "a_pods_m1": ("a_pods_incoming_n2", 14.5),   # drop montage: pods at your ship (14-16 s)
            "a_pods_m2": ("a_pods_incoming_n4", 13.5),   # drop montage: pods at your ship (13-16 s)
            "a_pod_player": ("board2_approach", 5.2),   # your pod flying past their ship burning in a fight (5-8 s)
            "fp_pod_impact": ("board2_approach", 10.4)})  # your pod closing on their hull (10-12 s)
# second boarding, OBS take 14 Nov (obs_232934 3:42.5-4:04.5): two soldiers, the second fought from cover
CIN.update({"fp_board_fight": ("board2_fights", 2.44),  # first soldier: shot, falls by 3.7
            "fp_board_fight2": ("board2_fights", 8.0),  # peeking from the red container
            "fp_board_fight3": ("board2_fights", 11.0), # soldier rounding the cover
            "fp_board_clear": ("board2_fights", 19.0)})  # lined up on the doorway, fight over

# station flybys from outside, 15 Nov (orec.sh, CINE.orbit): one per station type the caption names
CIN.update({"a_map1": ("a_map_mine", 5.0),        # Asteroid Mine and its rings over the blue planet (Space_Beta)
            "a_map2": ("a_map_penal", 3.0),       # Penal Colony in the asteroid field, orange nebula (Space_Solo_02)
            "a_map3": ("a_map_spaceport", 1.5),   # Spaceport, low side-on (Space_Alpha; rocks cover it after 8 s)
            "a_map4": ("a_map_capital", 6.0)})    # Capital Ship's red lights, Penal Colony behind (Space_Solo_02)
# the game stalled for 10-20 frames at a time while those were recorded; the *_s files are 7 s spans of them with the
# repeats dropped and the gaps motion-interpolated (mine from 3 s, penal 1, spaceport 0, capital 4)
# refilmed 2026-11-15 after a warm-up orbit: a_map_mine2 55 fps, a_map_penal2 52, a_map_spaceport2 59 a_map_minimine2 60 (spare: a_map_rebel2 58)
CIN.update({"a_map1": ("a_map_mine2", 3.0), "a_map2": ("a_map_penal2", 3.0),
            "a_map3": ("a_map_spaceport2", 3.0), "a_map4": ("a_map_minimine2", 1.0)})

# third boarding, OBS take 15 Nov (footage/board3.mkv, Space_Delta): pod into their hull, your crew fighting alongside
# you through their ship and its red room, then their helm and flying it away. Replaces the board2 fight picks.
_B3 = "board3"
CIN.update({"fp_pod_impact": (_B3, 28.3),    # your pod closing on their hull, hits at ~29.5
            "fp_board_breach": (_B3, 30.65),  # into their corridor, just after the breach haze (cut by 31.9)
            "fp_board_entry": ("board_run1", 36.3),  # (unused take) a soldier in the smoke by their red light, shot
            "fp_crew_follow": (_B3, 37.0),   # your crew running up the stairs ahead of you (31-33: a crew member pops in, skip)
            "fp_board_fight2": (_B3, 34.0),  # your crew at the pillar, fighting beside you
            "fp_board_fight": (_B3, 41.0),   # a soldier firing down the corridor, one running at you past a body
            "a_crew_fight": (_B3, 51.0),     # your crew pushing into the red room, firing
            "fp_board_fight3": ("fp_steal1", 141.0),  # (earlier take) a boarder crouched in their red room, drops
            "fp_board_clear": (_B3, 69.5),   # a body in the red room, fight over
            "fp_board_helm": (_B3, 74.5),    # walking up to their helm and taking it (hands on it ~77)
            "fp_steal_fly": (_B3, 79.0),     # the stolen Light Scout flying out
            "a_stolen_leave": ("fp_steal1", 180.0)})  # (earlier take) the stolen Long Odds past the planet, sun behind

# the earlier pod take (fp_pod_board1): inside your pod as it fires off, red light
CIN.update({"fp_pod_launch": ("fp_pod_board1", 1.0)})
# rivals board you (fp_repel_take1, 86 s): pods hit at ~18, you leave the helm, clear the corridors, back at the helm ~64
_R = "fp_repel_take1"
CIN.update({"fp_breach_alarm": (_R, 11.5),  # the pod hits your ship: explosion (the helm from ~20 stays out)
            "fp_repel1": (_R, 26.0),        # moving through your corridors, gun up
            "fp_repel2": (_R, 37.0),        # a boarder in the doorway, dropped
            "a_repel_crew": (_B3, 55.0),    # your crew firing in the red room (board3; no crew in the repel take)
            "fp_repel3": (_R, 58.5),        # close fight, smoke, a body
            "fp_repel_last": (_R, 49.0),    # a body on the floor (61+ turns back to the helm)
            "a_ship_ok": (_R, 70.0)})       # your ship flying on over the red planet
# station fights from the newest take (a_station1, 15 Nov, Asteroid Mine; windows in ANIMALS_SHOTS.md). Replaces the
# 14 Nov fortress takes and the first trailer's s09_rival (beret soldier) and s10_firefight. Never 149-161 (shotgun).
_S = "a_station1"   # 239-244: an unarmed enemy (bug?) by the stairs, keep out
LIFT = {_S: 1.6}   # the mine's tunnels are near black once graded; gamma-lift the take
CROP = {_S: 1.1}   # crop the debug overlay (FPS / location text) out of its corners
CIN.update({"a_rival_airlock": (_S, 248.0),  # a rival walking down the lit stairs
            "a_inf_fight1": (_S, 255.5),     # white suit drops
            "a_inf_search": (_S, 163.5),     # the stairs fight
            "fp_fight1": (_S, 68.0), "a_inf_fight2": (_S, 79.5),  # slumps down the wall
            "a_inf_peek": (_S, 184.5), "fp_fight3": (_S, 136.0),  # muzzle flash / fire
            "fp_fight2": (_S, 214.5),
            "fp_kill1": (_S, 81.0), "a_kill1": (_S, 256.5), "fp_kill2": (_S, 70.0), "a_kill2": (_S, 88.5),
            "fp_kill3": (_S, 165.0), "a_kill6": (_S, 242.0), "fp_kill4": (_S, 186.0), "a_kill3": (_S, 216.0),
            "fp_kill5": (_S, 138.0), "a_kill7": (_S, 82.5), "fp_kill6": (_S, 257.5), "a_kill4": (_S, 166.5),
            "fp_kill7": (_S, 257.0), "a_kill5": (_S, 217.0), "fp_kill8": (_S, 71.5), "fp_kill9": (_S, 256.0)})
# the kill stabs (k214-232) and the drop / final montages mix the station take with the 14 Nov fortress fights
# (_F0, _F1, _E) and the firefights aboard ships (board3, board2, the repel take, fp_steal1)
_D, _R, _ST = "board2_fights", "fp_repel_take1", "fp_steal1"
CIN.update({"a_kill1": (_F1, 25.8), "fp_kill2": (_B3, 42.0), "a_kill2": (_S, 256.5), "fp_kill3": (_E, 214.9),
            "a_kill6": (_R, 47.0), "a_kill3": (_D, 2.44), "fp_kill5": (_F0, 271.8), "fp_kill6": (_B3, 53.0),
            "a_kill4": (_E, 240.0), "a_kill5": (_ST, 141.0), "fp_kill8": (_F1, 53.8),
            "fp_kill10": (_R, 43.5), "fp_kill11": (_D, 8.0), "fp_kill12": (_F0, 287.8), "fp_kill13": (_E, 273.0)})
# menus (m_menus1 lobby, m_stash1, m_level1, m_female_orbit2, fp_raid_map1); see ANIMALS_SHOTS.md for the windows
_M = "m_menus1"
CIN.update({"m_hire": (_M, 16.5), "m_traders": (_M, 29.0), "m_contracts": (_M, 42.0), "m_shipshop": (_M, 46.5),
            "m_lobby_crew": (_M, 62.0), "m_stash": ("m_stash1", 1.0), "m_level": ("m_level1", 15.5),
            "m_female_orbit": ("m_female_orbit2", 18.0), "m_minimap": ("fp_raid_map1", 58.0),
            "fp_raid_start": ("fp_raid_map1", 26.6)})  # the bar fills 26.5-30; 34+ is the faded freeze
# AI vs AI (raider crews fighting each other, 15 Nov, ~60 fps). Approved: a_aifight1 0-7 (hangar, duel cam), and from
# the wall-safe CINE.fight cam a_aifight12 0-1.5 (two fighters trading shots by crates; a bot walks through the camera
# after 4 s) and a_aifight8 (a raider moving down corridors, 0-8). Takes 2-7 and 9 clip walls or hold on a wall.
# a_aifight14 0-5 (a raider running and shooting down a corridor; after 5 s the cam loses him): 7 beats, in place of
# the old a_inf_fight2 / a_inf_peek stand-ins. Never a_aifight16 (the mouse cursor is in it).
CIN.update({"a_inf_search": ("a_aifight8", 1.0), "a_aif12": ("a_aifight12", 0.2), "a_aif1": ("a_aifight1", 0.5),
            "a_aif14": ("a_aifight14", 0.3)})
# a_lean1 (your own view, 15 Nov): a raider leaning his whole body out from a pillar to fire. The approved span is
# 3-8 (8 beats; fp_fight1 gave up its slot for it). The mouse cursor is in 0-0.6 only. Cropped like _S for the debug
# overlay, and gamma-lifted (he's in shadow by the pillar).
CIN["a_inf_cover"] = ("a_lean1", 3.0)
LIFT["a_lean1"] = 1.4
CROP["a_lean1"] = 1.1
# a_rival_geared2 (15 Nov, CINE.front on a spawned top-grade raider: Stahlhelm, Panzer armour, big pack): 0.5-4.5 is
# her holding the doorway frame as cover and firing round it, which you liked; 6-8 turns front-on to show the armour
# (spare for a flash cut). 4.5-5.5 passes close to the camera, so stay out of it.
CIN["a_rival_geared"] = ("a_rival_geared2", 1.0)
# m_ai_menu1 (15 Nov, your F3 menu in the lobby): tabs flicked 23-33 (Cover 26, Senses 29, Rivals 31), Saved setups
# from 34, "MAIN" typed 36-37 and saved at 38. The menu fills the top-left, so both slots zoom in on it.
CIN.update({"m_ai_menu": ("m_ai_menu1", 28.8), "m_ai_presets": ("m_ai_menu1", 36.0)})
# Space, 15 Nov (fight.sh fights by your ship). a_chase3b (chase 8 m back): a burning ship by an asteroid 0-3, firing
# 3.5-5, then a big blast 5-6. a_battle_top1 (orbit from 70 m up): tracers between three ships, one blows up at 2-3; a
# red glow sweeps in from the right after 3. a_chase3a was filmed too far back (the ships are specks).
# You: the opening of a_chase3b is the chase; a_burn2 gets its own shot of a wreck. 4.2-6 (the blast) is spare.
CIN.update({"a_chase3": ("a_chase3b", 0.2), "a_battle_top": ("a_battle_top1", 1.0)})
# a_burn2b: a slow close orbit round a burning rival wreck (glowing hull, smoke). The reddest stretch is 5.5-9; a_burn2a
# was filmed too far out.
CIN["a_burn2"] = ("a_burn2b", 6.0)
# a_rival_extract2: chase cam behind a red strike frigate leaving after winning its fight, threading the asteroids with
# a station far off. Rivals vanish at their exit point (no gate), so this is the flying-off part. a_rival_extract1 is
# inside a station wall (that ship was stuck).
CIN["a_rival_extract"] = ("a_rival_extract2", 1.0)
CIN["a_captured"] = ("a_captured2", 5.5)   # staged 1v1: capture at ~6 s, ship banks away 5.5-8.5 then cruises; a_captured1 is a dud (took a wreck)
CIN["a_open"] = ("a_open5", 5.3)   # scout weaving through asteroids over the planet, turns toward camera; a_open2 too far out, a_open3/4 forcefield
CIN.update({"gh_readme": ("gh_repo2", 11.0), "m_launcher": ("m_launcher1", 0.8), "m_newsave": ("m_launcher1", 4.6)})  # sandboxed launcher on a blurred backdrop: list 0-3.5, dialog 3.6, name typed 4.8-5.6, "25" 6.4, created 7.8


# The in-game mouse cursor sits over the lobby shot (m_menus1 ~62-65 s, near 1116,342 at 1080p): find it by its sprite
# (cut from that take, assets/lobby_cursor.npy) and paint it out from the surrounding pixels, before the zoom.
DECURSOR = {"m_lobby_crew"}
_CUR = None


def decursor(fr):
    global _CUR
    import cv2
    k = fr.shape[1] / 1920
    if _CUR is None or _CUR[0] != k:
        t = np.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "lobby_cursor.npy"))
        _CUR = (k, cv2.resize(t, None, fx=k, fy=k, interpolation=cv2.INTER_AREA) if k != 1 else t)
    tpl = _CUR[1]
    x0, y0, x1, y1 = (int(v * k) for v in (900, 200, 1400, 560))  # search box around where it hovers
    win = np.ascontiguousarray(fr[y0:y1, x0:x1])
    r = cv2.matchTemplate(cv2.cvtColor(win, cv2.COLOR_RGB2GRAY), tpl, cv2.TM_CCOEFF_NORMED)
    _, mx, _, (bx, by) = cv2.minMaxLoc(r)
    if mx < 0.8:
        return fr
    th, tw = tpl.shape
    m = np.zeros(fr.shape[:2], np.uint8)
    m[y0 + by:y0 + by + th, x0 + bx + int(2 * k):x0 + bx + tw] = 255  # the arrow fills the template bar its left edge
    fr = np.ascontiguousarray(fr)
    return cv2.inpaint(fr, cv2.dilate(m, np.ones((3, 3), np.uint8)), 5, cv2.INPAINT_TELEA)


def resolve(clip, opts):
    """-> (path or None, in point). A recorded clip wins; then the old stand-in; else a slate."""
    c = CIN.get(clip, 0.5)
    if isinstance(c, tuple):  # this slot is filled from another recorded clip
        clip, c = c
    p = clip_path(clip)
    if p:
        return p, c + opts.get("cin", 0.0)
    if clip in STANDIN:
        old, cin = STANDIN[clip]
        return clip_path(old), cin + opts.get("cin", 0.0)
    return None, 0


def edl():
    out = []
    for k0, nb, clip, desc, _s, o, _c in SHOTS:
        path, cin = resolve(clip, o)
        out.append((T(k0), nb * BEAT, clip, desc, path, cin, o))
    return sorted(out, key=lambda e: e[0])


def song_audio():
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", SONG, "-f", "f32le", "-ac", "2",
                          "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, np.float32).reshape(-1, 2)
    xf = int(0.012 * SR)  # 12 ms crossfade, ending right on the new downbeat
    out = []
    for a, b in PARTS:
        i0 = int(round((PH + a * BEAT) * SR)) if a else 0
        i1 = int(round((PH + b * BEAT) * SR)) if b else len(x)
        seg = x[i0:i1].copy()
        j = JOINS.get(len(out))
        if j:
            nq, nr = int(j["quiet"] * BEAT * SR), int(j["rise"] * BEAT * SR)
            seg[:nq] = 0
            seg[nq:nq + nr] *= (np.linspace(0, 1, nr) ** 2)[:, None]
            nf = int(0.02 * SR)
            out[-1][-nf:] *= np.linspace(1, 0, nf)[:, None]
            b = impact(j["boom"], SR)
            seg[:len(b)] += b
        if out and not j:
            fade = np.linspace(0, 1, xf)[:, None]
            tail = x[i0 - xf:i0]
            out[-1][-xf:] = out[-1][-xf:] * np.cos(fade * np.pi / 2) + tail * np.sin(fade * np.pi / 2)
        out.append(seg)
    y = np.concatenate(out)[: int(END * SR)]
    y[-int(0.05 * SR):] *= np.linspace(1, 0, int(0.05 * SR))[:, None]
    path = os.path.join(HERE, "music", "animals", "trailer_audio.wav")
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes((np.clip(y, -1, 1) * 32767).astype(np.int16).tobytes())
    return path


def stab_layer(word, lt, dur):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = 1.0 + 0.12 * max(0, 1 - lt / 0.18) ** 2
    f = MT.font_cond(int(150 * s), "Bold Condensed")
    a = 1 - MT.ease_out((lt - (dur - 0.12)) / 0.12) if lt > dur - 0.12 else 1
    y = H / 2 - 95 * s
    MT.spaced(d, (W / 2 + 5, y), word, f, MT.ORANGE + (int(150 * a),), 14, anchor_center=True)
    MT.spaced(d, (W / 2, y), word, f, (245, 245, 245, int(255 * a)), 14, anchor_center=True)
    return img


def slate(clip, desc):
    img = Image.new("RGB", (W, H), (38, 40, 44))
    d = ImageDraw.Draw(img)
    d.text((W / 2, H / 2 - 60), clip, font=MT.font(72), fill=(200, 200, 200), anchor="mm")
    d.text((W / 2, H / 2 + 30), desc, font=MT.font_cond(44, "Light Condensed"), fill=(150, 150, 150), anchor="mm")
    return np.asarray(img)


class Reader(MT.Clip):
    def __init__(self, path, cin, dur):
        self.p = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(max(0, cin)), "-i", path, "-t", str(dur + 0.2),
             "-vf", f"fps={FPS},scale={W}:{H}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdout=subprocess.PIPE)
        self.last = np.zeros((H, W, 3), np.uint8)


def render(audio):
    vig = MT.make_vignette()
    rng = np.random.default_rng(3)
    grain = [rng.normal(0, 3.5, (H // 2, W // 2, 1)).astype(np.float32) for _ in range(6)]
    bar = 56
    tmp = OUT + ".part.mp4"
    enc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
         "-r", str(FPS), "-i", "-", "-i", audio, "-c:v", "libx264", "-preset", "veryfast" if DRAFT else "slow",
         "-crf", "22" if DRAFT else "14", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "320k", "-shortest",
         "-movflags", "+faststart", tmp], stdin=subprocess.PIPE)
    shots = edl()
    total = int(END * FPS)
    cur, ci, still = None, -1, None
    for fi in range(total):
        t = fi / FPS
        seg = None
        for i, e in enumerate(shots):
            if e[0] - 1e-6 <= t < e[0] + e[1] - 1e-6:
                seg = i
        if seg != ci:
            if cur:
                cur.close()
            cur, still = None, None
            if seg is not None:
                st, dur, clip, desc, path, cin, o = shots[seg]
                if path:
                    cur = Reader(path, cin, dur)
                else:
                    still = slate(clip, desc)
            ci = seg
        if seg is not None:
            st, dur, clip, desc, path, cin, o = shots[seg]
            lt = t - st
            fr = cur.read() if cur else still
            if clip in DECURSOR:
                fr = decursor(fr)
            z0, z1 = o.get("zoom", (1.0, 1.0))
            s = z0 + (z1 - z0) * (lt / dur)
            if o.get("punch"):
                s *= 1 + 0.05 * max(0, 1 - lt / 0.25) ** 2
            src = os.path.splitext(os.path.basename(path))[0] if path else None
            s *= CROP.get(src, 1.0)
            fx, fy = o.get("focus", (0.5, 0.5))
            fr = MT.zoom_frame(fr, s, fx, fy).astype(np.float32)
            g = LIFT.get(src)
            if g:  # gamma lift for a dark take, before the grade's contrast
                fr = 255 * (fr / 255) ** (1 / g)
            if o.get("fadein"):
                fr *= min(1, lt / o["fadein"])
            fr = (fr - 128) * 1.1 + 128
            lum = fr.mean(axis=2, keepdims=True) / 255
            fr += (lum - 0.5) * np.array([10, 2, -10], np.float32)
            fr *= vig
            fr += np.repeat(np.repeat(grain[fi % 6], 2, axis=0), 2, axis=1)
            if o.get("flash") and lt < 0.1:
                fr = fr + (255 - fr) * (1 - lt / 0.1) * 0.8
        else:
            fr = np.zeros((H, W, 3), np.float32)
        for h in HITS:
            if 0 <= t - h < 0.12:
                fr = fr + (255 - fr) * (1 - (t - h) / 0.12) * 0.9
        fr = np.clip(fr, 0, 255).astype(np.uint8)
        fr[:bar] = 0
        fr[H - bar:] = 0
        img = None
        for (a, b, kind, lines) in TEXT:
            if a <= t < b:
                if img is None:
                    img = Image.fromarray(fr).convert("RGBA")
                lay = stab_layer(lines[0], t - a, b - a) if kind == "stab" else MT.text_layer(kind, lines, t - a, b - a)
                img.alpha_composite(lay)
        if img is not None:
            fr = np.asarray(img.convert("RGB"))
        enc.stdin.write(fr.tobytes())
        if fi % 300 == 0:
            print(f"  frame {fi}/{total}", flush=True)
    if cur:
        cur.close()
    enc.stdin.close()
    enc.wait()
    os.replace(tmp, OUT)


def listing():
    seen = {}
    for st, dur, clip, desc, path, cin, o in edl():
        src = CIN.get(clip)
        own = clip_path(src[0] if isinstance(src, tuple) else clip)  # (a slot filled from another recorded take)
        state = "recorded" if own else ("stand-in" if path else "MISSING")
        print(f"{int(st // 60)}:{st % 60:05.2f}  {dur:5.2f}s  {clip:18s} {state:9s} {desc}")
        seen.setdefault(clip, (state, desc))
    print("\nStill to record:")
    for c, (s, d) in sorted(seen.items()):
        if s != "recorded":
            print(f"  {c:18s} {s:9s} {d}")


# 15 Nov: no source range plays twice. The drop, the final montage and a few kill stabs get windows of their own
# (checked on contact sheets), and the breakdown's ship shop / contracts repeats give way to screens not shown elsewhere.
_O, _A = "obs_232934", "a_station1"
CIN.update({"fp_kill2": (_S, 89.5), "a_kill2": (_S, 94.5), "fp_kill6": (_O, 247.5), "fp_kill7": (_O, 268.0),
            "a_kill5": (_O, 271.0), "a_battle_wide": ("a_battle_wide", 3.5), "a_duel2": ("c_b2", 4.6),
            "m_craft": (_M, 36.0), "m_inspect": (_M, 54.5), "m_loadout": (_M, 58.0),
            "x_steal_cruise": (_ST, 169.0), "x_two2": ("a_two2", 12.0),
            # drop: one beat each
            "x_duel_n4a": ("a_duel_n4", 1.5), "x_obs255": (_O, 254.8), "x_obs_pod200": (_O, 200.5), "x_st69": (_S, 69.0),
            "x_orbit_n3a": ("a_orbit_n3", 2.5), "x_steal_fire": (_ST, 125.0), "x_steal_boom": (_ST, 60.5),
            "x_b2f": (_D, 12.0),
            # drop: half beats
            "x_duel_n2a": ("a_duel_n2", 4.0), "x_f1a": (_F1, 1.0), "x_hit2a": ("a_hit2", 6.0), "x_st165": (_S, 165.5),
            "x_c_c4": ("c_c4", 6.0), "x_obs117": (_O, 117.0), "x_obs_pod88": (_O, 88.0), "x_e266": (_E, 266.0),
            "x_duel_n1a": ("a_duel_n1", 0.5), "x_st216": (_S, 216.0), "x_chase3b": ("a_chase3b", 4.5),
            "x_obs266": (_O, 266.5), "x_tfight2": ("t_fight2", 8.0), "x_aif17a": ("a_aifight17", 4.0),
            "x_obs_breach": (_O, 92.0), "x_st184": (_S, 184.6),
            # final montage
            "x_duel_n2b": ("a_duel_n2", 8.0), "x_f1b": (_F1, 4.0), "x_obs_pod203": (_O, 203.5), "x_st71": (_S, 71.0),
            "x_orbit_n3b": ("a_orbit_n3", 6.0), "x_steal_fire2": (_ST, 129.0), "x_duel_n4b": ("a_duel_n4", 4.5),
            "x_e272": (_E, 272.8), "x_hit2b": ("a_hit2", 10.0), "x_aif17b": ("a_aifight17", 7.0),
            "x_steal_pod": (_ST, 103.5), "x_f1c": (_F1, 13.0), "x_duel_n1b": ("a_duel_n1", 8.0), "x_obs70": (_O, 70.0),
            "x_chase_n6": ("a_chase_n6", 6.0), "x_obs249": (_O, 249.5), "x_orbit_n3c": ("a_orbit_n3", 10.5),
            "x_duel_n3": ("a_duel_n3", 6.0), "x_geared": ("a_rival_geared2", 6.0), "x_b2f2": (_D, 13.0),
            "x_b3fly": (_B3, 89.5), "x_hit2c": ("a_hit2", 20.0),
            "a_rival_dock": ("a_rival_dock2", 3.0), "a_breach_ship": ("s07_docked", 5.0), "x_chase_n7": ("a_chase_n7", 4.0)})

if __name__ == "__main__":
    if "--list" in sys.argv:
        listing()
        sys.exit(0)
    print(f"audio... ({END:.1f} s)")
    a = song_audio()
    print("video...")
    render(a)
    print("wrote", OUT)
