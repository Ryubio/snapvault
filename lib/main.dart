// ============================================================================
// SnapVault — Zero-Background Bilingual (TR/EN) Screenshot Organizer & Vault
// Architecture:
//   1. Strict On-Demand Execution (Zero background services, zero battery drain)
//   2. Isolate-Offloaded Perceptual Hashing (64-bit dHash) via compute() with
//      primitive Map payload (100% free of closure/State capture exceptions)
//   3. Full-Resolution Coordinate OCR Filtering & Bilingual (TR/EN) Classifier
//   4. Smart Burst-Shot Clustering (same category + <= 4s & pHash dist <= 6)
//   5. Keyless Public API Enrichment (Jikan / TVMaze / iTunes / OpenLibrary)
//   6. Native OS Gallery Purge (PhotoManager.editor.deleteWithIds)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
  String get scanNow => isTr ? 'Sonraki 25 Görüntüyü Tara' : 'Scan Next 25 Screenshots';
  String get rescanAll => isTr ? 'Baştan Tara' : 'Rescan All';
  String get scanning => isTr ? 'Taranıyor...' : 'Scanning...';
  String get catAll => isTr ? 'Tümü' : 'All';
  String get catMovie => isTr ? 'Film / Dizi' : 'Movie / Series';
  String get catAnime => isTr ? 'Anime' : 'Anime';
  String get catBook => isTr ? 'Kitap' : 'Book';
  String get catShopping => isTr ? 'Alışveriş' : 'Shopping';
  String get catTemp => isTr ? 'IBAN / Not' : 'IBAN / Note';

  String get copyPayload => isTr ? 'Kopyala' : 'Copy';
  String get copiedToast =>
      isTr ? 'Panoya kopyalandı!' : 'Copied to clipboard!';
  String get deleteFromGallery =>
      isTr ? 'Orijinali Galeriden Sil' : 'Delete Original from Gallery';
  String get deleteCard => isTr ? 'Kartı Sil' : 'Delete Card';
  String get purgedBadge =>
      isTr ? 'Galeriden Temizlendi' : 'Purged from Gallery';
  String get burstBadge => isTr ? 'Seri' : 'Burst';
  String get emptyStateTitle => isTr
      ? 'Henüz İşlenmiş Ekran Görüntüsü Yok'
      : 'No Processed Screenshots Yet';
  String get emptyStateSub => isTr
      ? 'SnapVault arka planda çalışmaz ve pil tüketmez.\nEkran görüntülerinizi taramak için aşağıdaki "Sonraki 25 Görüntüyü Tara" butonuna dokunun.'
      : 'SnapVault never runs in the background or drains battery.\nTap "Scan Next 25 Screenshots" below to organize your screenshots.';
  String get permDenied => isTr
      ? 'Galeri izni gerekli. Lütfen ayarlardan fotoğraf erişimine izin verin.'
      : 'Gallery permission required. Please grant photo access in Settings.';
  String get openSettings => isTr ? 'Ayarları Aç' : 'Open Settings';
  String scanCompleteMsg(int added, int grouped) => isTr
      ? '$added yeni kart eklendi ($grouped seri çekim birleştirildi).'
      : '$added new cards added ($grouped burst shots merged).';
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
  final String? actionPayload;
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
    final decodedGroup =
        (jsonDecode(map['grouped_asset_ids'] as String? ?? '[]') as List<dynamic>)
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

  static Future<void> clearProcessedAssets() async {
    final db = await instance;
    await db.delete('processed_assets');
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
//    Uses primitive Map<String, dynamic> with compute() so Dart NEVER captures
//    State/BuildContext across Isolate boundaries!
// ============================================================================

Future<Map<String, dynamic>> processScreenshotInIsolate(
  Map<String, dynamic> payload,
) async {
  final Uint8List thumbBytes = payload['thumbBytes'] as Uint8List;
  final String targetThumbFilePath = payload['targetThumbFilePath'] as String;
  final int origW = (payload['origWidth'] as int?) ?? 1080;
  final int origH = (payload['origHeight'] as int?) ?? 2400;
  final List<dynamic> rawOcrList = payload['ocrLines'] as List<dynamic>;

  // 1. Decode thumbnail & compute 64-bit Difference Perceptual Hash (dHash)
  String pHashHex = '0000000000000000';
  try {
    final decoded = img.decodeImage(thumbBytes);
    if (decoded != null) {
      final preview =
          decoded.width > 400 ? img.copyResize(decoded, width: 400) : decoded;
      final jpgBytes = img.encodeJpg(preview, quality: 82);
      await File(targetThumbFilePath).writeAsBytes(jpgBytes, flush: false);

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
      await File(targetThumbFilePath).writeAsBytes(thumbBytes, flush: false);
    }
  } catch (_) {
    await File(targetThumbFilePath).writeAsBytes(thumbBytes, flush: false);
  }

  // 2. Coordinate-Based Bounding-Box Filtering using true full-resolution dimensions
  final imgW = origW > 0 ? origW : 1080;
  final imgH = origH > 0 ? origH : 2400;

  final List<Map<String, dynamic>> validLines = [];
  for (final item in rawOcrList) {
    final map = item as Map<String, dynamic>;
    final String text = (map['text'] as String?) ?? '';
    final double left = (map['left'] as num?)?.toDouble() ?? 0.0;
    final double top = (map['top'] as num?)?.toDouble() ?? 0.0;
    final double right = (map['right'] as num?)?.toDouble() ?? 0.0;
    final double bottom = (map['bottom'] as num?)?.toDouble() ?? 0.0;

    final centerY = (top + bottom) / 2.0;
    final centerX = (left + right) / 2.0;
    final normY = centerY / imgH;
    final normX = centerX / imgW;

    // Ignore top 7% (clock/battery status bar) and bottom 6% (gesture nav bar)
    if (normY < 0.07 || normY > 0.94) continue;
    // Ignore far-right TikTok/Reels vertical icon column
    if (normX > 0.86 && normY > 0.45) continue;

    final cleaned = _stripBilingualSocialClutter(text);
    if (cleaned.length >= 2) {
      validLines.add({
        'text': cleaned,
        'height': (bottom - top).abs(),
      });
    }
  }

  // Fallback if coordinate filter was too strict for a cropped screenshot
  if (validLines.isEmpty && rawOcrList.isNotEmpty) {
    for (final item in rawOcrList) {
      final map = item as Map<String, dynamic>;
      final cleaned = _stripBilingualSocialClutter((map['text'] as String?) ?? '');
      if (cleaned.length >= 2) {
        validLines.add({
          'text': cleaned,
          'height': ((map['bottom'] as num? ?? 20) - (map['top'] as num? ?? 0))
              .abs()
              .toDouble(),
        });
      }
    }
  }

  final fullCleanText =
      validLines.map((l) => l['text'] as String).join('\n');
  final lowerText = fullCleanText.toLowerCase();

  // 3. Deterministic Bilingual (TR/EN) Regex & Keyword Classification
  // 3A. Check Temporary / IBAN / Verification Code
  final ibanRegex = RegExp(
    r'\bTR\s*\d{2}\s*(?:\d{4}\s*){5}\d{2}\b',
    caseSensitive: false,
  );
  final ibanMatch = ibanRegex.firstMatch(fullCleanText);
  if (ibanMatch != null) {
    final rawIban =
        ibanMatch.group(0)!.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.tempCode.name,
      'extractedTitle':
          'IBAN (${rawIban.substring(0, 6)}...${rawIban.substring(rawIban.length - 4)})',
      'cleanedText': fullCleanText,
      'actionPayload': rawIban,
    };
  }

  final otpKeywords = RegExp(
    r'\b(doğrulama kodu|onay kodu|şifre|kargo takip|iade kodu|verification code|security code|otp|passcode|tracking number|iban)\b',
    caseSensitive: false,
  );
  if (otpKeywords.hasMatch(lowerText)) {
    final codeMatch = RegExp(r'\b[A-Z0-9]{4,14}\b').firstMatch(fullCleanText);
    final code = codeMatch?.group(0) ?? _pickProminentTitle(validLines);
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.tempCode.name,
      'extractedTitle': code.isNotEmpty ? 'Kod: $code' : 'Geçici Kod / Not',
      'cleanedText': fullCleanText,
      'actionPayload': code,
    };
  }

  // 3B. Check Shopping / Product / E-Commerce (TR & EN)
  final priceRegex = RegExp(
    r'(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?\s*(?:TL|₺|TRY|USD|\$|EUR|€))|(?:(?:TL|₺|\$|€)\s*\d{1,3}(?:[.,]\d{3})*)',
    caseSensitive: false,
  );
  final shoppingKeywords = RegExp(
    r'\b(sepete ekle|hemen al|ücretsiz kargo|indirim|beden|stokta|trendyol|hepsiburada|amazon|n11|zara|bershka|add to cart|buy now|free shipping|in stock|checkout|discount|fiyat)\b',
    caseSensitive: false,
  );
  final priceMatch = priceRegex.firstMatch(fullCleanText);
  if (shoppingKeywords.hasMatch(lowerText) || priceMatch != null) {
    final detectedPrice = priceMatch?.group(0)?.trim();
    final title = _pickProminentTitle(validLines, ignoreRegex: priceRegex);
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.shopping.name,
      'extractedTitle': title.isNotEmpty ? title : 'Ürün / Alışveriş',
      'cleanedText': fullCleanText,
      'actionPayload': detectedPrice,
    };
  }

  // 3C. Check Anime (TR & EN)
  final animeKeywords = RegExp(
    r'\b(anime|manga|myanimelist|crunchyroll|anizle|türkanime|turkanime|shonen|shounen|seinen|isekai|ova|subbed|dubbed|altyazılı|fansub|webtoon|manhwa)\b',
    caseSensitive: false,
  );
  final japaneseCue = RegExp(
    r'\b(naruto|one piece|bleach|attack on titan|shingeki|jujutsu kaisen|demon slayer|kimetsu|death note|fullmetal|hunter x hunter|chainsaw man|frieren|solo leveling|steins|evangelion|gintama|berserk|vinland|haikyuu|blue lock|boku no hero|my hero academia|dan da dan|dandadan|one punch|dragon ball|uzumaki|uchiha|gojo|sukuna|luffy|zoro)\b',
    caseSensitive: false,
  );
  if (japaneseCue.hasMatch(lowerText) || animeKeywords.hasMatch(lowerText)) {
    final title = _pickProminentTitle(validLines);
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.anime.name,
      'extractedTitle': title,
      'cleanedText': fullCleanText,
      'actionPayload': null,
    };
  }

  // 3D. Check Book / Literature (TR & EN)
  final bookKeywords = RegExp(
    r'\b(isbn|kitap|roman|yazar|yayınları|yayınevi|çevirmen|sayfa\s*\d+|goodreads|1000kitap|kitapyurdu|chapter\s*\d+|page\s*\d+|author|published by|publisher|novel|bestseller|edebiyat)\b',
    caseSensitive: false,
  );
  if (bookKeywords.hasMatch(lowerText) ||
      (validLines.length >= 6 && fullCleanText.length > 350)) {
    final title = _pickProminentTitle(validLines);
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.book.name,
      'extractedTitle': title,
      'cleanedText': fullCleanText,
      'actionPayload': null,
    };
  }

  // 3E. Check Movie / TV Series (TR & EN)
  final movieKeywords = RegExp(
    r'\b(imdb|netflix|disney\+|prime video|blutv|mubi|exxen|gain|hbo|apple tv|yönetmen|oyuncular|fragman|sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|s\d{1,2}e\d{1,2}|directed by|starring|trailer|cast|rottentomatoes|letterboxd|film|dizi)\b',
    caseSensitive: false,
  );
  if (movieKeywords.hasMatch(lowerText)) {
    final title = _pickProminentTitle(validLines);
    return {
      'pHashHex': pHashHex,
      'category': VaultCategory.movieSeries.name,
      'extractedTitle': title,
      'cleanedText': fullCleanText,
      'actionPayload': null,
    };
  }

  // Default fallback
  final yearMatch = RegExp(r'\b(19\d{2}|20[0-2]\d)\b').hasMatch(fullCleanText);
  final fallbackTitle = _pickProminentTitle(validLines);
  return {
    'pHashHex': pHashHex,
    'category': yearMatch
        ? VaultCategory.movieSeries.name
        : VaultCategory.tempCode.name,
    'extractedTitle':
        fallbackTitle.isNotEmpty ? fallbackTitle : 'Ekran Görüntüsü',
    'cleanedText':
        fullCleanText.isNotEmpty ? fullCleanText : 'Görsel Kayıt',
    'actionPayload':
        (!yearMatch && fallbackTitle.isNotEmpty) ? fallbackTitle : null,
  };
}

