// ============================================================================
// SnapVault — Zero-Background Bilingual (TR/EN) Gallery & Screenshot Vault
// Architecture:
//   1. Strict On-Demand Execution (Zero background services, zero battery drain)
//   2. Android 13/14/15/16 Image-Only Permission Fix (RequestType.image +
//      setIgnorePermissionCheck)
//   3. Strict Trash-Photo Filter & >=80% Similarity Deduplication Engine
//   4. User-Configurable Scan Batch Limit (25, 50, 100, 250, 500, 1000) with
//      20ms UI-thread breathing & Instant Stop/Break
//   5. Smart API Query Cleaner (_cleanQueryForApi) & Token-Overlap _isTitleSimilar
//   6. Smart Action Extractor (Clean IBAN/URL/OTP copy with descriptive SnackBar)
//   7. Card Editing (Change Category, Edit Title) & Permanent Ignore List
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
      ? 'Akıllı Galeri & Ekran Görüntüsü Kasası'
      : 'Smart Gallery & Screenshot Vault';
  String get searchHint => isTr
      ? 'Başlıkta veya 📷 okunan metin içinde anlık ara...'
      : 'Instant search in titles or 📷 OCR text...';
  String scanNextN(int n) =>
      isTr ? 'Sonraki $n Fotoğrafı Tara' : 'Scan Next $n Photos';
  String get stopScan => isTr ? 'Taramayı Durdur' : 'Stop Scan';
  String get resetVaultTitle =>
      isTr ? 'Uygulama Verilerini Sıfırla' : 'Reset App Data';
  String get resetVaultConfirm => isTr
      ? 'Bulunan tüm kartlar, yoksayılanlar ve tarama geçmişi sıfırlanacak (Telefon galerinizdeki fotoğraflara dokunulmaz). Devam edilsin mi?'
      : 'All saved cards, ignored list, and scan history will be cleared (Your phone gallery photos will NOT be deleted). Continue?';
  String get cancel => isTr ? 'Vazgeç' : 'Cancel';
  String get save => isTr ? 'Kaydet' : 'Save';
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
  String get deleteFromGallery =>
      isTr ? 'Orijinali Galeriden Sil' : 'Delete Original from Gallery';
  String get deleteAndIgnoreCard => isTr
      ? 'Bu Kartı Sil (Ve Bir Daha Tarama)'
      : 'Delete Card (And Never Scan Again)';
  String get editTitleBtn => isTr ? 'Başlığı Düzenle' : 'Edit Title';
  String get changeCategoryLabel =>
      isTr ? 'Kategoriyi Değiştir:' : 'Change Category:';
  String get cardIgnoredToast => isTr
      ? 'Kart silindi ve bu fotoğraf bir daha taranmamak üzere yoksayıldı.'
      : 'Card deleted and photo added to permanent ignore list.';
  String get purgedBadge =>
      isTr ? 'Galeriden Silindi' : 'Purged from Gallery';
  String get burstBadge => isTr ? 'Seri' : 'Burst';
  String get readFromPhotoLabel =>
      isTr ? 'Fotoğraftan Okunan:' : 'Read from Photo:';
  String get emptyStateTitle => isTr
      ? 'Kasanız Temiz ve Taranmaya Hazır'
      : 'Your Vault is Clean & Ready';
  String get emptyStateSub => isTr
      ? 'Manzara, duvar kağıdı, mükerrer görüntüler ve sıradan sohbetler otomatik atlanır.\nSadece Film/Dizi, Anime, Kitap, Alışveriş/Fiyat ve IBAN/Kod/Link içeren fotoğraflar karta dönüştürülür.\n\nÜstten tarama adedini (25 - 1000) seçip taramayı başlatabilirsiniz.'
      : 'Wallpapers, landscapes, duplicates, and casual chats are automatically skipped.\nOnly Movies/Series, Anime, Books, Shopping/Prices, and IBAN/Codes/Links are turned into cards.\n\nPick your scan batch size (25 - 1000) and start scanning.';
  String get permDenied => isTr
      ? 'Galeri erişim izni gerekli. Lütfen aşağıdaki butondan uygulama ayarlarını açıp Fotoğraflar iznini verin.'
      : 'Gallery permission required. Please tap below to grant Photos permission in Settings.';
  String get openSettings =>
      isTr ? 'İzin Ayarlarını Aç' : 'Open Permission Settings';

  String scanCompleteMsg(int scanned, int added, int skipped, int dupes) => isTr
      ? '$scanned foto incelendi: $added yeni kart, $dupes mükerrer engellendi, $skipped alakasız atlandı.'
      : 'Checked $scanned: $added new cards, $dupes duplicates blocked, $skipped irrelevant skipped.';

  String purgeSuccessMsg(int count) => isTr
      ? '$count orijinal fotoğraf telefon galerisinden silindi!'
      : '$count original photos deleted from device gallery!';

  String smartCopyToast(String payload) {
    final pUpper = payload.toUpperCase();
    final preview =
        payload.length > 28 ? '${payload.substring(0, 25)}...' : payload;
    if (pUpper.startsWith('TR') && pUpper.length >= 24) {
      return isTr
          ? '✅ IBAN Kopyalandı: $preview'
          : '✅ IBAN Copied: $preview';
    }
    if (payload.toLowerCase().startsWith('http') ||
        payload.toLowerCase().startsWith('www.')) {
      return isTr
          ? '✅ Link Kopyalandı: $preview'
          : '✅ Link Copied: $preview';
    }
    if (RegExp(r'(TL|₺|TRY|USD|\$|EUR|€)', caseSensitive: false)
        .hasMatch(payload)) {
      return isTr
          ? '✅ Fiyat Kopyalandı: $preview'
          : '✅ Price Copied: $preview';
    }
    return isTr ? '✅ Kod Kopyalandı: $preview' : '✅ Code Copied: $preview';
  }

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

  String get displayTitle => hasApiMatch ? apiTitle! : extractedTitle;

  VaultCard copyWith({
    List<String>? groupedAssetIds,
    VaultCategory? category,
    String? extractedTitle,
    String? actionPayload,
    String? apiTitle,
    String? apiSubtitle,
    String? apiPosterUrl,
    double? apiRating,
    String? apiSummary,
    bool clearApiData = false,
    bool? isPurgedFromGallery,
  }) {
    return VaultCard(
      id: id,
      primaryAssetId: primaryAssetId,
      groupedAssetIds: groupedAssetIds ?? this.groupedAssetIds,
      localThumbPath: localThumbPath,
      category: category ?? this.category,
      extractedTitle: extractedTitle ?? this.extractedTitle,
      cleanedOcrText: cleanedOcrText,
      actionPayload: actionPayload ?? this.actionPayload,
      apiTitle: clearApiData ? null : (apiTitle ?? this.apiTitle),
      apiSubtitle: clearApiData ? null : (apiSubtitle ?? this.apiSubtitle),
      apiPosterUrl: clearApiData ? null : (apiPosterUrl ?? this.apiPosterUrl),
      apiRating: clearApiData ? null : (apiRating ?? this.apiRating),
      apiSummary: clearApiData ? null : (apiSummary ?? this.apiSummary),
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
// 3. LOCAL SQLITE STORAGE ENGINE (With Ignored Assets Support)
// ============================================================================
class SnapVaultDb {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dbDir = await getDatabasesPath();
    final path = p.join(dbDir, 'snapvault_core.db');
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _createTables(db);
      },
    );
    return _db!;
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vault_cards (
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
      CREATE TABLE IF NOT EXISTS processed_assets (
        asset_id TEXT PRIMARY KEY,
        processed_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ignored_assets (
        asset_id TEXT PRIMARY KEY,
        ignored_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_Config (
        cfg_key TEXT PRIMARY KEY,
        cfg_val TEXT NOT NULL
      )
    ''');
  }

  static Future<List<VaultCard>> loadAllCards() async {
    final db = await instance;
    final rows = await db.query(
      'vault_cards',
      orderBy: 'captured_epoch_ms DESC',
    );
    return rows.map(VaultCard.fromMap).toList();
  }

  static Future<Set<String>> loadSkipAssetIds() async {
    final db = await instance;
    final procRows = await db.query('processed_assets', columns: ['asset_id']);
    final ignRows = await db.query('ignored_assets', columns: ['asset_id']);
    final set = <String>{};
    for (final r in procRows) {
      set.add(r['asset_id'] as String);
    }
    for (final r in ignRows) {
      set.add(r['asset_id'] as String);
    }
    return set;
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

  static Future<void> ignoreAndDeleteCard(VaultCard card) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final aid in card.groupedAssetIds) {
      await db.insert(
        'ignored_assets',
        {'asset_id': aid, 'ignored_at_ms': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.insert(
        'processed_assets',
        {'asset_id': aid, 'processed_at_ms': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await db.delete('vault_cards', where: 'id = ?', whereArgs: [card.id]);
  }

  static Future<void> resetAllVaultData() async {
    final db = await instance;
    await db.delete('vault_cards');
    await db.delete('processed_assets');
    await db.delete('ignored_assets');
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
// 4. ISOLATE-SAFE STRICT CLASSIFIER, SMART EXTRACTOR & PERCEPTUAL HASHING
// ============================================================================

Future<Map<String, dynamic>> processScreenshotInIsolate(
  Map<String, dynamic> payload,
) async {
  final Uint8List thumbBytes = payload['thumbBytes'] as Uint8List;
  final String targetThumbFilePath = payload['targetThumbFilePath'] as String;
  final int origW = (payload['origWidth'] as int?) ?? 1080;
  final int origH = (payload['origHeight'] as int?) ?? 2400;
  final List<dynamic> rawOcrList = payload['ocrLines'] as List<dynamic>;

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

      // Ignore top 6% status bar (clock, battery, wifi) and bottom 5% gesture bar
      if (normY < 0.06 || normY > 0.95) continue;
      // Ignore right-edge social media action buttons
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

  // Reject pure chat / DM / GitHub / system UI screenshots unless they contain an IBAN
  final chatOrSystemNoise = RegExp(
    r'\b(senin notuna yanıt verdi|bir fotoğraf gönderdi|bir video gönderdi|sesli mesaj|mesaj yaz|çevrimiçi|son görülme|replied to your note|sent a photo|type a message|workflow run|build snapvault|scraper cron job|unread repository|commit by)\b',
    caseSensitive: false,
  );

  // 1. Smart IBAN Extraction (TR + 24 digits = 26 chars clean)
  final ibanRegex = RegExp(
    r'\bTR\s*\d{2}\s*(?:[0-9A-Z]{4}\s*){5}[0-9A-Z]{2}\b',
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
        'IBAN: ${rawIban.substring(0, 6)}...${rawIban.substring(rawIban.length - 4)}';
    actionPayload = rawIban;
  }

  // 2. Smart URL / OTP / Verification / Cargo Code Extraction
  if (matchedCategory == null) {
    final urlRegex = RegExp(
      r'(https?:\/\/[^\s]+)|(www\.[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}[^\s]*)',
      caseSensitive: false,
    );
    final urlMatch = urlRegex.firstMatch(fullCleanText);

    final otpKeywords = RegExp(
      r'\b(doğrulama kodu|onay kodu|tek kullanımlık|kargo takip|takip no|takip numarası|iade kodu|rezervasyon kodu|pnr\s*kodu|pnr\s*no|kupon kodu|promosyon kodu|verification code|security code|otp\s*code|passcode|tracking number|wifi\s*şifre|wi-fi\s*password)\b',
      caseSensitive: false,
    );

    if (urlMatch != null) {
      final cleanUrl = urlMatch
          .group(0)!
          .trim()
          .replaceAll(RegExp(r'[.,;)\]]+$'), '');
      matchedCategory = VaultCategory.tempCode.name;
      extractedTitle = cleanUrl;
      actionPayload = cleanUrl;
    } else if (otpKeywords.hasMatch(lowerText)) {
      // Extract clean 4-8 digit OTP or 5-12 char alphanumeric tracking/coupon code
      final numericOtp = RegExp(r'\b\d{4,8}\b').firstMatch(fullCleanText);
      final alphaCode =
          RegExp(r'\b[A-Z0-9]{5,12}\b').firstMatch(fullCleanText);
      final cleanCode = numericOtp?.group(0) ?? alphaCode?.group(0);
      final prominent = _pickProminentTitle(validLines);

      if (cleanCode != null && cleanCode.isNotEmpty) {
        matchedCategory = VaultCategory.tempCode.name;
        extractedTitle =
            prominent.isNotEmpty ? prominent : 'Kod: $cleanCode';
        actionPayload = cleanCode;
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
      final rawTitle = _pickProminentTitle(validLines);
      final cleanTitle = _cleanQueryForApi(rawTitle);
      if (_isValidMediaTitle(cleanTitle)) {
        matchedCategory = VaultCategory.anime.name;
        extractedTitle = cleanTitle;
      }
    }
  }

  // 5. Check Book / Novel (Strictly excluding school/club/announcement flyers)
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
      final rawTitle = _pickProminentTitle(validLines);
      final cleanTitle = _cleanQueryForApi(rawTitle);
      if (_isValidMediaTitle(cleanTitle)) {
        matchedCategory = VaultCategory.book.name;
        extractedTitle = cleanTitle;
      }
    }
  }

  // 6. Check Movie / TV Series
  if (matchedCategory == null) {
    final movieKeywords = RegExp(
      r'\b(imdb|netflix|disney\+|prime video|blutv|mubi|exxen|gain|hbo max|apple tv\+|letterboxd|rottentomatoes|beyazperde|sinemalar|yönetmen|fragman|sezon\s*\d+|bölüm\s*\d+|season\s*\d+|episode\s*\d+|s\d{1,2}e\d{1,2}|directed by|starring|original series|altyazılı|türkçe dublaj|vizyon tarihi|imax)\b',
      caseSensitive: false,
    );
    if (movieKeywords.hasMatch(lowerText)) {
      final rawTitle = _pickProminentTitle(validLines);
      final cleanTitle = _cleanQueryForApi(rawTitle);
      if (_isValidMediaTitle(cleanTitle)) {
        matchedCategory = VaultCategory.movieSeries.name;
        extractedTitle = cleanTitle;
      }
    }
  }

  if (matchedCategory == null ||
      extractedTitle == null ||
      extractedTitle.trim().isEmpty) {
    return {'skip': true};
  }

  // Decode thumbnail & compute 64-bit dHash ONLY for accepted cards
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

/// Cleans OCR title text before sending to TVMaze, iTunes, Jikan, or OpenLibrary
String _cleanQueryForApi(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';

  // Remove clock times (14:52), battery percentages (%45, 85%), resolution & episode markers
  final uiClutterRegex = RegExp(
    r'(\b\d{1,2}:\d{2}\b|%\s*\d+|\d+\s*%|\b(?:netflix|prime video|disney\+|blutv|mubi|exxen|gain|hbo max|apple tv|crunchyroll|myanimelist|imdb|letterboxd|goodreads|1000kitap|kitapyurdu|sezon\s*\d*|bölüm\s*\d*|season\s*\d*|episode\s*\d*|ep\.?\s*\d*|s\d{1,2}e\d{1,2}|1080p|720p|4k|uhd|hd|altyazılı|altyazı|türkçe dublaj|dublaj|izle|full izle|fragman|trailer|official trailer|yayınları|yayınevi|kitabevi|çevirmen|sayfa\s*\d*)\b)',
    caseSensitive: false,
  );

  s = s.replaceAll(uiClutterRegex, ' ');
  s = s.replaceAll(RegExp(r'[^\w\sçğıöşüÇĞİÖŞÜ\-:]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

bool _isValidMediaTitle(String title) {
  final t = _cleanQueryForApi(title);
  if (t.length < 3 || t.length > 65) return false;
  if (RegExp(r'^\d+$').hasMatch(t)) return false;

  final letterCount =
      RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ]').allMatches(t).length;
  if (letterCount < 3) return false;

  // Reject single generic UI words like "Contact", "Search", "Home", "Unread"
  final genericSingleWordStop = RegExp(
    r'^(contact|home|search|inbox|unread|profile|settings|login|logout|menu|notification|bildirim|ayarlar|anasayfa|iletişim|mesajlar|galeri|görsel kayıt|lucky\s*\d*)$',
    caseSensitive: false,
  );
  if (genericSingleWordStop.hasMatch(t)) return false;
  return true;
}

String _stripBilingualSocialClutter(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';

  final pureNoiseLine = RegExp(
    r'^(\d{1,2}:\d{2}|\d+\s*(sn|dk|sa|gün|hafta|ay|yıl|s|m|h|d|w|y)\s*(önce|ago)?|\d+[.,]?\d*\s*(b|bin|m|mn|k|görüntüleme|views|likes|beğeni|yorum|comments)|@[a-zA-Z0-9_.\-]+|#\S+|%\s*\d+|\d+\s*%)$',
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

  String? bestText;
  double bestScore = -1.0;

  for (final l in lines) {
    final rawText = (l['text'] as String?) ?? '';
    final height = (l['height'] as num?)?.toDouble() ?? 16.0;

    var candidate = _cleanQueryForApi(rawText);
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

/// Computes normalized text similarity (0.0 to 1.0) combining word-token overlap
/// and character bigram Dice coefficient to detect >=80% duplicate screenshots.
double calculateTextSimilarity(String a, String b) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9çğıöşü\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final na = norm(a);
  final nb = norm(b);
  if (na.isEmpty || nb.isEmpty) return 0.0;
  if (na == nb) return 1.0;

  // 1. Token overlap similarity
  final wordsA = na.split(' ').where((w) => w.length >= 2).toSet();
  final wordsB = nb.split(' ').where((w) => w.length >= 2).toSet();
  double tokenSim = 0.0;
  if (wordsA.isNotEmpty && wordsB.isNotEmpty) {
    final inter = wordsA.intersection(wordsB).length;
    final minLen = math.min(wordsA.length, wordsB.length);
    tokenSim = inter / minLen;
  }

  // 2. Character bigram Dice similarity
  final compactA = na.replaceAll(' ', '');
  final compactB = nb.replaceAll(' ', '');
  if (compactA.length < 2 || compactB.length < 2) return tokenSim;

  final bigramsA = <String>{};
  for (int i = 0; i < compactA.length - 1; i++) {
    bigramsA.add(compactA.substring(i, i + 2));
  }
  final bigramsB = <String>{};
  for (int i = 0; i < compactB.length - 1; i++) {
    bigramsB.add(compactB.substring(i, i + 2));
  }
  final bigramInter = bigramsA.intersection(bigramsB).length;
  final diceSim = (2.0 * bigramInter) / (bigramsA.length + bigramsB.length);

  return math.max(tokenSim, diceSim);
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
// 5. ZERO-KEY PUBLIC METADATA ENRICHER WITH _cleanQueryForApi & _isTitleSimilar
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
    final cleanQuery = _cleanQueryForApi(rawQuery);
    if (!_isValidMediaTitle(cleanQuery)) return null;

    final words = cleanQuery.split(' ');
    if (words.length > 8) return null;

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

  /// Smart token-overlap title matcher:
  /// - Blocks single-char/numeric ("3", "1") and generic single-word UI matches ("Contact")
  /// - Accurately matches multi-word series/books/anime via token intersection ratio
  static bool _isTitleSimilar(String query, String apiTitle) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9çğıöşü\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final nq = norm(_cleanQueryForApi(query));
    final na = norm(apiTitle);
    if (nq.length < 3 || na.length < 3) return false;
    if (RegExp(r'^\d+$').hasMatch(nq) || RegExp(r'^\d+$').hasMatch(na)) {
      return false;
    }

    final qWords = nq.split(' ').where((w) => w.length >= 2).toList();
    final aWords = na.split(' ').where((w) => w.length >= 2).toList();
    if (qWords.isEmpty || aWords.isEmpty) return false;

    // Single-word queries must be at least 5 chars and match the API title closely
    if (qWords.length == 1) {
      final single = qWords.first;
      if (single.length < 5) return false;
      return na == single || aWords.contains(single);
    }

    if (na == nq) return true;
    if (na.contains(nq) || nq.contains(na)) return true;

    final sigQ = qWords.where((w) => w.length >= 3).toSet();
    final sigA = aWords.where((w) => w.length >= 3).toSet();
    if (sigQ.isEmpty || sigA.isEmpty) return false;

    final overlap = sigQ.intersection(sigA).length;
    final denom = math.min(sigQ.length, sigA.length);
    return overlap > 0 && (overlap / denom) >= 0.5;
  }

  static Future<EnrichedMetadata?> _fetchAnimeJikan(String query) async {
    final uri = Uri.https(
      'api.jikan.moe',
      '/v4/anime',
      {'q': query, 'limit': '3', 'sfw': 'true'},
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = data['data'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;

    for (final rawItem in list) {
      final item = rawItem as Map<String, dynamic>;
      final titleEn = item['title_english']?.toString() ?? '';
      final titleJp = item['title']?.toString() ?? '';
      if (_isTitleSimilar(query, titleEn) || _isTitleSimilar(query, titleJp)) {
        final bestTitle = titleEn.isNotEmpty ? titleEn : titleJp;
        final episodes = item['episodes'];
        final year = item['year'];
        final score = (item['score'] as num?)?.toDouble();
        final synopsis = item['synopsis']?.toString();
        final images = item['images'] as Map<String, dynamic>?;
        final jpg = images?['jpg'] as Map<String, dynamic>?;
        final poster =
            (jpg?['large_image_url'] ?? jpg?['image_url'])?.toString();

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
    }
    return null;
  }

  static Future<EnrichedMetadata?> _fetchMovieOrShow(String query) async {
    final itunesUri = Uri.https(
      'itunes.apple.com',
      '/search',
      {'term': query, 'entity': 'movie', 'limit': '3'},
    );
    final itunesResp = await http.get(itunesUri).timeout(_timeout);
    if (itunesResp.statusCode == 200) {
      final body = jsonDecode(itunesResp.body) as Map<String, dynamic>;
      final results = body['results'] as List<dynamic>?;
      if (results != null) {
        for (final rawItem in results) {
          final m = rawItem as Map<String, dynamic>;
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
        'limit': '3',
        'fields': 'title,author_name,first_publish_year,cover_i,ratings_average'
      },
    );
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final docs = data['docs'] as List<dynamic>?;
    if (docs == null || docs.isEmpty) return null;

    for (final rawDoc in docs) {
      final doc = rawDoc as Map<String, dynamic>;
      final title = doc['title']?.toString() ?? '';
      if (_isTitleSimilar(query, title)) {
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
          rating:
              rating != null ? double.parse(rating.toStringAsFixed(1)) : null,
          summary: null,
        );
      }
    }
    return null;
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

  void _stopScanningImmediately() {
    if (!_isScanning) return;
    setState(() {
      _cancelScanRequested = true;
      _isScanning = false;
      _statusBanner = _t.isTr
          ? 'Tarama kullanıcı tarafından durduruldu ($_scanFoundCount yeni kart kaydedildi).'
          : 'Scan stopped by user ($_scanFoundCount new cards saved).';
    });
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
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          _t.resetVaultConfirm,
          style: const TextStyle(
              fontSize: 13, color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text(_t.cancel, style: const TextStyle(color: Colors.white60)),
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
      _stopScanningImmediately();
      await Future.delayed(const Duration(milliseconds: 120));
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

  /// Checks if a newly scanned candidate is a duplicate (>=80% text/title overlap,
  /// identical IBAN/Link/Code payload, or perceptual hash match) of an existing card.
  VaultCard? _findDuplicateCard({
    required VaultCategory category,
    required String extractedTitle,
    required String cleanedText,
    required String? actionPayload,
    required String pHashHex,
  }) {
    for (final existing in _cards) {
      // 1. Exact same non-empty IBAN, Link, or OTP Code
      if (actionPayload != null &&
          actionPayload.trim().length >= 4 &&
          existing.actionPayload != null &&
          existing.actionPayload!.trim().toLowerCase() ==
              actionPayload.trim().toLowerCase()) {
        return existing;
      }

      // 2. Perceptual hash visual match (dHash Hamming distance <= 6)
      final pHashDist = hammingDistanceHex(pHashHex, existing.pHashHex);
      if (pHashDist <= 6) {
        return existing;
      }

      // 3. >= 80% normalized title or OCR text overlap
      final titleSim =
          calculateTextSimilarity(extractedTitle, existing.extractedTitle);
      if (titleSim >= 0.80) {
        return existing;
      }

      final ocrSim =
          calculateTextSimilarity(cleanedText, existing.cleanedOcrText);
      if (ocrSim >= 0.80) {
        return existing;
      }
    }
    return null;
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

      final skipIds = await SnapVaultDb.loadSkipAssetIds();
      final List<AssetEntity> newAssets = [];
      final int targetLimit = _scanLimit;

      int page = 0;
      const int pageSize = 80;
      while (newAssets.length < targetLimit && page < 300) {
        if (_cancelScanRequested || !_isScanning) break;
        final pageAssets =
            await activeAlbum.getAssetListPaged(page: page, size: pageSize);
        if (pageAssets.isEmpty) break;
        for (final a in pageAssets) {
          if (!skipIds.contains(a.id)) {
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

      if (mounted && _isScanning) {
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
      int duplicateBlockedCount = 0;

      for (final asset in newAssets) {
        // Instant stop check before starting work on next photo
        if (_cancelScanRequested || !_isScanning) break;

        try {
          final file = await asset.file;
          if (_cancelScanRequested || !_isScanning) break;

          final thumbBytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(480, 854),
            quality: 84,
          );
          if (_cancelScanRequested || !_isScanning) break;

          if (file == null || thumbBytes == null) {
            await SnapVaultDb.markAssetProcessed(asset.id);
            skippedCount++;
            if (mounted) setState(() => _scanDoneCount++);
            await Future.delayed(const Duration(milliseconds: 20));
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

          if (_cancelScanRequested || !_isScanning) break;

          if (rawLines.isEmpty) {
            await SnapVaultDb.markAssetProcessed(asset.id);
            skippedCount++;
            if (mounted) setState(() => _scanDoneCount++);
            await Future.delayed(const Duration(milliseconds: 20));
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

          if (_cancelScanRequested || !_isScanning) break;

          if (result['skip'] == true) {
            await SnapVaultDb.markAssetProcessed(asset.id);
            skippedCount++;
            if (mounted) setState(() => _scanDoneCount++);
            await Future.delayed(const Duration(milliseconds: 20));
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

          // DEDUPLICATION ENGINE: Check >=80% text/title overlap, payload, or pHash
          final existingDuplicate = _findDuplicateCard(
            category: category,
            extractedTitle: extractedTitle,
            cleanedText: cleanedText,
            actionPayload: actionPayload,
            pHashHex: pHashHex,
          );

          if (existingDuplicate != null) {
            final updatedGroup = <String>{
              ...existingDuplicate.groupedAssetIds,
              asset.id,
            }.toList();
            final updatedCard =
                existingDuplicate.copyWith(groupedAssetIds: updatedGroup);
            await SnapVaultDb.upsertCard(updatedCard);
            await SnapVaultDb.markAssetProcessed(asset.id);

            final idx =
                _cards.indexWhere((c) => c.id == existingDuplicate.id);
            if (idx != -1 && mounted) {
              setState(() => _cards[idx] = updatedCard);
            }
            duplicateBlockedCount++;
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
        // 20ms UI-thread breathing delay for 60/120Hz zero-jank scrolling even on 1000 photos
        await Future.delayed(const Duration(milliseconds: 20));
      }

      if (mounted && !_cancelScanRequested) {
        setState(() {
          _statusBanner = _t.scanCompleteMsg(
            _scanDoneCount,
            addedCardsCount,
            skippedCount,
            duplicateBlockedCount,
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

  void _copySmartPayload(BuildContext context, String payload) {
    final clean = payload.trim();
    if (clean.isEmpty) return;
    Clipboard.setData(ClipboardData(text: clean));
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _t.smartCopyToast(clean),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        backgroundColor: const Color(0xFF065F46),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _changeCardCategory(
    VaultCard card,
    VaultCategory newCategory,
  ) async {
    final updated = card.copyWith(
      category: newCategory,
      clearApiData: true,
    );
    await SnapVaultDb.upsertCard(updated);
    if (!mounted) return;
    setState(() {
      final idx = _cards.indexWhere((c) => c.id == card.id);
      if (idx != -1) _cards[idx] = updated;
    });
    unawaited(_enrichCardInBackground(updated));
  }

  Future<void> _editCardTitleDialog(VaultCard card) async {
    final ctrl = TextEditingController(text: card.displayTitle);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          _t.editTitleBtn,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF090C12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(_t.save),
          ),
        ],
      ),
    );

    if (newTitle == null || newTitle.isEmpty) return;
    final updated = card.copyWith(
      extractedTitle: newTitle,
      apiTitle: newTitle,
    );
    await SnapVaultDb.upsertCard(updated);
    if (!mounted) return;
    setState(() {
      final idx = _cards.indexWhere((c) => c.id == card.id);
      if (idx != -1) _cards[idx] = updated;
    });
    unawaited(_enrichCardInBackground(updated));
  }

  Future<void> _deleteAndIgnoreCardForever(VaultCard card) async {
    await SnapVaultDb.ignoreAndDeleteCard(card);
    if (!mounted) return;
    setState(() {
      _cards.removeWhere((c) => c.id == card.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_t.cardIgnoredToast),
        backgroundColor: const Color(0xFF334155),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
        final matchSub = (card.apiSubtitle ?? '').toLowerCase().contains(q);
        final matchPayload =
            (card.actionPayload ?? '').toLowerCase().contains(q);
        return matchTitle ||
            matchExtracted ||
            matchOcr ||
            matchSub ||
            matchPayload;
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
                          ? '${_t.isTr ? "Taranıyor" : "Scanning"} ($_scanDoneCount / $_scanTotalCount) • ${_t.isTr ? "Bulunan" : "Found"}: $_scanFoundCount'
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

          // 2. Album Selector + User-Selectable Scan Batch Limit [25..1000]
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
                                    setState(
                                        () => _selectedAlbum = entry.album);
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

          // 3. Instant Search Bar (Filters both Matched Title & 📷 Read OCR Text)
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

          // 5. Transparent Source-to-Match Rich Media Grid (PiP Design)
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
                            onCopyPayload: () {
                              if (card.actionPayload != null) {
                                _copySmartPayload(context, card.actionPayload!);
                              }
                            },
                            onPurgeGallery: () =>
                                _purgeCardScreenshotsFromGallery(card),
                            onDeleteCard: () =>
                                _deleteAndIgnoreCardForever(card),
                            onTapCard: () => _showCardDetailSheet(card),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? _stopScanningImmediately : _scanGalleryPhotos,
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

  void _showCardDetailSheet(VaultCard initialCard) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131824),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final currentCard = _cards.firstWhere(
              (c) => c.id == initialCard.id,
              orElse: () => initialCard,
            );
            final hasPoster = currentCard.apiPosterUrl != null &&
                currentCard.apiPosterUrl!.startsWith('http');

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.82,
              maxChildSize: 0.95,
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
                                      currentCard.localThumbPath,
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
                                          NetworkImage(
                                              currentCard.apiPosterUrl!),
                                          width: 400,
                                        ),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            _buildLocalThumbImage(
                                                currentCard.localThumbPath),
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
                    const SizedBox(height: 14),

                    // Title + Edit Title Action
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentCard.displayTitle,
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (currentCard.apiSubtitle != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  currentCard.apiSubtitle!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF06B6D4),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await _editCardTitleDialog(currentCard);
                            setModalState(() {});
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          icon: const Icon(Icons.edit_rounded, size: 15),
                          label: Text(
                            _t.editTitleBtn,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Category Switcher (Kategoriyi Değiştir)
                    Text(
                      _t.changeCategoryLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final cat in VaultCategory.values)
                          ChoiceChip(
                            selected: currentCard.category == cat,
                            onSelected: (_) async {
                              await _changeCardCategory(currentCard, cat);
                              setModalState(() {});
                            },
                            label: Text(_t.categoryLabel(cat)),
                            labelStyle: TextStyle(
                              fontSize: 11,
                              fontWeight: currentCard.category == cat
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: Colors.white,
                            ),
                            selectedColor: _categoryColor(cat),
                            backgroundColor: const Color(0xFF090C12),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Clean Extracted Payload Copy Box (IBAN / Code / Link / Price)
                    if (currentCard.actionPayload != null &&
                        currentCard.actionPayload!.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF090C12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color:
                                const Color(0xFF10B981).withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                currentCard.actionPayload!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: Color(0xFF10B981),
                                ),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => _copySmartPayload(
                                context,
                                currentCard.actionPayload!,
                              ),
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: Text(_t.copyPayload),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Exact OCR Trigger Line Box
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A2130),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              const Color(0xFF6366F1).withValues(alpha: 0.4),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📷 ${_t.readFromPhotoLabel}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF818CF8),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            currentCard.extractedTitle,
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

                    if (currentCard.apiSummary != null &&
                        currentCard.apiSummary!.isNotEmpty) ...[
                      Text(
                        currentCard.apiSummary!,
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
                      currentCard.cleanedOcrText,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Action Buttons: Delete Original from Gallery & Delete/Ignore Card Forever
                    if (!currentCard.isPurgedFromGallery) ...[
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _purgeCardScreenshotsFromGallery(currentCard);
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF43F5E),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.delete_sweep_rounded),
                        label: Text(
                          '${_t.deleteFromGallery} (${currentCard.groupedAssetIds.length})',
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _deleteAndIgnoreCardForever(currentCard);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      icon: const Icon(Icons.visibility_off_rounded, size: 18),
                      label: Text(_t.deleteAndIgnoreCard),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ============================================================================
// 7. TRANSPARENT SOURCE-TO-MATCH CARD WIDGET (PiP Design)
// ============================================================================
class _RichMediaCardWidget extends StatelessWidget {
  final VaultCard card;
  final L10n l10n;
  final VoidCallback onCopyPayload;
  final VoidCallback onPurgeGallery;
  final VoidCallback onDeleteCard;
  final VoidCallback onTapCard;

  const _RichMediaCardWidget({
    required this.card,
    required this.l10n,
    required this.onCopyPayload,
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
            // TOP IMAGE AREA: User's own screenshot + PiP API Poster
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
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

            // BOTTOM INFO AREA: Matched Title + "📷 Fotoğraftan Okunan:" Box + Smart Actions
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                    Row(
                      children: [
                        if (hasCopyablePayload)
                          Expanded(
                            child: InkWell(
                              onTap: onCopyPayload,
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
                          tooltip: l10n.deleteAndIgnoreCard,
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
