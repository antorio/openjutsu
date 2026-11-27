# Analisis Openjutsu (fork antorio/openjutsu)

Disusun 27 November 2026, dari fork yang identik dengan `D3voz/openjutsu` di commit `7fe118b` (30 Oktober 2026), ditambah perubahan lokal saya yang belum di-commit.

## 0. Cara membaca dokumen ini

Setiap klaim diberi label:

- **[V]** Terverifikasi. Sumbernya saya baca sendiri: file di repo, source pack yang saya clone, API Hugging Face/GitHub, atau halaman resmi. Sumbernya ditulis.
- **[S]** Disimpulkan dari bukti. Hal yang disimpulkan ditulis.
- **[B]** Belum diverifikasi. Klaim pihak lain, atau hal yang hanya bisa dipastikan dengan menjalankannya di GPU.

### Apa yang benar-benar saya baca

| Bagian | Cakupan |
| --- | --- |
| `lib/*.ts` (13 file), `app/**/route.ts` (8 route), `proxy.ts`, `instrumentation.ts`, `next.config.ts`, `package.json`, `.env.example`, CI, `start_openjutsu.bat`, `patch_proxy.py` | dibaca utuh |
| `components/openjutsu.tsx` (1.534 baris), `components/from-picture.tsx`, `components/welcome.tsx` | dibaca utuh |
| `components/object-placement.tsx` | 60 dari 170 baris (alat gambar kotak/kuas di canvas) |
| `app/globals.css`, isi `test/*.ts` | tidak dibaca. Tes saya jalankan: 132/132 lolos |
| `workflows/*.api.json` (14 graph) | dianalisis dengan skrip: semua node, tipe, nilai file model |
| `workflows/build/*` | hanya header. Isinya pembangkit workflow, bukan kode runtime |
| README, CUSTOM_NODES_REPORT, `workflows/picture/README.md` | dibaca utuh |
| 52 issue dan PR upstream | body dan semua komentar dibaca utuh (5 komentar dan 1 review bot) |
| ComfyUI v0.43.0 dan 14 custom pack | di-clone untuk dibaca, tidak dijalankan. Yang diperiksa: definisi node, folder model, validasi |
| comfy-api-proxy 0.1.6 | wheel diunduh dan source-nya dibaca, tidak di-install |
| Model di Hugging Face | daftar file, ukuran, dan sha256 lewat API |

Yang tidak saya lakukan: menjalankan workflow apa pun di GPU. Semua klaim soal "jalan atau tidak di GPU" berstatus **[B]**.

---

## 1. Ringkasan

Openjutsu adalah front end Next.js kecil di atas ComfyUI **[V]**. Hampir semua kecerdasannya ada di graph ComfyUI (`workflows/*.api.json`) dan di custom pack, terutama `comfyui-h3-oneclick-swap` milik D3voz (2.377 baris Python) **[V]**. Kode app sendiri sekitar 4.560 baris TypeScript, ditambah 2.150 baris tes **[V]**. Tugasnya:

1. Menerima upload.
2. Memvalidasi input.
3. Memangkas dan mengubah graph sesuai pilihan di UI.
4. Mengirim graph ke ComfyUI lewat comfy-api-proxy.
5. Meneruskan progres dan hasil ke browser.

App ini tidak punya database dan tidak punya akun pengguna. Satu password dipakai bersama. Riwayat dan pengaturan disimpan di `localStorage` browser **[V]**.

