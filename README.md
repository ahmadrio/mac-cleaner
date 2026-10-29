# Mac Cleaner

**Free, open-source disk cleaner for macOS — built with developers in mind.**
One interactive script, no install, no sudo, no dependencies. English & Bahasa Indonesia.

🇮🇩 [Baca dalam Bahasa Indonesia](#bahasa-indonesia)

- 🧹 **Clean caches** — npm, Yarn, pnpm, Bun, Composer, pip, Go, Homebrew, Gradle, Maven, Flutter, NuGet, Xcode, iOS Simulator, `~/Library/Caches`, logs, Trash
- 🐳 **Docker / OrbStack** — prune build cache & unused images, remove unused volumes, or a full OrbStack reset
- 📦 **Find rarely used & large apps** — sorted by size, with "last opened" from macOS, and move them to Trash
- 📊 **Find the largest folders & app data** in your home folder and `~/Library`, then reveal them in Finder

## Quick start

Run it straight from GitHub (nothing is installed):

```bash
# Try it first: shows what would be deleted, deletes nothing
bash <(curl -fsSL https://raw.githubusercontent.com/ahmadrio/mac-cleaner/main/mac-cleaner.command) --dry-run

# Run for real
bash <(curl -fsSL https://raw.githubusercontent.com/ahmadrio/mac-cleaner/main/mac-cleaner.command)
```

Or keep a copy you can double-click in Finder:

```bash
git clone https://github.com/ahmadrio/mac-cleaner.git
open mac-cleaner          # then double-click mac-cleaner.command
```

### Options

| Option | What it does |
| --- | --- |
| `--dry-run`, `-n` | Show what would be deleted without deleting anything |
| `--lang en` / `--lang id` | Force English or Bahasa Indonesia |
| `--help`, `-h` | Show help |

The language follows your macOS language by default. Switch it any time with **`l`** in the main menu — your choice is remembered (`~/.config/mac-cleaner/lang`). You can also set `MAC_CLEANER_LANG=en|id`.

## Example

```
  Mac Cleaner v1.1
  Disk: 41.3 GB free of 460.4 GB (91% used)

  1) Clean caches (dev tools, apps, logs, Trash)
  2) Docker: clean up / reset
  3) Find rarely used & largest apps
  4) Find the largest folders & app data
  l) Language: English (ganti ke Bahasa Indonesia)
  q) Quit

   No       Size  Item                                     Type
    1     4.2 GB  npm / npx cache                          safe
    2     1.1 GB  Homebrew (downloads & old versions)      safe
    3     8.7 GB  Xcode DerivedData                        safe
    4     3.4 GB  App caches (~/Library/Caches)            safe
    5     6.0 GB  Gradle caches & wrapper                  heavy
    6     2.3 GB  Maven repository (~/.m2)                 heavy
    7     1.9 GB  Trash                                    permanent

  Pick numbers (e.g. 1 3 5), a = all 'safe', s = 'safe' + 'heavy', Enter = cancel:
```

*(Example output — your items and sizes will differ.)*

## What gets cleaned

Every item shows its size first and only runs after you confirm. Items are labelled:

- **safe** — rebuilt automatically when needed
- **heavy** — re-downloaded on your next build (needs internet, first build is slower)
- **permanent** — cannot be undone (emptying the Trash)

| Item | Location / command | Type |
| --- | --- | --- |
| npm / npx | `~/.npm/_cacache`, `_npx`, `_logs` | safe |
| Yarn | `~/Library/Caches/Yarn`, `~/.yarn/berry/cache` | safe |
| pnpm | `pnpm store prune` (only unreferenced packages) | safe |
| Bun | `~/.bun/install/cache` | safe |
| Composer | `~/Library/Caches/composer`, `~/.composer/cache` | safe |
| pip | `~/Library/Caches/pip` | safe |
| Go build cache | `go env GOCACHE` | safe |
| Homebrew | `brew cleanup --prune=all -s` | safe |
| CocoaPods | `~/Library/Caches/CocoaPods` | safe |
| Xcode | `DerivedData`, `iOS/watchOS DeviceSupport` | safe |
| iOS Simulator | `xcrun simctl delete unavailable` + simulator caches | safe |
| App caches | `~/Library/Caches/*` (Apple system caches are skipped) | safe |
| App logs | `~/Library/Logs` | safe |
| Gradle | `~/.gradle/caches`, `~/.gradle/wrapper/dists` | heavy |
| Maven | `~/.m2/repository` | heavy |
| Go modules | `go clean -modcache` | heavy |
| Dart / Flutter | `~/.pub-cache/hosted`, `~/.pub-cache/git` | heavy |
| NuGet | `~/.nuget/packages` | heavy |
| `~/.cache` | Playwright browsers, Puppeteer, other CLI caches | heavy |
| Trash | Empties the Trash via Finder | permanent |

### Docker (OrbStack or Docker Desktop)

1. **Safe cleanup** — stopped containers (listed first), unused networks, dangling images, build cache. Volumes are not touched.
2. **All unused images** — `docker image prune -a`.
3. **Unused volumes** — listed first; you must type `DELETE` (`HAPUS` in Indonesian). ⚠️ This includes database volumes of projects you stopped with `docker compose down`.
4. **Full OrbStack reset** — `orb reset`; you must type `RESET`. For Docker Desktop, the menu points you to *Troubleshoot › Clean / Purge data*.

OrbStack returns freed disk space to macOS automatically.

## Safety

- No `sudo`. The script itself only deletes inside your home folder, and only the **contents** of known cache folders. Anything else is done by each tool's own cleanup command (`brew cleanup`, `docker … prune`, `orb reset`, `xcrun simctl`).
- Never touched: Desktop, Documents, Downloads, Pictures, Music, Movies, your projects, `~/.ssh`, Keychains, Preferences.
- Apps are **moved to Trash** (recoverable), never deleted directly. Running apps are skipped.
- Use `--dry-run` first to see exactly what would happen.

## Requirements

- macOS (Apple Silicon or Intel). Uses the built-in `/bin/bash` 3.2 — nothing to install.
- Tools such as `brew`, `pnpm`, `go`, `docker`, `orb` and `xcrun` are detected automatically; missing ones are simply skipped.

## FAQ

**Free space didn't go up right away.** macOS may hold deleted space in APFS local snapshots for a while. Check again after a few minutes.

**An app shows "never recorded".** macOS has no record of it being opened — it was never opened, or only launched from the command line.

**Menu 4 doesn't count `~/Library/Containers`.** Those folders need *Full Disk Access*. Give it to Terminal in *System Settings › Privacy & Security › Full Disk Access* if you want them included. Without it, Mac Cleaner skips them so you don't get a flood of permission pop-ups.

**macOS blocks double-clicking the file.** If you downloaded it with a browser, run `xattr -d com.apple.quarantine mac-cleaner.command` and `chmod +x mac-cleaner.command` once. Files from `git clone` or `curl` don't have this problem.

## Contributing

Issues and pull requests are welcome — especially new cache locations, translations, and bug reports with the output of `--dry-run`. Please keep it a single dependency-free script that runs on macOS's bash 3.2.

## License

[MIT](LICENSE) © Ahmad Rio. Provided as is, without warranty — review what you delete.

---

## Bahasa Indonesia

**Aplikasi pembersih disk gratis & open source untuk macOS — dibuat dengan kebutuhan developer.**
Satu script interaktif, tanpa instalasi, tanpa sudo, tanpa dependency. Tersedia dalam Bahasa Indonesia & English.

- 🧹 **Bersihkan cache** — npm, Yarn, pnpm, Bun, Composer, pip, Go, Homebrew, Gradle, Maven, Flutter, NuGet, Xcode, Simulator iOS, `~/Library/Caches`, log, Trash
- 🐳 **Docker / OrbStack** — hapus build cache & image tak terpakai, hapus volume tak terpakai, atau reset total OrbStack
- 📦 **Cari aplikasi jarang dipakai & paling besar** — urut dari yang terbesar, lengkap dengan "terakhir dibuka", lalu pindahkan ke Trash
- 📊 **Cari folder & data aplikasi terbesar** di folder home dan `~/Library`, lalu tampilkan di Finder

### Cara pakai

Jalankan langsung dari GitHub (tidak ada yang diinstal):

```bash
# Coba dulu: tampilkan apa yang akan dihapus, tanpa menghapus apa pun
bash <(curl -fsSL https://raw.githubusercontent.com/ahmadrio/mac-cleaner/main/mac-cleaner.command) --dry-run --lang id

# Jalankan sungguhan
bash <(curl -fsSL https://raw.githubusercontent.com/ahmadrio/mac-cleaner/main/mac-cleaner.command) --lang id
```

Atau simpan supaya bisa di-double-click dari Finder:

```bash
git clone https://github.com/ahmadrio/mac-cleaner.git
open mac-cleaner          # lalu double-click mac-cleaner.command
```

**Bahasa:** otomatis mengikuti bahasa macOS. Ganti kapan saja dengan menekan **`l`** di menu utama — pilihan Anda disimpan. Bisa juga pakai `--lang id` / `--lang en`.

### Yang dibersihkan

Setiap item ditampilkan ukurannya dulu dan baru dijalankan setelah Anda konfirmasi. Labelnya:

- **aman** — dibuat ulang otomatis saat dibutuhkan
- **berat** — di-download ulang saat build berikutnya (perlu internet, build pertama lebih lama)
- **permanen** — tidak bisa dikembalikan (mengosongkan Trash)

Daftar lengkap lokasi ada di tabel [What gets cleaned](#what-gets-cleaned) di atas.

**Docker:** (1) bersihkan aman — container berhenti, network & image dangling, build cache, volume tidak disentuh; (2) hapus semua image tak terpakai; (3) hapus volume tak terpakai — wajib ketik `HAPUS`, ⚠️ termasuk volume database proyek yang sudah `docker compose down`; (4) reset total OrbStack — wajib ketik `RESET`.

### Keamanan

- Tanpa `sudo`. Script ini hanya menghapus di dalam folder home, dan hanya **isi** folder cache yang dikenal. Selebihnya dikerjakan perintah pembersih bawaan tiap tool (`brew cleanup`, `docker … prune`, `orb reset`, `xcrun simctl`).
- Tidak pernah disentuh: Desktop, Documents, Downloads, Pictures, Music, Movies, proyek Anda, `~/.ssh`, Keychain, Preferences.
- Aplikasi hanya **dipindah ke Trash** (bisa dikembalikan). Aplikasi yang sedang berjalan dilewati.
- Pakai `--dry-run` dulu untuk melihat persis apa yang akan terjadi.

### Pertanyaan umum

- **Ruang kosong tidak langsung bertambah?** macOS kadang menahan ruang di snapshot APFS. Cek lagi beberapa menit kemudian.
- **Aplikasi "tidak tercatat"?** macOS tidak punya catatan kapan aplikasi itu dibuka (belum pernah dibuka, atau hanya lewat CLI).
- **Menu 4 tidak menghitung `~/Library/Containers`?** Folder itu butuh *Full Disk Access*. Aktifkan untuk Terminal di *System Settings › Privacy & Security › Full Disk Access*.
- **File tidak bisa di-double-click?** Kalau di-download lewat browser, jalankan sekali: `xattr -d com.apple.quarantine mac-cleaner.command` dan `chmod +x mac-cleaner.command`.

### Kontribusi

Issue dan pull request sangat diterima — terutama lokasi cache baru, terjemahan, dan laporan bug (sertakan output `--dry-run`).

### Lisensi

[MIT](LICENSE) © Ahmad Rio. Gratis untuk dipakai, diubah, dan dibagikan. Disediakan apa adanya — periksa dulu apa yang Anda hapus.