String _stripBilingualSocialClutter(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';

  final pureNoiseLine = RegExp(
    r'^(\d{1,2}:\d{2}|\d+\s*(sn|dk|sa|gün|hafta|ay|yıl|s|m|h|d|w|y)\s*(önce|ago)?|\d+[.,]?\d*\s*(b|bin|m|mn|k|görüntüleme|views|likes|beğeni|yorum|comments)|@[a-zA-Z0-9_.\-]+|#\S+)$',
    caseSensitive: false,
  );
  if (pureNoiseLine.hasMatch(s)) return '';

  final uiWords = RegExp(
    r'\b(beğen|yorum yap|yorumlar|paylaş|kaydet|takip et|takip ediliyor|abone ol|daha fazla|devamını oku|sesi aç|orijinal ses|like|comment|share|save|follow|following|subscribe|more|read more|original audio|sponsored|reklam)\b',
    caseSensitive: false,
  );
  s = s.replaceAll(uiWords, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

String _pickProminentTitle(
  List<Map<String, dynamic>> lines, {
  RegExp? ignoreRegex,
}) {
  if (lines.isEmpty) return 'Ekran Görüntüsü';

  final episodeStrip = RegExp(
    r'\b(sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|ep\.?\s*\d+|s\d+e\d+|hd|1080p|720p|4k|izle|watch|fragman|trailer|altyazılı|dublaj)\b',
    caseSensitive: false,
  );

  String? bestText;
  double bestScore = -1.0;

  for (final l in lines) {
    final rawText = (l['text'] as String?) ?? '';
    final height = (l['height'] as num?)?.toDouble() ?? 16.0;

    var candidate = rawText.replaceAll(episodeStrip, ' ').trim();
    if (ignoreRegex != null) {
      candidate = candidate.replaceAll(ignoreRegex, ' ').trim();
    }
    candidate = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (candidate.length < 2 || candidate.length > 70) continue;

    final letters =
        RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ0-9]').allMatches(candidate).length;
    if (letters < 2) continue;

    final alphaRatio = letters / candidate.length;
    final score = height * (0.5 + alphaRatio);

    if (score > bestScore) {
      bestScore = score;
      bestText = candidate;
    }
  }

  return bestText ?? (lines.first['text'] as String? ?? 'Ekran Görüntüsü');
}

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

  static Future<EnrichedMetadata?> _fetchMovieOrShow(String query) async {
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
  String _statusBanner = '';

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
    await _scanNewScreenshots();
  }

  Future<void> _toggleLanguage() async {
    final next = _lang == AppLang.tr ? AppLang.en : AppLang.tr;
    await SnapVaultDb.saveLanguage(next);
    if (!mounted) return;
    setState(() => _lang = next);
  }

  Future<void> _resetAndRescan() async {
    if (_isScanning) return;
    await SnapVaultDb.clearProcessedAssets();
    await _scanNewScreenshots();
  }

  /// Strictly On-Demand Screenshot Scanner:
  /// 1. Collects all non-empty Screenshot albums (or falls back to main album)
  /// 2. Scans up to 25 unprocessed screenshots per tap in throttled batches of 5
  /// 3. Uses `compute(processScreenshotInIsolate, map)` with primitive Map payload
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
      _statusBanner = _t.isTr ? 'Albümler kontrol ediliyor...' : 'Checking albums...';
    });

    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );

      if (paths.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusBanner = _t.isTr ? 'Galeride fotoğraf bulunamadı.' : 'No images found in gallery.';
          });
        }
        return;
      }

      // Find all non-empty Screenshot albums (handles devices with multiple Screenshot folders)
      final List<AssetPathEntity> screenshotAlbums = [];
      int totalScreenshotCount = 0;

      for (final album in paths) {
        final count = await album.assetCountAsync;
        if (count <= 0) continue;
        final lowerName = album.name.toLowerCase();
        if (lowerName.contains('screenshot') ||
            lowerName.contains('ekran') ||
            lowerName.contains('screen')) {
          screenshotAlbums.add(album);
          totalScreenshotCount += count;
        }
      }

      // If no album is named "Screenshots", use the largest non-empty album (e.g. Recent/All)
      if (screenshotAlbums.isEmpty) {
        for (final album in paths) {
          final count = await album.assetCountAsync;
          if (count > 0) {
            screenshotAlbums.add(album);
            totalScreenshotCount = count;
            break;
          }
        }
      }

      if (screenshotAlbums.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusBanner = _t.isTr ? 'Taranacak görüntü bulunamadı.' : 'No screenshots found.';
          });
        }
        return;
      }

      final processedIds = await SnapVaultDb.loadProcessedAssetIds();
      final List<AssetEntity> newAssets = [];

      // Page through the screenshot album(s) until we gather 25 unprocessed screenshots
      for (final album in screenshotAlbums) {
        int page = 0;
        const int pageSize = 50;
        while (newAssets.length < 25 && page < 80) {
          final pageAssets =
              await album.getAssetListPaged(page: page, size: pageSize);
          if (pageAssets.isEmpty) break;
          for (final a in pageAssets) {
            if (!processedIds.contains(a.id)) {
              newAssets.add(a);
              if (newAssets.length >= 25) break;
            }
          }
          if (pageAssets.length < pageSize) break;
          page++;
        }
        if (newAssets.length >= 25) break;
      }

      if (newAssets.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusBanner = _t.isTr
                ? 'Toplam $totalScreenshotCount görüntü incelendi (Yeni görüntü yok).'
                : 'Checked $totalScreenshotCount images (No new items).';
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _scanTotalCount = newAssets.length;
          _statusBanner = _t.isTr
              ? 'Bulunan: $totalScreenshotCount görüntü • 25 yeni görüntü işleniyor...'
              : 'Found: $totalScreenshotCount images • Processing batch of ${newAssets.length}...';
        });
      }

      final appSupportDir = await getApplicationSupportDirectory();
      final thumbDir = Directory(p.join(appSupportDir.path, 'vault_thumbs'));
      if (!thumbDir.existsSync()) {
        thumbDir.createSync(recursive: true);
      }

      int addedCardsCount = 0;
      int burstMergedCount = 0;

      const int batchSize = 5;
      for (int i = 0; i < newAssets.length; i += batchSize) {
        final batch = newAssets.skip(i).take(batchSize).toList();

        for (final asset in batch) {
          try {
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

            // 1. Run on-device ML Kit OCR (wrapped in its own try/catch so even pure-image screenshots work)
            final rawLines = <Map<String, dynamic>>[];
            try {
              final inputImage = InputImage.fromFilePath(file.path);
              final recognized = await textRecognizer.processImage(inputImage);
              for (final block in recognized.blocks) {
                for (final line in block.lines) {
                  final rect = line.boundingBox;
                  rawLines.add({
                    'text': line.text,
                    'left': rect.left,
                    'top': rect.top,
                    'right': rect.right,
                    'bottom': rect.bottom,
                  });
                }
              }
            } catch (_) {
              // OCR failed on this image format; proceed with visual card creation
            }

            // 2. Run pHash & Bilingual Classifier inside background Isolate using `compute()`
            final safeId = asset.id.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
            final targetThumbPath = p.join(
              thumbDir.path,
              'thumb_${safeId}_${asset.createDateSecond}.jpg',
            );

            final isolatePayload = <String, dynamic>{
              'thumbBytes': thumbBytes,
              'targetThumbFilePath': targetThumbPath,
              'origWidth': asset.width,
              'origHeight': asset.height,
              'ocrLines': rawLines,
            };

            final result =
                await compute(processScreenshotInIsolate, isolatePayload);

            final String pHashHex = result['pHashHex'] as String;
            final String catName = result['category'] as String;
            final VaultCategory category = VaultCategory.values.firstWhere(
              (e) => e.name == catName,
              orElse: () => VaultCategory.tempCode,
            );
            final String extractedTitle = result['extractedTitle'] as String;
            final String cleanedText = result['cleanedText'] as String;
            final String? actionPayload = result['actionPayload'] as String?;

            final capturedMs = asset.createDateTime.millisecondsSinceEpoch;

            // 3. Smart Burst-Shot Grouping:
            //    Merge only if BOTH captured within 4 seconds AND perceptually very similar (Hamming <= 6)
            VaultCard? burstTarget;
            for (final existing in _cards) {
              final timeDiffMs = (capturedMs - existing.capturedEpochMs).abs();
              final pHashDist = hammingDistanceHex(pHashHex, existing.pHashHex);
              if (existing.category == category &&
                  timeDiffMs <= 4000 &&
                  pHashDist <= 6) {
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
              final newCard = VaultCard(
                id: 'card_${capturedMs}_$safeId',
                primaryAssetId: asset.id,
                groupedAssetIds: [asset.id],
                localThumbPath: targetThumbPath,
                category: category,
                extractedTitle: extractedTitle,
                cleanedOcrText: cleanedText,
                actionPayload: actionPayload,
                pHashHex: pHashHex,
                capturedEpochMs: capturedMs,
                isPurgedFromGallery: false,
              );

              await SnapVaultDb.upsertCard(newCard);
              await SnapVaultDb.markAssetProcessed(asset.id);

              if (mounted) {
                setState(() {
                  _cards.add(newCard);
                  _cards.sort(
                      (a, b) => b.capturedEpochMs.compareTo(a.capturedEpochMs));
                });
              }
              addedCardsCount++;

              unawaited(_enrichCardInBackground(newCard));
            }
          } catch (err) {
            debugPrint('Asset scan error: $err');
          }

          if (mounted) {
            setState(() => _scanDoneCount++);
          }
          await Future.delayed(const Duration(milliseconds: 16));
        }
      }

      if (mounted) {
        setState(() {
          _statusBanner = _t.scanCompleteMsg(addedCardsCount, burstMergedCount);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusBanner = 'Hata / Error: $e';
        });
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
          Padding(
            padding: const EdgeInsets.only(right: 4),
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
          IconButton(
            tooltip: _t.rescanAll,
            onPressed: _isScanning ? null : _resetAndRescan,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
          ),
        ],
      ),
      body: Column(
        children: [
          // Live Status & Progress Bar
          if (_isScanning || _statusBanner.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF151923),
              child: Row(
                children: [
                  if (_isScanning) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                  ] else ...[
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Color(0xFF10B981),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      _isScanning
                          ? '${_t.scanning} ($_scanDoneCount / $_scanTotalCount) — $_statusBanner'
                          : _statusBanner,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),

          // Instant Offline Search Bar + Bulk Gallery Clean-up Button
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

          // Category Filter Chips
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

          // Main Rich Media Card Grid
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
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCardImage(card),
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
      return const Color(0xFF6366F1);
    case VaultCategory.anime:
      return const Color(0xFFEC4899);
    case VaultCategory.book:
      return const Color(0xFFF59E0B);
    case VaultCategory.shopping:
      return const Color(0xFF10B981);
    case VaultCategory.tempCode:
      return const Color(0xFF06B6D4);
  }
}