README menyebutnya "Genjutsu-style" **[V]**. Kaitan dengan "Higgsfield Genjutsu" hanya muncul di issue pihak ketiga (#42), bukan dari penulisnya.

---

## 2. Arsitektur dan jalur jaringan

```
Browser ──HTTP/SSE──▶ Next.js app (127.0.0.1:3000)
                         │
                         ├─▶ comfy-api-proxy (127.0.0.1:8189, Comfy API v2) ─▶ ComfyUI (127.0.0.1:8188)
                         │     upload input, submit job, event stream, output
                         │
                         └─▶ ComfyUI langsung (COMFYUI_URL, default 127.0.0.1:8188)
                               /object_info/*  : daftar model dan cek node (SETIAP job)
                               /websocket_reconnect_fix : cek pack
                               /orion4d_fxmax/* : preset Fix colours
                               /upload/image, /prompt, /history, /queue, /view : SELURUH From picture
```

Fakta penting untuk setup remote **[V]**:

- **App wajib bisa menjangkau dua port: proxy dan ComfyUI langsung.**
  - `.env.example` menulis bahwa `COMFYUI_URL` hanya untuk mengisi pemilih model. Itu tidak lengkap.
  - `parseModel()` di `app/api/jobs/route.ts` memanggil `listModels()` ke `COMFYUI_URL` dan menolak job kalau daftar model tidak terbaca. Ini berlaku untuk Simple, Advanced, Object, Fix faces, dan Montage.
  - `/api/setup` juga dipanggil sebelum setiap job, dan route itu pun memakai `COMFYUI_URL`.
- **From picture sama sekali tidak memakai proxy.** Upload, submit, polling, dan download langsung ke ComfyUI. Sinyal timeout-nya 30 detik untuk seluruh request (`app/api/picture/route.ts:24`). Kalau app berjalan di Mac dan ComfyUI di server jauh, upload video besar lewat SSH tunnel yang lambat bisa melebihi 30 detik **[S]**. Klaim yang sama ada di PR #26 **[B]**.
- **Progres job memakai Server-Sent Events** (`/api/jobs/[id]/events`), ditambah polling `GET /api/jobs/<id>` sebagai cadangan (tambahan saya, lihat bagian 7). From picture memakai polling setiap 2 detik.
- Proxy menyimpan job di memori. Opsi `--state-dir` (SQLite) ada di proxy 0.1.6 tetapi tidak dipakai oleh launcher mana pun **[V]**. Karena itu, setelah proxy restart, job lama tampil sebagai "expired".

---

## 3. Peta mode → workflow → kode

| Mode di UI | `kind` | Graph | Pemangkas | Yang diubah per request |
| --- | --- | --- | --- | --- |
| Simple motion transfer | `simple` | `simple.api.json` (70 node) | `pruneSimple` di `lib/simple.ts` | target SAM, margin, hat fix, No lip-sync, ukuran motion ref, resolusi, seed, panjang klip, role |
| Simple → Check mask | `mask` | `mask.api.json` (20) | `pruneMask` | target, margin, hat fix |
| Advanced (Standard) | `advanced` | `advanced.api.json` (84) | `pruneAdvanced` di `lib/advanced.ts` | 1–4 foto, role, hat fix, No lip-sync, dll. |
| Advanced → One pass per person | `advanced_maxq` | `advanced_maxq.api.json` (98) | `pruneAdvanced` | tepat 2 foto, dua pass H3 per klip |
| Advanced → Montage | `montage` | `montage.api.json` (95) | `pruneMontage` di `lib/montage.ts` | dengan atau tanpa review dari Find people |
| Montage → Find people | `people` | `people.api.json` (9) | `submitPeople` di `lib/comfy.ts` | role, describer, crop custom |
| Object swap (Change/Remove/Background/Add) | `object` | `object.api.json` (54) | `pruneObject` di `lib/object.ts` | mode, target, `change_to`, kuas, kotak penempatan, aksi |
| Object → Add → Check fit | `fit` | `fit.api.json` (7) | `pruneFit` | kotak, aksi |
| Object → From picture | (route terpisah) | `workflows/picture/*` (4 graph) | `lib/picture.ts`, `app/api/picture/route.ts` | prepare (FLUX), describe (Qwen), render (H3 atau SolarRenderer) |
| Post → Fix faces | `face` | `face.api.json` (30) | `pruneFace` di `lib/face.ts` | gaya (photo/mouth), seed, panjang chunk |
| Post → Fix colours | `color` | `color.api.json` (4) | `pruneColor` di `lib/color.ts` | detail contrast, tone mapper (Orion4D) |

Daftar `JOB_KINDS` ada di `lib/comfy.ts:47`.

### Cara graph diubah **[V]**

- **Node dicari lewat judul (`_meta.title`) atau ID.** Simple dan mask memakai ID tetap (`NODES` dan `MASK_NODES` di `lib/simple.ts`). Mode lain memakai judul lewat `nodeByTitle`, yang melempar error kalau judulnya tidak tepat satu. Karena itu, mengekspor ulang workflow dengan judul atau ID yang berubah langsung merusak app. `npm test` menguji pemangkasan terhadap file ekspor.
- **Video tanpa suara.** `silenceWhenSoundless()` di `lib/comfy.ts:57` membelokkan setiap pembacaan audio dari `VHS_LoadVideo` ke `H3SoundtrackOrSilence`. Node ini ada di pack oneclick-swap sejak 25 Oktober; padding sejak 28 Oktober.
- **Bagian video.** `setSection` mengubah detik menjadi frame dengan asumsi 24 fps (`force_rate: 24` di semua loader).
- **Resolusi custom.** `cropSource` menyisipkan `ImageScale` dengan center crop sebelum SAM, supaya mask dan render memakai bentuk yang sama.
- **Model.** `applyModel` di `lib/model.ts`:
  - mengganti file UNET, encoder teks H3, dan VAE;
  - mengganti node berjudul "DMAD LoRA" dengan rantai berisi 0–4 LoRA;
  - kalau Spectrum dipilih, menyisipkan `SpectrumApplyMiniMaxH3` di depan setiap guider.
- **Resume.** Klip yang sudah jadi disimpan oleh Context Loop, dan rerun dengan input yang sama melanjutkan dari klip terakhir. Identitas run-nya:
  - `run_hash` di pack oneclick-swap: SHA-1 dari frame sampel (setiap frame ke-24, setiap piksel ke-32, rata-rata kanal warna), foto, dan settings. Audio tidak ikut **[V]**, saya baca fungsinya.
  - App menambahkan akhiran untuk ukuran motion ref (`_motion768`) dan untuk komponen model non-default (`_model<fnv1a>`).
  - Hash ini lemah. Video berbeda bisa mendapat hash yang sama. PR #27 dan #11 menyatakan hal ini disertai bukti **[B]**, dan cara kerja fungsinya mendukung klaim itu **[S]**.

### Alur satu job (selain From picture) **[V]**

1. `submit()` di `components/openjutsu.tsx:507` menyusun FormData dan objek `SetupRequest`.
2. `POST /api/setup`:
   - membuat graph versi pangkas;
   - menanyakan `/object_info/<tipe>` untuk setiap tipe node;
   - membandingkan nama file model, dengan `\` dan `/` dianggap sama;
   - mengecek route `/websocket_reconnect_fix`.
   Kalau ada yang kurang, upload tidak dimulai.
3. `POST /api/jobs`:
   - Maksimal 3 upload bersamaan per proses.
   - Multipart dibaca streaming ke folder temp. Total 512 MB, maksimal 16 file, field teks 1 MB. Byte awal file dicek (MP4/MOV/MKV/WebM/AVI, PNG/JPEG/WebP).
   - Validasi field, lalu daftar model dibaca dari ComfyUI.
   - Graph dipangkas, lalu file diunggah lewat SDK (`assets.fromFile`). Proxy memberi ID yang sama untuk byte yang sama.
   - `comfy.submit`, lalu balasan 202 berisi ID job.
4. Browser membuka `EventSource` ke `/api/jobs/<id>/events?kind=…`. Route ini membaca stream mentah dari proxy (`getJobEvents`), lalu menerjemahkan ID node menjadi judul dan nomor klip (`lib/progress.ts`).
5. Hasil diunduh lewat `/api/jobs/<id>/outputs/<outputId>`. Hanya tipe video, png/jpeg/webp/gif, dan json yang dilayani. Header Range diteruskan.
6. Setelah job selesai, input yang diunggah server ini dihapus dari proxy. File-nya tetap tertinggal di folder `input/` ComfyUI.

### From picture **[V]**

1. **Prepare.** FLUX 3 Klein mengedit satu frame: karakter dipasang dalam pose frame itu. Kanvas 768p. Prompt di-upsample oleh Qwen3.5 9B. Opsi Relight (17 look) menulis ulang graph lewat `applyRelight` atau `applyFrameRelight`. Hasilnya disimpan di `output/openjutsu_picture/flux3/`.
2. **Describe** (otomatis setelah "Use this image"). Qwen3-VL membaca bagian video pada 2 fps, lalu menulis ulang deskripsinya untuk gambar yang sudah disiapkan.
3. **Render.** Gambar yang sudah disiapkan, normal map Metric3D, dan prompt dirender oleh H3 native atau SolarRenderer, dalam satu klip maksimal 15 detik tanpa context loop.

Status job dilacak lewat `/history` ComfyUI. Job dikenali dari judul node yang khas (`OpenJutsu · prepared picture`, dan seterusnya).

---

## 4. Keamanan **[V]**

- **Tanpa password:**
  - `instrumentation.ts` mengecek alamat socket yang benar-benar di-bind, lewat API Node yang tidak terdokumentasi (`_getActiveHandles`). Kalau ada yang bukan loopback, proses keluar.
  - `authorize()` menolak header Host yang bukan localhost, untuk mencegah DNS rebinding.
- **Dengan password:**
  - Basic Auth dengan user `openjutsu`, panjang minimal 12, dibandingkan lewat SHA-256 dan `timingSafeEqual`.
  - Login yang gagal diperlambat. Setiap klien punya 5 percobaan gratis, lalu jeda 1 detik yang berlipat ganda sampai 5 menit. Batas gabungan 20 percobaan. Klien dibedakan lewat entri terakhir `X-Forwarded-For`.
- `proxy.ts` (middleware Next 16) hanya menjaga `/`. Setiap route API memanggil `apiAccess` sendiri, yang berisi auth ditambah cek same-origin lewat `Origin` dan `Sec-Fetch-Site`. Aset statis (`/_next/*`, `/relight/*.webp`) tidak dijaga. Isinya hanya bundle JS dan gambar contoh.
- Header keamanan: `X-Frame-Options DENY`, `frame-ancestors 'none'`, `nosniff`, `Referrer-Policy same-origin`. Tidak ada CSP penuh.
- Model akses: satu pemilik. Semua orang yang tahu password melihat dan mengendalikan semua job.

---

## 5. Data dan persistensi **[V]**

| Di mana | Apa |
| --- | --- |
| `localStorage` browser | `openjutsu.settings` (semua pengaturan, divalidasi ulang saat dibaca), `openjutsu.run` (job aktif), `openjutsu.history` (20 job terakhir), `openjutsu.welcome`, `openjutsu.picture-preview`, `openjutsu.picture-video-settings`, `openjutsu.picture-description` |
| Memori proses Next | antrean upload (maks 3), kunci From picture (1 request), catatan login gagal, hitungan pemakaian input |
| Memori proxy | job dan indeks aset, hilang saat restart (`--state-dir` tidak dipakai) |
| ComfyUI `output/` | `h3_oneclick_swap/`, `h3_oneclick_edit/`, `openjutsu_face/`, `openjutsu_color/`, `openjutsu_picture/flux3/`, serta checkpoint klip untuk resume |
| ComfyUI `input/` | semua upload, tidak pernah dibersihkan otomatis |
| ComfyUI `temp/` | track Find people (`h3_montage_people_*.npz`) |

---

## 6. Ketergantungan eksternal

### Node → pack

Saya memetakan **103 tipe node**. Isinya semua yang ada di 14 graph, ditambah node yang disisipkan app saat runtime (misalnya `ImageScale`, `StringConcatenate`, `H3PaintedEditArea`, `SpectrumApplyMiniMaxH3`). Pemetaan dilakukan dengan mencari definisinya di source ComfyUI v0.43.0 dan 14 pack **[V]**. Hasilnya, semua ditemukan.

| Sumber | Node (ringkas) |
| --- | --- |
| ComfyUI core v0.43.0 | loader, sampler, `MiniMaxH3ReferenceToVideo`, `MiniMaxH3SigmaShift`, `SAM3_VideoTrack`, `SAM3_TrackToMask`, `TextGenerate`, `ModelAttentionBackend`, `ReferenceMultiLatent`, `EmptyFlux2LatentImage`, `LTXVSeparateAVLatent`, `ComfyMathExpression`, `ComfySwitchNode`, dll. |
| `D3voz/comfyui-h3-oneclick-swap` | 24 node `H3*`: semua Plan, mask, mannequin, labeling, montage, face chunk/join, penempatan objek, soundtrack |
| `ethanfel/ComfyUI-MiniMaxH3-Context-Loop` | 14 node `MiniMaxH3Chain*` / `MiniMaxH3Contex*` (loop klip, checkpoint, assembly) |
| `Adudeguyman/...-PromptBuilder` | `MiniMaxH3FantasticVideoEditLatent` |
| `kijai/ComfyUI-KJNodes` | `GrowMaskWithBlur`, `ImageAndMaskPreview`, `VRAM_Debug` |
| `Kosinkadink/ComfyUI-VideoHelperSuite` | `VHS_LoadVideo`, `VHS_SelectEveryNthImage`, `VHS_VideoCombine` |
| `Carasibana/ComfyUI-H3-FaceRefine` | `H3FaceTrackCrop`, `H3FaceMaskSAM`, `H3FaceStitch` |
| `ltdrdata/ComfyUI-Impact-Pack` | `SAMLoader` |
| `ltdrdata/ComfyUI-Impact-Subpack` | tidak menambah node yang dipakai, tetapi mendaftarkan folder `ultralytics`, `ultralytics_bbox`, dan `ultralytics_segm` |
| `D3voz/comfyui-image-detail-contrast` | `ImageDetailContrast` |
| `orion4d/Orion4D_FXMax` | `Orion4D_FXMax_DCTLToneMapper` |
| `Enderfga/SolarRenderer` | 4 node `SolarRenderer*`. Ada di subfolder `comfyui/`, tetapi `__init__.py` di root memuatnya, jadi clone di root sudah benar |
| `Fannovel16/comfyui_controlnet_aux` | `Metric3D-NormalMapPreprocessor` |
| `xmarre/ComfyUI-Spectrum-MiniMax-H3` | `SpectrumApplyMiniMaxH3`. Hanya untuk Acceleration → Spectrum. **Tidak dipasang `setup.sh`** |
| `D3voz/comfyui-websocket-reconnect-fix` | tidak ada node, hanya route |

Detail yang terverifikasi dari source:

- **Fix faces di Linux.**
  - ComfyUI mendaftar file model dengan `os.path.relpath`, jadi di Linux pemisahnya `/` (`folder_paths.py:429`).
  - Validasi combo-nya ketat: `val not in combo_options` (`execution.py:1070`).
  - `face.api.json` diekspor di Windows dengan nilai `bbox\face_yolov8m.pt`, jadi di Linux job ditolak.
  - Setup check app menganggap `\` dan `/` sama, sehingga masalah ini lolos cek lalu baru gagal saat submit.
  - Perbaikan saya (`useInstalledDetectors` di `lib/face.ts`) memakai ejaan yang dilaporkan ComfyUI.
- **Impact-Subpack.**
  - H3-FaceRefine membaca daftar detektor dari kunci folder `ultralytics_bbox` dan `ultralytics`. Kedua kunci itu hanya didaftarkan oleh Subpack, bukan oleh ComfyUI core.
  - Tanpa Subpack, FaceRefine hanya menawarkan nama cadangan `face_yolov8m.pt`, yang tidak cocok dengan `bbox/face_yolov8m.pt` di workflow.
- **Versi H3-FaceRefine.**
  - 1.1.0 (30 Agustus) sampai 1.1.2 (12 September) mengganti pilihan `select`: `largest` diganti `largest_face`, dan seterusnya. Nama input tidak berubah.
  - `face.api.json` mengirim `largest`, jadi ditolak oleh 1.1.x (#45).
  - Semua input yang dikirim workflow diterima oleh 1.0.0 (`79a97ce`). Pin ke 1.0.0 adalah pilihan yang kompatibel. Alternatifnya: ubah `largest` menjadi `largest_face` dan pakai 1.1.2. Kalau itu dipilih, input baru di 1.1.2 perlu dicek dulu.
- **`ModelAttentionBackend` = "comfy kitchen attention".**
  - Opsi ini hanya muncul kalau `comfy_kitchen.int8_attention_is_available()` bernilai true.
  - Node-nya punya `validate_inputs` yang selalu true, dan saat dieksekusi kembali ke PyTorch attention dengan peringatan. Jadi tidak gagal keras.
  - `comfy-kitchen==0.2.40` di-pin oleh requirements ComfyUI v0.43.0.
- **comfy-api-proxy 0.1.6.** Keenam string yang diganti `patch_proxy.py` masing-masing ditemukan tepat sekali di source 0.1.6. Patch-nya cocok.

### Versi ComfyUI

README meminta 0.41.2 atau lebih baru **[V]**. Versi yang dipakai penulis tidak tercatat **[V]**. `setup.sh` sekarang memakai **v0.43.2**, versi terbaru pada 30 Oktober (commit terakhir upstream). Sebelumnya saya memilih v0.43.0. Di luar node partner, beda keduanya hanya perbaikan `memfd_create` untuk Linux (Python build tertentu, misalnya conda) dan versi paket template **[V]** (`git log v0.43.0..v0.43.2`). Saat ini sudah ada v0.46.3 (24 November). Semua tipe node yang dikirim app ada di v0.43.0 dan v0.43.2 **[V]**. Apakah setiap nilai input valid di versi itu baru pasti setelah dijalankan **[B]**.

### Model **[V]** (ukuran dari API Hugging Face)

| File yang dipakai workflow | Ukuran | Sumber | Status sumber |
| --- | --- | --- | --- |
| `minimax_h3_ref2va_pruned_int8_convrot` | 20,97 GB | `Comfy-Org/MiniMax-H3` | resmi Comfy-Org |
| `qwen3vl_32b_minimax_h3_int4_convrot` (encoder teks H3) | 14,95 GB | `Merserk/MiniMax-H3-INT4-ConvRot` | **komunitas**. Comfy-Org hanya punya bf16 (51,5 GB), int8_convrot (27,1 GB), dan nvfp4_awq (15,7 GB) |
| `qwen3vl_8b_int8_convrot` (describer) | 9,35 GB | `Comfy-Org/Qwen3-VL` | resmi Comfy-Org |
| `minimax_h3_video_vae_int8_convrot` | 2,81 GB | `Comfy-Org/MiniMax-H3` | resmi |
| `minimax_h3_audio_vae_fp32` | 0,61 GB | `Comfy-Org/MiniMax-H3` | resmi |
| `minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16` | 0,37 GB | `Kijai/MiniMax-H3-experimental` | **komunitas** (Kijai, pembuat KJNodes), nama persis. Penulis tidak pernah menautkan sumber, jadi belum pasti byte-nya sama dengan file penulis **[B]** |
| `sam3.1_multiplex_fp16` | 1,75 GB | `Comfy-Org/sam3.1` | resmi |
| `face_yolov8m.pt`, `person_yolov8m-seg.pt` | 0,05 GB masing-masing | `Bingsu/adetailer` | ditautkan README |
| `sam_vit_b_01ec64.pth` | ±0,37 GB | `dl.fbaipublicfiles.com` (Meta) | resmi Meta. Ukurannya tidak saya cek ulang **[B]** |
| `buffalo_l` (InsightFace) | – | diunduh InsightFace saat pertama dipakai | menurut README dan CUSTOM_NODES_REPORT **[V]** |
| `flux3_image_klein_sd_int8_convrot` | 5,83 GB | `black-forest-labs/flux-3-image-klein-comfy` dengan nama baru `flux3-image-klein-int8-convrot` | gated (perlu setuju lisensi dan `HF_TOKEN`), lihat catatan di bawah |
| `qwen3vl_4b_fp8_scaled` | 5,24 GB | `Comfy-Org/Qwen3-VL` | resmi |
| `qwen3.5_9b_flux3_prompt_upsampler_int8_convrot` | 9,75 GB | BFL (gated) | resmi |
| `flux2-vae` | 0,34 GB | BFL (gated) | resmi |
| SolarRenderer 4step dan control | 4,15 GB masing-masing (rank 384) atau 0,69 GB (rank 64) | `Enderfga/SolarRenderer`, `mdevoz/SolarRendererRank64` | ditautkan README |
| Metric3D, `depth_anything_v2_vitb` | – | diunduh `comfyui_controlnet_aux` saat dipakai | menurut docs **[V]**, ukuran **[B]** |

Total model inti sekitar 51 GB. From picture menambah sekitar 30 GB, atau sekitar 23 GB dengan rank 64.

**Catatan FLUX:**

- **[V]** KoalaNation (16 Oktober) menyimpan file bernama lama, ml-resources (setelah commit 17 Oktober "Rename diffusion models to match upstream (base / distilled)") menyimpan file bernama baru. Keduanya punya sha256 `847d8933…` dan ukuran 5.827.874.779 byte.
- **[V]** File BFL berukuran sama.
- **[S]** BFL yang mengganti nama. Riwayat commit dan hash file BFL tertutup (HTTP 401). "sd" sepertinya berarti versi distilled (non-base), karena commit mirror menyebut "base / distilled".

### Lisensi

- **[V]** README: kode MIT. InsightFace `buffalo_l` hanya untuk riset non-komersial. Bobot YOLO dari Bingsu/adetailer berlisensi AGPL-3.0.
- **[B]** PR #1 (pihak ketiga) menyebut FLUX 3 Klein non-komersial. Lisensi MiniMax H3 dan model lain belum saya baca.

---

## 7. Masalah yang diketahui

### Dari issue upstream (dibaca utuh)

| # | Isi | Analisis saya |
| --- | --- | --- |
| #41 | minta link resmi model | Satu-satunya link di thread: SolarRenderer. CUSTOM_NODES_REPORT bagian 4.2 juga mengakui file H3/Qwen INT8/INT4 dan DMAD belum punya link langsung **[V]** |
| #44 | MemoryError untuk video 1080p yang panjang | **[V]** Semua `VHS_LoadVideo` memakai `custom_width/height = 0`, jadi video di-decode pada ukuran asli sebagai float32: 1920×1080×3×4 ≈ 24,9 MB per frame, sekitar 36 GB per menit pada 24 fps. Bagian default adalah seluruh video. Usulan di issue itu (set ukuran load ke kanvas) masuk akal tetapi belum saya uji **[B]**. Ini relevan untuk RAM Colab |
| #45 | `select: 'largest'` ditolak | Terverifikasi, lihat bagian 6. Pin 1.0.0 menyelesaikannya |
| #46 | gagal kalau video tidak ada audionya | Kode sudah menangani sejak 25 Oktober (`H3SoundtrackOrSilence`). Issue ini tanggal 2 November dan tanpa log, jadi penyebabnya tidak bisa dipastikan. Kemungkinan pack-nya versi lama **[S]** |
| #51 | setup check melaporkan `bbox\face_yolov8m.pt` hilang | Setup check sudah menyamakan `\` dan `/`, jadi pesan ini **bukan** disebabkan backslash. Penyebabnya: daftar detektor FaceRefine tidak memuat file itu, kemungkinan karena Subpack tidak terpasang atau file tidak ada di `models/ultralytics/bbox` **[S]** |
| #48 | minta flake.nix | permintaan fitur |
| #42, #43 | pemberitahuan dari blog pihak ketiga | bukan bug |
| #50 | "fetch failed", tanpa isi | tidak bisa dianalisis |

### PR upstream: 43 total, 42 masih open, 1 ditutup tanpa merge (#1)

- **#2–#39 (38 PR, 28–29 Oktober) dari satu akun, ditulis dengan bantuan AI.** Masing-masing mengklaim satu bug disertai tes regresi. Semuanya **[B]**: klaimnya belum saya cek satu per satu. Yang paling relevan:
  - #11 dan #27: identitas resume terlalu lemah, sehingga klip dengan mask atau media berbeda bisa ikut terpakai.
  - #44 sudah dibahas di atas.
  - #3: race condition saat cleanup input.
  - #26: timeout 30 detik memutus stream media From picture yang sehat.
  - #23: mask check mengabaikan kanvas custom.
  - #37: SolarRenderer di preset 1080p bisa melebihi batas 2048 px.
  - #30: Content-Length salah untuk respons gzip.
- **#40:** i18n EN/ZH.
- **#49:** tombol Download model.
- **#52:** API v1 bahasa Spanyol, SQLite, dan notebook Colab. +2.655/−472 baris di 31 file, termasuk menerjemahkan UI. **Path notebook-nya sama dengan notebook saya** (`notebooks/openjutsu_colab.ipynb`), jadi akan bentrok kalau suatu saat di-merge.

### Temuan saya sendiri

1. **Quick tunnel Cloudflare tidak mendukung SSE.**
   - **[V]** Halaman resmi "Quick Tunnels", bagian Limitations, menyatakan: "Quick Tunnels do not support Server-Sent Events (SSE)." Halaman yang sama mencantumkan batas 200 request bersamaan.
   - **Sudah ditangani dengan fallback polling.** Selain membuka SSE, halaman progres juga mengecek `GET /api/jobs/<id>`:
     - setiap 5 detik selama stream belum mengirim apa-apa, atau setelah stream error;
     - setiap 30 detik kalau stream jalan, sebagai cadangan.
   - Kalau proxy sudah melupakan job, route itu kini menjawab 404 dan halaman menandai job "expired".
   - Kalau stream tidak masuk dalam 15 detik, halaman menjelaskan bahwa yang tampil hanya status dan hasil, tanpa langkah, nomor klip, atau preview mask.
   - Teruji **[V]** dengan backend tiruan dan proxy yang meniru tunnel:
     - SSE ditahan sampai job selesai: status dan hasil tetap muncul dari polling;
     - SSE tidak pernah terkirim (koneksi diputus): hasil tetap muncul dari polling, lalu EventSource berhenti reconnect;
     - SSE normal: progres live tetap tampil dan keterangan fallback tidak muncul;
     - job yang dilupakan proxy tampil sebagai "Job no longer available".
   - Lewat Cloudflare sungguhan belum diuji **[B]**.
   - From picture memang sejak awal memakai polling.
2. **Batas upload 100 MB untuk quick tunnel tidak tercantum** di halaman Quick Tunnels. Klaim saya sebelumnya tidak bersumber dan sudah saya koreksi di dokumentasi.
3. **Seluruh UI ada dalam satu komponen** (`openjutsu.tsx`, 1.534 baris, 58 `useState` di komponen utamanya). Tidak ada state manager dan tidak ada i18n. Ini titik tersulit kalau mau mengubah UI.
4. **CUSTOM_NODES_REPORT sudah usang.** Laporan itu masih menyebut `control.api.json` (Object swap ControlNet), padahal file itu sudah dihapus di #23 (`4af1a70`).
5. **`.env.example` menyebut `COMFYUI_URL` hanya untuk pemilih model**, padahal setiap job dan seluruh From picture bergantung padanya (lihat bagian 2). Komentarnya sudah saya perbaiki.
6. **Encoder teks H3 default berasal dari repo komunitas**, bukan dari Comfy-Org (lihat tabel model).

---

## 8. Koreksi atas klaim saya sebelumnya

| Klaim sebelumnya | Status | Yang benar |
| --- | --- | --- |
| "Alternatif open-source untuk Higgsfield Genjutsu" | dilebih-lebihkan | README hanya menyebut "Genjutsu-style". Nama Higgsfield datang dari issue pihak ketiga (#42) |
| "~7.900 baris TypeScript" | **salah** | 6.709 baris: sekitar 4.560 app dan 2.150 tes |
| Fork identik dengan upstream, 0/0 commit | benar | HEAD sama, `7fe118b` |
| 2,6 ribu star, 430 fork, push terakhir 30 Oktober | benar (angka saat itu) | sekarang 2.683 star dan 437 fork |
| #51 disebabkan backslash | **salah** | lihat tabel issue: setup check sudah menyamakan `\` dan `/`. Bug backslash-nya nyata untuk Linux, tetapi muncul saat submit, bukan di setup check |
| "FaceRefine 1.1 mengganti nama input" | **salah** | 1.1 mengganti pilihan nilai `select`. Nama input tidak berubah |
| "Subpack: tanpanya tidak ada detektor yang terdaftar" | kurang tepat | tanpa Subpack hanya ada nama cadangan `face_yolov8m.pt` yang tidak cocok dengan workflow |
| Batas upload tunnel 100 MB | **tidak bersumber** | tidak ada di halaman Quick Tunnels. Sudah dihapus dari dokumentasi |
| Masalah SSE di quick tunnel | **terlewat** | baru ditemukan sekarang. Ini masalah paling serius di rancangan Colab |
| RAM T4 gratis ±12–13 GB | **tidak bersumber** | Google tidak menerbitkan angka RAM |
| "Akun Google bisa kena tindakan" | **tidak bersumber** | FAQ hanya menyebut runtime gratis bisa dihentikan tanpa peringatan |
| Larangan "creating deepfakes" di semua runtime, termasuk berbayar | benar | dikutip dari FAQ |
| Sesi Colab maksimal ±12 jam | sebagian | 12 jam untuk gratis, 24 jam untuk Pro+, angka lain tidak dipublikasikan |
| "Spesifikasi minimal VRAM ≥24 GB" | itu saran saya, bukan syarat | konfigurasi yang diuji penulis: 16 GB VRAM dan 64 GB RAM |
| "COMFYUI_REF v0.43.0 = versi terbaru saat workflow terakhir diubah" | **salah** | saat itu sudah ada v0.43.2. Versi yang dipakai penulis tidak tercatat. Default sudah diganti ke v0.43.2 |
| DMAD tidak ada dengan nama persis | **salah** (sudah dikoreksi) | ada di Kijai/MiniMax-H3-experimental, repo komunitas |
| BFL mengganti nama FLUX pada 17 Oktober, byte-nya identik | dilebih-lebihkan | lihat catatan FLUX: kedua mirror identik, ukuran BFL sama, hash BFL tertutup |
| 131/131 tes lolos | benar | sekarang 132/132 setelah tes baru saya |
| openjutsu.tsx 1.534 baris, start script hanya Windows, `.gitignore` mengecualikan CLAUDE.md dan AGENTS.md | benar | – |

File buatan saya sudah saya perbaiki supaya sesuai tabel ini: komentar di `scripts/linux/setup.sh` dan `start.sh`, `docs/linux-gpu.md`, notebook, dan baris di `CUSTOM_NODES_REPORT.md`.

---

## 9. Kalau mau memodifikasi, menambah, atau menggabungkan dengan app lain

- **Menambah mode baru** perlu lima hal:
  1. graph API di `workflows/`;
  2. pemangkas di `lib/`;
  3. entri di `JOB_KINDS` beserta parser di `app/api/jobs/route.ts`;
  4. entri `SetupRequest` dan `setupGraph` di `lib/setup.ts`, plus `PACKS` kalau ada pack baru;
  5. UI di `openjutsu.tsx`.
  Tes pemangkasan ada di `test/`.
- **Kontrak paling rapuh:** judul dan ID node di file ekspor. Setiap ekspor ulang dari ComfyUI harus menjaga judulnya.
- **Logika yang menentukan hasil ada di luar repo ini:** pack `comfyui-h3-oneclick-swap` (prompt, rencana klip, mask) dan Context Loop. Mengubah perilaku swap biasanya berarti mengubah pack itu, bukan TypeScript.
- **Untuk digabung dengan app lain:** backend-nya bersih untuk dipakai ulang, karena cukup HTTP ke proxy dan ComfyUI. Hambatan terbesarnya:
  - tidak ada akun dan tidak ada antrean per pengguna;
  - status job hanya ada di memori proxy dan browser;
  - From picture melewati proxy.
  Untuk multi-user dibutuhkan database job, auth per pengguna, dan antrean GPU.
- **Lisensi** menentukan apakah fitur boleh dipakai komersial (lihat bagian 6).

## 10. Yang masih terbuka

- Menjalankan `setup.sh` dan setiap mode di GPU sungguhan (Colab L4 atau RunPod), termasuk instalasi pip pack (insightface, onnxruntime-gpu) dan kecocokan torch.
- Menguji fallback polling lewat quick tunnel Cloudflare sungguhan (temuan 1); sejauh ini baru diuji dengan tunnel tiruan.
- Memverifikasi klaim 38 PR bugfix yang relevan sebelum diadopsi.
- Membaca lisensi MiniMax H3, FLUX 3 Klein, dan SolarRenderer.
