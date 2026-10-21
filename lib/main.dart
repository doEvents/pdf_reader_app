import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:share_plus/share_plus.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  
  String? initialPath;
  if (args.isNotEmpty) {
    final possiblePath = args.first;
    if (possiblePath.toLowerCase().endsWith('.pdf') && File(possiblePath).existsSync()) {
      initialPath = possiblePath;
    }
  }

  runApp(MyApp(initialFilepath: initialPath));
}

class MyApp extends StatefulWidget {
  final String? initialFilepath;
  const MyApp({super.key, this.initialFilepath});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _changeTheme(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fajar PDF Reader',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: PdfViewerScreen(
        currentThemeMode: _themeMode,
        onThemeChanged: _changeTheme,
        initialFilepath: widget.initialFilepath,
      ),
    );
  }
}

class PlacedSignature {
  final String id;
  int pageNumber;
  final Uint8List imageBytes;
  final double aspectRatio;
  double relX;
  double relY;
  double relWidth;
  double relHeight;
  double rotation;

  PlacedSignature({
    required this.id,
    required this.pageNumber,
    required this.imageBytes,
    required this.aspectRatio,
    this.relX = 0.35,
    this.relY = 0.4,
    this.relWidth = 0.25,
    this.relHeight = 0.1,
    this.rotation = 0.0,
  });
}

