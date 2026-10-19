// ============================================================================
// SnapVault — Zero-Background Bilingual (TR/EN) Gallery & Screenshot Vault
// Architecture:
//   1. Strict On-Demand Execution (Zero background services, zero battery drain)
//   2. Android 13/14/15/16 Image-Only Permission Fix (RequestType.image +
//      setIgnorePermissionCheck)
//   3. Strict Trash-Photo Filter (Skips wallpapers, landscapes, selfies, and
//      casual chat screenshots before image decoding for ultra-fast scanning)
//   4. User-Configurable Scan Batch Limit (Default 25, selectable up to 1000
//      with instant Stop/Cancel & One-Tap Full App Data Reset)
//   5. Transparent Source-to-Match UI (Shows user's original screenshot, exact
//      OCR trigger text, and Picture-in-Picture matched API poster side-by-side)
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
  String get subtitle =>
      isTr ? 'Akıllı Galeri & Ekran Görüntüsü Kasası' : 'Smart Gallery & Screenshot Vault';
  String get searchHint => isTr
      ? 'Film, anime, kitap, ürün, kod veya okunan metin ara...'
      : 'Search movie, anime, book, product, code or OCR text...';
  String scanNextN(int n) =>
      isTr ? 'Sonraki $n Fotoğrafı Tara' : 'Scan Next $n Photos';
  String get stopScan => isTr ? 'Taramayı Durdur' : 'Stop Scan';
  String get resetVaultTitle =>
      isTr ? 'Uygulama Verilerini Sıfırla' : 'Reset App Data';
  String get resetVaultConfirm => isTr
      ? 'Bulunan tüm kartlar ve tarama geçmişi sıfırlanacak (Telefon galerinizdeki fotoğraflara dokunulmaz). Devam edilsin mi?'
      : 'All saved cards and scan history will be cleared (Your phone gallery photos will NOT be deleted). Continue?';
  String get cancel => isTr ? 'Vazgeç' : 'Cancel';
  String get resetNow => isTr ? 'Verileri Sıfırla' : 'Reset All Data';
  String get resetDoneToast => isTr
      ? 'Tüm uygulama verileri ve tarama geçmişi sıfırlandı.'
      : 'All app data and scan history have been reset.';
  String get scanLimitLabel => isTr ? 'Tarama Adedi:' : 'Scan Limit:';
  String get allGalleryAlbum => isTr ? 'Tüm Galeri' : 'All Gallery';
  String get catAll => isTr ? 'Tümü' : 'All';
  String get catMovie => isTr ? 'Film / Dizi' : 'Movie / Series';
  String get catAnime => isTr ? 'Anime' : 'Anime';
  String get catBook => isTr ? 'Kitap' : 'Book';
  String get catShopping => isTr ? 'Alışveriş' : 'Shopping';
  String get catTemp => isTr ? 'IBAN / Kod / Link' : 'IBAN / Code / Link';

  String get copyPayload => isTr ? 'Kopyala' : 'Copy';
  String get copiedToast =>
      isTr ? 'Panoya kopyalandı!' : 'Copied to clipboard!';
  String get deleteFromGallery =>
      isTr ? 'Orijinali Galeriden Sil' : 'Delete Original from Gallery';
  String get deleteCard => isTr ? 'Kartı Kaldır' : 'Remove Card';
  String get purgedBadge =>
      isTr ? 'Galeriden Silindi' : 'Purged from Gallery';
  String get burstBadge => isTr ? 'Seri' : 'Burst';
  String get readFromPhotoLabel =>
      isTr ? 'Fotoğraftan Okunan:' : 'Read from Photo:';
  String get matchedResultLabel =>
      isTr ? 'Eşleşen Sonuç:' : 'Matched Result:';
  String get emptyStateTitle => isTr
      ? 'Kasanız Temiz ve Taranmaya Hazır'
      : 'Your Vault is Clean & Ready';
  String get emptyStateSub => isTr
      ? 'Manzara, duvar kağıdı ve sıradan sohbet fotoğrafları otomatik atlanır.\nSadece Film/Dizi, Anime, Kitap, Alışveriş/Fiyat ve IBAN/Kod/Link içeren fotoğraflar karta dönüştürülür.\n\nÜstten tarama adedini (25 - 1000) seçip taramayı başlatabilirsiniz.'
      : 'Wallpapers, landscapes, and casual chats are automatically skipped.\nOnly Movies/Series, Anime, Books, Shopping/Prices, and IBAN/Codes/Links are turned into cards.\n\nPick your scan batch size (25 - 1000) and start scanning.';
  String get permDenied => isTr
      ? 'Galeri erişim izni gerekli. Lütfen aşağıdaki butondan uygulama ayarlarını açıp Fotoğraflar iznini verin.'
      : 'Gallery permission required. Please tap below to grant Photos permission in Settings.';
  String get openSettings =>
      isTr ? 'İzin Ayarlarını Aç' : 'Open Permission Settings';

  String scanCompleteMsg(int scanned, int added, int skipped) => isTr
      ? '$scanned foto incelendi: $added anlamlı kart bulundu, $skipped alakasız görsel atlandı.'
      : 'Checked $scanned photos: $added cards created, $skipped irrelevant images skipped.';

  String purgeSuccessMsg(int count) => isTr
      ? '$count orijinal fotoğraf telefon galerisinden silindi!'
      : '$count original photos deleted from device gallery!';

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

  bool get hasApiMatch => apiTitle != null && apiTitle!.trim().isNotEmpty;

  String get displayTitle =>
      hasApiMatch ? apiTitle! : extractedTitle;

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
        (jsonDecode(map['grouped_asset_ids'] as String? ?? '[]')
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

  static Future<void> resetAllVaultData() async {
    final db = await instance;
    await db.delete('vault_cards');
    await db.delete('processed_assets');
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final thumbDir = Directory(p.join(appSupportDir.path, 'vault_thumbs'));
      if (thumbDir.existsSync()) {
        await thumbDir.delete(recursive: true);
      }
    } catch (_) {}
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

  static Future<int> loadScanLimit() async {
    final db = await instance;
    final rows = await db.query(
      'app_Config',
      where: 'cfg_key = ?',
      whereArgs: ['scan_limit'],
    );
    if (rows.isEmpty) return 25;
    return int.tryParse(rows.first['cfg_val'] as String? ?? '25') ?? 25;
  }

  static Future<void> saveScanLimit(int limit) async {
    final db = await instance;
    await db.insert(
      'app_Config',
      {'cfg_key': 'scan_limit', 'cfg_val': '$limit'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

// ============================================================================
// 4. ISOLATE-SAFE STRICT CLASSIFIER & PERCEPTUAL HASHING ENGINE
// ============================================================================

Future<Map<String, dynamic>> processScreenshotInIsolate(
  Map<String, dynamic> payload,
) async {
  final Uint8List thumbBytes = payload['thumbBytes'] as Uint8List;
  final String targetThumbFilePath = payload['targetThumbFilePath'] as String;
  final int origW = (payload['origWidth'] as int?) ?? 1080;
  final int origH = (payload['origHeight'] as int?) ?? 2400;
  final List<dynamic> rawOcrList = payload['ocrLines'] as List<dynamic>;

  // STEP 1: Fast Coordinate & Social Clutter Filtering BEFORE decoding image
  if (rawOcrList.isEmpty) {
    return {'skip': true};
  }

  final imgW = origW > 0 ? origW : 1080;
  final imgH = origH > 0 ? origH : 2400;
  final bool isPortraitScreen = imgH > imgW * 1.5;

  final List<Map<String, dynamic>> validLines = [];
  for (final item in rawOcrList) {
    final map = item as Map<String, dynamic>;
    final String text = (map['text'] as String?) ?? '';
    final double left = (map['left'] as num?)?.toDouble() ?? 0.0;
    final double top = (map['top'] as num?)?.toDouble() ?? 0.0;
    final double right = (map['right'] as num?)?.toDouble() ?? 0.0;
    final double bottom = (map['bottom'] as num?)?.toDouble() ?? 0.0;

    if (isPortraitScreen) {
      final centerY = (top + bottom) / 2.0;
      final centerX = (left + right) / 2.0;
      final normY = centerY / imgH;
      final normX = centerX / imgW;

      // Ignore top 5% status bar and bottom 5% gesture bar on phone screenshots
      if (normY < 0.05 || normY > 0.95) continue;
      // Ignore right-edge social media action buttons (Reels/TikTok/Shorts)
      if (normX > 0.88 && normY > 0.45) continue;
    }

    final cleaned = _stripBilingualSocialClutter(text);
    if (cleaned.length >= 2) {
      validLines.add({
        'text': cleaned,
        'height': (bottom - top).abs(),
      });
    }
  }

  if (validLines.isEmpty) {
    return {'skip': true};
  }

  final fullCleanText =
      validLines.map((l) => l['text'] as String).join('\n');
  final lowerText = fullCleanText.toLowerCase();

  // Reject pure chat / DM / GitHub / system UI screenshots unless they contain an IBAN or price
  final chatOrSystemNoise = RegExp(
    r'\b(senin notuna yanıt verdi|bir fotoğraf gönderdi|bir video gönderdi|sesli mesaj|mesaj yaz|çevrimiçi|son görülme|replied to your note|sent a photo|type a message|workflow run|build snapvault|scraper cron job|unread repository|commit by)\b',
    caseSensitive: false,
  );

  // 1. Check IBAN (Turkish & International)
  final ibanRegex = RegExp(
    r'\bTR\s*\d{2}\s*(?:\d{4}\s*){5}\d{2}\b',
    caseSensitive: false,
  );
  final ibanMatch = ibanRegex.firstMatch(fullCleanText);

  if (chatOrSystemNoise.hasMatch(lowerText) && ibanMatch == null) {
    return {'skip': true};
  }

  String? matchedCategory;
  String? extractedTitle;
  String? actionPayload;

  if (ibanMatch != null) {
    final rawIban =
        ibanMatch.group(0)!.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    matchedCategory = VaultCategory.tempCode.name;
    extractedTitle =
        'IBAN (${rawIban.substring(0, 6)}...${rawIban.substring(rawIban.length - 4)})';
    actionPayload = rawIban;
  }

  // 2. Check Explicit OTP / Verification / Cargo Code / Wi-Fi / URL / QR Link
  if (matchedCategory == null) {
    final urlRegex = RegExp(
      r'(https?:\/\/[^\s]+)|(www\.[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}[^\s]*)',
      caseSensitive: false,
    );
    final urlMatch = urlRegex.firstMatch(fullCleanText);

    final otpKeywords = RegExp(
      r'\b(doğrulama kodu|onay kodu|tek kullanımlık şifre|kargo takip|takip numarası|iade kodu|rezervasyon kodu|pnr\s*kodu|kupon kodu|promosyon kodu|verification code|security code|otp\s*code|passcode|tracking number|wifi\s*şifre|wi-fi\s*password|otopark)\b',
      caseSensitive: false,
    );

    if (urlMatch != null) {
      final rawUrl = urlMatch.group(0)!.trim();
      matchedCategory = VaultCategory.tempCode.name;
      extractedTitle = rawUrl;
      actionPayload = rawUrl;
    } else if (otpKeywords.hasMatch(lowerText)) {
      final codeMatch =
          RegExp(r'\b[A-Z0-9]{4,14}\b').firstMatch(fullCleanText);
      final title = _pickProminentTitle(validLines);
      final payloadStr = codeMatch?.group(0) ?? title;
      if (payloadStr.length >= 3) {
        matchedCategory = VaultCategory.tempCode.name;
        extractedTitle = title.isNotEmpty ? title : payloadStr;
        actionPayload = payloadStr;
      }
    }
  }

  // 3. Check Shopping / Product / Price Tag
  if (matchedCategory == null) {
    final priceRegex = RegExp(
      r'(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?\s*(?:TL|₺|TRY|USD|\$|EUR|€))|(?:(?:TL|₺|\$|€)\s*\d{1,3}(?:[.,]\d{3})*)',
      caseSensitive: false,
    );
    final shoppingKeywords = RegExp(
      r'\b(sepete ekle|hemen al|ücretsiz kargo|kargo bedava|trendyol|hepsiburada|amazon\.com|n11\.com|akakçe|cimri|add to cart|buy now|free shipping|sipariş özeti|ürün özellikleri)\b',
      caseSensitive: false,
    );
    final priceMatch = priceRegex.firstMatch(fullCleanText);
    if (shoppingKeywords.hasMatch(lowerText) || priceMatch != null) {
      final detectedPrice = priceMatch?.group(0)?.trim();
      final title = _pickProminentTitle(validLines, ignoreRegex: priceRegex);
      if (title.length >= 3) {
        matchedCategory = VaultCategory.shopping.name;
        extractedTitle = title;
        actionPayload = detectedPrice;
      }
    }
  }

  // 4. Check Anime / Manga / Webtoon
  if (matchedCategory == null) {
    final animeKeywords = RegExp(
      r'\b(myanimelist|crunchyroll|anizle|türkanime|turkanime|animecix|openani|shonen|shounen|seinen|isekai|fansub|webtoon|manhwa|manga\s*oku|anime\s*izle)\b',
      caseSensitive: false,
    );
    final famousAnimeCue = RegExp(
      r'\b(naruto|one piece|bleach|attack on titan|shingeki no kyojin|jujutsu kaisen|demon slayer|kimetsu no yaiba|death note|fullmetal alchemist|hunter x hunter|chainsaw man|frieren|solo leveling|steins;gate|evangelion|gintama|berserk|vinland saga|haikyuu|blue lock|my hero academia|boku no hero|dandadan|one punch man|dragon ball|uzumaki|uchiha|gojo satoru|luffy)\b',
      caseSensitive: false,
    );
    if (animeKeywords.hasMatch(lowerText) ||
        famousAnimeCue.hasMatch(lowerText)) {
      final title = _pickProminentTitle(validLines);
      if (_isValidMediaTitle(title)) {
        matchedCategory = VaultCategory.anime.name;
        extractedTitle = title;
      }
    }
  }

  // 5. Check Book / Novel (Strictly excluding school/club/announcement posters)
  if (matchedCategory == null) {
    final announcementExclude = RegExp(
      r'\b(öğrenci kulübü|başvuru|başvurusu|duyuru|üniversitesi|fakültesi|rektörlük|sınav|kongre|sempozyum|etkinlik takvimi)\b',
      caseSensitive: false,
    );
    final bookKeywords = RegExp(
      r'\b(isbn|yayınevi|yayınları|kitabevi|çevirmen|çeviren|sayfa\s*\d+|goodreads|1000kitap|kitapyurdu|bkmkitap|idefix|dr\.com\.tr|chapter\s*\d+|published by|paperback|hardcover|bestseller|romanı|kitabı)\b',
      caseSensitive: false,
    );
    if (!announcementExclude.hasMatch(lowerText) &&
        bookKeywords.hasMatch(lowerText)) {
      final title = _pickProminentTitle(validLines);
      if (_isValidMediaTitle(title)) {
        matchedCategory = VaultCategory.book.name;
        extractedTitle = title;
      }
    }
  }

  // 6. Check Movie / TV Series (Requires explicit streaming/cinema/episode cues)
  if (matchedCategory == null) {
    final movieKeywords = RegExp(
      r'\b(imdb|netflix|disney\+|prime video|blutv|mubi|exxen|gain|hbo max|apple tv\+|letterboxd|rottentomatoes|beyazperde|sinemalar|yönetmen|fragman|sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|s\d{1,2}e\d{1,2}|directed by|starring|original series|altyazılı|türkçe dublaj|vizyon tarihi|imax)\b',
      caseSensitive: false,
    );
    if (movieKeywords.hasMatch(lowerText)) {
      final title = _pickProminentTitle(validLines);
      if (_isValidMediaTitle(title)) {
        matchedCategory = VaultCategory.movieSeries.name;
        extractedTitle = title;
      }
    }
  }

  // STRICT FILTER: If the photo did not match any real category, SKIP IT!
  if (matchedCategory == null ||
      extractedTitle == null ||
      extractedTitle.trim().isEmpty) {
    return {'skip': true};
  }

  // STEP 2: Only decode thumbnail & compute 64-bit dHash for ACCEPTED cards!
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

  return {
    'skip': false,
    'pHashHex': pHashHex,
    'category': matchedCategory,
    'extractedTitle': extractedTitle,
    'cleanedText': fullCleanText,
    'actionPayload': actionPayload,
  };
}

bool _isValidMediaTitle(String title) {
  final t = title.trim();
  if (t.length < 3 || t.length > 65) return false;
  // Reject purely numeric strings like "3" or "2024"
  if (RegExp(r'^\d+$').hasMatch(t)) return false;
  // Require at least 3 letters
  final letterCount =
      RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ]').allMatches(t).length;
  if (letterCount < 3) return false;
  // Reject single generic UI words like "Contact", "Search", "Home", "Unread"
  final genericUiStop = RegExp(
    r'^(contact|home|search|inbox|unread|profile|settings|login|logout|menu|notification|bildirim|ayarlar|anasayfa|iletişim|mesajlar|galeri|görsel kayıt)$',
    caseSensitive: false,
  );
  if (genericUiStop.hasMatch(t)) return false;
  return true;
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
  if (lines.isEmpty) return '';

  final episodeStrip = RegExp(
    r'\b(sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|ep\.?\s*\d+|s\d+e\d+|hd|1080p|720p|4k|izle|watch|fragman|trailer|altyazılı|türkçe dublaj|dublaj|netflix|imdb|disney\+|prime video|blutv)\b',
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
    if (candidate.length < 3 || candidate.length > 65) continue;

    final letters =
        RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ]').allMatches(candidate).length;
    if (letters < 3) continue;

    final alphaRatio = letters / candidate.length;
    final score = height * (0.5 + alphaRatio);

    if (score > bestScore) {
      bestScore = score;
      bestText = candidate;
    }
  }

  return bestText ?? '';
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
// 5. ZERO-KEY PUBLIC METADATA ENRICHER WITH STRICT SIMILARITY VERIFICATION
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

    if (!_isValidMediaTitle(cleanQuery)) return null;
    final words = cleanQuery.split(' ');
    if (words.length > 7) return null;

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

  /// Ensures API result title actually matches the OCR query (prevents
  /// "Öğrenci Kulübü" -> "İslâm eğitiminde..." or "3" -> "3 (2012 TV Series)")
  static bool _isTitleSimilar(String query, String apiTitle) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9çğıöşü\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final nq = norm(query);
    final na = norm(apiTitle);
    if (nq.length < 3 || na.length < 3) return false;
    if (na == nq) return true;
    if (na.contains(nq) && nq.length >= 5) return true;
    if (nq.contains(na) && na.length >= 5) return true;

    final qWords = nq.split(' ').where((w) => w.length >= 3).toSet();
    final aWords = na.split(' ').where((w) => w.length >= 3).toSet();
    if (qWords.isEmpty || aWords.isEmpty) return false;

    final overlap = qWords.intersection(aWords).length;
    final minLen = qWords.length < aWords.length ? qWords.length : aWords.length;
    return overlap > 0 && (overlap / minLen) >= 0.5;
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
    final titleEn = item['title_english']?.toString() ?? '';
    final titleJp = item['title']?.toString() ?? '';
    final bestTitle = titleEn.isNotEmpty ? titleEn : titleJp;

    if (!_isTitleSimilar(query, titleEn) && !_isTitleSimilar(query, titleJp)) {
      return null;
    }

    final episodes = item['episodes'];
    final year = item['year'];
    final score = (item['score'] as num?)?.toDouble();
    final synopsis = item['synopsis']?.toString();
    final images = item['images'] as Map<String, dynamic>?;
    final jpg = images?['jpg'] as Map<String, dynamic>?;
    final poster = (jpg?['large_image_url'] ?? jpg?['image_url'])?.toString();

    return EnrichedMetadata(
      title: bestTitle,
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
        final trackName = m['trackName']?.toString() ?? '';
        if (_isTitleSimilar(query, trackName)) {
          final genre = m['primaryGenreName']?.toString();
          final releaseDate = m['releaseDate']?.toString() ?? '';
          final year =
              releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
          final rawArt = m['artworkUrl100']?.toString();
          final hiResArt = rawArt?.replaceAll('100x100bb', '600x600bb');
          final desc = m['longDescription']?.toString() ??
              m['shortDescription']?.toString();

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
      final name = show['name']?.toString() ?? '';
      if (!_isTitleSimilar(query, name)) return null;

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
        'title': query,
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
    final title = doc['title']?.toString() ?? '';
    if (!_isTitleSimilar(query, title)) return null;

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
// 6. MAIN APPLICATION & USER-CONTROLLED ON-DEMAND SCANNER
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
        scaffoldBackgroundColor: const Color(0xFF090C12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF131824),
        ),
        useMaterial3: true,
      ),
      home: const VaultHomeScreen(),
    );
  }
}

