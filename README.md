# Fever

Windows x64 test build of Hivemind. The playable build is distributed through [GitHub Releases](https://github.com/DrewParmelee/Fever/releases); this repository contains its download helper and verification manifest.

On the target Windows computer, install Git, open PowerShell, and run:

```powershell
git clone https://github.com/DrewParmelee/Fever.git
cd Fever
powershell -ExecutionPolicy Bypass -File .\Get-Build.ps1
.\Build\Hivemind.exe
```

The helper requires Windows PowerShell 5.1 or later and Windows `tar.exe`. It downloads the public release without signing in, verifies each archive part, extracts the build, and verifies every runtime file. Keep the whole `Build` folder together.

The download is approximately 4.1 GiB across three archive parts; the extracted runtime build is approximately 8.9 GiB. Have at least 16 GiB free for a fresh install. Updates need this free space in addition to the space occupied by the current `Build`, which is retained as a backup. The helper removes its temporary download directory when finished.

To update, close the game and run:

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\Get-Build.ps1
.\Build\Hivemind.exe
```

A matching installed build is verified and reused. A differing build is replaced only after the new build passes verification; the previous folder is preserved as `Build.backup-*`. You can remove an old backup after confirming the new build works.

`build-manifest.json` pins the release, archive part hashes, and runtime file hashes. Release `v2026.10.08` contains `Fever-Windows-x64.tar.gz.part001` and subsequent numbered parts. Unity backup and debug output is excluded. The runtime binaries remain in release assets, so cloning does not require Git LFS.
