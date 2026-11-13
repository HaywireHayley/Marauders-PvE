# Finds live objects holding the excluded-extensions set: walks private memory for TSet shape at +0x60 with 5-ish FName entries whose object's vtable is in .xtext
import sys, struct, ctypes as C
from ctypes import wintypes as W
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
print('use vtable', sys.argv[1:] )
