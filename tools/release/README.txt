MARAUDERS OFFLINE  -  PvE public test
=====================================

Single-player Marauders against AI: soldiers on the stations, rival crews in their own ships, and a crew of your own to
hire. Everything runs on your PC. Nothing talks to the live Marauders servers.

Marauders is being developed by a small team from the UK. Offline PvE is a fan mod and is not affiliated with the
original developer or publisher. You need your own copy of Marauders on Steam.


WHAT YOU NEED
-------------
  - Windows 10 or 11
  - Marauders installed through Steam, and Steam running when you play
  - Python 3.9 or newer  (Install.bat offers to install it for you with winget)


INSTALL
-------
  1. Unzip this folder somewhere permanent with a plain path, e.g.  C:\Games\MaraudersOffline
     (not Program Files, and no non-English letters in the path). Your saves live inside it.
  2. Double-click Install.bat. It finds Python and the game, installs Pillow for the launcher, and puts a
     "Marauders Offline" shortcut on your desktop and in the Start menu.

Install.bat doesn't touch the game folder. That only happens while you play (see "Is my online game safe?").


PLAYING
-------
  Start "Marauders Offline", make a save (NEW SAVE), pick it and press PLAY. When you close the game the launcher saves
  and tidies up. Keep the launcher open while you play.

  Saves:  as many as you like. Copy one before trying something risky, or use "Undo last raid" to go back to the
          moment your last raid started. "Debug start" makes a save with a full stash and infinite money.

  Keys in game:
    F6        crew: hire, dismiss, and choose who comes on raids (in the lobby)
    N / M / B minimap on/off  /  full overview  /  next task
    F2        play as a woman or a man (also a launcher setting)
    F3        AI tuning: every setting of the AI's behaviour as a slider (in a raid)
    F9        debug menu: god mode, extract now, spawn a soldier, and more
    Left click (flying your ship, with a crew gunner aboard): the gunner fires on the ship or space turret nearest the
              middle of your view. Click empty space to send them back to whoever is attacking you.


IS MY ONLINE GAME SAFE?
-----------------------
  PLAY switches the game folder to offline mode (it adds the mod loader, and points the game's backend at your own PC),
  starts the game directly without Easy Anti-Cheat, and puts every file back to stock when you close the game. The
  online game is untouched: launch Marauders from Steam as usual whenever the launcher isn't running a game.

  If your PC crashed mid-game, open the launcher once and close it again, or run Uninstall.bat: either puts the game
  back to stock. Don't start Marauders from Steam while the game folder is in offline mode.

  Hold off game updates: an update to Marauders is unlikely, but if one came it could break the mod. In Steam,
  right-click Marauders > Properties > Updates and choose "Only update this game when I launch it". The launcher starts
  the game without going through Steam, so playing offline won't trigger an update.


KNOWN ISSUES
------------
  - Rarely, dark flat slabs hang in space on the solo maps.
  - Dead boarders' legs can stretch into odd poses.
  - The status line can say "in space" while you're aboard another crew's ship.
  - A short hitch when you first enter a station, and after a hitch, blue gaps can flash at the screen's corners.
  - Space_Solo_02 now and then finds no stations, so that raid has no station tasks.
  - AI ships can get stuck on rocks or station hulls for a while.
  - Some explosion effects and sounds, and some extraction prompts, are missing offline.
  - Soldiers on a station you haven't reached yet are asleep until you get close. This is on purpose, to save
    performance.


REPORTING BUGS
--------------
  After the game has closed, please send:
    backend\last_game.log    the mod's log from your last session
    backend\server.log       the offline backend's log
  and say what you were doing. A save that shows the problem (backend\saves\<name>) helps too.


TROUBLESHOOTING
---------------
  "The game didn't start"     Is Steam running? Is the game updated and installed where Install.bat found it?
                              Run Install.bat again to pick the game folder.
  The launcher won't open     Run Install.bat again; it checks Python and Pillow.
  Game updated and something  The mod patches the game in memory and checks every patch first; after a game update
  stopped working             some patches may be skipped. Check backend\last_game.log for "SKIPPED" and report it.


UNINSTALL
---------
  Run Uninstall.bat (puts the game back to stock, removes the shortcuts), then delete this folder.


CREDITS
-------
  Built with UE4SS (https://github.com/UE4SS-RE/RE-UE4SS, MIT licence).
