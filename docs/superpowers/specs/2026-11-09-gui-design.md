# Mac Cleaner: versi GUI (aplikasi Mac SwiftUI)

## Context

Mac Cleaner sekarang adalah satu script bash interaktif (`mac-cleaner.command`, v1.5.1, ±1.640 baris, harus jalan di `/bin/bash` 3.2) dengan menu teks 1–7: cache, Docker, aplikasi jarang dipakai, uninstall, folder terbesar, update aplikasi, RAM. Pemilik ingin versi GUI supaya **orang awam (bukan developer)**, yang tidak nyaman membuka Terminal, juga bisa memakainya.

Keputusan pemilik:
- Bentuk GUI: **aplikasi Mac native (SwiftUI)**, berupa `Mac Cleaner.app` dengan sidebar, daftar centang, dan tombol.
- **CLI tetap dipertahankan**: menu teks, opsi `--dry-run`/`--lang`, dan curl one-liner di README tetap berfungsi persis seperti sekarang.
- **Ketujuh fitur masuk di rilis GUI pertama.**
- **Belum ada akun Apple Developer**: aplikasi hanya ditandatangani ad-hoc. README menjelaskan cara membukanya pertama kali.
- **Hanya Apple Silicon (arm64) dulu.** Pengguna Mac Intel tetap memakai CLI. Dukungan Intel bisa ditambahkan nanti lewat CI.

Hasil yang diharapkan: `Mac Cleaner.app` yang bisa di-download dari GitHub Releases, berisi 7 fitur dalam Bahasa Indonesia dan Inggris, dengan aturan keamanan yang sama seperti CLI: semua ditampilkan dulu, perlu konfirmasi, aplikasi beserta sisa filenya masuk Trash, dan ada mode coba (dry-run).

Lingkungan build: Mac ini hanya punya Command Line Tools (tanpa Xcode). Tersedia Swift 6.4.2, SwiftPM, SDK berisi SwiftUI/AppKit, `Testing.framework` (tanpa XCTest), `codesign`, `iconutil`, `sips`, dan `ditto`. Library back-deploy Swift di CLT hanya ada untuk arm64, karena itu build x86_64 tidak bisa dilakukan di sini.

## Pendekatan

**Script bash tetap jadi satu-satunya mesin.** Aplikasi SwiftUI tidak menulis ulang logika pembersihan. Script mendapat mode baru yang tidak interaktif, `--engine <perintah>`, yang mengeluarkan baris data terstruktur. Aplikasi menjalankan salinan script yang dibundel di dalam `.app` dan menampilkan hasilnya. Logika yang sudah teruji hanya ada di satu tempat, dan perbaikan di script otomatis berlaku untuk CLI dan GUI.

Struktur repo baru:

```
mac-cleaner.command          # mesin + CLI (diubah)
app/
  Package.swift              # SwiftPM, macOS 13+, arm64; target: MacCleanerCore (lib) + MacCleaner (exe) + tes
  Sources/MacCleanerCore/    # EngineRunner, parser protokol, model data (bisa dites tanpa UI)
  Sources/MacCleaner/        # SwiftUI: App, sidebar, 7 layar, sheet konfirmasi, log
  Tests/MacCleanerCoreTests/ # Swift Testing (import Testing), bukan XCTest
  Resources/                 # Info.plist template, AppIcon, askpass.sh, fixture demo
  build.sh                   # build → rakit "Mac Cleaner.app" → codesign ad-hoc → zip
tests/
  engine_test.sh             # tes mode engine dengan HOME palsu
docs/superpowers/specs/2026-11-09-gui-design.md   # salinan rancangan ini
```

### 1. Mode engine di `mac-cleaner.command`

**Pemanggilan:** `/bin/bash mac-cleaner.command --engine <perintah> [argumen…] [--lang en|id] [--dry-run]`. Parser argumen (L52–62) menerima `--engine` dan menyimpan sisa argumen. Kalau `ENGINE` di-set, `main` tidak dijalankan. Yang dijalankan adalah `engine_dispatch`, lalu proses keluar dengan kode status perintah tersebut.

**Protokol keluaran (stdout, satu record per baris):** baris protokol diawali `@@` dan dipisah TAB. Baris lain (keluaran mentah `brew`, `docker`, dan sebagainya) diperlakukan GUI sebagai log biasa. stderr ditangkap GUI sebagai log peringatan.

