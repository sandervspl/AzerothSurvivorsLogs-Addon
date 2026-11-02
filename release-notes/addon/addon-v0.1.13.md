The recorder can now capture individual outgoing hits on game versions that provide combat-text events. Reports can credit procs, pets and summons to the source shown in the game's damage meter, even when the floating spell name differs.

Native damage capture now starts correctly when the game provides it, with bounded retries while entering a run. Use `/azsrec native` to see the current or most recent capture status.

Reports warn when capture starts late, the game drops events or recording reaches a limit. Older game versions continue to use combat logs. Healing capture is unchanged. Existing recordings cannot gain source information that was never captured.

Reload the UI or restart the game after installing. Reload the UI or exit normally after a run to save its recording.
