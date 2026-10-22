import 'dart:convert';
import 'dart:io';
//import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:share_plus/share_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:printing/printing.dart';
import 'package:archive/archive.dart';

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
  String? _sharedFilepath;

  @override
  void initState() {
    super.initState();
    _sharedFilepath = widget.initialFilepath;

    if (Platform.isAndroid || Platform.isIOS) {
      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (value.isNotEmpty && value.first.path.isNotEmpty) {
          setState(() {
            _sharedFilepath = value.first.path;
          });
        }
        ReceiveSharingIntent.instance.reset();
      });

      ReceiveSharingIntent.instance.getMediaStream().listen((value) {
        if (value.isNotEmpty && value.first.path.isNotEmpty) {
          setState(() {
            _sharedFilepath = value.first.path;
          });
        }
      }, onError: (err) {
        debugPrint("Error sharing intent: $err");
      });
    }
  }

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
        initialFilepath: _sharedFilepath,
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
  double _currentZoom = 1.0;
  PdfTextSearcher? _textSearcher;
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

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

  @override
  void didUpdateWidget(covariant PdfViewerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFilepath != null && widget.initialFilepath != oldWidget.initialFilepath) {
      _openPdfFromPath(widget.initialFilepath!);
    }
  }

  void _goToPage(int page) {
    if (_pdfController.isReady && _totalPages > 0) {
      final target = page.clamp(1, _totalPages);
      _pdfController.goToPage(pageNumber: target);
    }
  }

  void _setZoomValue(double val) {
    if (_pdfController.isReady) {
      final clamped = val.clamp(0.5, 4.0);
      setState(() => _currentZoom = clamped);
      _pdfController.setZoom(Offset.zero, clamped);
    }
  }

  void _zoomIn() {
    if (_pdfController.isReady) {
      _setZoomValue(_currentZoom + 0.25);
    }
  }

  void _zoomOut() {
    if (_pdfController.isReady) {
      _setZoomValue(_currentZoom - 0.25);
    }
  }

  void _resetZoom() {
    if (_pdfController.isReady) {
      _setZoomValue(1.0);
    }
  }

  void _showJumpPageDialog() {
    if (_totalPages <= 0) return;
    final textController = TextEditingController(text: _currentPage.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Jump to Page'),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Enter page number (1 - $_totalPages)',
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(textController.text);
              if (page != null) _goToPage(page);
              Navigator.pop(ctx);
            },
            child: const Text('Jump'),
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
      _showToast('File not found or has been moved.');
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
      _currentZoom = 1.0;
      _isSearching = false;
      _searchController.clear();
      _textSearcher?.resetTextSearch();
      _textSearcher = null;
    });
    _addToRecentFiles(path, name);
  }

  Future<void> _shareCurrentPdf() async {
    if (_filePath == null) return;
    try {
      final xFile = XFile(_filePath!);
      await Share.shareXFiles([xFile], text: 'PDF Document: $_fileName');
    } catch (e) {
      _showToast('Failed to share file: $e');
    }
  }

  Future<void> _printCurrentPdf() async {
    if (_filePath == null) return;
    try {
      final file = File(_filePath!);
      if (!await file.exists()) {
        _showToast('Document file not found.');
        return;
      }
      final bytes = await file.readAsBytes();
      await Printing.layoutPdf(
        name: _fileName ?? 'Document',
        onLayout: (format) async => bytes,
      );
    } catch (e) {
      _showToast('Failed to print document: $e');
    }
  }

  Future<void> _convertPdfToImages() async {
    if (_filePath == null || _totalPages <= 0) return;

    bool convertAll = true;
    final pagesCtrl = TextEditingController(text: '1-$_totalPages');

    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.image_outlined, color: Colors.blueAccent),
                  SizedBox(width: 10),
                  Text('Convert PDF to Image'),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pilih halaman yang ingin dikonversi ke gambar:'),
                    const SizedBox(height: 12),
                    RadioListTile<bool>(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Semua Halaman (1 - $_totalPages)'),
                      value: true,
                      groupValue: convertAll,
                      onChanged: (val) => setModalState(() => convertAll = val!),
                    ),
                    RadioListTile<bool>(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Halaman Tertentu'),
                      value: false,
                      groupValue: convertAll,
                      onChanged: (val) => setModalState(() => convertAll = val!),
                    ),
                    if (!convertAll) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                        child: TextField(
                          controller: pagesCtrl,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Contoh: 1, 5, 7 atau 1-3, 5',
                            hintText: '1, 5, 7',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
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
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Pilih Folder & Konversi'),
                ),
              ],
            );
          },
        );
      },
    );

    if (proceed != true) return;

    // Parsing daftar halaman yang dipilih
    final List<int> targetPages = [];
    if (convertAll) {
      targetPages.addAll(List.generate(_totalPages, (i) => i + 1));
    } else {
      final input = pagesCtrl.text.replaceAll(' ', '');
      final parts = input.split(',');
      for (final part in parts) {
        if (part.contains('-')) {
          final range = part.split('-');
          if (range.length == 2) {
            final start = int.tryParse(range[0]);
            final end = int.tryParse(range[1]);
            if (start != null && end != null) {
              final minP = start < end ? start : end;
              final maxP = start > end ? start : end;
              for (int p = minP; p <= maxP; p++) {
                if (p >= 1 && p <= _totalPages && !targetPages.contains(p)) {
                  targetPages.add(p);
                }
              }
            }
          }
        } else {
          final pageNum = int.tryParse(part);
          if (pageNum != null && pageNum >= 1 && pageNum <= _totalPages && !targetPages.contains(pageNum)) {
            targetPages.add(pageNum);
          }
        }
      }
      targetPages.sort();
    }

    if (targetPages.isEmpty) {
      _showToast('Nomor halaman tidak valid.');
      return;
    }

    try {
      final String? selectedDirectory = await FilePicker.getDirectoryPath(
        dialogTitle: 'Pilih Folder Tujuan Penyimpanan Gambar',
      );

      if (selectedDirectory == null || selectedDirectory.isEmpty) return;

      final baseName = (_fileName ?? 'Document').replaceAll('.pdf', '');
      final exportFolder = Directory('$selectedDirectory${Platform.pathSeparator}${baseName}_images');
      if (!await exportFolder.exists()) await exportFolder.create(recursive: true);

      final doc = await PdfDocument.openFile(_filePath!);
      int count = 0;

      for (final p in targetPages) {
        final pageIndex = p - 1;
        if (pageIndex < doc.pages.length) {
          final page = doc.pages[pageIndex];
          final pdfImage = await page.render(
            fullWidth: page.width * 2.0,
            fullHeight: page.height * 2.0,
            backgroundColor: 0xFFFFFFFF,
          );
          if (pdfImage != null) {
            final uiImg = await pdfImage.createImage();
            pdfImage.dispose();
            final byteData = await uiImg.toByteData(format: ui.ImageByteFormat.png);
            uiImg.dispose();
            if (byteData != null) {
              final outFile = File('${exportFolder.path}${Platform.pathSeparator}page_$p.png');
              await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
              count++;
            }
          }
        }
      }
      await doc.dispose();
      _showToast('Berhasil disimpan: $count gambar (${targetPages.join(", ")}) di folder ${exportFolder.path}');
    } catch (e) {
      _showToast('Gagal konversi ke Gambar: $e');
    }
  }

  Future<void> _convertPdfToWord() async {
    if (_filePath == null) return;

    final baseName = (_fileName ?? 'Document').replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final Uri? saveUri = await FilePicker.saveFile(
      dialogTitle: 'Save Word Document',
      fileName: '$baseName.docx',
      type: FileType.custom,
      allowedExtensions: ['docx'],
      bytes: Uint8List(0),
    );

    if (saveUri == null) return;
    String finalPath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
    if (!finalPath.toLowerCase().endsWith('.docx')) finalPath = '$finalPath.docx';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Mengonversi PDF ke Word dengan tata letak rapi...')),
          ],
        ),
      ),
    );

    try {
      bool convertedWithNativeWord = false;

      // 1. Prioritaskan mesin konversi Word Reflow bawaan Windows (Format 100% presisi)
      if (Platform.isWindows) {
        final escapedPdf = _filePath!.replaceAll("'", "''");
        final escapedDocx = finalPath.replaceAll("'", "''");

        final script = '''
\$ErrorActionPreference = 'Stop'
\$word = New-Object -ComObject Word.Application
\$word.Visible = \$false
\$doc = \$word.Documents.Open('$escapedPdf', \$false, \$true)
\$doc.SaveAs2([ref] '$escapedDocx', [ref] 16)
\$doc.Close(\$false)
\$word.Quit()
''';
        final res = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script])
            .timeout(const Duration(seconds: 40));

        if (res.exitCode == 0 && await File(finalPath).exists()) {
          convertedWithNativeWord = true;
        }
      }

      // 2. Fallback: Rekonstruksi layout paragraf dan font jika Word COM tidak tersedia
      if (!convertedWithNativeWord) {
        final fileBytes = await File(_filePath!).readAsBytes();
        final sfDoc = sf.PdfDocument(inputBytes: fileBytes);
        final textExtractor = sf.PdfTextExtractor(sfDoc);
        final String extractedText = textExtractor.extractText();
        sfDoc.dispose();

        final cleanText = extractedText
            .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n');

        // Gabungkan baris-baris yang merupakan satu paragraf berkelanjutan agar rapi
        final rawLines = cleanText.split('\n');
        final List<String> paragraphs = [];
        String currentParagraph = '';

        for (final line in rawLines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) {
            if (currentParagraph.isNotEmpty) {
              paragraphs.add(currentParagraph);
              currentParagraph = '';
            }
          } else {
            if (currentParagraph.isEmpty) {
              currentParagraph = trimmed;
            } else {
              // Jika baris sebelumnya tidak berakhiran tanda baca penutup, sambung kalimatnya
              if (!currentParagraph.endsWith('.') && !currentParagraph.endsWith(':') && !currentParagraph.endsWith('?')) {
                currentParagraph += ' $trimmed';
              } else {
                paragraphs.add(currentParagraph);
                currentParagraph = trimmed;
              }
            }
          }
        }
        if (currentParagraph.isNotEmpty) {
          paragraphs.add(currentParagraph);
        }

        final StringBuffer xmlBody = StringBuffer();
        for (final p in paragraphs) {
          final escaped = p
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;')
              .replaceAll("'", '&apos;');

          xmlBody.write(
            '<w:p>'
            '<w:pPr><w:spacing w:after="160" w:line="260" w:lineRule="auto"/><w:jc w:val="both"/></w:pPr>'
            '<w:r>'
            '<w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr>'
            '<w:t xml:space="preserve">$escaped</w:t>'
            '</w:r>'
            '</w:p>',
          );
        }

        final documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body>${xmlBody.toString()}</w:body>'
            '</w:document>';

        final contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '</Types>';

        final relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '</Relationships>';

        final archive = Archive();
        void addFile(String name, String content) {
          final bytes = utf8.encode(content);
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }

        addFile('[Content_Types].xml', contentTypesXml);
        addFile('_rels/.rels', relsXml);
        addFile('word/document.xml', documentXml);

        final zipData = ZipEncoder().encode(archive);
        if (zipData != null) {
          await File(finalPath).writeAsBytes(Uint8List.fromList(zipData), flush: true);
        }
      }

      if (mounted) Navigator.pop(context);
      _showToast('Berhasil diekspor ke Word: ${finalPath.split(Platform.pathSeparator).last}');
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showToast('Gagal konversi ke Word: $e');
    }
  }

  Future<void> _convertPdfToExcel() async {
    if (_filePath == null) return;
    try {
      final fileBytes = await File(_filePath!).readAsBytes();
      final sfDoc = sf.PdfDocument(inputBytes: fileBytes);
      final textExtractor = sf.PdfTextExtractor(sfDoc);
      final String extractedText = textExtractor.extractText();
      sfDoc.dispose();

      final StringBuffer csvBuffer = StringBuffer();
      // UTF-8 BOM agar terbaca sempurna di Microsoft Excel
      csvBuffer.write('\uFEFF');
      final lines = extractedText.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          // Deteksi pemisah spasi ganda/tab sebagai kolom tabel Excel
          final cols = trimmed.split(RegExp(r'\s{2,}|\t'));
          final formattedCols = cols.map((c) => '"${c.replaceAll('"', '""')}"').join(',');
          csvBuffer.writeln(formattedCols);
        }
      }

      final excelBytes = Uint8List.fromList(utf8.encode(csvBuffer.toString()));
      final baseName = (_fileName ?? 'Document').replaceAll('.pdf', '');

      final Uri? saveUri = await FilePicker.saveFile(
        dialogTitle: 'Save Excel/Spreadsheet Document',
        fileName: '$baseName.csv',
        type: FileType.custom,
        allowedExtensions: ['csv', 'xlsx'],
        bytes: excelBytes,
      );

      if (saveUri != null) {
        String finalPath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
        if (!finalPath.toLowerCase().endsWith('.csv') && !finalPath.toLowerCase().endsWith('.xlsx')) {
          finalPath = '$finalPath.csv';
        }

        await File(finalPath).writeAsBytes(excelBytes, flush: true);
        _showToast('Berhasil diekspor ke format Excel (CSV): ${finalPath.split(Platform.pathSeparator).last}');
      }
    } catch (e) {
      _showToast('Gagal konversi ke Excel: $e');
    }
  }

  Future<bool> _onWillPop() async {
    if (_filePath == null) {
      return true;
    }

    if (_placedSignatures.isNotEmpty) {
      final bool? shouldClose = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unsaved Changes'),
          content: const Text(
            'You have signatures or edits that have not been saved to the PDF file. Are you sure you want to close this document?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Close Without Saving'),
            ),
          ],
        ),
      );

      if (shouldClose != true) return false;
    }

    setState(() {
      _filePath = null;
      _fileName = null;
      _placedSignatures.clear();
      _selectedSigId = null;
      _activeSignatureBytes = null;
    });

    return false;
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
                          'Recent Files History',
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
                            label: const Text('Clear All'),
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
                          child: Text('No recent document history.'),
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
                            final name = item['name'] ?? 'Document.pdf';
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
                                tooltip: 'Remove from history',
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

  Future<void> _createNewPdf() async {
  try {
    if (_filePath != null && _placedSignatures.isNotEmpty) {
      bool canProceed = await _onWillPop();
      if (!canProceed) return;
    }

    // Membuat dokumen PDF baru kosong dengan 1 halaman default
    final newDoc = sf.PdfDocument();
    newDoc.pageSettings.margins.all = 0;
    newDoc.pages.add(); // Minimal 1 halaman kosong

    final bytes = Uint8List.fromList(await newDoc.save());
    newDoc.dispose();

    final tempWorkFile = File('${Directory.systemTemp.path}${Platform.pathSeparator}new_document_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await tempWorkFile.writeAsBytes(bytes, flush: true);

    _openPdfFromPath(tempWorkFile.path);
      setState(() {
        _fileName = 'MyDocument.pdf';
        _originalFilePath = null; // Menandakan file baru belum punya path asli
      });
    _showToast('New PDF created successfully. You can now edit or save it.');
  } catch (e) {
    _showToast('Failed to create PDF: $e');
  }
}



Future<void> _pickPdfFile() async {
  try {
    final dynamic pickResult = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (pickResult == null) return;

    String? selectedPath;
    if (pickResult is List && pickResult.isNotEmpty) {
      selectedPath = pickResult.first?.path;
    } else {
      try {
        final files = pickResult.files;
        if (files != null && files.isNotEmpty) {
          selectedPath = files.first.path;
        }
      } catch (_) {
        selectedPath = pickResult.paths?.firstOrNull;
      }
    }

    if (selectedPath == null || selectedPath.isEmpty) return;

    if (_filePath != null && _placedSignatures.isNotEmpty) {
      bool canProceed = await _onWillPop();
      if (!canProceed) return;
    }

    _openPdfFromPath(selectedPath);
  } catch (e, stack) {
    debugPrint('Failed to pick file: $e\n$stack');
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
              title: const Text('Save Options & PDF Compression'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Select PDF save method:'),
                    const SizedBox(height: 16),
                    RadioListTile<bool>(
                      title: const Text('Original Size (Full Quality)'),
                      subtitle: Text(
                          'Estimated: ${originalSizeKb > 1024 ? "${(originalSizeKb / 1024).toStringAsFixed(2)} MB" : "${originalSizeKb.toStringAsFixed(0)} KB"}'),
                      value: true,
                      groupValue: useOriginalSize,
                      onChanged: (val) => setStateModal(() => useOriginalSize = val!),
                    ),
                    RadioListTile<bool>(
                      title: const Text('Shrink Entire PDF'),
                      subtitle: const Text('Compress resolution of all document pages & signatures'),
                      value: false,
                      groupValue: useOriginalSize,
                      onChanged: (val) => setStateModal(() => useOriginalSize = val!),
                    ),
                    if (!useOriginalSize) ...[
                      const SizedBox(height: 10),
                      Text('Compression Scale: ${(scaleFactor * 100).toInt()}%'),
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
                              'Estimated Output Size: $sizeText',
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
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Save File'),
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
            Expanded(child: Text('Processing & compressing PDF document...')),
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

      final savedSizeKb = signedBytes.length / 1024;
      final savedSizeText = savedSizeKb > 1024
          ? '${(savedSizeKb / 1024).toStringAsFixed(2)} MB'
          : '${savedSizeKb.toStringAsFixed(0)} KB';

      // Jika file baru (Create PDF) atau memilih Save As
      if (saveAs || _originalFilePath == null) {
        // Jika file baru, gunakan nama bersih atau biarkan kosong/default yang bagus tanpa kata 'Untitled' kaku
        final defaultName = _originalFilePath == null ? 'MyDocument.pdf' : 'Signed_${_fileName ?? "document.pdf"}';
        final Uri? saveUri = await FilePicker.saveFile(
          dialogTitle: 'Save PDF As',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
          bytes: signedBytes,
        );

        if (saveUri == null) return;

        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          String finalPath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
          if (!finalPath.toLowerCase().endsWith('.pdf')) {
            finalPath = '$finalPath.pdf';
          }
          await File(finalPath).writeAsBytes(signedBytes, flush: true);

          if (mounted) {
            _showToast(
              'Successfully saved ($savedSizeText): ${finalPath.split(Platform.pathSeparator).last}',
              actionLabel: 'Open File',
              onAction: () {
                setState(() {
                  _filePath = finalPath;
                  _fileName = finalPath.split(Platform.pathSeparator).last;
                  _placedSignatures.clear();
                  _selectedSigId = null;
                });
              },
            );
          }
        } else {
          // Setelah file baru disimpan, langsung set acuan path baru dan buka file tersebut otomatis
          final tempDir = await getTemporaryDirectory();
          final saveFileName = _originalFilePath == null ? (_fileName ?? 'Untitled.pdf') : 'Signed_${_fileName ?? "document.pdf"}';
          final tempSavedFile = File('${tempDir.path}${Platform.pathSeparator}$saveFileName');
          await tempSavedFile.writeAsBytes(signedBytes, flush: true);

          if (mounted) {
            setState(() {
              _originalFilePath = tempSavedFile.path;
              _fileName = saveFileName;
              _placedSignatures.clear();
              _selectedSigId = null;
            });
            _openPdfFromPath(tempSavedFile.path);
            _showToast('Successfully saved and opened ($savedSizeText)');
          }
        }
      } else {
        final String finalPath = _originalFilePath ?? _filePath!;
        final int lastPage = _currentPage;

        setState(() => _filePath = null);
        await Future.delayed(const Duration(milliseconds: 150));

        final outFile = File(finalPath);
        await outFile.writeAsBytes(signedBytes, flush: true);

        if (mounted) {
          setState(() {
            _filePath = finalPath;
            _placedSignatures.clear();
            _selectedSigId = null;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.delayed(const Duration(milliseconds: 200), () => _goToPage(lastPage));
          });
          _showToast('File successfully updated ($savedSizeText)');
        }
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showToast('Failed to save PDF: $e');
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
                          'Signature Bank',
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
                          label: const Text('Draw New'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final res = await FilePicker.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['png'],
                            );
                            if (res.isNotEmpty && res.single.path != null) {
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
                      'Select a signature to place onto the PDF page:',
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
                            Text('No saved signatures'),
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
                                _showToast('Stamp Mode Active: Tap on the PDF page to place signature.');
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
                                        tooltip: 'Delete signature',
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
      return clean.trim().isEmpty ? 'Word Document' : clean.trim();
    } catch (e) {
      return 'Failed to extract text: $e';
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
                  Expanded(child: Text('Insert / Add Page')),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Select insertion position:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('At Beginning of Document'),
                        value: 0,
                        groupValue: insertPosOption,
                        onChanged: (val) => setModalState(() => insertPosOption = val!),
                      ),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('After Specific Page'),
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
                              labelText: 'Insert after page (1 - $_totalPages)',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      RadioListTile<int>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('At End of Document'),
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
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose File...'),
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
      dialogTitle: 'Select PDF, Image, or Word File',
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'docx', 'doc'],
    );

    if (pickResult.isEmpty || pickResult.single.path == null) return;

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
            Expanded(child: Text('Inserting page into document...')),
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

      if (insertPdfBytes == null) throw Exception('File format cannot be processed.');

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

      _showToast('Successfully inserted $addedCount page(s)');
    } catch (e) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showToast('Failed to insert page: $e');
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
      await _applyModifiedPdfBytes(saved, _currentPage + 1, 'Blank page added');
    } catch (e) {
      _showToast('Failed to add page: $e');
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
      await _applyModifiedPdfBytes(saved, _currentPage + 1, 'Page duplicated');
    } catch (e) {
      _showToast('Failed to duplicate: $e');
    }
  }

  Future<void> _deleteCurrentPage() async {
    if (_filePath == null) return;
    if (_totalPages <= 1) {
      _showToast('Cannot delete the only remaining page.');
      return;
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Page'),
        content: Text('Are you sure you want to delete Page $_currentPage?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
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
      await _applyModifiedPdfBytes(saved, _currentPage > 1 ? _currentPage - 1 : 1, 'Page deleted');
    } catch (e) {
      _showToast('Failed to delete: $e');
    }
  }

  Future<void> _moveCurrentPageDialog() async {
    if (_filePath == null || _totalPages <= 1) return;

    final targetCtrl = TextEditingController(text: _currentPage.toString());
    final int? targetPage = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move Page $_currentPage'),
        content: TextField(
          controller: targetCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Move to page index', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(targetCtrl.text)), child: const Text('Move')),
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
      await _applyModifiedPdfBytes(saved, newPos, 'Page moved');
    } catch (e) {
      _showToast('Failed to move: $e');
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
        dialogTitle: 'Extract Page As PDF',
        fileName: 'Page_${_currentPage}_${_fileName ?? "document.pdf"}',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: extractedBytes,
      );

      if (saveUri != null) {
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          String savePath = saveUri.scheme == 'file' ? saveUri.toFilePath() : saveUri.toString();
          if (!savePath.toLowerCase().endsWith('.pdf')) savePath = '$savePath.pdf';
          await File(savePath).writeAsBytes(extractedBytes, flush: true);
        }
        _showToast('Page successfully extracted!');
      }
    } catch (e) {
      _showToast('Failed to extract: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final bool shouldQuitApp = await _onWillPop();
        if (shouldQuitApp) {
          if (Platform.isAndroid || Platform.isIOS) {
            await SystemNavigator.pop();
            exit(0);
          } else {
            exit(0);
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(
                    hintText: 'Search text in document...',
                    border: InputBorder.none,
                  ),
                  onChanged: (query) {
                    if (_textSearcher == null) return;
                    if (query.trim().isNotEmpty) {
                      _textSearcher!.startTextSearch(query.trim());
                    } else {
                      _textSearcher!.resetTextSearch();
                    }
                  },
                )
              : Text(_fileName ?? 'Fajar PDF Reader', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          centerTitle: false,
          actions: [
            if (_filePath != null) ...[
              if (_isSearching && _textSearcher != null) ...[
                ListenableBuilder(
                  listenable: _textSearcher!,
                  builder: (context, _) {
                    final matches = _textSearcher!.matches;
                    final currentIdx = _textSearcher!.currentIndex;
                    final total = matches.length;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          total > 0 ? '${(currentIdx ?? 0) + 1}/$total' : '0/0',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          tooltip: 'Previous match',
                          icon: const Icon(Icons.keyboard_arrow_up),
                          onPressed: total > 0 ? () => _textSearcher!.goToPrevMatch() : null,
                        ),
                        IconButton(
                          tooltip: 'Next match',
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: total > 0 ? () => _textSearcher!.goToNextMatch() : null,
                        ),
                      ],
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Close search',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _isSearching = false;
                      _searchController.clear();
                      _textSearcher?.resetTextSearch();
                    });
                  },
                ),
              ] else ...[
                IconButton(
                  tooltip: 'Search in PDF',
                  icon: const Icon(Icons.search),
                  onPressed: () => setState(() => _isSearching = true),
                ),
              ],
            ],
            if (_filePath != null)
              IconButton(
                tooltip: 'Print Document',
                icon: const Icon(Icons.print_outlined),
                onPressed: _printCurrentPdf,
              ),
            const SizedBox(width: 4),
          ],
        ),
        // MENU HAMBURGER (DRAWER) DENGAN LABEL BAHASA INGGRIS
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(Icons.picture_as_pdf, size: 40, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 10),
                    Text(
                      'Fajar PDF Reader',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _fileName ?? 'No document open',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('Create PDF'),
              onTap: () {
                Navigator.pop(context);
                _createNewPdf();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Open File'),
              onTap: () {
                Navigator.pop(context);
                _pickPdfFile();
              },
            ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('History'),
                onTap: () {
                  Navigator.pop(context);
                  _openHistoryModal();
                },
              ),
              if (_filePath != null) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share Document'),
                  onTap: () {
                    Navigator.pop(context);
                    _shareCurrentPdf();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: const Text('Print Document'),
                  onTap: () {
                    Navigator.pop(context);
                    _printCurrentPdf();
                  },
                ),
                ExpansionTile(
                  leading: const Icon(Icons.transform_outlined),
                  title: const Text('Convert'),
                  childrenPadding: const EdgeInsets.only(left: 16),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.image_outlined, color: Colors.blueAccent),
                      title: const Text('Convert to Image (PNG)'),
                      onTap: () {
                        Navigator.pop(context);
                        _convertPdfToImages();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.description_outlined, color: Colors.indigoAccent),
                      title: const Text('Convert to Document Word (.docx)'),
                      onTap: () {
                        Navigator.pop(context);
                        _convertPdfToWord();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.table_chart_outlined, color: Colors.teal),
                      title: const Text('Convert to Excel (.csv / .xlsx)'),
                      onTap: () {
                        Navigator.pop(context);
                        _convertPdfToExcel();
                      },
                    ),
                  ],
                ),
                ListTile(
                  leading: const Icon(Icons.layers_outlined),
                  title: const Text('Manage Pages'),
                  onTap: () {
                    Navigator.pop(context);
                    _openPageManagerModal();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.draw_outlined),
                  title: const Text('Signature Bank'),
                  onTap: () {
                    Navigator.pop(context);
                    _openSignatureManager();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: const Text('Save'),
                  onTap: () {
                    Navigator.pop(context);
                    _exportSignedPdf(saveAs: false);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.save_as_outlined),
                  title: const Text('Save As'),
                  onTap: () {
                    Navigator.pop(context);
                    _exportSignedPdf(saveAs: true);
                  },
                ),
              ],
              const Divider(),
              ExpansionTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('Theme Mode'),
                children: [
                  RadioListTile<ThemeMode>(
                    title: const Text('System'),
                    value: ThemeMode.system,
                    groupValue: widget.currentThemeMode,
                    onChanged: (val) {
                      if (val != null) widget.onThemeChanged(val);
                    },
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('Light'),
                    value: ThemeMode.light,
                    groupValue: widget.currentThemeMode,
                    onChanged: (val) {
                      if (val != null) widget.onThemeChanged(val);
                    },
                  ),
                  RadioListTile<ThemeMode>(
                    title: const Text('Dark'),
                    value: ThemeMode.dark,
                    groupValue: widget.currentThemeMode,
                    onChanged: (val) {
                      if (val != null) widget.onThemeChanged(val);
                    },
                  ),
                ],
              ),
            ],
          ),
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
                                    Text('No Document Open', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Open a PDF file to read, manage pages, or apply digital signatures.',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                                    ),
                                    const SizedBox(height: 20),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FilledButton.icon(
                                        onPressed: _pickPdfFile,
                                        icon: const Icon(Icons.file_open_outlined),
                                        label: const Text('Open PDF File'),
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
                        pagePaintCallbacks: [
                          if (_textSearcher != null) _textSearcher!.pageTextMatchPaintCallback,
                        ],
                        maxScale: 5.0,
                        minScale: 0.5,
                        onViewerReady: (document, controller) {
                          setState(() {
                            _totalPages = document.pages.length;
                            _currentPage = controller.pageNumber ?? 1;
                            _textSearcher = PdfTextSearcher(controller);
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
                                        'Tap to place signature (Page ${page.pageNumber})',
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
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: Transform.translate(
                                              offset: const Offset(6, 0),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.resizeLeftRight,
                                                child: GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onPanUpdate: (details) {
                                                    setState(() {
                                                      final deltaW = details.delta.dx / pageRect.width;
                                                      sig.relWidth = (sig.relWidth + deltaW).clamp(0.04, 1.0 - sig.relX);
                                                    });
                                                  },
                                                  child: Padding(
                                                    padding: const EdgeInsets.all(6.0),
                                                    child: Container(
                                                      width: 12,
                                                      height: 12,
                                                      decoration: BoxDecoration(
                                                        color: Colors.blueAccent,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white, width: 1.5),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Align(
                                            alignment: Alignment.bottomCenter,
                                            child: Transform.translate(
                                              offset: const Offset(0, 6),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.resizeUpDown,
                                                child: GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onPanUpdate: (details) {
                                                    setState(() {
                                                      final deltaH = details.delta.dy / pageRect.height;
                                                      sig.relHeight = (sig.relHeight + deltaH).clamp(0.02, 1.0 - sig.relY);
                                                    });
                                                  },
                                                  child: Padding(
                                                    padding: const EdgeInsets.all(6.0),
                                                    child: Container(
                                                      width: 12,
                                                      height: 12,
                                                      decoration: BoxDecoration(
                                                        color: Colors.blueAccent,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white, width: 1.5),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Align(
                                            alignment: Alignment.bottomRight,
                                            child: Transform.translate(
                                              offset: const Offset(6, 6),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                                                child: GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  onPanUpdate: (details) {
                                                    setState(() {
                                                      final deltaW = details.delta.dx / pageRect.width;
                                                      final newRelW = (sig.relWidth + deltaW).clamp(0.04, 1.0 - sig.relX);
                                                      final newPixelW = newRelW * pageRect.width;
                                                      final newPixelH = newPixelW / sig.aspectRatio;
                                                      final newRelH = (newPixelH / pageRect.height).clamp(0.02, 1.0 - sig.relY);
                                                      sig.relWidth = newRelW;
                                                      sig.relHeight = newRelH;
                                                    });
                                                  },
                                                  child: Padding(
                                                    padding: const EdgeInsets.all(6.0),
                                                    child: Container(
                                                      width: 14,
                                                      height: 14,
                                                      decoration: BoxDecoration(
                                                        color: Colors.blueAccent,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white, width: 1.5),
                                                      ),
                                                    ),
                                                  ),
                                                ),
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
                      tooltip: 'First Page',
                      icon: const Icon(Icons.first_page),
                      onPressed: _currentPage > 1 ? () => _goToPage(1) : null,
                    ),
                    IconButton(
                      tooltip: 'Previous Page',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _showJumpPageDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: Text('Page $_currentPage / $_totalPages', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Next Page',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: _currentPage < _totalPages ? () => _goToPage(_currentPage + 1) : null,
                    ),
                    IconButton(
                      tooltip: 'Last Page',
                      icon: const Icon(Icons.last_page),
                      onPressed: _currentPage < _totalPages ? () => _goToPage(_totalPages) : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    IconButton(
                      tooltip: 'Zoom Out (-)',
                      icon: const Icon(Icons.zoom_out),
                      onPressed: _zoomOut,
                    ),
                    SizedBox(
                      width: 130,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        ),
                        child: Slider(
                          value: _currentZoom.clamp(0.5, 4.0),
                          min: 0.5,
                          max: 4.0,
                          onChanged: (val) => _setZoomValue(val),
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _resetZoom,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          '${(_currentZoom * 100).toInt()}%',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zoom In (+)',
                      icon: const Icon(Icons.zoom_in),
                      onPressed: _zoomIn,
                    ),
                  ],
                ),
              ),
      ),
    );
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
                          'Manage Pages (Page $_currentPage of $_totalPages)',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                    ],
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.post_add_outlined, color: Colors.indigo),
                    title: const Text('Insert File (PDF / Image / Word)'),
                    onTap: () { Navigator.pop(ctx); _openInsertPageModal(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.note_add_outlined, color: Colors.teal),
                    title: const Text('Add Blank Page'),
                    onTap: () { Navigator.pop(ctx); _insertBlankPage(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.copy_all_outlined, color: Colors.blue),
                    title: const Text('Duplicate This Page'),
                    onTap: () { Navigator.pop(ctx); _duplicateCurrentPage(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.low_priority_outlined, color: Colors.orange),
                    title: const Text('Move Page Order...'),
                    onTap: () { Navigator.pop(ctx); _moveCurrentPageDialog(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.ios_share_outlined, color: Colors.deepPurple),
                    title: const Text('Extract Page to New PDF'),
                    onTap: () { Navigator.pop(ctx); _extractCurrentPageToPdf(); },
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
                    title: const Text('Delete This Page', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
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
      title: const Text('Draw Signature'),
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
                    const Text('Ink:'),
                    const SizedBox(width: 10),
                    _buildColorCircle(Colors.black, 'Black'),
                    const SizedBox(width: 8),
                    _buildColorCircle(Colors.blue.shade800, 'Blue'),
                    const SizedBox(width: 8),
                    _buildColorCircle(Colors.red.shade800, 'Red'),
                  ],
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _strokes.clear()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Clear'),
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
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () async {
            final bytes = await _exportToPngBytes();
            if (context.mounted) Navigator.pop(context, bytes);
          },
          icon: const Icon(Icons.check),
          label: const Text('Save Signature'),
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