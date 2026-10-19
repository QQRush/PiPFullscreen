# PiPFullscreen

Experimental iOS 15 rootless PiP fullscreen tweak project for iPhone 7 Plus / iOS 15.8.4 / Dopamine.

**v0.1.0 is injection-only. It does NOT enable fullscreen PiP yet.** This first build validates Theos packaging and SpringBoard injection before private PiP layout changes.

## Goal
- Full-screen black background, whole PiP video visible with aspect ratio preserved (letterbox/pillarbox).
- No modifications to Hongguo.
- Reversible behavior, eventually via a gesture or configuration.
- Automatic episode progression unaffected.

## Build
GitHub Actions -> Build rootless DEB -> artifact ZIP containing .deb.

Do not install on a primary device before a backup. SpringBoard tweaks can cause respring loops; disable in Dopamine safe mode and remove from Sileo if necessary.
