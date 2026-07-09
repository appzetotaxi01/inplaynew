import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:webview_master_app/services/ad_settings_service.dart';

/// Loads and shows interstitial ads, keyed off the admin-configurable ad
/// unit IDs in AdConfig (empty string = feature disabled, safe no-op).
class InterstitialAdController {
  InterstitialAdController._();
  static final InterstitialAdController instance = InterstitialAdController._();

  InterstitialAd? _ad;
  bool _isLoading = false;

  String _adUnitId(AdConfig config) => Platform.isIOS ? config.iosAdUnitId : config.androidAdUnitId;

  bool get isReady => _ad != null;

  void preload(AdConfig config) {
    final unitId = _adUnitId(config);
    if (unitId.isEmpty || _isLoading || _ad != null) return;
    _isLoading = true;

    InterstitialAd.load(
      adUnitId: unitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _isLoading = false;
        },
        onAdFailedToLoad: (error) {
          _ad = null;
          _isLoading = false;
        },
      ),
    );
  }

  Future<bool> showIfReady(AdConfig config) async {
    final ad = _ad;
    if (ad == null) return false;

    _ad = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        preload(config);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        preload(config);
      },
    );
    await ad.show();
    return true;
  }
}
