// ============================================================================
// SnapVault — Zero-Background Bilingual (TR/EN) Screenshot Organizer & Vault
// Architecture:
//   1. Strict On-Demand Execution (Zero background services, zero battery drain)
//   2. Isolate-Offloaded Perceptual Hashing (64-bit dHash) & Coordinate OCR Filtering
//   3. Burst-Shot Clustering (<= 5s window or Hamming distance <= 8)
//   4. Bilingual (TR/EN) Social UI Noise Stripper & Deterministic Category Engine
//   5. Keyless Public API Enrichment (Jikan / TVMaze / iTunes / OpenLibrary)
//   6. Native OS Gallery Purge (PhotoManager.editor.deleteWithIds)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const SnapVaultApp());
}

// ============================================================================
// 1. BILINGUAL LOCALIZATION DICTIONARY (TR & EN)
// ============================================================================
enum AppLang { tr, en }

class L10n {
  final AppLang lang;
  const L10n(this.lang);

  bool get isTr => lang == AppLang.tr;

  String get appTitle => 'SnapVault';
  String get subtitle => isTr
      ? 'Sıfır Arka Plan • Akıllı Ekran Görüntüsü Kasası'
      : 'Zero-Background • Smart Screenshot Vault';
  String get searchHint => isTr
      ? 'Film, anime, kitap, ürün veya IBAN ara...'
      : 'Search movie, anime, book, product or IBAN...';
  String get scanNow => isTr ? 'Yeni Görüntüleri Tara' : 'Scan New Screenshots';
  String get scanning => isTr ? 'Taranıyor...' : 'Scanning...';
  String get catAll => isTr ? 'Tümü' : 'All';
  String get catMovie => isTr ? 'Film / Dizi' : 'Movie / Series';
  String get catAnime => isTr ? 'Anime' : 'Anime';
  String get catBook => isTr ? 'Kitap' : 'Book';
  String get catShopping => isTr ? 'Alışveriş' : 'Shopping';
  String get catTemp => isTr ? 'IBAN / Kod' : 'IBAN / Code';

  String get purgeGalleryBtn => isTr
      ? 'Galeriden Çöpleri Sil'
      : 'Purge Raw Screenshots';
  String get copyPayload => isTr ? 'Kopyala' : 'Copy';
  String get copiedToast =>
      isTr ? 'Panoya kopyalandı!' : 'Copied to clipboard!';
  String get deleteFromGallery =>
      isTr ? 'Orijinali Galeriden Sil' : 'Delete Original from Gallery';
  String get deleteCard => isTr ? 'Kartı Sil' : 'Delete Card';
  String get purgedBadge =>
      isTr ? 'Galeriden Temizlendi' : 'Purged from Gallery';
  String get burstBadge => isTr ? 'Seri Çekim' : 'Burst Group';
  String get emptyStateTitle => isTr
      ? 'Henüz İşlenmiş Ekran Görüntüsü Yok'
      : 'No Processed Screenshots Yet';
  String get emptyStateSub => isTr
      ? 'SnapVault arka planda çalışmaz ve pil tüketmez.\n"Screenshots" klasöründeki yeni görüntüleri taramak için aşağıdaki butona dokunun.'
      : 'SnapVault never runs in the background or drains battery.\nTap the button below to scan new items from your "Screenshots" album.';
  String get permDenied => isTr
      ? 'Galeri izni gerekli. Lütfen ayarlardan fotoğraf erişimine izin verin.'
      : 'Gallery permission required. Please grant photo access in Settings.';
  String get openSettings => isTr ? 'Ayarları Aç' : 'Open Settings';
  String scanCompleteMsg(int added, int grouped) => isTr
      ? '$added yeni kart oluşturuldu ($grouped seri görüntü birleştirildi).'
      : '$added new cards created ($grouped burst shots merged).';
  String purgeSuccessMsg(int count) => isTr
      ? '$count orijinal ekran görüntüsü telefon galerisinden silindi!'
      : '$count raw screenshots deleted from device gallery!';

  String categoryLabel(VaultCategory cat) {
    switch (cat) {
      case VaultCategory.movieSeries:
        return catMovie;
      case VaultCategory.anime:
        return catAnime;
      case VaultCategory.book:
        return catBook;
      case VaultCategory.shopping:
        return catShopping;
      case VaultCategory.tempCode:
        return catTemp;
    }
  }
}

// ============================================================================
// 2. DATA MODELS & ENUMS
// ============================================================================
enum VaultCategory {
  movieSeries,
  anime,
  book,
  shopping,
  tempCode,
}

class VaultCard {
  final String id;
  final String primaryAssetId;
  final List<String> groupedAssetIds;
  final String localThumbPath;
  final VaultCategory category;
  final String extractedTitle;
  final String cleanedOcrText;
  final String? actionPayload; // IBAN, OTP code, price tag, tracking number
  final String? apiTitle;
  final String? apiSubtitle;
  final String? apiPosterUrl;
  final double? apiRating;
  final String? apiSummary;
  final String pHashHex;
  final int capturedEpochMs;
  final bool isPurgedFromGallery;

  const VaultCard({
    required this.id,
    required this.primaryAssetId,
    required this.groupedAssetIds,
    required this.localThumbPath,
    required this.category,
    required this.extractedTitle,
    required this.cleanedOcrText,
    this.actionPayload,
    this.apiTitle,
    this.apiSubtitle,
    this.apiPosterUrl,
    this.apiRating,
    this.apiSummary,
    required this.pHashHex,
    required this.capturedEpochMs,
    required this.isPurgedFromGallery,
  });

  String get displayTitle =>
      (apiTitle != null && apiTitle!.trim().isNotEmpty)
          ? apiTitle!
          : extractedTitle;

