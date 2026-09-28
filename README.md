# Tsukimi Reader releases

Built copies of Tsukimi Reader, a manga reader for Linux, Windows and Android. This repository holds
the releases only; the source is not published.

Installed copies update themselves from here: a computer downloads a new version by itself and asks
to restart, and a phone asks before downloading it. To install by hand, open the
[latest release](https://github.com/nearestdev/tsukimi-releases/releases/latest) and take the file
for your system:

| System | File |
| --- | --- |
| Linux, x86-64 | `tsukimi-reader-linux-amd64`, then `chmod +x` it and run it |
| Windows, x86-64 | `tsukimi-reader-windows-amd64.exe` |
| Android, arm64 | `tsukimi-reader-android-arm64.apk` |

Each release also carries `manifest.json`, which lists every file with its SHA-256 and an ed25519
signature. The app installs an update only when that signature matches the key built into it.
