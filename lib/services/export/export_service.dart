import 'dart:io';

import 'package:gal/gal.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../data/local/file_storage.dart';
import '../../data/models/scan_document.dart';

/// Raised when an export cannot complete, so the UI can show a Retry snackbar
/// instead of failing silently.
class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns stored scans into files the user can keep: PDF, JPGs in the gallery,
/// or a share-sheet handoff. Everything is produced locally.
class ExportService {
  ExportService(this._storage);

  final FileStorage _storage;

  /// Builds a multi-page PDF, one page per scan, sized to each image so
  /// nothing is letterboxed or cropped.
  Future<File> buildPdf(ScanDocument document) async {
    if (document.pages.isEmpty) {
      throw const ExportException('This document has no pages to export');
    }

    final pdf = pw.Document(title: document.name);
    for (final page in document.pages) {
      if (!page.file.existsSync()) {
        throw ExportException('A page image is missing: ${page.filePath}');
      }
      final image = pw.MemoryImage(await page.file.readAsBytes());
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(
            image.width!.toDouble(),
            image.height!.toDouble(),
            marginAll: 0,
          ),
          build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
        ),
      );
    }

    final file = File(_storage.exportPath('${_safeFileName(document.name)}.pdf'));
    try {
      await file.writeAsBytes(await pdf.save());
    } on FileSystemException catch (error) {
      throw ExportException('Could not write the PDF: ${error.osError?.message ?? error.message}');
    }
    return file;
  }

  /// Saves every page to the device gallery under a ScanFlow album.
  Future<int> saveToGallery(ScanDocument document) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      if (!await Gal.requestAccess(toAlbum: true)) {
        throw const ExportException('Gallery access was denied');
      }
    }
    try {
      for (final page in document.pages) {
        await Gal.putImage(page.filePath, album: 'ScanFlow');
      }
    } on GalException catch (error) {
      throw ExportException('Could not save to the gallery: ${error.type.message}');
    }
    return document.pageCount;
  }

  Future<void> sharePdf(ScanDocument document) async {
    final file = await buildPdf(document);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: document.name,
      ),
    );
  }

  Future<void> shareImages(ScanDocument document) async {
    if (document.pages.isEmpty) {
      throw const ExportException('This document has no pages to share');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final page in document.pages) XFile(page.filePath, mimeType: 'image/jpeg'),
        ],
        subject: document.name,
      ),
    );
  }

  /// Shares several documents as PDFs at once (home-screen multi-select).
  Future<void> shareMany(List<ScanDocument> documents) async {
    final files = <XFile>[];
    for (final document in documents) {
      final pdf = await buildPdf(document);
      files.add(XFile(pdf.path, mimeType: 'application/pdf'));
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  /// Strips characters Android's file system rejects, so a document called
  /// "Invoice 09/2026" still exports.
  static String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-').trim();
    return cleaned.isEmpty ? 'scan' : cleaned;
  }
}