  VaultCard copyWith({
    List<String>? groupedAssetIds,
    String? apiTitle,
    String? apiSubtitle,
    String? apiPosterUrl,
    double? apiRating,
    String? apiSummary,
    bool? isPurgedFromGallery,
  }) {
    return VaultCard(
      id: id,
      primaryAssetId: primaryAssetId,
      groupedAssetIds: groupedAssetIds ?? this.groupedAssetIds,
      localThumbPath: localThumbPath,
      category: category,
      extractedTitle: extractedTitle,
      cleanedOcrText: cleanedOcrText,
      actionPayload: actionPayload,
      apiTitle: apiTitle ?? this.apiTitle,
      apiSubtitle: apiSubtitle ?? this.apiSubtitle,
      apiPosterUrl: apiPosterUrl ?? this.apiPosterUrl,
      apiRating: apiRating ?? this.apiRating,
      apiSummary: apiSummary ?? this.apiSummary,
      pHashHex: pHashHex,
      capturedEpochMs: capturedEpochMs,
      isPurgedFromGallery: isPurgedFromGallery ?? this.isPurgedFromGallery,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'primary_asset_id': primaryAssetId,
        'grouped_asset_ids': jsonEncode(groupedAssetIds),
        'local_thumb_path': localThumbPath,
        'category': category.name,
        'extracted_title': extractedTitle,
        'cleaned_ocr_text': cleanedOcrText,
        'action_payload': actionPayload,
        'api_title': apiTitle,
        'api_subtitle': apiSubtitle,
        'api_poster_url': apiPosterUrl,
        'api_rating': apiRating,
        'api_summary': apiSummary,
        'phash_hex': pHashHex,
        'captured_epoch_ms': capturedEpochMs,
        'is_purged_from_gallery': isPurgedFromGallery ? 1 : 0,
      };

  factory VaultCard.fromMap(Map<String, dynamic> map) {
    final catName = map['category'] as String? ?? 'tempCode';
    final cat = VaultCategory.values.firstWhere(
      (e) => e.name == catName,
      orElse: () => VaultCategory.tempCode,
    );
    final decodedGroup = (jsonDecode(map['grouped_asset_ids'] as String? ?? '[]')
            as List<dynamic>)
        .map((e) => e.toString())
        .toList();

    return VaultCard(
      id: map['id'] as String,
      primaryAssetId: map['primary_asset_id'] as String,
      groupedAssetIds: decodedGroup,
      localThumbPath: map['local_thumb_path'] as String,
      category: cat,
      extractedTitle: map['extracted_title'] as String,
      cleanedOcrText: map['cleaned_ocr_text'] as String,
      actionPayload: map['action_payload'] as String?,
      apiTitle: map['api_title'] as String?,
      apiSubtitle: map['api_subtitle'] as String?,
      apiPosterUrl: map['api_poster_url'] as String?,
      apiRating: (map['api_rating'] as num?)?.toDouble(),
      apiSummary: map['api_summary'] as String?,
      pHashHex: map['phash_hex'] as String,
      capturedEpochMs: map['captured_epoch_ms'] as int,
      isPurgedFromGallery: (map['is_purged_from_gallery'] as int? ?? 0) == 1,
    );
  }
}

// ============================================================================
// 3. LOCAL SQLITE STORAGE ENGINE
// ============================================================================
class SnapVaultDb {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dbDir = await getDatabasesPath();
    final path = p.join(dbDir, 'snapvault_core.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vault_cards (
            id TEXT PRIMARY KEY,
            primary_asset_id TEXT NOT NULL,
            grouped_asset_ids TEXT NOT NULL,
            local_thumb_path TEXT NOT NULL,
            category TEXT NOT NULL,
            extracted_title TEXT NOT NULL,
            cleaned_ocr_text TEXT NOT NULL,
            action_payload TEXT,
            api_title TEXT,
            api_subtitle TEXT,
            api_poster_url TEXT,
            api_rating REAL,
            api_summary TEXT,
            phash_hex TEXT NOT NULL,
            captured_epoch_ms INTEGER NOT NULL,
            is_purged_from_gallery INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE processed_assets (
            asset_id TEXT PRIMARY KEY,
            processed_at_ms INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE app_Config (
            cfg_key TEXT PRIMARY KEY,
            cfg_val TEXT NOT NULL
          )
        ''');
      },
    );
    return _db!;
  }

  static Future<List<VaultCard>> loadAllCards() async {
    final db = await instance;
    final rows = await db.query(
      'vault_cards',
      orderBy: 'captured_epoch_ms DESC',
    );
    return rows.map(VaultCard.fromMap).toList();
  }

  static Future<Set<String>> loadProcessedAssetIds() async {
    final db = await instance;
    final rows = await db.query('processed_assets', columns: ['asset_id']);
    return rows.map((r) => r['asset_id'] as String).toSet();
  }

  static Future<void> markAssetProcessed(String assetId) async {
    final db = await instance;
    await db.insert(
      'processed_assets',
      {
        'asset_id': assetId,
        'processed_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> upsertCard(VaultCard card) async {
    final db = await instance;
    await db.insert(
      'vault_cards',
      card.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteCard(String id) async {
    final db = await instance;
    await db.delete('vault_cards', where: 'id = ?', whereArgs: [id]);
  }

  static Future<AppLang> loadLanguage() async {
    final db = await instance;
    final rows = await db.query(
      'app_Config',
      where: 'cfg_key = ?',
      whereArgs: ['lang'],
    );
    if (rows.isEmpty) return AppLang.tr;
    return (rows.first['cfg_val'] == 'en') ? AppLang.en : AppLang.tr;
  }

  static Future<void> saveLanguage(AppLang lang) async {
    final db = await instance;
    await db.insert(
      'app_Config',
      {'cfg_key': 'lang', 'cfg_val': lang.name},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

// ============================================================================
// 4. ISOLATE-SAFE PERCEPTUAL HASHING & BILINGUAL CLASSIFICATION ENGINE
// ============================================================================

/// Lightweight serializable OCR block passed into the background Isolate
class RawOcrLine {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const RawOcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get height => (bottom - top).abs();
  double get centerY => (top + bottom) / 2.0;
  double get centerX => (left + right) / 2.0;
}

class IsolateClassifyInput {
  final Uint8List thumbBytes;
  final String targetThumbFilePath;
  final List<RawOcrLine> ocrLines;

  const IsolateClassifyInput({
    required this.thumbBytes,
    required this.targetThumbFilePath,
    required this.ocrLines,
  });
}

class IsolateClassifyOutput {
  final int width;
  final int height;
  final String pHashHex;
  final VaultCategory category;
  final String extractedTitle;
  final String cleanedText;
  final String? actionPayload;

  const IsolateClassifyOutput({
    required this.width,
    required this.height,
    required this.pHashHex,
    required this.category,
    required this.extractedTitle,
    required this.cleanedText,
    this.actionPayload,
  });
}

/// Top-level function executed inside `Isolate.run()` so decoding, resizing,
/// perceptual hashing (64-bit dHash), coordinate filtering, and regex
/// classification NEVER touch the UI thread.
Future<IsolateClassifyOutput> processScreenshotInIsolate(
  IsolateClassifyInput input,
) async {
  // 1. Decode thumbnail & compute 64-bit Difference Perceptual Hash (dHash)
  final decoded = img.decodeImage(input.thumbBytes);
  int imgW = decoded?.width ?? 1080;
  int imgH = decoded?.height ?? 2400;
  String pHashHex = '0000000000000000';

  if (decoded != null) {
    // Save compact 400px-wide cached JPEG for zero-jank UI rendering even after Gallery deletion
    final preview =
        decoded.width > 400 ? img.copyResize(decoded, width: 400) : decoded;
    final jpgBytes = img.encodeJpg(preview, quality: 82);
    await File(input.targetThumbFilePath).writeAsBytes(jpgBytes, flush: false);

    // 9x8 grayscale grid for 64-bit horizontal gradient dHash
    final small = img.copyResize(
      decoded,
      width: 9,
      height: 8,
      interpolation: img.Interpolation.average,
    );
    BigInt bits = BigInt.zero;
    int bitIndex = 0;
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        final pLeft = small.getPixel(x, y);
        final pRight = small.getPixel(x + 1, y);
        final lumLeft =
            0.299 * pLeft.r + 0.587 * pLeft.g + 0.114 * pLeft.b;
        final lumRight =
            0.299 * pRight.r + 0.587 * pRight.g + 0.114 * pRight.b;
        if (lumLeft > lumRight) {
          bits |= (BigInt.one << bitIndex);
        }
        bitIndex++;
      }
    }
    pHashHex = bits.toRadixString(16).padLeft(16, '0');
  } else {
    await File(input.targetThumbFilePath)
        .writeAsBytes(input.thumbBytes, flush: false);
  }

  // 2. Coordinate-Based Bounding-Box Filtering
  // Ignore top 12% (status bar: clock, carrier, battery, notifications)
  // Ignore bottom 10% (navigation bar, comment input bar, home tabs)
  // Ignore right-side social action rail (x > 82% width & y > 40% height)
  final List<RawOcrLine> validLines = [];
  for (final line in input.ocrLines) {
    final normY = imgH > 0 ? (line.centerY / imgH) : 0.5;
    final normX = imgW > 0 ? (line.centerX / imgW) : 0.5;

    if (normY < 0.12 || normY > 0.90) continue;
    if (normX > 0.82 && normY > 0.40) continue;

    final cleaned = _stripBilingualSocialClutter(line.text);
    if (cleaned.length >= 2) {
      validLines.add(
        RawOcrLine(
          text: cleaned,
          left: line.left,
          top: line.top,
          right: line.right,
          bottom: line.bottom,
        ),
      );
    }
  }

  final fullCleanText = validLines.map((l) => l.text).join('\n');
  final lowerText = fullCleanText.toLowerCase();

  // 3. Deterministic Bilingual (TR/EN) Regex & Keyword Classification
  // 3A. Check Temporary / IBAN / Verification Code / Wi-Fi
  final ibanRegex = RegExp(
    r'\bTR\s*\d{2}\s*(?:\d{4}\s*){5}\d{2}\b',
    caseSensitive: false,
  );
  final ibanMatch = ibanRegex.firstMatch(fullCleanText);
  if (ibanMatch != null) {
    final rawIban = ibanMatch.group(0)!.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.tempCode,
      extractedTitle: 'IBAN (${rawIban.substring(0, 6)}...${rawIban.substring(rawIban.length - 4)})',
      cleanedText: fullCleanText,
      actionPayload: rawIban,
    );
  }

  final otpKeywords = RegExp(
    r'\b(doğrulama kodu|onay kodu|şifre|kargo takip|iade kodu|verification code|security code|otp|passcode|tracking number|pin)\b',
    caseSensitive: false,
  );
  if (otpKeywords.hasMatch(lowerText)) {
    final codeMatch =
        RegExp(r'\b[A-Z0-9]{4,12}\b').firstMatch(fullCleanText);
    final code = codeMatch?.group(0) ?? _pickProminentTitle(validLines);
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.tempCode,
      extractedTitle: code.isNotEmpty ? 'Kod: $code' : 'Geçici Kod / Not',
      cleanedText: fullCleanText,
      actionPayload: code,
    );
  }

  // 3B. Check Shopping / Product / E-Commerce (TR & EN)
  final priceRegex = RegExp(
    r'(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?\s*(?:TL|₺|TRY|USD|\$|EUR|€))|(?:(?:TL|₺|\$|€)\s*\d{1,3}(?:[.,]\d{3})*)',
    caseSensitive: false,
  );
  final shoppingKeywords = RegExp(
    r'\b(sepete ekle|hemen al|ücretsiz kargo|indirim|beden|stokta|trendyol|hepsiburada|amazon|n11|zara|bershka|add to cart|buy now|free shipping|in stock|checkout|discount)\b',
    caseSensitive: false,
  );
  final priceMatch = priceRegex.firstMatch(fullCleanText);
  if (shoppingKeywords.hasMatch(lowerText) || priceMatch != null) {
    final detectedPrice = priceMatch?.group(0)?.trim();
    final title = _pickProminentTitle(validLines, ignoreRegex: priceRegex);
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.shopping,
      extractedTitle: title.isNotEmpty ? title : 'Ürün / Alışveriş',
      cleanedText: fullCleanText,
      actionPayload: detectedPrice,
    );
  }

  // 3C. Check Anime (TR & EN)
  final animeKeywords = RegExp(
    r'\b(anime|manga|myanimelist|crunchyroll|anizle|türkanime|turkanime|shonen|shounen|seinen|isekai|ova|subbed|dubbed|altyazılı|fansub|bölüm\s*\d+|episode\s*\d+|ep\s*\d+)\b',
    caseSensitive: false,
  );
  final japaneseCue = RegExp(
    r'\b(naruto|one piece|bleach|attack on titan|shingeki|jujutsu kaisen|demon slayer|kimetsu|death note|fullmetal|hunter x hunter|chainsaw man|frieren|solo leveling|steins|evangelion|gintama|berserk|vinland|haikyuu|blue lock|boku no hero|my hero academia|dan da dan|dandadan|one punch)\b',
    caseSensitive: false,
  );
  if (japaneseCue.hasMatch(lowerText) ||
      (animeKeywords.hasMatch(lowerText) &&
          (lowerText.contains('anime') ||
              lowerText.contains('manga') ||
              lowerText.contains('mal') ||
              lowerText.contains('crunchyroll') ||
              lowerText.contains('fansub') ||
              lowerText.contains('türkanime')))) {
    final title = _pickProminentTitle(validLines);
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.anime,
      extractedTitle: title,
      cleanedText: fullCleanText,
    );
  }

  // 3D. Check Book / Literature (TR & EN)
  final bookKeywords = RegExp(
    r'\b(isbn|kitap|roman|yazar|yayınları|yayınevi|çevirmen|sayfa\s*\d+|goodreads|1000kitap|kitapyurdu|bölüm|chapter\s*\d+|page\s*\d+|author|published by|publisher|novel|bestseller|edebiyat)\b',
    caseSensitive: false,
  );
  if (bookKeywords.hasMatch(lowerText) ||
      (validLines.length >= 6 && fullCleanText.length > 380)) {
    final title = _pickProminentTitle(validLines);
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.book,
      extractedTitle: title,
      cleanedText: fullCleanText,
    );
  }

  // 3E. Check Movie / TV Series (TR & EN)
  final movieKeywords = RegExp(
    r'\b(imdb|netflix|disney\+|prime video|blutv|mubi|exxen|gain|hbo|apple tv|yönetmen|oyuncular|fragman|sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|s\d{1,2}e\d{1,2}|directed by|starring|trailer|cast|rottentomatoes|letterboxd)\b',
    caseSensitive: false,
  );
  if (movieKeywords.hasMatch(lowerText)) {
    final title = _pickProminentTitle(validLines);
    return IsolateClassifyOutput(
      width: imgW,
      height: imgH,
      pHashHex: pHashHex,
      category: VaultCategory.movieSeries,
      extractedTitle: title,
      cleanedText: fullCleanText,
    );
  }

  // Default fallback: If short title with year -> Movie/Series; else Temp/Note
  final yearMatch = RegExp(r'\b(19\d{2}|20[0-2]\d)\b').hasMatch(fullCleanText);
  final fallbackTitle = _pickProminentTitle(validLines);
  return IsolateClassifyOutput(
    width: imgW,
    height: imgH,
    pHashHex: pHashHex,
    category:
        yearMatch ? VaultCategory.movieSeries : VaultCategory.tempCode,
    extractedTitle:
        fallbackTitle.isNotEmpty ? fallbackTitle : 'Ekran Görüntüsü Notu',
    cleanedText: fullCleanText,
    actionPayload: yearMatch ? null : fallbackTitle,
  );
}

/// Strips Turkish & English social media UI buttons, counters, and clutter
String _stripBilingualSocialClutter(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';

  // Drop pure timestamps, battery %, view counts, and social handles
  final pureNoiseLine = RegExp(
    r'^(\d{1,2}:\d{2}|\d+\s*(sn|dk|sa|gün|hafta|ay|yıl|s|m|h|d|w|y)\s*(önce|ago)?|\d+[.,]?\d*\s*(b|bin|m|mn|k|görüntüleme|views|likes|beğeni|yorum|comments)|@[a-zA-Z0-9_.\-]+|#\S+)$',
    caseSensitive: false,
  );
  if (pureNoiseLine.hasMatch(s)) return '';

  // Remove inline bilingual UI chrome words
  final uiWords = RegExp(
    r'\b(beğen|yorum yap|yorumlar|paylaş|kaydet|takip et|takip ediliyor|abone ol|daha fazla|devamını oku|sesi aç|orijinal ses|like|comment|share|save|follow|following|subscribe|more|read more|original audio|sponsored|प्रायोजित|reklam)\b',
    caseSensitive: false,
  );
  s = s.replaceAll(uiWords, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// Selects the most likely title from OCR bounding boxes using visual prominence
/// (largest font height + cleanest alphabetic ratio)
String _pickProminentTitle(
  List<RawOcrLine> lines, {
  RegExp? ignoreRegex,
}) {
  if (lines.isEmpty) return 'Adsız Kayıt';

  final episodeStrip = RegExp(
    r'\b(sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|ep\.?\s*\d+|s\d+e\d+|hd|1080p|720p|4k|izle|watch|fragman|trailer|altyazılı|dublaj)\b',
    caseSensitive: false,
  );

  RawOcrLine? bestLine;
  double bestScore = -1.0;

  for (final l in lines) {
    var candidate = l.text.replaceAll(episodeStrip, ' ').trim();
    if (ignoreRegex != null) {
      candidate = candidate.replaceAll(ignoreRegex, ' ').trim();
    }
    candidate = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (candidate.length < 2 || candidate.length > 65) continue;

    // Count letters vs symbols
    final letters = RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ]').allMatches(candidate).length;
    if (letters < 2) continue;

    final alphaRatio = letters / candidate.length;
    final heightScore = l.height;
    final score = heightScore * (0.5 + alphaRatio);

    if (score > bestScore) {
      bestScore = score;
      bestLine = RawOcrLine(
        text: candidate,
        left: l.left,
        top: l.top,
        right: l.right,
        bottom: l.bottom,
      );
    }
  }

  return bestLine?.text ?? lines.first.text;
}

/// Computes Hamming distance between two 64-bit hex perceptual hashes
int hammingDistanceHex(String hexA, String hexB) {
  try {
    final a = BigInt.parse(hexA, radix: 16);
    final b = BigInt.parse(hexB, radix: 16);
    BigInt xor = a ^ b;
    int count = 0;
    while (xor > BigInt.zero) {
      count += (xor & BigInt.one) == BigInt.one ? 1 : 0;
      xor = xor >> 1;
    }
    return count;
  } catch (_) {
    return 64;
  }
}

// ============================================================================
// 5. ZERO-KEY PUBLIC METADATA ENRICHER (Jikan / TVMaze / iTunes / OpenLibrary)
// ============================================================================
class EnrichedMetadata {
  final String title;
  final String? subtitle;
  final String? posterUrl;
  final double? rating;
  final String? summary;

  const EnrichedMetadata({
    required this.title,
    this.subtitle,
    this.posterUrl,
    this.rating,
    this.summary,
  });
}

class MetadataEnricher {
  static const Duration _timeout = Duration(seconds: 5);

  static Future<EnrichedMetadata?> enrich(
    VaultCategory category,
    String rawQuery,
  ) async {
    final cleanQuery = rawQuery
        .replaceAll(RegExp(r'[^\w\sçğıöşüÇĞİÖŞÜ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleanQuery.length < 2) return null;

    try {
      switch (category) {
        case VaultCategory.anime:
          return await _fetchAnimeJikan(cleanQuery);
        case VaultCategory.movieSeries:
          return await _fetchMovieOrShow(cleanQuery);
        case VaultCategory.book:
          return await _fetchBookOpenLibrary(cleanQuery);
        case VaultCategory.shopping:
        case VaultCategory.tempCode:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Free Keyless Anime API: Jikan v4 (MyAnimeList Official Public Mirror)
  static Future<EnrichedMetadata?> _fetchAnimeJikan(String query) async {
    final uri = Uri.https(
      'api.jikan.moe',
      '/v4/anime',
      {'q': query, 'limit': '1', 'sfw': 'true'},
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = data['data'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;

    final item = list.first as Map<String, dynamic>;
    final title = (item['title_english'] ?? item['title'])?.toString() ?? query;
    final episodes = item['episodes'];
    final year = item['year'];
    final score = (item['score'] as num?)?.toDouble();
    final synopsis = item['synopsis']?.toString();
    final images = item['images'] as Map<String, dynamic>?;
    final jpg = images?['jpg'] as Map<String, dynamic>?;
    final poster = (jpg?['large_image_url'] ?? jpg?['image_url'])?.toString();

    return EnrichedMetadata(
      title: title,
      subtitle: [
        if (year != null) '$year',
        if (episodes != null) '$episodes EP',
        'Anime',
      ].join(' • '),
      posterUrl: poster,
      rating: score,
      summary: synopsis,
    );
  }

  /// Free Keyless Movie & TV Series APIs: TVMaze + Apple iTunes Search API
  static Future<EnrichedMetadata?> _fetchMovieOrShow(String query) async {
    // 1. Try iTunes Movie Search first for feature films
    final itunesUri = Uri.https(
      'itunes.apple.com',
      '/search',
      {'term': query, 'entity': 'movie', 'limit': '1'},
    );
    final itunesResp = await http.get(itunesUri).timeout(_timeout);
    if (itunesResp.statusCode == 200) {
      final body = jsonDecode(itunesResp.body) as Map<String, dynamic>;
      final results = body['results'] as List<dynamic>?;
      if (results != null && results.isNotEmpty) {
        final m = results.first as Map<String, dynamic>;
        final trackName = m['trackName']?.toString();
        final genre = m['primaryGenreName']?.toString();
        final releaseDate = m['releaseDate']?.toString() ?? '';
        final year =
            releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
        final rawArt = m['artworkUrl100']?.toString();
        final hiResArt = rawArt?.replaceAll('100x100bb', '600x600bb');
        final desc = m['longDescription']?.toString() ??
            m['shortDescription']?.toString();

        if (trackName != null) {
          return EnrichedMetadata(
            title: trackName,
            subtitle: [if (year.isNotEmpty) year, if (genre != null) genre]
                .join(' • '),
            posterUrl: hiResArt,
            rating: null,
            summary: desc,
          );
        }
      }
    }

    // 2. Fallback to TVMaze SingleSearch for TV Shows / Series
    final tvUri = Uri.https(
      'api.tvmaze.com',
      '/singlesearch/shows',
      {'q': query},
    );
    final tvResp = await http.get(tvUri).timeout(_timeout);
    if (tvResp.statusCode == 200) {
      final show = jsonDecode(tvResp.body) as Map<String, dynamic>;
      final name = show['name']?.toString() ?? query;
      final premiered = show['premiered']?.toString() ?? '';
      final year = premiered.length >= 4 ? premiered.substring(0, 4) : '';
      final ratingMap = show['rating'] as Map<String, dynamic>?;
      final avgRating = (ratingMap?['average'] as num?)?.toDouble();
      final imageMap = show['image'] as Map<String, dynamic>?;
      final poster =
          (imageMap?['original'] ?? imageMap?['medium'])?.toString();
      final rawSummary = show['summary']?.toString() ?? '';
      final cleanSummary =
          rawSummary.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      return EnrichedMetadata(
        title: name,
        subtitle: [if (year.isNotEmpty) year, 'TV Series'].join(' • '),
        posterUrl: poster,
        rating: avgRating,
        summary: cleanSummary,
      );
    }
    return null;
  }

  /// Free Keyless Book API: OpenLibrary Search API
  static Future<EnrichedMetadata?> _fetchBookOpenLibrary(String query) async {
    final uri = Uri.https(
      'openlibrary.org',
      '/search.json',
      {
        'q': query,
        'limit': '1',
        'fields': 'title,author_name,first_publish_year,cover_i,ratings_average'
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final docs = data['docs'] as List<dynamic>?;
    if (docs == null || docs.isEmpty) return null;

    final doc = docs.first as Map<String, dynamic>;
    final title = doc['title']?.toString() ?? query;
    final authors = (doc['author_name'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList();
    final authorStr =
        (authors != null && authors.isNotEmpty) ? authors.first : null;
    final year = doc['first_publish_year']?.toString();
    final coverId = doc['cover_i'];
    final rating = (doc['ratings_average'] as num?)?.toDouble();
    final poster = coverId != null
        ? 'https://covers.openlibrary.org/b/id/$coverId-L.jpg'
        : null;

    return EnrichedMetadata(
      title: title,
      subtitle: [
        if (authorStr != null) authorStr,
        if (year != null) year,
      ].join(' • '),
      posterUrl: poster,
      rating: rating != null ? double.parse(rating.toStringAsFixed(1)) : null,
      summary: null,
    );
  }
}

// ============================================================================
// 6. MAIN APPLICATION & ON-DEMAND SCANNER PIPELINE
// ============================================================================
class SnapVaultApp extends StatelessWidget {
  const SnapVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF151923),
        ),
        useMaterial3: true,
      ),
      home: const VaultHomeScreen(),
    );
  }
}

class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  AppLang _lang = AppLang.tr;
  L10n get _t => L10n(_lang);

  List<VaultCard> _cards = [];
  VaultCategory? _selectedCategory;
  String _searchQuery = '';
  bool _isScanning = false;
  int _scanDoneCount = 0;
  int _scanTotalCount = 0;
  bool _permissionDenied = false;

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeVault();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _initializeVault() async {
    final savedLang = await SnapVaultDb.loadLanguage();
    final savedCards = await SnapVaultDb.loadAllCards();
    if (!mounted) return;
    setState(() {
      _lang = savedLang;
      _cards = savedCards;
    });
    // Automatically trigger lightweight delta scan on launch
    await _scanNewScreenshots();
  }

  Future<void> _toggleLanguage() async {
    final next = _lang == AppLang.tr ? AppLang.en : AppLang.tr;
    await SnapVaultDb.saveLanguage(next);
    if (!mounted) return;
    setState(() => _lang = next);
  }

  /// Strictly On-Demand Screenshot Scanner:
  /// 1. Queries OS MediaStore for "Screenshots" album
  /// 2. Filters only unprocessed assets (max 25 per run, throttled in batches of 5)
  /// 3. Runs ML Kit Latin OCR + Isolate pHash/Classifier
  /// 4. Merges burst shots taken within <= 5 seconds or Hamming distance <= 8
  Future<void> _scanNewScreenshots() async {
    if (_isScanning) return;

    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth && !perm.hasAccess) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    if (mounted) setState(() => _permissionDenied = false);

    setState(() {
      _isScanning = true;
      _scanDoneCount = 0;
      _scanTotalCount = 0;
    });

    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      // Locate the "Screenshots" album (or fallback to Recent if device has no dedicated album)
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );

      if (paths.isEmpty) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }

      AssetPathEntity targetAlbum = paths.first;
      for (final album in paths) {
        final lowerName = album.name.toLowerCase();
        if (lowerName.contains('screenshot') ||
            lowerName.contains('ekran') ||
            lowerName.contains('screen')) {
          targetAlbum = album;
          break;
        }
      }

      // Inspect up to 35 most recent screenshots
      final recentAssets = await targetAlbum.getAssetListPaged(page: 0, size: 35);
      final processedIds = await SnapVaultDb.loadProcessedAssetIds();

      final newAssets = recentAssets
          .where((a) => !processedIds.contains(a.id))
          .take(20)
          .toList();

      if (newAssets.isEmpty) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }

      // Sort oldest-to-newest so burst-shot grouping merges sequentially
      newAssets.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      if (mounted) {
        setState(() => _scanTotalCount = newAssets.length);
      }

      final appSupportDir = await getApplicationSupportDirectory();
      final thumbDir = Directory(p.join(appSupportDir.path, 'vault_thumbs'));
      if (!thumbDir.existsSync()) {
        thumbDir.createSync(recursive: true);
      }

      int addedCardsCount = 0;
      int burstMergedCount = 0;

      // Process in throttled batches of 5 to keep 120Hz UI responsive
      const int batchSize = 5;
      for (int i = 0; i < newAssets.length; i += batchSize) {
        final batch = newAssets.skip(i).take(batchSize).toList();

        for (final asset in batch) {
          final file = await asset.file;
          final thumbBytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(480, 854),
            quality: 85,
          );

          if (file == null || thumbBytes == null) {
            await SnapVaultDb.markAssetProcessed(asset.id);
            if (mounted) setState(() => _scanDoneCount++);
            continue;
          }

          // 1. Run lightweight native ML Kit OCR (asynchronous platform channel)
          final inputImage = InputImage.fromFilePath(file.path);
          final recognized = await textRecognizer.processImage(inputImage);

          final rawLines = <RawOcrLine>[];
          for (final block in recognized.blocks) {
            for (final line in block.lines) {
              final rect = line.boundingBox;
              rawLines.add(
                RawOcrLine(
                  text: line.text,
                  left: rect.left,
                  top: rect.top,
                  right: rect.right,
                  bottom: rect.bottom,
                ),
              );
            }
          }

          // 2. Offload image decoding, pHash calculation, coordinate filtering,
          //    and bilingual regex classification to a background Isolate
          final safeId = asset.id.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
          final targetThumbPath =
              p.join(thumbDir.path, 'thumb_${safeId}_${asset.createDateSecond}.jpg');

          final isolateInput = IsolateClassifyInput(
            thumbBytes: thumbBytes,
            targetThumbFilePath: targetThumbPath,
            ocrLines: rawLines,
          );

          final result = await Isolate.run(
            () => processScreenshotInIsolate(isolateInput),
          );

          final capturedMs = asset.createDateTime.millisecondsSinceEpoch;

          // 3. Burst-Shot & Perceptual Duplicate Grouping Check:
          //    If an existing card was captured within 5 seconds OR has a pHash
          //    Hamming distance <= 8, merge this screenshot into that card!
          VaultCard? burstTarget;
          for (final existing in _cards) {
            final timeDiffMs = (capturedMs - existing.capturedEpochMs).abs();
            final pHashDist =
                hammingDistanceHex(result.pHashHex, existing.pHashHex);
            if (timeDiffMs <= 5000 || pHashDist <= 8) {
              burstTarget = existing;
              break;
            }
          }

          if (burstTarget != null) {
            final updatedGroup = <String>{
              ...burstTarget.groupedAssetIds,
              asset.id,
            }.toList();
            final updatedCard =
                burstTarget.copyWith(groupedAssetIds: updatedGroup);
            await SnapVaultDb.upsertCard(updatedCard);
            await SnapVaultDb.markAssetProcessed(asset.id);

            final idx = _cards.indexWhere((c) => c.id == burstTarget!.id);
            if (idx != -1 && mounted) {
              setState(() => _cards[idx] = updatedCard);
            }
            burstMergedCount++;
          } else {
            // Create a brand new VaultCard
            final newCard = VaultCard(
              id: 'card_${capturedMs}_$safeId',
              primaryAssetId: asset.id,
              groupedAssetIds: [asset.id],
              localThumbPath: targetThumbPath,
              category: result.category,
              extractedTitle: result.extractedTitle,
              cleanedOcrText: result.cleanedText,
              actionPayload: result.actionPayload,
              pHashHex: result.pHashHex,
              capturedEpochMs: capturedMs,
              isPurgedFromGallery: false,
            );

            await SnapVaultDb.upsertCard(newCard);
            await SnapVaultDb.markAssetProcessed(asset.id);

            if (mounted) {
              setState(() {
                _cards.insert(0, newCard);
              });
            }
            addedCardsCount++;

            // Fire-and-forget non-blocking public API metadata enrichment
            unawaited(_enrichCardInBackground(newCard));
          }

          if (mounted) {
            setState(() => _scanDoneCount++);
          }
          // Yield a frame between screenshots to guarantee 0 UI jank
          await Future.delayed(const Duration(milliseconds: 16));
        }
      }

      if (mounted && (addedCardsCount > 0 || burstMergedCount > 0)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_t.scanCompleteMsg(addedCardsCount, burstMergedCount)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF1E293B),
          ),
        );
      }
    } finally {
      await textRecognizer.close();
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _enrichCardInBackground(VaultCard card) async {
    final enriched =
        await MetadataEnricher.enrich(card.category, card.extractedTitle);
    if (enriched == null) return;

    final updated = card.copyWith(
      apiTitle: enriched.title,
      apiSubtitle: enriched.subtitle,
      apiPosterUrl: enriched.posterUrl,
      apiRating: enriched.rating,
      apiSummary: enriched.summary,
    );
    await SnapVaultDb.upsertCard(updated);
    if (!mounted) return;
    setState(() {
      final idx = _cards.indexWhere((c) => c.id == card.id);
      if (idx != -1) {
        _cards[idx] = updated;
      }
    });
  }

  /// Deletes the raw screenshots from the phone's main gallery using the OS native prompt
  /// while keeping the organized card & cached thumbnail inside SnapVault!
  Future<void> _purgeCardScreenshotsFromGallery(VaultCard card) async {
    if (card.isPurgedFromGallery || card.groupedAssetIds.isEmpty) return;
    final deletedIds =
        await PhotoManager.editor.deleteWithIds(card.groupedAssetIds);
    if (deletedIds.isNotEmpty) {
      final updated = card.copyWith(isPurgedFromGallery: true);
      await SnapVaultDb.upsertCard(updated);
      if (!mounted) return;
      setState(() {
        final idx = _cards.indexWhere((c) => c.id == card.id);
        if (idx != -1) _cards[idx] = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_t.purgeSuccessMsg(deletedIds.length)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF065F46),
        ),
      );
    }
  }

  /// Bulk Gallery Clean-up: Deletes all unpurged raw screenshots from the phone's gallery in one tap
  Future<void> _purgeAllProcessedFromGallery() async {
    final unpurgedCards =
        _cards.where((c) => !c.isPurgedFromGallery).toList();
    if (unpurgedCards.isEmpty) return;

    final allIds = <String>{};
    for (final c in unpurgedCards) {
      allIds.addAll(c.groupedAssetIds);
    }
    if (allIds.isEmpty) return;

    final deletedIds =
        await PhotoManager.editor.deleteWithIds(allIds.toList());
    if (deletedIds.isEmpty) return;

    final deletedSet = deletedIds.toSet();
    for (int i = 0; i < _cards.length; i++) {
      final c = _cards[i];
      if (c.groupedAssetIds.any(deletedSet.contains)) {
        final updated = c.copyWith(isPurgedFromGallery: true);
        await SnapVaultDb.upsertCard(updated);
        _cards[i] = updated;
      }
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_t.purgeSuccessMsg(deletedIds.length)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF065F46),
      ),
    );
  }

  List<VaultCard> get _filteredCards {
    return _cards.where((card) {
      if (_selectedCategory != null && card.category != _selectedCategory) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchTitle = card.displayTitle.toLowerCase().contains(q);
        final matchOcr = card.cleanedOcrText.toLowerCase().contains(q);
        final matchPayload =
            (card.actionPayload ?? '').toLowerCase().contains(q);
        return matchTitle || matchOcr || matchPayload;
      }
      return true;
    }).toList();
  }

  int get _unpurgedAssetCount {
    int count = 0;
    for (final c in _cards) {
      if (!c.isPurgedFromGallery) count += c.groupedAssetIds.length;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final visibleCards = _filteredCards;
    final unpurgedCount = _unpurgedAssetCount;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0E14),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _t.appTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
            Text(
              _t.subtitle,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white54,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          // Bilingual Language Toggle (TR / EN)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextButton.icon(
              onPressed: _toggleLanguage,
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF1E2433),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              icon: const Icon(Icons.language, size: 16, color: Colors.white70),
              label: Text(
                _lang == AppLang.tr ? 'TR' : 'EN',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          // Scan button
          IconButton(
            tooltip: _t.scanNow,
            onPressed: _isScanning ? null : _scanNewScreenshots,
            icon: _isScanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt_rounded, color: Color(0xFF10B981)),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Progress Indicator when scanning
          if (_isScanning)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF151923),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${_t.scanning} ($_scanDoneCount / $_scanTotalCount)',
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),

          // 2. Instant Offline Search Bar + Bulk Gallery Clean-up Button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _t.searchHint,
                      hintStyle:
                          const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: Colors.white54,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF151923),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (unpurgedCount > 0) ...[
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _purgeAllProcessedFromGallery,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3B1D2E),
                      foregroundColor: const Color(0xFFF43F5E),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                    label: Text(
                      '$unpurgedCount',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 3. Category Filter Chips
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                _buildCategoryChip(null, _t.catAll, Icons.grid_view_rounded),
                _buildCategoryChip(
                  VaultCategory.tempCode,
                  _t.catTemp,
                  Icons.qr_code_2_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.movieSeries,
                  _t.catMovie,
                  Icons.movie_creation_outlined,
                ),
                _buildCategoryChip(
                  VaultCategory.anime,
                  _t.catAnime,
                  Icons.auto_awesome_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.book,
                  _t.catBook,
                  Icons.menu_book_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.shopping,
                  _t.catShopping,
                  Icons.shopping_bag_outlined,
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // 4. Main Rich Media Card Grid
          Expanded(
            child: _permissionDenied
                ? _buildPermissionDeniedView()
                : visibleCards.isEmpty
                    ? _buildEmptyStateView()
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 88),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.64,
                        ),
                        itemCount: visibleCards.length,
                        itemBuilder: (context, index) {
                          final card = visibleCards[index];
                          return _RichMediaCardWidget(
                            card: card,
                            l10n: _t,
                            onPurgeGallery: () =>
                                _purgeCardScreenshotsFromGallery(card),
                            onDeleteCard: () async {
                              await SnapVaultDb.deleteCard(card.id);
                              if (!mounted) return;
                              setState(() {
                                _cards.removeWhere((c) => c.id == card.id);
                              });
                            },
                            onTapCard: () => _showCardDetailSheet(card),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _scanNewScreenshots,
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.document_scanner_rounded),
        label: Text(
          _t.scanNow,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildCategoryChip(
    VaultCategory? cat,
    String label,
    IconData icon,
  ) {
    final isSelected = _selectedCategory == cat;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: isSelected,
        onSelected: (_) => setState(() => _selectedCategory = cat),
        avatar: Icon(
          icon,
          size: 16,
          color: isSelected ? Colors.white : Colors.white60,
        ),
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: isSelected ? Colors.white : Colors.white70,
        ),
        selectedColor: const Color(0xFF6366F1),
        backgroundColor: const Color(0xFF151923),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  Widget _buildPermissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded,
                size: 52, color: Colors.white54),
            const SizedBox(height: 14),
            Text(
              _t.permDenied,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: PhotoManager.openSetting,
              child: Text(_t.openSettings),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF151923),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.auto_awesome_motion_rounded,
                size: 48,
                color: Color(0xFF6366F1),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _t.emptyStateTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _t.emptyStateSub,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white60,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCardDetailSheet(VaultCard card) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151923),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (_, scrollCtrl) {
            return ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 90,
                        height: 130,
                        child: _buildCardImage(card),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _t.categoryLabel(card.category).toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: _categoryColor(card.category),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            card.displayTitle,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (card.apiSubtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              card.apiSubtitle!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                          if (card.apiRating != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.star_rounded,
                                    color: Colors.amber, size: 16),
                                const SizedBox(width: 4),
                                Text(
                                  card.apiRating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (card.actionPayload != null &&
                    card.actionPayload!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B0E14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            card.actionPayload!,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: card.actionPayload!),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(_t.copiedToast)),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (card.apiSummary != null && card.apiSummary!.isNotEmpty) ...[
                  Text(
                    card.apiSummary!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                const Divider(color: Colors.white12),
                const SizedBox(height: 8),
                Text(
                  _t.isTr
                      ? 'Temizlenmiş OCR Metni (Sosyal Medya Gürültüsü Ayıklandı):'
                      : 'Cleaned OCR Text (Social UI Clutter Stripped):',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  card.cleanedOcrText,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white60,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                if (!card.isPurgedFromGallery)
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _purgeCardScreenshotsFromGallery(card);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF43F5E),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.delete_sweep_rounded),
                    label: Text(
                      '${_t.deleteFromGallery} (${card.groupedAssetIds.length})',
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// 7. ANTI-JANK RICH MEDIA CARD WIDGET (ResizeImage cacheWidth: 400)
// ============================================================================
class _RichMediaCardWidget extends StatelessWidget {
  final VaultCard card;
  final L10n l10n;
  final VoidCallback onPurgeGallery;
  final VoidCallback onDeleteCard;
  final VoidCallback onTapCard;

  const _RichMediaCardWidget({
    required this.card,
    required this.l10n,
    required this.onPurgeGallery,
    required this.onDeleteCard,
    required this.onTapCard,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = _categoryColor(card.category);

    return GestureDetector(
      onTap: onTapCard,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF151923),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Poster / Cached 400px Thumbnail Header
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCardImage(card),
                  // Gradient overlay
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black38,
                          Colors.transparent,
                          Color(0xE6151923),
                        ],
                      ),
                    ),
                  ),
                  // Category Badge
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        l10n.categoryLabel(card.category),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  // Rating or Burst Shot Counter
                  if (card.apiRating != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.star_rounded,
                              size: 12,
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              card.apiRating!.toStringAsFixed(1),
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (card.groupedAssetIds.length > 1)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${card.groupedAssetIds.length}x ${l10n.burstBadge}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.amberAccent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Metadata & One-Tap Action Footer
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (card.apiSubtitle != null)
                      Text(
                        card.apiSubtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      )
                    else
                      Text(
                        card.cleanedOcrText.replaceAll('\n', ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    const Spacer(),
                    // Action Row: Copy Payload (if any) + Gallery Purge / Delete
                    Row(
                      children: [
                        if (card.actionPayload != null &&
                            card.actionPayload!.isNotEmpty)
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                Clipboard.setData(
                                  ClipboardData(text: card.actionPayload!),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.copiedToast),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981)
                                      .withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.copy_rounded,
                                      size: 12,
                                      color: Color(0xFF10B981),
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        l10n.copyPayload,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF10B981),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else
                          Expanded(
                            child: Text(
                              card.isPurgedFromGallery
                                  ? '✓ ${l10n.purgedBadge}'
                                  : '',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFF10B981),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (!card.isPurgedFromGallery)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.deleteFromGallery,
                            onPressed: onPurgeGallery,
                            icon: const Icon(
                              Icons.cleaning_services_rounded,
                              size: 16,
                              color: Color(0xFFF43F5E),
                            ),
                          ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.deleteCard,
                          onPressed: onDeleteCard,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders either the enriched API poster or the locally cached 400px screenshot
/// using `ResizeImage(cacheWidth: 400)` so RAM consumption never spikes.
Widget _buildCardImage(VaultCard card) {
  if (card.apiPosterUrl != null && card.apiPosterUrl!.startsWith('http')) {
    return Image(
      image: ResizeImage(
        NetworkImage(card.apiPosterUrl!),
        width: 400,
      ),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildLocalThumbImage(card.localThumbPath),
    );
  }
  return _buildLocalThumbImage(card.localThumbPath);
}

Widget _buildLocalThumbImage(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return Container(
      color: const Color(0xFF1E2433),
      child: const Center(
        child: Icon(Icons.image_not_supported_outlined, color: Colors.white24),
      ),
    );
  }
  return Image(
    image: ResizeImage(
      FileImage(file),
      width: 400,
    ),
    fit: BoxFit.cover,
  );
}

Color _categoryColor(VaultCategory cat) {
  switch (cat) {
    case VaultCategory.movieSeries:
      return const Color(0xFF6366F1); // Indigo
    case VaultCategory.anime:
      return const Color(0xFFEC4899); // Pink
    case VaultCategory.book:
      return const Color(0xFFF59E0B); // Amber
    case VaultCategory.shopping:
      return const Color(0xFF10B981); // Emerald
    case VaultCategory.tempCode:
      return const Color(0xFF06B6D4); // Cyan
  }
}
