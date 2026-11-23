# Finds live objects holding the excluded-extensions set: walks private memory for TSet shape at +0x60 with 5-ish FName entries whose object's vtable is in .xtext
import sys
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
print('use vtable', sys.argv[1:] )
