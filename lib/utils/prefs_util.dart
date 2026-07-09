import 'package:shared_preferences/shared_preferences.dart';

/// Utility class for SharedPreferences operations
class PrefsUtil {
  static const String _keyOnboardingComplete = 'onboarding_complete';
  static const String _keyFirstLaunch = 'first_launch';
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyPhoneNumber = 'phone_number';

  static SharedPreferences? _prefs;

  /// Initialize SharedPreferences
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Get SharedPreferences instance
  static SharedPreferences get instance {
    if (_prefs == null) {
      throw Exception(
          'PrefsUtil not initialized. Call PrefsUtil.init() first.');
    }
    return _prefs!;
  }

  // ==================== ONBOARDING ====================

  /// Check if onboarding has been completed
  static bool isOnboardingComplete() {
    return instance.getBool(_keyOnboardingComplete) ?? false;
  }

  /// Mark onboarding as complete
  static Future<void> setOnboardingComplete() async {
    await instance.setBool(_keyOnboardingComplete, true);
  }

  /// Reset onboarding status (for testing)
  static Future<void> resetOnboarding() async {
    await instance.setBool(_keyOnboardingComplete, false);
  }

  // ==================== FIRST LAUNCH ====================

  /// Check if this is the first launch
  static bool isFirstLaunch() {
    return instance.getBool(_keyFirstLaunch) ?? true;
  }

  /// Mark first launch as complete
  static Future<void> setFirstLaunchComplete() async {
    await instance.setBool(_keyFirstLaunch, false);
  }

  // ==================== THEME ====================

  /// Get saved theme mode (0: system, 1: light, 2: dark)
  static int getThemeMode() {
    return instance.getInt(_keyThemeMode) ?? 0;
  }

  /// Save theme mode
  static Future<void> setThemeMode(int mode) async {
    await instance.setInt(_keyThemeMode, mode);
  }

  // ==================== PHONE NUMBER ====================

  /// Save phone number (10-digit without +91)
  static Future<void> setPhoneNumber(String phone) async {
    await instance.setString(_keyPhoneNumber, phone);
  }

  /// Get saved phone number
  static String? getPhoneNumber() {
    return instance.getString(_keyPhoneNumber);
  }

  /// Clear phone number
  static Future<void> clearPhoneNumber() async {
    await instance.remove(_keyPhoneNumber);
  }

  // ==================== AUTH TOKEN ====================
  
  static const String _keyAccessToken = 'access_token';

  /// Save API access token
  static Future<void> setAccessToken(String token) async {
    await instance.setString(_keyAccessToken, token);
  }

  /// Get API access token
  static String? getAccessToken() {
    return instance.getString(_keyAccessToken);
  }

  /// Clear API access token
  static Future<void> clearAccessToken() async {
    await instance.remove(_keyAccessToken);
  }

  // ==================== AD FREQUENCY CAPPING ====================

  static const String _keyAdsShownDayCount = 'ads_shown_day_count';
  static const String _keyAdsShownDayStamp = 'ads_shown_day_stamp';
  static const String _keyLastAdShownAtMs = 'last_ad_shown_at_ms';

  /// Number of interstitial ads shown on [getAdsShownDayStamp]'s date
  static int getAdsShownDayCount() {
    return instance.getInt(_keyAdsShownDayCount) ?? 0;
  }

  static Future<void> setAdsShownDayCount(int count) async {
    await instance.setInt(_keyAdsShownDayCount, count);
  }

  /// Date the day-count was last reset for, formatted 'yyyy-MM-dd'. Compare
  /// against today's date to detect day rollover before trusting the count.
  static String? getAdsShownDayStamp() {
    return instance.getString(_keyAdsShownDayStamp);
  }

  static Future<void> setAdsShownDayStamp(String stamp) async {
    await instance.setString(_keyAdsShownDayStamp, stamp);
  }

  /// Epoch milliseconds of the last interstitial shown (persists across restarts)
  static int? getLastAdShownAtMs() {
    return instance.getInt(_keyLastAdShownAtMs);
  }

  static Future<void> setLastAdShownAtMs(int ms) async {
    await instance.setInt(_keyLastAdShownAtMs, ms);
  }

  // ==================== CLEAR ALL ====================

  /// Clear all preferences (for testing/debugging)
  static Future<void> clearAll() async {
    await instance.clear();
  }
}