| Record | Isi |
|---|---|
| `@@progress\t<teks>[\t<i>\t<total>]` | status pemindaian/proses |
| `@@log\t<info\|ok\|warn\|err\|say>\t<teks>` | pengganti `info/ok/warn/err/say` saat mode engine |
| `@@meta\t<kunci>\t<nilai>` | info tambahan (total, fda=0/1, status docker, ringkasan RAM, dll.) |
| `@@row\t<jenis>\t<kolom…>` | satu baris data; kolom per jenis ada di tabel perintah |
| `@@freed\t<kb>` / `@@disk\t<total_kb>\t<free_kb>` | hasil akhir |
| `@@error\t<kode>\t<teks>` | kegagalan yang perlu ditampilkan GUI (mis. `interactive`, `running`, `finder_denied`) |

**Pagar pengaman:**
- Dalam mode engine, `say/info/ok/warn/err` ditulis ulang agar mengeluarkan `@@log`, `progress` mengeluarkan `@@progress`, dan warna dikosongkan.
- `ask/confirm/confirm_word/pause` **tidak boleh pernah terpanggil**. Kalau terpanggil, fungsi itu mengeluarkan `@@error\tinteractive\t…` dan mengembalikan 1 (sama dengan batal), jadi tidak ada aksi yang jalan tanpa konfirmasi GUI.
- Mesin dijalankan dengan stdin dari `/dev/null`.

**Tanpa pindai ulang saat aksi.** Setiap perintah adalah proses baru, jadi aksi menerima **persis apa yang dikonfirmasi pengguna** lewat file daftar (`--list <file>`, satu item per baris, ditulis GUI ke folder sementara). Aksi tidak memindai ulang, karena hasilnya bisa berbeda dari yang sudah ditunjukkan. Mesin tetap memeriksa ulang setiap path dengan `safe_path` dan memastikan path itu masih ada.

**Pola refactor:** setiap menu dipecah menjadi fungsi *pindai* (mengisi array/mengeluarkan baris) dan fungsi *jalankan* (menerima ID/path). Menu CLI tetap memanggil pindai → menampilkan tabel → `ask` → jalankan, dengan keluaran yang sama seperti sekarang. Mode engine memanggil pindai/jalankan secara langsung. Fungsi yang dipakai ulang apa adanya:
- cache & penghapusan: `cache_def`, `cache_size`, `cache_clean`, `report_freed`, `safe_path`, `rm_contents`, `move_to_trash`;
- aplikasi & uninstall: `app_bundle_id`, `load_app_ids`, `find_leftovers`, `list_apps`, `last_used_epoch`;
- RAM: `mem_stats`, `mem_by_app`, `host_app`;
- update: `brew_outdated`, `cask_info_lines`, `cask_catalog`, `catalog_lines`, `catalog_match`, `sparkle_fetch`, `mas_outdated`, `replace_with_cask`;
- Docker: semua `dk_*` (setelah dipecah).

**Perubahan kecil di logika bersama:**
- `list_apps` mengecualikan Mac Cleaner sendiri (bundle id `io.github.ahmadrio.mac-cleaner`), supaya aplikasi ini tidak muncul di layar Aplikasi, Uninstall, dan Update.
- Di mode engine, kalau Finder menolak perintah (izin Automation ditolak, error -1743), `move_to_trash` mengeluarkan `@@error finder_denied` dan **tidak** memindahkan apa pun. GUI lalu menampilkan cara memberi izin. Mengosongkan Trash di layar Cache juga mengikuti aturan ini.

**Perintah engine:**

