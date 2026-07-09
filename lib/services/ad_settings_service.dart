import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_master_app/config/app_config.dart';

/// Interstitial ad frequency-cap config, mirrors `adSettings` in the
/// backend's AppSetting model (backend/models/AppSetting.js). Field defaults
/// match the backend schema defaults exactly, so a fetch failure degrades to
/// the same behavior the backend ships with out of the box.
class AdConfig {
  const AdConfig({
    this.interstitialEnabled = true,
    this.skipAdsForPremium = true,
    this.androidAdUnitId = '',
    this.iosAdUnitId = '',
    this.cooldownMinutes = 3,
    this.maxAdsPerSession = 6,
    this.maxAdsPerDay = 15,
    this.watchIntervalMinutes = 12,
    this.shortsSwipeInterval = 10,
  });

  final bool interstitialEnabled;
  final bool skipAdsForPremium;
  final String androidAdUnitId;
  final String iosAdUnitId;
  final int cooldownMinutes;
  final int maxAdsPerSession;
  final int maxAdsPerDay;
  final int watchIntervalMinutes;
  final int shortsSwipeInterval;

  factory AdConfig.fromJson(Map<String, dynamic> json) {
    const defaults = AdConfig();
    return AdConfig(
      interstitialEnabled: json['interstitialEnabled'] as bool? ?? defaults.interstitialEnabled,
      skipAdsForPremium: json['skipAdsForPremium'] as bool? ?? defaults.skipAdsForPremium,
      androidAdUnitId: json['androidAdUnitId'] as String? ?? defaults.androidAdUnitId,
      iosAdUnitId: json['iosAdUnitId'] as String? ?? defaults.iosAdUnitId,
      cooldownMinutes: (json['cooldownMinutes'] as num?)?.toInt() ?? defaults.cooldownMinutes,
      maxAdsPerSession: (json['maxAdsPerSession'] as num?)?.toInt() ?? defaults.maxAdsPerSession,
      maxAdsPerDay: (json['maxAdsPerDay'] as num?)?.toInt() ?? defaults.maxAdsPerDay,
      watchIntervalMinutes: (json['watchIntervalMinutes'] as num?)?.toInt() ?? defaults.watchIntervalMinutes,
      shortsSwipeInterval: (json['shortsSwipeInterval'] as num?)?.toInt() ?? defaults.shortsSwipeInterval,
    );
  }
}

/// Fetches the interstitial ad config from the backend's public
/// `GET /api/app-settings` endpoint (same endpoint the admin panel writes to).
class AdSettingsService {
  static final AdSettingsService _instance = AdSettingsService._internal();
  factory AdSettingsService() => _instance;
  AdSettingsService._internal();

  Future<AdConfig> fetchAdConfig() async {
    try {
      final url = '${AppConfig.apiBaseUrl}/api/app-settings';
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw Exception('Request timeout'),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('❌ Failed to fetch ad settings. Status: ${response.statusCode}');
        return const AdConfig();
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final adSettings = (body['data'] as Map<String, dynamic>?)?['adSettings'] as Map<String, dynamic>?;
      if (adSettings == null) {
        debugPrint('⚠️ No adSettings in app-settings response, using defaults');
        return const AdConfig();
      }

      return AdConfig.fromJson(adSettings);
    } catch (e) {
      debugPrint('❌ Error fetching ad settings, using defaults: $e');
      return const AdConfig();
    }
  }
}