class _AlbumEntry {
  final AssetPathEntity album;
  final int count;
  const _AlbumEntry(this.album, this.count);
}

class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key});

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  static const List<int> _scanLimitOptions = [25, 50, 100, 250, 500, 1000];

  AppLang _lang = AppLang.tr;
  L10n get _t => L10n(_lang);

  List<VaultCard> _cards = [];
  List<_AlbumEntry> _albums = [];
  AssetPathEntity? _selectedAlbum;

  VaultCategory? _selectedCategory;
  String _searchQuery = '';
  int _scanLimit = 25;
  bool _isScanning = false;
  bool _cancelScanRequested = false;
  int _scanDoneCount = 0;
  int _scanTotalCount = 0;
  int _scanFoundCount = 0;
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
    final savedLimit = await SnapVaultDb.loadScanLimit();
    final savedCards = await SnapVaultDb.loadAllCards();
    if (!mounted) return;
    setState(() {
      _lang = savedLang;
      _scanLimit = _scanLimitOptions.contains(savedLimit) ? savedLimit : 25;
      _cards = savedCards;
    });
    await _loadAlbumsOnly();
  }

  Future<void> _toggleLanguage() async {
    final next = _lang == AppLang.tr ? AppLang.en : AppLang.tr;
    await SnapVaultDb.saveLanguage(next);
    if (!mounted) return;
    setState(() => _lang = next);
  }

  Future<void> _changeScanLimit(int newLimit) async {
    await SnapVaultDb.saveScanLimit(newLimit);
    if (!mounted) return;
    setState(() => _scanLimit = newLimit);
  }

  Future<void> _confirmAndResetAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever_rounded, color: Color(0xFFF43F5E)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _t.resetVaultTitle,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          _t.resetVaultConfirm,
          style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_t.cancel, style: const TextStyle(color: Colors.white60)),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF43F5E),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cleaning_services_rounded, size: 16),
            label: Text(_t.resetNow),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (_isScanning) {
      setState(() => _cancelScanRequested = true);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    await SnapVaultDb.resetAllVaultData();
    if (!mounted) return;
    setState(() {
      _cards = [];
      _statusBanner = _t.resetDoneToast;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_t.resetDoneToast),
        backgroundColor: const Color(0xFF6366F1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _loadAlbumsOnly() async {
    try {
      const permOption = PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      );
      await PhotoManager.requestPermissionExtend(requestOption: permOption);
      await PhotoManager.setIgnorePermissionCheck(true);

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (paths.isEmpty) {
        if (mounted) setState(() => _permissionDenied = true);
        return;
      }

      final List<_AlbumEntry> nonEmpty = [];
      for (final album in paths) {
        final c = await album.assetCountAsync;
        if (c > 0) nonEmpty.add(_AlbumEntry(album, c));
      }
      if (mounted && nonEmpty.isNotEmpty) {
        setState(() {
          _permissionDenied = false;
          _albums = nonEmpty;
          _selectedAlbum ??= nonEmpty.first.album;
        });
      }
    } catch (_) {}
  }

  Future<void> _scanGalleryPhotos() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _cancelScanRequested = false;
      _scanDoneCount = 0;
      _scanTotalCount = 0;
      _scanFoundCount = 0;
      _statusBanner = _t.isTr
          ? 'Galeri okunuyor ($_scanLimit fotoğraf hazırlanıyor)...'
          : 'Reading gallery (preparing $_scanLimit photos)...';
    });

    try {
      const permOption = PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      );
      await PhotoManager.requestPermissionExtend(requestOption: permOption);
      await PhotoManager.setIgnorePermissionCheck(true);
    } catch (_) {}

    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
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
            _permissionDenied = true;
            _statusBanner = _t.permDenied;
          });
        }
        return;
      }

      final List<_AlbumEntry> nonEmptyAlbums = [];
      for (final album in paths) {
        final c = await album.assetCountAsync;
        if (c > 0) nonEmptyAlbums.add(_AlbumEntry(album, c));
      }

      if (nonEmptyAlbums.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusBanner = _t.isTr
                ? 'Galeride fotoğraf bulunamadı.'
                : 'No photos found in gallery.';
          });
        }
        return;
      }

      AssetPathEntity activeAlbum = nonEmptyAlbums.first.album;
      int activeAlbumCount = nonEmptyAlbums.first.count;
      if (_selectedAlbum != null) {
        for (final entry in nonEmptyAlbums) {
          if (entry.album.id == _selectedAlbum!.id) {
            activeAlbum = entry.album;
            activeAlbumCount = entry.count;
            break;
          }
        }
      }

      if (mounted) {
        setState(() {
          _permissionDenied = false;
          _albums = nonEmptyAlbums;
          _selectedAlbum = activeAlbum;
        });
      }

      final processedIds = await SnapVaultDb.loadProcessedAssetIds();
      final List<AssetEntity> newAssets = [];
      final int targetLimit = _scanLimit;

      int page = 0;
      const int pageSize = 80;
      while (newAssets.length < targetLimit && page < 250) {
        final pageAssets =
            await activeAlbum.getAssetListPaged(page: page, size: pageSize);
        if (pageAssets.isEmpty) break;
        for (final a in pageAssets) {
          if (!processedIds.contains(a.id)) {
            newAssets.add(a);
            if (newAssets.length >= targetLimit) break;
          }
        }
        if (pageAssets.length < pageSize) break;
        page++;
      }

      if (newAssets.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _statusBanner = _t.isTr
                ? 'Bu albümdeki tüm fotoğraflar ($activeAlbumCount) zaten incelendi. Tekrar taramak için sağ üstten Sıfırla butonunu kullanabilirsiniz.'
                : 'All $activeAlbumCount photos in this album were already checked.';
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _scanTotalCount = newAssets.length;
          _statusBanner = _t.isTr
              ? '${newAssets.length} fotoğraf analiz ediliyor...'
              : 'Analyzing ${newAssets.length} photos...';
        });
      }

      final appSupportDir = await getApplicationSupportDirectory();
      final thumbDir = Directory(p.join(appSupportDir.path, 'vault_thumbs'));
      if (!thumbDir.existsSync()) {
        thumbDir.createSync(recursive: true);
      }

      int addedCardsCount = 0;
      int skippedCount = 0;

      const int batchSize = 5;
      for (int i = 0; i < newAssets.length; i += batchSize) {
        if (_cancelScanRequested) break;
        final batch = newAssets.skip(i).take(batchSize).toList();

        for (final asset in batch) {
          if (_cancelScanRequested) break;
          try {
            final file = await asset.file;
            final thumbBytes = await asset.thumbnailDataWithSize(
              const ThumbnailSize(480, 854),
              quality: 84,
            );

            if (file == null || thumbBytes == null) {
              await SnapVaultDb.markAssetProcessed(asset.id);
              skippedCount++;
              if (mounted) setState(() => _scanDoneCount++);
              continue;
            }

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
            } catch (_) {}

            if (rawLines.isEmpty) {
              // Fast path: photo has no text (wallpaper, selfie, landscape) -> skip immediately!
              await SnapVaultDb.markAssetProcessed(asset.id);
              skippedCount++;
              if (mounted) setState(() => _scanDoneCount++);
              continue;
            }

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

            if (result['skip'] == true) {
              await SnapVaultDb.markAssetProcessed(asset.id);
              skippedCount++;
              if (mounted) setState(() => _scanDoneCount++);
              continue;
            }

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

            // Burst-shot & near-duplicate grouping (within 60s or identical pHash/title)
            VaultCard? burstTarget;
            for (final existing in _cards) {
              final timeDiffMs = (capturedMs - existing.capturedEpochMs).abs();
              final pHashDist = hammingDistanceHex(pHashHex, existing.pHashHex);
              final sameTitle = existing.extractedTitle.toLowerCase() ==
                  extractedTitle.toLowerCase();
              if (existing.category == category &&
                  ((timeDiffMs <= 15000 && pHashDist <= 8) ||
                      (pHashDist <= 4) ||
                      (sameTitle && timeDiffMs <= 120000))) {
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

              addedCardsCount++;
              if (mounted) {
                setState(() {
                  _scanFoundCount = addedCardsCount;
                  _cards.add(newCard);
                  _cards.sort(
                      (a, b) => b.capturedEpochMs.compareTo(a.capturedEpochMs));
                });
              }

              unawaited(_enrichCardInBackground(newCard));
            }
          } catch (err) {
            debugPrint('Asset scan error: $err');
          }

          if (mounted) {
            setState(() => _scanDoneCount++);
          }
          await Future.delayed(const Duration(milliseconds: 12));
        }
      }

      if (mounted) {
        setState(() {
          _statusBanner = _t.scanCompleteMsg(
            _scanDoneCount,
            addedCardsCount,
            skippedCount,
          );
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
        setState(() {
          _isScanning = false;
          _cancelScanRequested = false;
        });
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
        final matchExtracted = card.extractedTitle.toLowerCase().contains(q);
        final matchOcr = card.cleanedOcrText.toLowerCase().contains(q);
        final matchPayload =
            (card.actionPayload ?? '').toLowerCase().contains(q);
        return matchTitle || matchExtracted || matchOcr || matchPayload;
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
        backgroundColor: const Color(0xFF090C12),
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6366F1), Color(0xFF06B6D4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.center_focus_strong_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t.appTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                      letterSpacing: -0.4,
                    ),
                  ),
                  Text(
                    _t.subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Language Switch (TR / EN)
          TextButton.icon(
            onPressed: _toggleLanguage,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF171D2B),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(Icons.language, size: 15, color: Colors.white70),
            label: Text(
              _lang == AppLang.tr ? 'TR' : 'EN',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Reset All Data Button (Wipes DB & Scan History)
          IconButton(
            tooltip: _t.resetVaultTitle,
            onPressed: _confirmAndResetAllData,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF2A1520),
            ),
            icon: const Icon(
              Icons.delete_forever_rounded,
              color: Color(0xFFF43F5E),
              size: 20,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 1. Live Scan Progress Banner
          if (_isScanning || _statusBanner.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF131824),
                border: Border(
                  bottom: BorderSide(color: Colors.white10),
                ),
              ),
              child: Row(
                children: [
                  if (_isScanning) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF06B6D4),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else ...[
                    const Icon(
                      Icons.verified_rounded,
                      size: 16,
                      color: Color(0xFF10B981),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      _isScanning
                          ? '${_t.isTr ? "Taranıyor" : "Scanning"} ($_scanDoneCount / $_scanTotalCount) • ${_t.isTr ? "Bulunan Kart" : "Found"}: $_scanFoundCount'
                          : _statusBanner,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 2. Album Selector + User-Selectable Scan Batch Limit (25 .. 1000)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Column(
              children: [
                if (_albums.isNotEmpty)
                  SizedBox(
                    height: 34,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _albums.length,
                      itemBuilder: (ctx, idx) {
                        final entry = _albums[idx];
                        final isSel = _selectedAlbum?.id == entry.album.id;
                        final displayAlbumName = entry.album.isAll
                            ? _t.allGalleryAlbum
                            : entry.album.name;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: _isScanning
                                ? null
                                : () {
                                    setState(() => _selectedAlbum = entry.album);
                                  },
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isSel
                                    ? const Color(0xFF10B981)
                                        .withValues(alpha: 0.18)
                                    : const Color(0xFF131824),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isSel
                                      ? const Color(0xFF10B981)
                                      : Colors.white10,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    entry.album.isAll
                                        ? Icons.photo_library_rounded
                                        : Icons.folder_rounded,
                                    size: 13,
                                    color: isSel
                                        ? const Color(0xFF10B981)
                                        : Colors.white54,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    '$displayAlbumName (${entry.count})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isSel
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                      color: isSel
                                          ? const Color(0xFF10B981)
                                          : Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 6),
                // Scan Batch Limit Selector Row (25 / 50 / 100 / 250 / 500 / 1000)
                SizedBox(
                  height: 30,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            _t.scanLimitLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      for (final limitOpt in _scanLimitOptions)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: _isScanning
                                ? null
                                : () => _changeScanLimit(limitOpt),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _scanLimit == limitOpt
                                    ? const Color(0xFF6366F1)
                                    : const Color(0xFF131824),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _scanLimit == limitOpt
                                      ? const Color(0xFF818CF8)
                                      : Colors.white10,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  '$limitOpt',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: _scanLimit == limitOpt
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: _scanLimit == limitOpt
                                        ? Colors.white
                                        : Colors.white60,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 3. Search Bar + Bulk Gallery Clean-up Button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: _t.searchHint,
                        hintStyle: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: Colors.white54,
                        ),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFF131824),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 0),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
                if (unpurgedCount > 0) ...[
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _purgeAllProcessedFromGallery,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF331826),
                      foregroundColor: const Color(0xFFF43F5E),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                    label: Text(
                      '$unpurgedCount',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 4. Category Filter Chips with Live Counts
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                _buildCategoryChip(
                  null,
                  '${_t.catAll} (${_cards.length})',
                  Icons.grid_view_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.movieSeries,
                  '${_t.catMovie} (${_cards.where((c) => c.category == VaultCategory.movieSeries).length})',
                  Icons.movie_creation_outlined,
                ),
                _buildCategoryChip(
                  VaultCategory.anime,
                  '${_t.catAnime} (${_cards.where((c) => c.category == VaultCategory.anime).length})',
                  Icons.auto_awesome_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.book,
                  '${_t.catBook} (${_cards.where((c) => c.category == VaultCategory.book).length})',
                  Icons.menu_book_rounded,
                ),
                _buildCategoryChip(
                  VaultCategory.shopping,
                  '${_t.catShopping} (${_cards.where((c) => c.category == VaultCategory.shopping).length})',
                  Icons.shopping_bag_outlined,
                ),
                _buildCategoryChip(
                  VaultCategory.tempCode,
                  '${_t.catTemp} (${_cards.where((c) => c.category == VaultCategory.tempCode).length})',
                  Icons.qr_code_2_rounded,
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // 5. Transparent Source-to-Match Rich Media Grid
          Expanded(
            child: _permissionDenied
                ? _buildPermissionDeniedView()
                : visibleCards.isEmpty
                    ? _buildEmptyStateView()
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 88),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.58,
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
        onPressed: _isScanning
            ? () => setState(() => _cancelScanRequested = true)
            : _scanGalleryPhotos,
        backgroundColor:
            _isScanning ? const Color(0xFFF43F5E) : const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        icon: Icon(
          _isScanning
              ? Icons.stop_circle_outlined
              : Icons.document_scanner_rounded,
        ),
        label: Text(
          _isScanning
              ? '${_t.stopScan} ($_scanDoneCount/$_scanTotalCount)'
              : _t.scanNextN(_scanLimit),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
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
          size: 15,
          color: isSelected ? Colors.white : Colors.white60,
        ),
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: isSelected ? Colors.white : Colors.white70,
        ),
        selectedColor: const Color(0xFF6366F1),
        backgroundColor: const Color(0xFF131824),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
            ElevatedButton.icon(
              onPressed: () async {
                await PhotoManager.openSetting();
                await Future.delayed(const Duration(seconds: 1));
                await _scanGalleryPhotos();
              },
              icon: const Icon(Icons.settings_rounded),
              label: Text(_t.openSettings),
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
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6366F1), Color(0xFF06B6D4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Icon(
                Icons.center_focus_strong_rounded,
                size: 38,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _t.emptyStateTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _t.emptyStateSub,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white60,
                height: 1.45,
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
      backgroundColor: const Color(0xFF131824),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final hasPoster =
            card.apiPosterUrl != null && card.apiPosterUrl!.startsWith('http');
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.78,
          maxChildSize: 0.94,
          minChildSize: 0.50,
          builder: (_, scrollCtrl) {
            return ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(20),
              children: [
                // Side-by-Side Comparison: [Original Photo] -> [Matched API Poster]
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090C12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      // 1. User's Actual Gallery Screenshot/Photo
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _t.isTr
                                  ? '📷 Kaynak Fotoğrafın'
                                  : '📷 Your Photo',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                height: 140,
                                width: double.infinity,
                                child: _buildLocalThumbImage(
                                  card.localThumbPath,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasPoster) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: Color(0xFF06B6D4),
                            size: 22,
                          ),
                        ),
                        // 2. Matched API Poster
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                _t.isTr
                                    ? '✨ Bulunan Eşleşme'
                                    : '✨ Matched Poster',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF06B6D4),
                                ),
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  height: 140,
                                  width: double.infinity,
                                  child: Image(
                                    image: ResizeImage(
                                      NetworkImage(card.apiPosterUrl!),
                                      width: 400,
                                    ),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        _buildLocalThumbImage(
                                            card.localThumbPath),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Category & Matched Title
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _categoryColor(card.category),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _t.categoryLabel(card.category),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (card.apiRating != null) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.star_rounded,
                          color: Colors.amber, size: 18),
                      const SizedBox(width: 4),
                      Text(
                        card.apiRating!.toStringAsFixed(1),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  card.displayTitle,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (card.apiSubtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    card.apiSubtitle!,
                    style: const TextStyle(fontSize: 13, color: Colors.white60),
                  ),
                ],
                const SizedBox(height: 12),

                // Exact OCR Trigger Line Box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2130),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _t.readFromPhotoLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF818CF8),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        card.extractedTitle,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                if (card.actionPayload != null &&
                    card.actionPayload!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090C12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF10B981).withValues(alpha: 0.5),
                      ),
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
                        FilledButton.tonalIcon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: card.actionPayload!),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(_t.copiedToast)),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: Text(_t.copyPayload),
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
                  const SizedBox(height: 14),
                ],

                const Divider(color: Colors.white12),
                const SizedBox(height: 6),
                Text(
                  _t.isTr
                      ? 'Fotoğraftaki Tüm Metin (Tam OCR):'
                      : 'Full OCR Text from Photo:',
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
                const SizedBox(height: 18),
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
// 7. TRANSPARENT SOURCE-TO-MATCH CARD WIDGET
//    Always displays the user's own screenshot as the main image, plus a
//    Picture-in-Picture matched API poster and explicit "Okunan:" source line!
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
    final hasPoster =
        card.apiPosterUrl != null && card.apiPosterUrl!.startsWith('http');
    final hasCopyablePayload =
        card.actionPayload != null && card.actionPayload!.trim().isNotEmpty;

    return GestureDetector(
      onTap: onTapCard,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF131824),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TOP IMAGE AREA: Always shows user's own screenshot + PiP API Poster
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. User's Actual Gallery Screenshot (Never hidden!)
                  _buildLocalThumbImage(card.localThumbPath),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black45,
                          Colors.transparent,
                          Color(0xEE131824),
                        ],
                      ),
                    ),
                  ),
                  // 2. Category Badge (Top-Left)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.92),
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
                  // 3. Rating or Burst Badge (Top-Right)
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

                  // 4. Picture-in-Picture Matched API Poster (Bottom-Right of Image)
                  if (hasPoster)
                    Positioned(
                      bottom: 6,
                      right: 8,
                      child: Container(
                        width: 44,
                        height: 62,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFF06B6D4),
                            width: 1.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black87,
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image(
                          image: ResizeImage(
                            NetworkImage(card.apiPosterUrl!),
                            width: 160,
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // BOTTOM INFO AREA: Clear "Matched Title" + "Read from Photo (OCR)" Box
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Matched / Primary Title
                    Text(
                      card.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                    if (card.apiSubtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        card.apiSubtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF06B6D4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),

                    // Explicit "Fotoğraftan Okunan" (Source Text) Pill
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF090C12),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📷 ${l10n.readFromPhotoLabel}',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            card.extractedTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Action Row: Copy (ONLY if real IBAN/Code/Price/URL exists) + Gallery Clean + Delete
                    Row(
                      children: [
                        if (hasCopyablePayload)
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
                                    Text(
                                      l10n.copyPayload,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF10B981),
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
                                  : (card.hasApiMatch ? '✨ API Eşleşti' : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: card.isPurgedFromGallery
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFF818CF8),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (!card.isPurgedFromGallery)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
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
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
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

Widget _buildLocalThumbImage(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return Container(
      color: const Color(0xFF1A2130),
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
