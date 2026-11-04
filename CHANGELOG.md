# Changelog

## [0.4.1](https://github.com/lucianodiisouza/voulum/compare/v0.4.0...v0.4.1) (2026-11-04)

Released by hand from a local, notarized build (PR #13).

### Features

* per-app output routing, including several outputs at once, with fallback when a device disconnects
* 10-band EQ per app with built-in and saved presets
* global shortcuts, full keyboard control in the popup and a `voulum://` URL scheme
* tab titles for audio playing in Safari, Chrome, Arc, Opera and Flecha
* new popup without an arrow, in Frosted or Liquid Glass; redesigned Settings with search
* welcome tour, new app icon, Brazilian Portuguese and Spanish
* Developer ID signed and notarized, with Sparkle auto-updates

## [0.4.0](https://github.com/lucianodiisouza/voulum/compare/v0.3.1...v0.4.0) (2026-07-29)


### Features

* now-playing metadata and media controls for Spotify & Apple Music ([d841bf1](https://github.com/lucianodiisouza/voulum/commit/d841bf1233753165c9a45bf7a79459019dec8489))
* scroll overflowing track text instead of truncating ([b986a29](https://github.com/lucianodiisouza/voulum/commit/b986a29eae95084422f2b98b52e19382e0b2e8a2))
* support VLC now-playing and transport ([8bd1415](https://github.com/lucianodiisouza/voulum/commit/8bd1415595bd41d78e5e530fe96e124b659b992a))


### Bug Fixes

* contain MarqueeText so it can't widen the menu window ([a3af1b1](https://github.com/lucianodiisouza/voulum/commit/a3af1b18d639491b5c8ce22ffdc889a1823d2fbb))

## [0.3.1](https://github.com/lucianodiisouza/voulum/compare/v0.3.0...v0.3.1) (2026-07-29)


### Bug Fixes

* keep the volume slider usable while muted ([f3d33d5](https://github.com/lucianodiisouza/voulum/commit/f3d33d5c48d22cdf45e2a8bf378d1e0c8e79bce3))

## [0.3.0](https://github.com/lucianodiisouza/voulum/compare/v0.2.1...v0.3.0) (2026-07-29)


### Features

* add scripts for cleaning and running Voulum application ([cf601f6](https://github.com/lucianodiisouza/voulum/commit/cf601f61a788c4ffe6f82c2e9335e7f39d211f8a))


### Bug Fixes

* exclude Voulum's own process from the audio list ([fb2daec](https://github.com/lucianodiisouza/voulum/commit/fb2daecabc7e8b42711095c3c2761aa10dec4b10))
* run Core Audio HAL calls off the main thread to prevent hangs ([ff53b25](https://github.com/lucianodiisouza/voulum/commit/ff53b25d4e5b4ba4d09da82e0a41fecfce069f88))
* tap only the selected app, not every other app ([4d472c2](https://github.com/lucianodiisouza/voulum/commit/4d472c29fa2bfc1aa5c8e3e9a235c4d7c230f537))

## [0.2.1](https://github.com/lucianodiisouza/voulum/compare/v0.2.0...v0.2.1) (2026-07-27)


### Bug Fixes

* attach a downloadable .dmg to each release ([22f9bfa](https://github.com/lucianodiisouza/voulum/commit/22f9bfabf35fdece9cce5707ad5d6acfe6bd1751))

## [0.2.0](https://github.com/lucianodiisouza/voulum/compare/v0.1.0...v0.2.0) (2026-07-27)


### Features

* add launch-at-login via SMAppService ([b778548](https://github.com/lucianodiisouza/voulum/commit/b778548bda960180905348eced1241ed3d813dfa))
* add per-app volume engine using Core Audio process taps ([6f80a51](https://github.com/lucianodiisouza/voulum/commit/6f80a518f26764b8647069d24d71e6464f330b6c))
* add typed Core Audio property helpers ([d295041](https://github.com/lucianodiisouza/voulum/commit/d2950411486a37e2334907d54dabe5001fa667e2))
* build the menu-bar UI with volume, mute and focus ([a3039c9](https://github.com/lucianodiisouza/voulum/commit/a3039c982e051f871f4aecb90508cbcb7105c328))
* detect playing apps and orchestrate taps with poll-on-open ([21c9432](https://github.com/lucianodiisouza/voulum/commit/21c9432d153043ab0646532be153f8d9699332f8))
* model audio processes and resolve the owning app ([6ca0d9d](https://github.com/lucianodiisouza/voulum/commit/6ca0d9d36798cbac537e797cd930b204647e3b24))