| Fitur | Perintah | Keluaran / perilaku |
|---|---|---|
| Umum | `disk`, `env` | `@@disk`; `@@meta` has_brew/has_docker/has_orb/has_mas/has_fda/version |
| Umum | `set-lang id\|en` | `save_lang` (berbagi file `~/.config/mac-cleaner/lang` dengan CLI) |
| Cache | `caches-scan` | `row cache id kb kind label`; meta total_safe/total_heavy. Ambang sama dengan CLI (sembunyikan <1 MB, Trash -1 = "?") |
| Cache | `caches-clean <id…>` | `cache_clean` per id → `@@freed` lewat `report_freed` |
| Docker | `docker-status` | meta state = `missing` / `stopped_orb` / `stopped_desktop` / `stopped_other` (mis. Colima, cukup diberi tahu) / `running`; `row df type total active size reclaimable` |
| Docker | `docker-start` | `orb start` atau `open -a Docker`, lalu menunggu `docker info` (batas waktu 60 dtk) |
| Docker | `docker-list containers\|images\|volumes` | baris per item dengan kolom yang sama seperti tabel CLI + flag in_use |
| Docker | `docker-rm containers\|images\|volumes --list <file>` | item yang sedang dipakai dilewati seperti di CLI |
| Docker | `docker-prune build-all\|build-old\|networks\|safe\|all-unused\|wipe\|orb-reset` | aksi opsi 4–9 |
| Aplikasi | `apps-scan <hari>` | `row app kb days rare name path` (rare + 10 terbesar), progress i/total |
| Uninstall | `apps-list` | `row app name path` |
| Uninstall | `uninstall-plan <path>` | meta bundle_id/app_kb/dup/vendor_hint; `row leftover kb path`; `row admin path` |
| Uninstall | `uninstall <app-path> --list <file>` | app + sisa file yang dikonfirmasi (file kosong = app saja) ke Trash lewat `move_to_trash`; `@@error running` kalau app masih jalan |
| Folder | `bigdata-scan` | meta fda; `row dir kb path` (25 teratas) |
| Update | `updates-scan` | `row update key kind name installed latest via ref app homepage`; meta pinned/auto_skip/mas_n/has_mas/offline |
| Update | `updates-apply --list <file>` | file berisi baris update lengkap yang dipilih (tanpa pindai ulang). Isinya: upgrade brew per batch, `replace_with_cask` (app yang jalan sudah ditutup GUI sebelumnya), `open` halaman/app untuk dmg-tanpa-brew & sparkle, `mas upgrade` |
| RAM | `ram-scan` | meta total/app/wired/comp/cached/used/swap/level; `row app kb path name note host`; `row proc kb path note` |
| RAM | `ram-purge` | `osascript … do shell script "/usr/sbin/purge" with administrator privileges` (dialog password macOS); CLI tetap memakai `sudo purge` |

**Menutup aplikasi dilakukan GUI secara native.** RAM, uninstall, dan update yang butuh app tertutup memakai `NSRunningApplication.terminate()`. GUI lalu memantau sampai app benar-benar tertutup (batas 15 dtk, sama dengan `quit_app`). Cara ini menghindari prompt izin "kendalikan <App>" untuk setiap aplikasi. CLI tetap memakai `quit_app`.

**Password untuk Homebrew:** pada mode engine, `SUDO_ASKPASS` diarahkan ke `askpass.sh` yang dibundel (memakai `osascript display dialog … with hidden answer`). Reviewer sudah memastikan `bin/brew` meneruskan `SUDO_ASKPASS` dan `system_command.rb` memakai `sudo -A`, jadi cask yang butuh sudo memunculkan dialog password Mac.

### 2. Aplikasi SwiftUI (`app/`)

**Inti (`MacCleanerCore`):**
- `EngineRunner`: menjalankan `/bin/bash <Resources>/mac-cleaner.command --engine … --lang … [--dry-run]` lewat `posix_spawn` dengan `POSIX_SPAWN_SETPGROUP`, supaya mesin punya process group sendiri. Ciri lainnya:
  - stdin `/dev/null`, dengan stdout/stderr dibaca per baris secara async (`AsyncStream<EngineEvent>`);
  - mengembalikan kode keluar;
  - Batal mengirim SIGTERM ke **seluruh group** (`kill(-pgid, SIGTERM)`), sehingga `du`/`brew`/`docker`/`curl` ikut berhenti.
- **Batal hanya tersedia saat memindai.** Selama aksi (hapus, uninstall, update, Docker), tombol Batal tidak ditampilkan. Membatalkan di tengah `replace_with_cask` bisa meninggalkan pengguna tanpa aplikasi sama sekali.
- `ProtocolParser`: baris → `EngineEvent` (`progress`, `log`, `meta`, `row`, `freed`, `disk`, `error`, `plain`). Baris tanpa awalan `@@` menjadi `plain`.
- Model per fitur yang dibangun dari `row`/`meta` (CacheItem, DockerItem, AppItem, Leftover, UpdateItem, MemApp, DirItem).
- **Mode demo tersembunyi** (`MAC_CLEANER_DEMO=1`): parser membaca fixture teks protokol dari `Resources/demo/` alih-alih menjalankan mesin. Mode ini dipakai untuk screenshot README dengan data demo, mengikuti kebiasaan screenshot CLI sekarang, dan untuk tes parser. Tidak terlihat di UI.