class PdfViewerScreen extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final String? initialFilepath;

  const PdfViewerScreen({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
    this.initialFilepath,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  String? _filePath;
  String? _originalFilePath;
  String? _fileName;
  List<Map<String, String>> _recentFiles = [];
  final PdfViewerController _pdfController = PdfViewerController();

  final List<PlacedSignature> _placedSignatures = [];
  List<File> _savedSignatureFiles = [];
  String? _selectedSigId;
  Uint8List? _activeSignatureBytes;

  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedSignatures();
    _loadRecentFiles();

    if (widget.initialFilepath != null && widget.initialFilepath!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openPdfFromPath(widget.initialFilepath!);
      });
    }
  }

  void _goToPage(int page) {
    if (_pdfController.isReady && _totalPages > 0) {
      final target = page.clamp(1, _totalPages);
      _pdfController.goToPage(pageNumber: target);
    }
  }

  void _showJumpPageDialog() {
    if (_totalPages <= 0) return;
    final textController = TextEditingController(text: _currentPage.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lompat ke Halaman'),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Masukkan nomor halaman (1 - $_totalPages)',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (val) {
            final page = int.tryParse(val);
            if (page != null) _goToPage(page);
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(textController.text);
              if (page != null) _goToPage(page);
              Navigator.pop(ctx);
            },
            child: const Text('Lompat'),
          ),
        ],
      ),
    );
  }

  Future<File> _getRecentHistoryFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}${Platform.pathSeparator}pdf_recent_history.json');
  }

  Future<void> _loadRecentFiles() async {
    try {
      final file = await _getRecentHistoryFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        final List<Map<String, String>> loaded = [];
        for (final item in decoded) {
          if (item is Map) {
            final path = item['path']?.toString() ?? '';
            if (path.isNotEmpty && File(path).existsSync()) {
              loaded.add({
                'path': path,
                'name': item['name']?.toString() ??
                    path.split(Platform.pathSeparator).last,
                'time': item['time']?.toString() ?? '',
              });
            }
          }
        }
        if (mounted) setState(() => _recentFiles = loaded);
      }
    } catch (_) {}
  }

  Future<void> _addToRecentFiles(String path, [String? customName]) async {
    try {
      final name = customName ?? path.split(Platform.pathSeparator).last;
      final now = DateTime.now();
      final timeStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      _recentFiles.removeWhere((item) => item['path'] == path);
      _recentFiles.insert(0, {'path': path, 'name': name, 'time': timeStr});
      if (_recentFiles.length > 20) _recentFiles = _recentFiles.sublist(0, 20);
      if (mounted) setState(() {});

      final file = await _getRecentHistoryFile();
      await file.writeAsString(jsonEncode(_recentFiles), flush: true);
    } catch (_) {}
  }

  Future<void> _removeRecentFile(String path) async {
    _recentFiles.removeWhere((item) => item['path'] == path);
    setState(() {});
    try {
      final file = await _getRecentHistoryFile();
      await file.writeAsString(jsonEncode(_recentFiles), flush: true);
    } catch (_) {}
  }

  Future<void> _clearRecentFiles() async {
    _recentFiles.clear();
    setState(() {});
    try {
      final file = await _getRecentHistoryFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _openPdfFromPath(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      _showToast('File tidak ditemukan atau sudah dipindahkan.');
      _removeRecentFile(path);
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    setState(() {
      _filePath = path;
      _originalFilePath = path;
      _fileName = name;
      _placedSignatures.clear();
      _selectedSigId = null;
      _activeSignatureBytes = null;
      _currentPage = 1;
      _totalPages = 0;
    });
    _addToRecentFiles(path, name);
  }

  /// Fungsi Bagikan File (Android, Windows, macOS) via share_plus
  Future<void> _shareCurrentPdf() async {
    if (_filePath == null) return;
    try {
      final xFile = XFile(_filePath!);
      await Share.shareXFiles([xFile], text: 'Dokumen PDF: $_fileName');
    } catch (e) {
      _showToast('Gagal membagikan file: $e');
    }
  }

  /// Cek konfirmasi jika ada perubahan/tanda tangan belum disimpan saat keluar/tutup
  Future<bool> _onWillPop() async {
    if (_filePath == null || _placedSignatures.isEmpty) {
      return true; // Boleh keluar langsung
    }

    final bool? shouldClose = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Perubahan Belum Disimpan'),
        content: const Text(
          'Anda memiliki tanda tangan atau editan yang belum disimpan ke file PDF. Yakin ingin keluar/menutup dokumen ini?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Keluar Tanpa Simpan'),
          ),
        ],
      ),
    );

    return shouldClose ?? false;
  }

  void _openHistoryModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.history),
                        const SizedBox(width: 10),
                        Text(
                          'Riwayat File Dibuka',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        if (_recentFiles.isNotEmpty)
                          TextButton.icon(
                            onPressed: () async {
                              await _clearRecentFiles();
                              setModalState(() {});
                            },
                            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                            label: const Text('Hapus Semua'),
                          ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_recentFiles.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text('Belum ada riwayat dokumen yang dibuka.'),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _recentFiles.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = _recentFiles[index];
                            final path = item['path'] ?? '';
                            final name = item['name'] ?? 'Dokumen.pdf';
                            final time = item['time'] ?? '';
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                              leading: CircleAvatar(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                child: Icon(
                                  Icons.picture_as_pdf_outlined,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '$time  •  $path',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                tooltip: 'Hapus dari riwayat',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () async {
                                  await _removeRecentFile(path);
                                  setModalState(() {});
                                },
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _openPdfFromPath(path);
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<Directory> _getSignatureDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final sigDir = Directory('${appDir.path}/pdf_reader_signatures');
    if (!await sigDir.exists()) await sigDir.create(recursive: true);
    return sigDir;
  }

  Future<void> _loadSavedSignatures() async {
    final dir = await _getSignatureDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.png'))
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    setState(() => _savedSignatureFiles = files);
  }

  Future<void> _saveSignatureToBank(Uint8List bytes) async {
    final dir = await _getSignatureDir();
    final file = File('${dir.path}/sig_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);
    await _loadSavedSignatures();
  }

  Future<void> _deleteSavedSignature(File file) async {
    if (await file.exists()) {
      await file.delete();
      await _loadSavedSignatures();
    }
  }

  Future<void> _pickPdfFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result != null && result.isNotEmpty && result.single.path != null) {
        if (_filePath != null && _placedSignatures.isNotEmpty) {
          bool canProceed = await _onWillPop();
          if (!canProceed) return;
        }
        _openPdfFromPath(result.single.path!);
      }
    } catch (e) {
      debugPrint('Gagal memilih file: $e');
    }
  }

  Future<Uint8List> _resizeImageBytes(Uint8List inputBytes, double scale) async {
    try {
      final codec = await ui.instantiateImageCodec(inputBytes);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;

      final targetW = (uiImage.width * scale).toInt().clamp(20, uiImage.width);
      final targetH = (uiImage.height * scale).toInt().clamp(20, uiImage.height);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()));
      canvas.drawImageRect(
        uiImage,
        Rect.fromLTWH(0, 0, uiImage.width.toDouble(), uiImage.height.toDouble()),
        Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final resizedImage = await picture.toImage(targetW, targetH);
      final byteData = await resizedImage.toByteData(format: ui.ImageByteFormat.png);
      uiImage.dispose();
      resizedImage.dispose();

      if (byteData != null) return byteData.buffer.asUint8List();
    } catch (_) {}
    return inputBytes;
  }

  void _showToast(String message, {String? actionLabel, VoidCallback? onAction}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        margin: const EdgeInsets.only(bottom: 28, left: 24, right: 24),
        content: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xE6323232),
              borderRadius: BorderRadius.circular(50),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      onAction();
                    },
                    child: Text(
                      actionLabel,
                      style: const TextStyle(
                        color: Colors.lightBlueAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportSignedPdf({required bool saveAs}) async {
    if (_filePath == null) return;

    final originalFile = File(_filePath!);
    final originalBytes = await originalFile.readAsBytes();
    final originalSizeKb = originalBytes.length / 1024;

    bool useOriginalSize = true;
    double scaleFactor = 0.6;

    if (!mounted) return;
    final bool? confirmSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            final estimatedKb = useOriginalSize
                ? originalSizeKb
                : (originalSizeKb * (scaleFactor * scaleFactor)).clamp(15.0, originalSizeKb);

            final sizeText = estimatedKb > 1024
                ? '${(estimatedKb / 1024).toStringAsFixed(2)} MB'
                : '${estimatedKb.toStringAsFixed(0)} KB';

            return AlertDialog(
              title: const Text('Opsi Simpan & Kompresi Dokumen PDF'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pilih metode penyimpanan file PDF:'),
                    const SizedBox(height: 16),
                    RadioListTile<bool>(
                      title: const Text('Ukuran Asli (Kualitas Penuh)'),
                      subtitle: Text(
                          'Estimasi: ${originalSizeKb > 1024 ? "${(originalSizeKb / 1024).toStringAsFixed(2)} MB" : "${originalSizeKb.toStringAsFixed(0)} KB"}'),
                      value: true,
                      groupValue: useOriginalSize,
                      onChanged: (val) => setStateModal(() => useOriginalSize = val!),
                    ),
                    RadioListTile<bool>(
                      title: const Text('Perkecil Keseluruhan File PDF'),
                      subtitle: const Text('Kompres resolusi seluruh halaman dokumen & tanda tangan'),
                      value: false,
                      groupValue: useOriginalSize,
                      onChanged: (val) => setStateModal(() => useOriginalSize = val!),
                    ),
                    if (!useOriginalSize) ...[
                      const SizedBox(height: 10),
                      Text('Skala Kompresi Dokumen: ${(scaleFactor * 100).toInt()}%'),
                      Slider(
                        value: scaleFactor.clamp(0.3, 0.9),
                        min: 0.3,
                        max: 0.9,
                        divisions: 6,
                        label: '${(scaleFactor * 100).toInt()}%',
                        onChanged: (val) => setStateModal(() => scaleFactor = val.clamp(0.3, 0.9)),
                      ),
                    ],
                    const Divider(height: 24),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Perkiraan Ukuran File Output: $sizeText',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Batal'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Simpan File'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmSave != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Memproses & mengompresi dokumen PDF...')),
          ],
        ),
      ),
    );

    try {
      Uint8List signedBytes;

      if (useOriginalSize) {
        final pdfDoc = sf.PdfDocument(inputBytes: originalBytes);
        pdfDoc.fileStructure.incrementalUpdate = false;

        for (final sig in _placedSignatures) {
          final pageIndex = sig.pageNumber - 1;
          if (pageIndex >= 0 && pageIndex < pdfDoc.pages.count) {
            final page = pdfDoc.pages[pageIndex];
            final pageSize = page.getClientSize();

            page.graphics.save();
            final x = sig.relX * pageSize.width;
            final y = sig.relY * pageSize.height;
            final w = sig.relWidth * pageSize.width;
            final h = sig.relHeight * pageSize.height;

            page.graphics.translateTransform(x + w / 2, y + h / 2);
            page.graphics.rotateTransform(sig.rotation * (180 / 3.141592653589793));

            final bitmap = sf.PdfBitmap(sig.imageBytes);
            page.graphics.drawImage(bitmap, Rect.fromLTWH(-w / 2, -h / 2, w, h));
            page.graphics.restore();
          }
        }

        signedBytes = Uint8List.fromList(await pdfDoc.save());
        pdfDoc.dispose();
      } else {
        final sourceDoc = await PdfDocument.openFile(_filePath!);
        final newPdfDoc = sf.PdfDocument();
        newPdfDoc.compressionLevel = sf.PdfCompressionLevel.best;
        newPdfDoc.pageSettings.margins.all = 0;

        final renderScale = 1.5 * scaleFactor;

        for (int i = 0; i < sourceDoc.pages.length; i++) {
          final srcPage = sourceDoc.pages[i];
          final pageNum = i + 1;

          final section = newPdfDoc.sections!.add();
          section.pageSettings.margins.all = 0;
          section.pageSettings.size = Size(srcPage.width, srcPage.height);
          section.pageSettings.orientation = srcPage.width > srcPage.height
              ? sf.PdfPageOrientation.landscape
              : sf.PdfPageOrientation.portrait;

          final dstPage = section.pages.add();
          final pageSize = dstPage.getClientSize();

          final targetWidth = (srcPage.width * renderScale).toInt().clamp(100, 4000);
          final targetHeight = (srcPage.height * renderScale).toInt().clamp(100, 4000);

          final pdfImage = await srcPage.render(
            fullWidth: targetWidth.toDouble(),
            fullHeight: targetHeight.toDouble(),
            backgroundColor: 0xFFFFFFFF,
          );

          if (pdfImage != null) {
            final uiImage = await pdfImage.createImage();
            pdfImage.dispose();

            final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
            uiImage.dispose();

            if (byteData != null) {
              final pageBitmap = sf.PdfBitmap(byteData.buffer.asUint8List());
              dstPage.graphics.drawImage(
                pageBitmap,
                Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
              );
            }
          }

          final sigsOnPage = _placedSignatures.where((s) => s.pageNumber == pageNum);
          for (final sig in sigsOnPage) {
            dstPage.graphics.save();
            final x = sig.relX * pageSize.width;
            final y = sig.relY * pageSize.height;
            final w = sig.relWidth * pageSize.width;
            final h = sig.relHeight * pageSize.height;

            dstPage.graphics.translateTransform(x + w / 2, y + h / 2);
            dstPage.graphics.rotateTransform(sig.rotation * (180 / 3.141592653589793));

            final resizedSigBytes = await _resizeImageBytes(sig.imageBytes, scaleFactor);
            final sigBitmap = sf.PdfBitmap(resizedSigBytes);
            dstPage.graphics.drawImage(sigBitmap, Rect.fromLTWH(-w / 2, -h / 2, w, h));
            dstPage.graphics.restore();
          }
        }

        await sourceDoc.dispose();
        signedBytes = Uint8List.fromList(await newPdfDoc.save());
        newPdfDoc.dispose();
      }

      if (mounted) Navigator.pop(context);

      String? targetSavePath;
      if (saveAs) {
        final Uri? saveUri = await FilePicker.saveFile(
          dialogTitle: 'Simpan PDF Sebagai (Save As)',
          fileName: 'Signed_${_fileName ?? "document.pdf"}',
          type: FileType.custom,
          allowedExtensions: ['pdf'],
          bytes: signedBytes,
        );

        if (saveUri != null) {
          targetSavePath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
          if (!targetSavePath.toLowerCase().endsWith('.pdf')) {
            targetSavePath = '$targetSavePath.pdf';
          }
        }
      } else {
        targetSavePath = _originalFilePath ?? _filePath;
      }

      if (targetSavePath != null) {
        final String finalPath = targetSavePath;
        final int lastPage = _currentPage;

        if (!saveAs) {
          setState(() => _filePath = null);
          await Future.delayed(const Duration(milliseconds: 150));
        }

        final outFile = File(finalPath);
        await outFile.writeAsBytes(signedBytes, flush: true);

        final savedSizeKb = signedBytes.length / 1024;
        final savedSizeText = savedSizeKb > 1024
            ? '${(savedSizeKb / 1024).toStringAsFixed(2)} MB'
            : '${savedSizeKb.toStringAsFixed(0)} KB';

        if (!saveAs && mounted) {
          setState(() {
            _filePath = finalPath;
            _placedSignatures.clear();
            _selectedSigId = null;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.delayed(const Duration(milliseconds: 200), () => _goToPage(lastPage));
          });
        }

        if (mounted) {
          _showToast(
            saveAs
                ? 'Berhasil disimpan ($savedSizeText): ${finalPath.split(Platform.pathSeparator).last}'
                : 'File berhasil diperbarui ($savedSizeText)',
            actionLabel: saveAs ? 'Buka File' : null,
            onAction: saveAs
                ? () {
                    setState(() {
                      _filePath = finalPath;
                      _fileName = finalPath.split(Platform.pathSeparator).last;
                      _placedSignatures.clear();
                      _selectedSigId = null;
                    });
                  }
                : null,
          );
        }
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showToast('Gagal menyimpan PDF: $e');
    }
  }

  void _openSignatureManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.draw_outlined),
                        const SizedBox(width: 10),
                        Text(
                          'Koleksi Tanda Tangan',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            final newBytes = await showDialog<Uint8List>(
                              context: context,
                              builder: (_) => const DrawSignatureDialog(),
                            );
                            if (newBytes != null) {
                              await _saveSignatureToBank(newBytes);
                              setModalState(() {});
                            }
                          },
                          icon: const Icon(Icons.gesture),
                          label: const Text('Buat Coretan Baru'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final res = await FilePicker.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['png'],
                            );
                            if (res != null && res.isNotEmpty && res.single.path != null) {
                              final bytes = await File(res.single.path!).readAsBytes();
                              await _saveSignatureToBank(bytes);
                              setModalState(() {});
                            }
                          },
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Upload PNG'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Pilih tanda tangan untuk mulai menempelkan ke halaman PDF:',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                    const SizedBox(height: 12),
                    if (_savedSignatureFiles.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 36),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Column(
                          children: [
                            Icon(Icons.inbox_outlined, size: 40, color: Colors.grey),
                            SizedBox(height: 8),
                            Text('Belum ada tanda tangan tersimpan'),
                          ],
                        ),
                      )
                    else
                      SizedBox(
                        height: 125,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _savedSignatureFiles.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 12),
                          itemBuilder: (context, index) {
                            final file = _savedSignatureFiles[index];
                            final bytes = file.readAsBytesSync();
                            return InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                Navigator.pop(ctx);
                                setState(() => _activeSignatureBytes = bytes);
                                _showToast('Mode Tempel Aktif: Klik pada halaman PDF untuk meletakkan tanda tangan.');
                              },
                              child: Container(
                                width: 170,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12.0),
                                        child: Image.memory(bytes, fit: BoxFit.contain),
                                      ),
                                    ),
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: IconButton.filledTonal(
                                        visualDensity: VisualDensity.compact,
                                        iconSize: 16,
                                        tooltip: 'Hapus dari koleksi',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () async {
                                          await _deleteSavedSignature(file);
                                          setModalState(() {});
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String? _extractDocxXmlPureDart(Uint8List bytes) {
    try {
      int i = 0;
      while (i < bytes.length - 30) {
        if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 0x03 && bytes[i + 3] == 0x04) {
          final compression = bytes[i + 8] | (bytes[i + 9] << 8);
          final compSize = bytes[i + 18] | (bytes[i + 19] << 8) | (bytes[i + 20] << 16) | (bytes[i + 21] << 24);
          final nameLen = bytes[i + 26] | (bytes[i + 27] << 8);
          final extraLen = bytes[i + 28] | (bytes[i + 29] << 8);
          final nameStart = i + 30;
          if (nameStart + nameLen > bytes.length) break;

          final fileName = utf8.decode(bytes.sublist(nameStart, nameStart + nameLen), allowMalformed: true);
          final dataStart = nameStart + nameLen + extraLen;

          if (fileName == 'word/document.xml' && compSize > 0 && dataStart + compSize <= bytes.length) {
            final compData = bytes.sublist(dataStart, dataStart + compSize);
            List<int> decompressed;
            if (compression == 0) {
              decompressed = compData;
            } else {
              decompressed = ZLibCodec(raw: true).decode(compData);
            }
            return utf8.decode(decompressed, allowMalformed: true);
          }
          i = (compSize > 0) ? (dataStart + compSize) : (dataStart + 1);
        } else {
          i++;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _extractTextFromWord(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (path.toLowerCase().endsWith('.docx')) {
        final xmlContent = _extractDocxXmlPureDart(bytes);
        if (xmlContent != null && xmlContent.isNotEmpty) {
          final text = xmlContent
              .replaceAll(RegExp(r'</w:p>'), '\n\n')
              .replaceAll(RegExp(r'<w:br[^>]*/>'), '\n')
              .replaceAll(RegExp(r'<w:tab[^>]*/>'), '    ')
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll('&amp;', '&')
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&quot;', '"')
              .replaceAll('&apos;', "'");
          if (text.trim().isNotEmpty) return text.trim();
        }
      }
      final raw = utf8.decode(bytes, allowMalformed: true);
      final clean = raw.replaceAll(RegExp(r'[^\x20-\x7E\n\r\t]'), ' ').replaceAll(RegExp(r' {3,}'), '\n');
      return clean.trim().isEmpty ? 'Dokumen Word' : clean.trim();
    } catch (e) {
      return 'Gagal mengekstrak teks: $e';
    }
  }

  Future<Uint8List?> _tryConvertWordToPdfWindows(String inputPath) async {
    if (!Platform.isWindows) return null;
    final outPath = '${Directory.systemTemp.path}\\word_conv_${DateTime.now().millisecondsSinceEpoch}.pdf';
    try {
      final escapedIn = inputPath.replaceAll("'", "''");
      final escapedOut = outPath.replaceAll("'", "''");
      final script = '''
\$ErrorActionPreference = 'Stop'
\$word = New-Object -ComObject Word.Application
\$word.Visible = \$false
\$doc = \$word.Documents.Open('$escapedIn', \$false, \$true)
\$doc.SaveAs([ref] '$escapedOut', [ref] 17)
\$doc.Close(\$false)
\$word.Quit()
''';
      final res = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script])
          .timeout(const Duration(seconds: 25));

      if (res.exitCode == 0 && await File(outPath).exists()) {
        final bytes = await File(outPath).readAsBytes();
        await File(outPath).delete();
        return bytes;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _openInsertPageModal() async {
    if (_filePath == null || _totalPages <= 0) return;

    int insertPosOption = 1;
    final afterPageCtrl = TextEditingController(text: _currentPage.toString());

    final bool? proceedToPick = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.post_add_outlined),
                  SizedBox(width: 10),
                  Expanded(child: Text('Tambah / Sisipkan Halaman')),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Pilih posisi penyisipan halaman baru:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Di Awal Dokumen'),
                        value: 0,
                        groupValue: insertPosOption,
                        onChanged: (val) => setModalState(() => insertPosOption = val!),
                      ),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Di Antara / Setelah Halaman'),
                        value: 1,
                        groupValue: insertPosOption,
                        onChanged: (val) => setModalState(() => insertPosOption = val!),
                      ),
                      if (insertPosOption == 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 36, right: 8, bottom: 8, top: 4),
                          child: TextField(
                            controller: afterPageCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: 'Sisipkan setelah nomor halaman (1 - $_totalPages)',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Di Akhir Dokumen'),
                        value: 2,
                        groupValue: insertPosOption,
                        onChanged: (val) => setModalState(() => insertPosOption = val!),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Batal'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Pilih File...'),
                ),
              ],
            );
          },
        );
      },
    );

    if (proceedToPick != true || !mounted) return;

    int insertAfterPage = _currentPage;
    if (insertPosOption == 0) {
      insertAfterPage = 0;
    } else if (insertPosOption == 1) {
      insertAfterPage = (int.tryParse(afterPageCtrl.text) ?? _currentPage).clamp(0, _totalPages);
    } else {
      insertAfterPage = _totalPages;
    }

    final pickResult = await FilePicker.pickFiles(
      dialogTitle: 'Pilih File PDF, Gambar, atau Word',
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'docx', 'doc'],
    );

    if (pickResult == null || pickResult.isEmpty || pickResult.single.path == null) return;

    final pickedPath = pickResult.single.path!;
    final ext = pickedPath.split('.').last.toLowerCase();

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Menyisipkan halaman ke dalam dokumen...')),
          ],
        ),
      ),
    );

    try {
      Uint8List? insertPdfBytes;

      if (ext == 'pdf') {
        insertPdfBytes = await File(pickedPath).readAsBytes();
      } else if (['png', 'jpg', 'jpeg', 'webp'].contains(ext)) {
        final imgBytes = await File(pickedPath).readAsBytes();
        final tempDoc = sf.PdfDocument();
        tempDoc.pageSettings.margins.all = 0;
        final bitmap = sf.PdfBitmap(imgBytes);
        tempDoc.pageSettings.orientation = bitmap.width > bitmap.height
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;

        final page = tempDoc.pages.add();
        final pageSize = page.getClientSize();
        final imgAspect = bitmap.width / bitmap.height;
        final pageAspect = pageSize.width / pageSize.height;
        double drawW = pageSize.width;
        double drawH = pageSize.height;
        if (imgAspect > pageAspect) {
          drawH = drawW / imgAspect;
        } else {
          drawW = drawH * imgAspect;
        }
        page.graphics.drawImage(bitmap, Rect.fromLTWH((pageSize.width - drawW) / 2, (pageSize.height - drawH) / 2, drawW, drawH));
        insertPdfBytes = Uint8List.fromList(await tempDoc.save());
        tempDoc.dispose();
      } else if (ext == 'docx' || ext == 'doc') {
        insertPdfBytes = await _tryConvertWordToPdfWindows(pickedPath);
        if (insertPdfBytes == null) {
          final extractedText = await _extractTextFromWord(pickedPath);
          final tempDoc = sf.PdfDocument();
          final page = tempDoc.pages.add();
          final font = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 11);
          sf.PdfTextElement(text: extractedText, font: font, brush: sf.PdfBrushes.black).draw(
            page: page,
            bounds: Rect.fromLTWH(0, 0, page.getClientSize().width, page.getClientSize().height),
            format: sf.PdfLayoutFormat(layoutType: sf.PdfLayoutType.paginate),
          );
          insertPdfBytes = Uint8List.fromList(await tempDoc.save());
          tempDoc.dispose();
        }
      }

      if (insertPdfBytes == null) throw Exception('Format file tidak dapat diproses.');

      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final insDoc = sf.PdfDocument(inputBytes: insertPdfBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      void copyPageToOut(sf.PdfPage srcPage) {
        final section = outDoc.sections!.add();
        section.pageSettings.margins.all = 0;
        final rawSize = srcPage.size;
        section.pageSettings.orientation = rawSize.width > rawSize.height
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;
        section.pageSettings.size = Size(
          rawSize.width > rawSize.height ? rawSize.height : rawSize.width,
          rawSize.width > rawSize.height ? rawSize.width : rawSize.height,
        );
        final newPage = section.pages.add();
        newPage.graphics.drawPdfTemplate(srcPage.createTemplate(), Offset.zero);
      }

      final int baseCount = baseDoc.pages.count;
      final int addedCount = insDoc.pages.count;

      if (insertAfterPage <= 0) {
        for (int j = 0; j < addedCount; j++) copyPageToOut(insDoc.pages[j]);
      }

      for (int i = 0; i < baseCount; i++) {
        copyPageToOut(baseDoc.pages[i]);
        if (i + 1 == insertAfterPage) {
          for (int j = 0; j < addedCount; j++) copyPageToOut(insDoc.pages[j]);
        }
      }

      final mergedBytes = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      insDoc.dispose();
      outDoc.dispose();

      for (final sig in _placedSignatures) {
        if (sig.pageNumber > insertAfterPage) sig.pageNumber += addedCount;
      }

      final tempWorkFile = File('${Directory.systemTemp.path}${Platform.pathSeparator}working_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await tempWorkFile.writeAsBytes(mergedBytes, flush: true);

      if (mounted) Navigator.pop(context);

      setState(() => _filePath = tempWorkFile.path);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 250), () => _goToPage(insertAfterPage + 1));
      });

      _showToast('Berhasil menyisipkan $addedCount halaman');
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showToast('Gagal menyisipkan halaman: $e');
    }
  }

  void _copyPageToDoc(sf.PdfDocument outDoc, sf.PdfPage srcPage) {
    final section = outDoc.sections!.add();
    section.pageSettings.margins.all = 0;
    final rawSize = srcPage.size;
    section.pageSettings.orientation = rawSize.width > rawSize.height
        ? sf.PdfPageOrientation.landscape
        : sf.PdfPageOrientation.portrait;
    section.pageSettings.size = Size(
      rawSize.width > rawSize.height ? rawSize.height : rawSize.width,
      rawSize.width > rawSize.height ? rawSize.width : rawSize.height,
    );
    section.pageSettings.rotate = srcPage.rotation;
    final newPage = section.pages.add();
    newPage.graphics.drawPdfTemplate(srcPage.createTemplate(), Offset.zero);
  }

  Future<void> _applyModifiedPdfBytes(Uint8List bytes, int targetPage, String toastMsg) async {
    final tempWorkFile = File('${Directory.systemTemp.path}${Platform.pathSeparator}working_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await tempWorkFile.writeAsBytes(bytes, flush: true);

    setState(() => _filePath = tempWorkFile.path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 250), () => _goToPage(targetPage));
    });
    _showToast(toastMsg);
  }

  Future<void> _rotatePdfPages({required bool clockwise, bool allPages = false}) async {
    if (_filePath == null) return;
    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final doc = sf.PdfDocument(inputBytes: originalBytes);
      doc.fileStructure.incrementalUpdate = false;

      final angles = [
        sf.PdfPageRotateAngle.rotateAngle0,
        sf.PdfPageRotateAngle.rotateAngle90,
        sf.PdfPageRotateAngle.rotateAngle180,
        sf.PdfPageRotateAngle.rotateAngle270,
      ];

      final startIdx = allPages ? 0 : (_currentPage - 1);
      final endIdx = allPages ? (doc.pages.count - 1) : (_currentPage - 1);

      for (int i = startIdx; i <= endIdx; i++) {
        if (i >= 0 && i < doc.pages.count) {
          final page = doc.pages[i];
          final currentIdx = angles.indexOf(page.rotation);
          final nextIdx = clockwise ? (currentIdx + 1) % 4 : (currentIdx + 3) % 4;
          page.rotation = angles[nextIdx];
        }
      }

      final saved = Uint8List.fromList(await doc.save());
      doc.dispose();
      await _applyModifiedPdfBytes(saved, _currentPage, allPages ? 'Semua halaman diputar' : 'Halaman diputar');
    } catch (e) {
      _showToast('Gagal memutar halaman: $e');
    }
  }

  Future<void> _insertBlankPage() async {
    if (_filePath == null) return;
    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      final int targetIdx = _currentPage - 1;
      for (int i = 0; i < baseDoc.pages.count; i++) {
        _copyPageToDoc(outDoc, baseDoc.pages[i]);
        if (i == targetIdx) {
          final refSize = baseDoc.pages[i].size;
          final section = outDoc.sections!.add();
          section.pageSettings.margins.all = 0;
          section.pageSettings.orientation = refSize.width > refSize.height
              ? sf.PdfPageOrientation.landscape
              : sf.PdfPageOrientation.portrait;
          section.pageSettings.size = Size(
            refSize.width > refSize.height ? refSize.height : refSize.width,
            refSize.width > refSize.height ? refSize.width : refSize.height,
          );
          section.pages.add();
        }
      }

      for (final sig in _placedSignatures) {
        if (sig.pageNumber > _currentPage) sig.pageNumber += 1;
      }

      final saved = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      outDoc.dispose();
      await _applyModifiedPdfBytes(saved, _currentPage + 1, 'Halaman kosong ditambahkan');
    } catch (e) {
      _showToast('Gagal menambah halaman: $e');
    }
  }

  Future<void> _duplicateCurrentPage() async {
    if (_filePath == null) return;
    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      final int targetIdx = _currentPage - 1;
      for (int i = 0; i < baseDoc.pages.count; i++) {
        _copyPageToDoc(outDoc, baseDoc.pages[i]);
        if (i == targetIdx) _copyPageToDoc(outDoc, baseDoc.pages[i]);
      }

      for (final sig in _placedSignatures) {
        if (sig.pageNumber > _currentPage) sig.pageNumber += 1;
      }

      final saved = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      outDoc.dispose();
      await _applyModifiedPdfBytes(saved, _currentPage + 1, 'Halaman diduplikat');
    } catch (e) {
      _showToast('Gagal menduplikat: $e');
    }
  }

  Future<void> _deleteCurrentPage() async {
    if (_filePath == null) return;
    if (_totalPages <= 1) {
      _showToast('Tidak bisa menghapus satu-satunya halaman.');
      return;
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Halaman'),
        content: Text('Yakin ingin menghapus Halaman $_currentPage?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      final int removeIdx = _currentPage - 1;
      for (int i = 0; i < baseDoc.pages.count; i++) {
        if (i != removeIdx) _copyPageToDoc(outDoc, baseDoc.pages[i]);
      }

      _placedSignatures.removeWhere((s) => s.pageNumber == _currentPage);
      for (final sig in _placedSignatures) {
        if (sig.pageNumber > _currentPage) sig.pageNumber -= 1;
      }

      final saved = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      outDoc.dispose();
      await _applyModifiedPdfBytes(saved, _currentPage > 1 ? _currentPage - 1 : 1, 'Halaman dihapus');
    } catch (e) {
      _showToast('Gagal menghapus: $e');
    }
  }

  Future<void> _moveCurrentPageDialog() async {
    if (_filePath == null || _totalPages <= 1) return;

    final targetCtrl = TextEditingController(text: _currentPage.toString());
    final int? targetPage = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pindahkan Halaman $_currentPage'),
        content: TextField(
          controller: targetCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Pindah ke urutan halaman', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(targetCtrl.text)), child: const Text('Pindahkan')),
        ],
      ),
    );

    if (targetPage == null) return;
    final int newPos = targetPage.clamp(1, _totalPages);
    if (newPos == _currentPage) return;

    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      final List<int> order = List.generate(baseDoc.pages.count, (i) => i);
      final int movedIdx = order.removeAt(_currentPage - 1);
      order.insert(newPos - 1, movedIdx);

      for (final idx in order) _copyPageToDoc(outDoc, baseDoc.pages[idx]);

      for (final sig in _placedSignatures) {
        final oldIdx = sig.pageNumber - 1;
        final updatedPos = order.indexOf(oldIdx);
        if (updatedPos != -1) sig.pageNumber = updatedPos + 1;
      }

      final saved = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      outDoc.dispose();
      await _applyModifiedPdfBytes(saved, newPos, 'Halaman dipindahkan');
    } catch (e) {
      _showToast('Gagal memindahkan: $e');
    }
  }

  Future<void> _extractCurrentPageToPdf() async {
    if (_filePath == null) return;
    try {
      final originalBytes = await File(_filePath!).readAsBytes();
      final baseDoc = sf.PdfDocument(inputBytes: originalBytes);
      final outDoc = sf.PdfDocument();
      outDoc.pageSettings.margins.all = 0;

      _copyPageToDoc(outDoc, baseDoc.pages[_currentPage - 1]);
      final extractedBytes = Uint8List.fromList(await outDoc.save());
      baseDoc.dispose();
      outDoc.dispose();

      final Uri? saveUri = await FilePicker.saveFile(
        dialogTitle: 'Ekstrak Halaman Sebagai PDF',
        fileName: 'Hal_${_currentPage}_${_fileName ?? "document.pdf"}',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: extractedBytes,
      );

      if (saveUri != null) {
        String savePath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
        if (!savePath.toLowerCase().endsWith('.pdf')) savePath = '$savePath.pdf';
        await File(savePath).writeAsBytes(extractedBytes, flush: true);
        _showToast('Halaman berhasil diekstrak!');
      }
    } catch (e) {
      _showToast('Gagal mengekstrak: $e');
    }
  }

  void _openPageManagerModal() {
    if (_filePath == null || _totalPages <= 0) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.layers_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Kelola Halaman (Hal $_currentPage dari $_totalPages)',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                    ],
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.post_add_outlined, color: Colors.indigo),
                    title: const Text('Sisipkan File (PDF / Gambar / Word)'),
                    onTap: () { Navigator.pop(ctx); _openInsertPageModal(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.note_add_outlined, color: Colors.teal),
                    title: const Text('Tambah Halaman Kosong'),
                    onTap: () { Navigator.pop(ctx); _insertBlankPage(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.copy_all_outlined, color: Colors.blue),
                    title: const Text('Duplikat Halaman Ini'),
                    onTap: () { Navigator.pop(ctx); _duplicateCurrentPage(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.low_priority_outlined, color: Colors.orange),
                    title: const Text('Pindahkan Urutan Halaman...'),
                    onTap: () { Navigator.pop(ctx); _moveCurrentPageDialog(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.ios_share_outlined, color: Colors.deepPurple),
                    title: const Text('Ekstrak Halaman ke PDF Baru'),
                    onTap: () { Navigator.pop(ctx); _extractCurrentPageToPdf(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
                    title: const Text('Hapus Halaman Ini', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
                    onTap: () { Navigator.pop(ctx); _deleteCurrentPage(); },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final bool shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_fileName ?? 'Fajar PDF Reader', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          centerTitle: false,
          actions: [
            IconButton(
              tooltip: 'Buka File PDF',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _pickPdfFile,
            ),
            IconButton(
              tooltip: 'Riwayat File Dibuka',
              icon: const Icon(Icons.history),
              onPressed: _openHistoryModal,
            ),
            if (_filePath != null) ...[
              IconButton(
                tooltip: 'Bagikan Dokumen (Share)',
                icon: const Icon(Icons.share_outlined),
                onPressed: _shareCurrentPdf,
              ),
              IconButton(
                tooltip: 'Kelola Halaman',
                icon: const Icon(Icons.layers_outlined),
                onPressed: _openPageManagerModal,
              ),
              IconButton(
                tooltip: 'Kelola Tanda Tangan',
                icon: const Icon(Icons.draw_outlined),
                onPressed: _openSignatureManager,
              ),
              IconButton(
                tooltip: 'Save (Simpan)',
                onPressed: () => _exportSignedPdf(saveAs: false),
                icon: const Icon(Icons.save_outlined),
              ),
              IconButton(
                tooltip: 'Save As (Simpan Sebagai)',
                onPressed: () => _exportSignedPdf(saveAs: true),
                icon: const Icon(Icons.save_as_outlined),
              ),
            ],
            PopupMenuButton<ThemeMode>(
              tooltip: 'Tema Tampilan',
              icon: Icon(
                widget.currentThemeMode == ThemeMode.dark
                    ? Icons.dark_mode_outlined
                    : widget.currentThemeMode == ThemeMode.light
                        ? Icons.light_mode_outlined
                        : Icons.brightness_auto_outlined,
              ),
              onSelected: widget.onThemeChanged,
              itemBuilder: (context) => [
                const CheckedPopupMenuItem(value: ThemeMode.system, child: Text('Ikuti Sistem')),
                const CheckedPopupMenuItem(value: ThemeMode.light, child: Text('Mode Terang')),
                const CheckedPopupMenuItem(value: ThemeMode.dark, child: Text('Mode Gelap')),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Stack(
          children: [
            _filePath == null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(28.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(18),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(Icons.picture_as_pdf_outlined, size: 44, color: Theme.of(context).colorScheme.primary),
                                    ),
                                    const SizedBox(height: 16),
                                    Text('Belum Ada Dokumen', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Buka file PDF untuk membaca, mengatur halaman, atau membubuhkan tanda tangan digital.',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                                    ),
                                    const SizedBox(height: 20),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FilledButton.icon(
                                        onPressed: _pickPdfFile,
                                        icon: const Icon(Icons.file_open_outlined),
                                        label: const Text('Pilih File PDF'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : GestureDetector(
                    onTap: () => setState(() => _selectedSigId = null),
                    child: PdfViewer.file(
                      _filePath!,
                      controller: _pdfController,
                      params: PdfViewerParams(
                        maxScale: 5.0,
                        minScale: 0.5,
                        onViewerReady: (document, controller) {
                          setState(() {
                            _totalPages = document.pages.length;
                            _currentPage = controller.pageNumber ?? 1;
                          });
                        },
                        onPageChanged: (pageNumber) {
                          if (pageNumber != null) setState(() => _currentPage = pageNumber);
                        },
                        viewerOverlayBuilder: (context, size, handleLinkTap) => [
                          PdfViewerScrollThumb(
                            controller: _pdfController,
                            orientation: ScrollbarOrientation.right,
                            thumbSize: const Size(44, 28),
                            thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${pageNumber ?? _currentPage}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                        pageOverlaysBuilder: (context, pageRect, page) {
                          final sigsOnPage = _placedSignatures.where((s) => s.pageNumber == page.pageNumber).toList();
                          List<Widget> overlays = [];

                          if (_activeSignatureBytes != null) {
                            overlays.add(
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) {
                                    final bytes = _activeSignatureBytes!;
                                    ui.decodeImageFromList(bytes, (ui.Image img) {
                                      final aspect = img.width / img.height;
                                      final tapX = details.localPosition.dx / pageRect.width;
                                      final tapY = details.localPosition.dy / pageRect.height;

                                      const initRelWidth = 0.24;
                                      final initPixelWidth = initRelWidth * pageRect.width;
                                      final initPixelHeight = initPixelWidth / aspect;
                                      final initRelHeight = initPixelHeight / pageRect.height;

                                      final newSig = PlacedSignature(
                                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                                        pageNumber: page.pageNumber,
                                        imageBytes: bytes,
                                        aspectRatio: aspect,
                                        relX: (tapX - (initRelWidth / 2)).clamp(0.0, 1.0 - initRelWidth),
                                        relY: (tapY - (initRelHeight / 2)).clamp(0.0, 1.0 - initRelHeight),
                                        relWidth: initRelWidth,
                                        relHeight: initRelHeight,
                                        rotation: 0.0,
                                      );

                                      setState(() {
                                        _placedSignatures.add(newSig);
                                        _selectedSigId = newSig.id;
                                        _activeSignatureBytes = null;
                                      });
                                    });
                                  },
                                  child: Container(
                                    color: Colors.indigo.withValues(alpha: 0.08),
                                    alignment: Alignment.topCenter,
                                    padding: const EdgeInsets.all(8),
                                    child: Chip(
                                      backgroundColor: Theme.of(context).colorScheme.primary,
                                      label: Text(
                                        'Ketuk untuk menempelkan Tanda Tangan (Hal ${page.pageNumber})',
                                        style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }

                          for (final sig in sigsOnPage) {
                            final isSelected = _selectedSigId == sig.id;
                            final width = sig.relWidth * pageRect.width;
                            final height = sig.relHeight * pageRect.height;
                            final left = sig.relX * pageRect.width;
                            final top = sig.relY * pageRect.height;

                            overlays.add(
                              Positioned(
                                left: left,
                                top: top,
                                width: width,
                                height: height,
                                child: Transform.rotate(
                                  angle: sig.rotation,
                                  alignment: Alignment.center,
                                  child: GestureDetector(
                                    onTap: () => setState(() => _selectedSigId = sig.id),
                                    onPanUpdate: (details) {
                                      setState(() {
                                        _selectedSigId = sig.id;
                                        sig.relX = (sig.relX + details.delta.dx / pageRect.width).clamp(0.0, (1.0 - sig.relWidth).clamp(0.0, 1.0));
                                        sig.relY = (sig.relY + details.delta.dy / pageRect.height).clamp(0.0, (1.0 - sig.relHeight).clamp(0.0, 1.0));
                                      });
                                    },
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            border: isSelected ? Border.all(color: Colors.blueAccent, width: 1.5) : null,
                                            color: isSelected ? Colors.blue.withValues(alpha: 0.05) : Colors.transparent,
                                          ),
                                          child: SizedBox.expand(
                                            child: Image.memory(sig.imageBytes, fit: BoxFit.fill),
                                          ),
                                        ),
                                        if (isSelected) ...[
                                          Align(
                                            alignment: Alignment.topCenter,
                                            child: Transform.translate(
                                              offset: const Offset(0, -16),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.alias,
                                                child: GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onPanUpdate: (details) {
                                                    setState(() => sig.rotation += details.delta.dx * 0.03);
                                                  },
                                                  child: Padding(
                                                    padding: const EdgeInsets.all(10.0),
                                                    child: Container(
                                                      width: 24,
                                                      height: 24,
                                                      decoration: BoxDecoration(
                                                        color: Colors.blueAccent,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white, width: 2),
                                                      ),
                                                      child: const Icon(Icons.rotate_right, size: 14, color: Colors.white),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            top: -10,
                                            right: -10,
                                            child: GestureDetector(
                                              onTap: () => setState(() => _placedSignatures.remove(sig)),
                                              child: const CircleAvatar(
                                                radius: 10,
                                                backgroundColor: Colors.redAccent,
                                                child: Icon(Icons.close, size: 12, color: Colors.white),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          return overlays;
                        },
                      ),
                    ),
                  ),
          ],
        ),
        bottomNavigationBar: _filePath == null || _totalPages == 0
            ? null
            : Container(
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 0.8),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.first_page),
                      onPressed: _currentPage > 1 ? () => _goToPage(1) : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _showJumpPageDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: Text('Halaman $_currentPage / $_totalPages', style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: _currentPage < _totalPages ? () => _goToPage(_currentPage + 1) : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.last_page),
                      onPressed: _currentPage < _totalPages ? () => _goToPage(_totalPages) : null,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class DrawSignatureDialog extends StatefulWidget {
  const DrawSignatureDialog({super.key});

  @override
  State<DrawSignatureDialog> createState() => _DrawSignatureDialogState();
}

class _DrawSignatureDialogState extends State<DrawSignatureDialog> {
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];
  Color _penColor = Colors.black;
  final double _strokeWidth = 3.0;
  final GlobalKey _canvasKey = GlobalKey();

  Future<Uint8List?> _exportToPngBytes() async {
    if (_strokes.isEmpty) return null;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? const Size(450, 220);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
    final paint = Paint()
      ..color = _penColor
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = _strokeWidth
      ..style = PaintingStyle.stroke;

    for (final stroke in _strokes) {
      if (stroke.length > 1) {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (int i = 1; i < stroke.length; i++) path.lineTo(stroke[i].dx, stroke[i].dy);
        canvas.drawPath(path, paint);
      } else if (stroke.isNotEmpty) {
        canvas.drawPoints(ui.PointMode.points, stroke, paint);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Gambar Tanda Tangan'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Tinta:'),
                    const SizedBox(width: 10),
                    _buildColorCircle(Colors.black, 'Hitam'),
                    const SizedBox(width: 8),
                    _buildColorCircle(Colors.blue.shade800, 'Biru'),
                    const SizedBox(width: 8),
                    _buildColorCircle(Colors.red.shade800, 'Merah'),
                  ],
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _strokes.clear()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Bersihkan'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              key: _canvasKey,
              height: 200,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: GestureDetector(
                  onPanStart: (details) => setState(() {
                    _currentStroke = [details.localPosition];
                    _strokes.add(_currentStroke);
                  }),
                  onPanUpdate: (details) => setState(() => _currentStroke.add(details.localPosition)),
                  child: CustomPaint(
                    painter: _SignaturePainter(strokes: _strokes, color: _penColor, strokeWidth: _strokeWidth),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: () async {
            final bytes = await _exportToPngBytes();
            if (context.mounted) Navigator.pop(context, bytes);
          },
          icon: const Icon(Icons.check),
          label: const Text('Simpan Tanda Tangan'),
        ),
      ],
    );
  }

  Widget _buildColorCircle(Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => setState(() => _penColor = color),
        child: CircleAvatar(
          radius: 14,
          backgroundColor: color,
          child: _penColor == color ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  final double strokeWidth;

  _SignaturePainter({required this.strokes, required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.length > 1) {
        final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
        for (int i = 1; i < stroke.length; i++) path.lineTo(stroke[i].dx, stroke[i].dy);
        canvas.drawPath(path, paint);
      } else if (stroke.isNotEmpty) {
        canvas.drawPoints(ui.PointMode.points, stroke, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}