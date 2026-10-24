# Fajar PDF Reader

Aplikasi pembaca, pengelola, dan konverter dokumen PDF lintas platform (*Windows, macOS, dan Android*) yang dibangun menggunakan Flutter. Dirancang dengan antarmuka yang bersih, navigasi cepat, serta fitur konversi dokumen dan pencetakan langsung.

---

## Fitur Utama

* **Penampil PDF Cepat & Halus**: Navigasi halaman lancar, zoom fleksibel (50% hingga 500%), dan tampilan responsif.
* **Pencarian Teks Interaktif**: Cari kata atau frasa di dalam dokumen lengkap dengan penandaan visual (*highlight*), navigasi kecocokan (*next/previous match*), dan penghitung hasil pencarian.
* **Cetak Dokumen Langsung (Native Print)**: Terintegrasi langsung dengan dialog pencetakan sistem operasi untuk memilih printer fisik atau *Print to PDF*.
* **Konversi Dokumen Lengkap**:
  * **PDF to Image (PNG)**: Ekspor halaman dokumen ke format gambar dengan opsi seluruh halaman maupun rentang halaman tertentu (misal: `1, 5, 7` atau `1-3, 5`) ke folder pilihan.
  * **PDF to Word (.docx)**: Ekspor dokumen ke format Microsoft Word. Menggunakan integrasi Word Reflow di Windows untuk tata letak presisi, serta generator OpenXML mandiri untuk macOS dan Android.
  * **PDF to Excel (.csv / .xlsx)**: Ekstraksi teks terstruktur berbasis kolom untuk pengolahan lembar kerja di spreadsheet.
* **Riwayat Berkas (Recent Files)**: Menyimpan daftar dokumen yang baru dibuka untuk akses cepat.
* **Bagikan Dokumen (Share Intent)**: Mendukung penerimaan berkas dari luar aplikasi dan berbagi dokumen langsung ke aplikasi lain.

---

## Teknologi yang Digunakan

* **Framework**: [Flutter](https://flutter.dev) (Dart)
* **PDF Rendering**: `pdfrx`
* **PDF Manipulation & Text Extraction**: `syncfusion_flutter_pdf`
* **File & Directory Picker**: `file_picker`
* **Native Printing**: `printing`
* **Archive & Compression**: `archive`
* **Sharing Intent**: `share_plus` & `receive_sharing_intent`

---

## Persiapan & Instalasi

### Prasyarat
* Flutter SDK (versi terbaru pada channel `stable`)
* Xcode (untuk macOS)
* Visual Studio Community dengan *Desktop development with C++* (untuk Windows)
* Android Studio / SDK (untuk Android)

### Menjalankan di Lingkungan Pengembangan

1. **Clone repositori**:
   ```bash
   git clone [https://github.com/username/pdf_reader_app.git](https://github.com/username/pdf_reader_app.git)
   cd pdf_reader_app