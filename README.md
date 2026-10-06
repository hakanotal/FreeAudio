# FreeAudio

> **Free & open-source alternative to [SoundSource](https://rogueamoeba.com/soundsource/)** (work in progress)

A macOS menu bar app for per-app audio control: a volume slider and mute for every app that plays sound, output device control, and software volume for outputs that macOS can't control (HDMI/DisplayPort monitors). Turkish and English UI.

FreeAudio is the sibling of [FreeDisplay](https://github.com/hakanotal/FreeDisplay) and shares its foundation and visual style.

> maintained by [@hakanotal](https://github.com/hakanotal)

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/hakantotal)

---

## Status

Early development; there is no release yet. The plan, technical approach and style guide are in [docs/FREEAUDIO_BRIEF.md](docs/FREEAUDIO_BRIEF.md).

Planned for the first release:

- Per-app volume (with boost) and mute
- Output device switching with volume and mute
- Software volume and volume keys for HDMI/DisplayPort outputs
- Launch at login, Turkish/English UI, update check

Requires macOS 14.2 or later (Core Audio process taps).

## Build from source

```bash
git clone https://github.com/hakanotal/FreeAudio.git
cd FreeAudio
./scripts/build-dmg.sh   # → build/FreeAudio.app and build/FreeAudio-<version>.dmg
```

Xcode is optional: without it the script builds with the Command Line Tools (`xcode-select --install`).

## License

MIT License — see [LICENSE](LICENSE) for details.