**Tampilan (`MacCleaner`):**
- `NavigationSplitView`: sidebar berisi 7 fitur. Di bawah sidebar ada bar ruang disk (`@@disk`). Docker menampilkan keadaan kosong yang menjelaskan alasannya kalau `docker` tidak ada. Update menampilkan catatan kalau Homebrew tidak ada.
- Toolbar: tombol bahasa ID/EN (ditulis ke file bahasa yang sama dengan CLI) dan saklar **Mode coba** (dry-run) dengan spanduk kuning saat aktif.
- Pola tiap layar: tombol **Pindai** → progress (teks + bar i/total) → `Table` dengan centang, ukuran, dan label jenis berwarna (aman/berat/permanen) → tombol aksi utama yang menampilkan total ukuran → **sheet konfirmasi** berisi daftar item → panel **log** yang mengalir selama proses → hasil ("Ruang kosong bertambah X").
- Konfirmasi setara CLI:
  - Aksi biasa memakai tombol konfirmasi.
  - Aksi yang di CLI memakai kata ketik tetap mewajibkan mengetik kata itu di field teks: `DELETE`/`HAPUS` untuk volume dan "semua yang tak terpakai", `RESET` untuk wipe/orb reset.
  - Hapus image "dangling", yang di CLI tanpa konfirmasi, diberi konfirmasi di GUI.
- Fitur khusus:
  - Cache: tombol cepat "Pilih semua yang aman" dan "aman + berat", plus peringatan untuk menutup IDE/browser dulu.
  - Aplikasi: field hari (default 90), dan tombol "Uninstall…" yang membuka sheet uninstall yang sama.
  - Uninstall: kolom pencarian, lalu sheet rencana berisi app, sisa file yang bisa dicentang, dan daftar admin (hanya ditampilkan). Kalau app sedang jalan, GUI menawarkan untuk menutupnya dulu.
  - Folder: tombol "Tampilkan di Finder" (`NSWorkspace.activateFileViewerSelecting`).
  - Update: tombol "Buka App Store" (`macappstore://showUpdatesPage`). App DMG yang sedang jalan ditawarkan untuk ditutup sebelum diganti.
  - RAM: ringkasan tekanan memori (warna sesuai level), daftar app dengan centang untuk "Tutup", dan tombol "Kosongkan cache file (purge)". `Mac Cleaner.app` sendiri muncul tanpa centang.
- Teks UI ID/EN memakai helper `L(id, en)` di Swift, meniru gaya script, tanpa file `.strings`. Label dari mesin sudah dilokalkan oleh script lewat `--lang`.

**Izin macOS (penting untuk orang awam).** Setiap izin mendapat callout di layar yang membutuhkannya, dengan tombol yang langsung membuka panel Pengaturan Sistem yang tepat:

| Izin | Dipakai untuk | Kapan ditampilkan |
|---|---|---|
| Automation → Finder | memindahkan ke Trash, mengosongkan Trash | saat `@@error finder_denied`. Info.plist **wajib** berisi `NSAppleEventsUsageDescription`; tanpa itu izin gagal diam-diam |
| Full Disk Access | `Containers`/`Group Containers` di Folder, ukuran Trash | layar Folder saat meta fda=0 (`Privacy_AllFiles`) |
| App Management | `brew upgrade/install --cask` mengganti app di /Applications | layar Update, sebelum menerapkan update cask/DMG (`Privacy_AppBundles`) |

Karena tanda tangan ad-hoc berubah tiap build, izin-izin ini mungkin perlu diberikan ulang setelah update aplikasi. Hal ini dijelaskan di README dan di callout.

**Bundle & distribusi (`app/build.sh`):**
- Membaca `VERSION` dari script (satu sumber versi), yang dinaikkan ke **2.0.0** karena ada GUI.
- Menjalankan `swift build -c release --arch arm64`, lalu merakit `build/Mac Cleaner.app`:
  - `Contents/MacOS/MacCleaner`;
  - `Contents/Resources/{mac-cleaner.command, askpass.sh, AppIcon.icns, demo/}`;
  - `Info.plist` berisi bundle id `io.github.ahmadrio.mac-cleaner`, versi, `LSMinimumSystemVersion` 13.0, `LSArchitecturePriority` arm64, dan `NSAppleEventsUsageDescription`.
- `codesign --force --deep -s -` (ad-hoc), lalu `ditto -c -k --keepParent` menjadi `build/Mac-Cleaner-2.0.0.zip`. `build/` masuk `.gitignore`.
- Ikon: ikon sederhana 1024 px dibuat oleh pembangun, sesuai gaya `screenshots/banner.png`, lalu dikonversi lewat `sips` + `iconutil`.

