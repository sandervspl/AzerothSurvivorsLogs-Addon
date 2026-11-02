Fixed native damage capture failing to start even when the game provided it.
The recorder also waits longer for damage tracking to become ready when entering
a run. If tracking cannot start, it saves the failure details so the problem can
be diagnosed instead of silently using only the combat log.

Use `/azsrec native` to see the current or most recently recorded native capture
status. Startup checks use bounded retries and stop after thirty seconds.

Reload the UI or restart the game after installing. Reload the UI or exit
normally after a run to save its recording.
