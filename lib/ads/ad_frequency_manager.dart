import 'package:webview_master_app/services/ad_settings_service.dart';
import 'package:webview_master_app/utils/prefs_util.dart';

/// Decides whether an interstitial should show for a given trigger event,
/// enforcing the cooldown/session/day/premium-skip rules from [AdConfig].
/// Session + swipe/watch-window counters reset on app launch (in-memory);
/// the per-day count and last-shown timestamp persist across restarts via
/// PrefsUtil so maxAdsPerDay/cooldownMinutes hold even after a relaunch.
class AdFrequencyManager {
  AdFrequencyManager._();
  static final AdFrequencyManager instance = AdFrequencyManager._();

  AdConfig _config = const AdConfig();
  bool _isPremiumUser = false;
  DateTime? _lastShownAt;
  int _adsShownThisSession = 0;
  int _shortsSwipeCount = 0;
  DateTime? _watchWindowStart;

  AdConfig get config => _config;

  void init(AdConfig config) {
    _config = config;
    final lastShownMs = PrefsUtil.getLastAdShownAtMs();
    _lastShownAt = lastShownMs != null ? DateTime.fromMillisecondsSinceEpoch(lastShownMs) : null;
  }

  void setPremium(bool isPremium) {
    _isPremiumUser = isPremium;
  }

  String _todayStamp() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  int _getTodayCount() {
    final stamp = PrefsUtil.getAdsShownDayStamp();
    if (stamp != _todayStamp()) return 0; // day rolled over since last recorded
    return PrefsUtil.getAdsShownDayCount();
  }

  /// [surface] is 'watch' or 'shorts'; [event] is 'video_end', 'episode_change',
  /// 'playback_tick' (long-form, every ~60s of active playback), or 'swipe'
  /// (shorts) — matches the values React's adBridge.js sends via adTriggerEvent.
  Future<bool> shouldShowAd({required String surface, required String event}) async {
    if (!_config.interstitialEnabled) return false;
    if (_isPremiumUser && _config.skipAdsForPremium) return false;
    if (_adsShownThisSession >= _config.maxAdsPerSession) return false;

    final todayCount = _getTodayCount();
    if (todayCount >= _config.maxAdsPerDay) return false;

    if (_lastShownAt != null) {
      final elapsed = DateTime.now().difference(_lastShownAt!);
      if (elapsed.inMinutes < _config.cooldownMinutes) return false;
    }

    if (surface == 'shorts') {
      if (event != 'swipe') return false;
      _shortsSwipeCount++;
      return _shortsSwipeCount >= _config.shortsSwipeInterval;
    }

    // surface == 'watch'
    if (event == 'video_end' || event == 'episode_change') return true;
    if (event == 'playback_tick') {
      _watchWindowStart ??= DateTime.now();
      final minutesInWindow = DateTime.now().difference(_watchWindowStart!).inMinutes;
      return minutesInWindow >= _config.watchIntervalMinutes;
    }
    return false;
  }

  Future<void> recordAdShown() async {
    _lastShownAt = DateTime.now();
    await PrefsUtil.setLastAdShownAtMs(_lastShownAt!.millisecondsSinceEpoch);
    _adsShownThisSession++;
    _shortsSwipeCount = 0;
    _watchWindowStart = null;

    final stamp = _todayStamp();
    final currentCount = PrefsUtil.getAdsShownDayStamp() == stamp ? PrefsUtil.getAdsShownDayCount() : 0;
    await PrefsUtil.setAdsShownDayStamp(stamp);
    await PrefsUtil.setAdsShownDayCount(currentCount + 1);
  }
}
