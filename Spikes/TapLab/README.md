# TapLab

Throwaway probe app for the spikes in [docs/ROADMAP.md](../../docs/ROADMAP.md). It is not part of the FreeAudio build. Everything it logs goes to the window and to `~/Library/Logs/TapLab/taplab.log`; write the conclusions into `docs/LESSONS.md` (Audio section).

```bash
./Spikes/TapLab/build.sh          # → build/TapLab.app
open -n build/TapLab.app          # launch with `open`, so TapLab (not the terminal) owns the permission
open -n build/TapLab.app --args --auto   # read-only probes only (devices, TCC status, process list), then quit
```

Quit FineTune, SoundSource or any other tap-based app first; taps from two processes on the same device interfere.

## Spikes

**S1, basic engine.** Play something in Music (or set "Target bundle ID" to another app). Pick the output, press *S1 app tap → output*. The first run should show the System Audio Recording prompt.
- Log to check: tap UID matches the description, aggregate alive time (target < 500 ms), `AudioDeviceStart` time (< 100 ms), callbacks/s, peak in > 0.
- Ear check: Music gets quieter at Gain 0.1 / 0.3 and back to normal at 1.0, without clicks.
- Pause Music before pressing S1 to measure `AudioDeviceStart` with a silent app.
- Deny the permission once (System Settings → Privacy & Security → Screen & System Audio Recording) and record what happens: does S1 fail, or run with peak in = 0 while Music goes silent?

**S2, device-scoped rest tap.** Make the Dell the output in the popup, play Music to the Dell, and play something to the built-in speakers at the same time (e.g. `afplay /System/Library/Sounds/Submarine.aiff` after choosing the speakers as that app's output, or a browser tab routed there). Press *S2 rest tap on output*.
- Only audio going to the Dell should follow the gain; the speakers stay unchanged; no howl or feedback at Gain 1.0.
- Switch the system default output away from the Dell while S2 runs: the log should keep running without errors.

**S6, muted tap without an aggregate.** Play Music, press *S6 muted tap only*.
- Music should go silent and stay silent while you switch the default output.
- *Stop all* should bring it back. Run S6 again and `kill -9` TapLab: Music must come back.

**S9, native OSD.** Press *S9 OSD 50%* and *S9 mute OSD*: does the macOS volume OSD appear?

**S8, grouping (Phase 1).** Play audio in Safari, Chrome, an Electron app (Slack/Discord/VS Code/Cursor), Spotify and Zoom, then press *List processes*. For each audio process, note which column (responsible, enclosing .app, own app) names the right app.
