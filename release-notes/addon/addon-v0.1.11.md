# Recorder 0.1.11

- Records the game's damage and healing meters, including published item, proc,
  regeneration and leech amounts that may be absent from the combat log.
- Keeps the latest meter counters when the sampled meter history reaches its
  recording limit. Meter counters do not include individual hit details.
- Adds `/azsrec probe` to collect a small sample of combat callbacks for two
  minutes during a run, helping investigate effects missing from combat logs.

Install the updated recorder before recording a new run. Reload the UI or exit
normally before uploading so the game saves your recording. Older recordings
cannot recover meter amounts that were never captured.
