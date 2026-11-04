# Changelog

## [0.5.2](https://github.com/lucianodiisouza/voulum/compare/v0.5.1...v0.5.2) (2026-11-04)


### Bug Fixes

* **scripts:** re-sign dev builds so they launch with Sparkle ([9f8d7e3](https://github.com/lucianodiisouza/voulum/commit/9f8d7e37dbe61e0a8b9eb6985c982d1f74adb54e))
* start the mic meter off the HAL queue ([05c2868](https://github.com/lucianodiisouza/voulum/commit/05c28680170b0ad58133f53c07a6be62d68dc9f6))
* stop popup animations while the popup is closed ([dc03926](https://github.com/lucianodiisouza/voulum/commit/dc03926355d9facdee4593080276ada880b91418))


### Performance Improvements

* breathe the level ring with Core Animation ([4fdb070](https://github.com/lucianodiisouza/voulum/commit/4fdb070afca9bc18f1f1bcda953ac2df91eee726))
* compile now-playing AppleScripts once ([1e87626](https://github.com/lucianodiisouza/voulum/commit/1e8762670d14e53169bd3251608e4fb340341110))
* draw LED meters in one Canvas ([a297a9f](https://github.com/lucianodiisouza/voulum/commit/a297a9f9fa682cf6d071d12fe7ac65a5a1c7a921))
* stop the marquee and the breathing ring ([f1dd0f6](https://github.com/lucianodiisouza/voulum/commit/f1dd0f6d9948a035e2a65d0cd3dd33b386742e0b))

## [0.5.1](https://github.com/lucianodiisouza/voulum/compare/v0.5.0...v0.5.1) (2026-11-04)


### Bug Fixes

* open the DMG in a designed installer window ([#21](https://github.com/lucianodiisouza/voulum/issues/21)) ([62db6f1](https://github.com/lucianodiisouza/voulum/commit/62db6f1ce05698118a6f68025cd3235bd77cc5de))

## [0.5.0](https://github.com/lucianodiisouza/voulum/compare/v0.4.1...v0.5.0) (2026-11-04)


### Features

* Mixing Desk popup style with live meters ([#17](https://github.com/lucianodiisouza/voulum/issues/17)) ([6c09f5f](https://github.com/lucianodiisouza/voulum/commit/6c09f5fc92bc2c7775d48d39cc4a625450de9f17))
* updates in the popup, more Primo apps, dev.oprimo.voulum ([#16](https://github.com/lucianodiisouza/voulum/issues/16)) ([a31b677](https://github.com/lucianodiisouza/voulum/commit/a31b67735444b12b18eefa4b2d1f7b9dca8c5981))

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