**README (bagian EN dan ID):** bagian baru "Aplikasi Mac (GUI)" di paling atas untuk orang awam berisi:
- link download Releases dan syarat Mac Apple Silicon (M1 atau lebih baru);
- langkah membuka pertama kali, dengan screenshot: (1) pindahkan `Mac Cleaner.app` ke folder Applications dulu, karena izin yang diberikan saat app masih di Downloads tidak menempel; (2) buka, lalu Pengaturan Sistem → Privasi & Keamanan → "Tetap Buka";
- izin Full Disk Access dan App Management (untuk apa, cara memberi), dan catatan bahwa izin ini perlu diberikan ulang setelah update;
- catatan bahwa pengguna Mac Intel memakai versi CLI.

Bagian CLI tetap ada di bawahnya. Screenshot GUI memakai mode demo.

## Urutan pengerjaan

0. Simpan rancangan ini ke `docs/superpowers/specs/2026-11-09-gui-design.md` di cabang baru `feature/gui`, lalu buat rencana implementasi rinci (superpowers:writing-plans).
1. **Uji Gatekeeper lebih dulu:** buat aplikasi SwiftUI "hello" minimal dengan `build.sh`, zip, beri atribut karantina (atau download lewat browser), lalu buka. Pastikan macOS menawarkan "Tetap Buka", bukan "rusak". Kalau ternyata "rusak", berhenti dan bahas ulang dengan pemilik sebelum lanjut, karena satu-satunya jalan keluar adalah perintah Terminal.
2. **Mesin:** pagar mode engine, protokol, `engine_dispatch`, pengecualian diri di `list_apps`, perilaku `finder_denied`, lalu refactor pindai/jalankan per menu (cache → folder → RAM → aplikasi/uninstall → Docker → update). Setiap menu dicek: keluaran CLI tidak berubah, dan `tests/engine_test.sh` lulus.
3. **Kerangka aplikasi:** `EngineRunner` (process group) + parser + tes Swift Testing, shell sidebar/toolbar/disk/bahasa/mode coba, mode demo.
4. **Layar fitur** sesuai urutan yang sama dengan langkah 2, termasuk callout izin.
5. **Penyelesaian:** ikon, Info.plist, README EN+ID, screenshot GUI (mode demo), VERSION 2.0.0.
6. Rilis ke GitHub (`gh release create`) hanya setelah pemilik memintanya.

Siapa yang mengecek apa: pembangun menjalankan semua cek otomatis dan membuka aplikasinya sendiri di Mac ini. Langkah yang butuh orang di depan layar dikumpulkan sebagai **daftar cek untuk pemilik** di akhir langkah 1, 4, dan 5: klik "Tetap Buka", memberi izin, mencoba ketujuh layar, dan uninstall sungguhan lalu "Put Back".

## Verifikasi

- `bash -n mac-cleaner.command` setelah setiap perubahan pada script.
- `tests/engine_test.sh`: menjalankan mesin dengan `HOME` sementara berisi folder palsu (mis. `~/.npm/_cacache`, `~/Library/Caches/Foo`, `~/Library/Logs`, `~/.Trash`, dan app palsu di `~/Applications/Foo.app` dengan sisa file di `~/Library/Preferences`). Yang dicek:
  - setiap baris keluaran berawalan `@@` jenis yang dikenal, atau baris biasa;
  - `caches-scan` memuat id yang benar beserta ukurannya;
  - `caches-clean --dry-run` tidak menghapus apa pun, sedangkan tanpa dry-run isi folder hilang tapi foldernya tetap ada;
  - `uninstall-plan` menemukan sisa file;
  - `uninstall --list` hanya memindahkan path yang ada di daftar;
  - path di luar HOME di dalam daftar ditolak (`safe_path`);
  - memanggil `ask` dalam mode engine menghasilkan `@@error interactive`.
- **Regresi CLI:** jalankan `printf '1\n\nq\n' | bash mac-cleaner.command --dry-run` dan input serupa untuk tiap menu, lalu bandingkan dengan keluaran v1.5.1 (`git show 6ecf5ce:mac-cleaner.command`) pada HOME palsu yang sama.
- **Aplikasi:** `cd app && swift build && swift test` (Swift Testing), lalu `./build.sh`, buka `build/Mac Cleaner.app`, dan jalani ketujuh layar dengan **Mode coba aktif**. Yang dipastikan:
  - Batal saat memindai menghentikan seluruh proses (cek dengan `pgrep du` setelahnya);
  - prompt Automation untuk Finder muncul;
  - callout Full Disk Access dan App Management muncul ketika izin belum diberikan;
  - bahasa berganti dan tersimpan untuk CLI juga;
  - Mac Cleaner tidak muncul di daftar aplikasinya sendiri.
- Daftar cek pemilik (lihat di atas), termasuk satu aksi sungguhan yang bisa dibalik: uninstall app uji ke Trash lalu "Put Back".
