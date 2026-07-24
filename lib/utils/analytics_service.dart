import 'dart:io';
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_master_app/utils/prefs_util.dart';

class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  final FirebaseAnalytics firebase = FirebaseAnalytics.instance;
  final FacebookAppEvents meta = FacebookAppEvents();

  Future<void> initialize() async {
    // Request App Tracking Transparency permission on iOS
    if (Platform.isIOS) {
      try {
        // Wait a short delay to allow the app UI/view controller to fully mount
        await Future.delayed(const Duration(seconds: 2));
        final status = await Permission.appTrackingTransparency.request();
        if (kDebugMode) {
          print('📱 App Tracking Transparency status: $status');
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error requesting App Tracking Transparency: $e');
        }
      }
    }

    // Enable debug logging for Facebook SDK only in local development
    await meta.setDebugLoggingEnabled(kDebugMode);
    // Enable advertiser ID collection for tracking attribution
    await meta.setAdvertiserIdCollectionEnabled(true);
    
    await logAppOpen();
  }

  Future<void> logAppOpen() async {
    // Firebase
    await firebase.logAppOpen();

    // Meta
    await meta.activateApp();

    // Track First Open event if this is the first launch
    if (PrefsUtil.isFirstLaunch()) {
      await meta.logEvent(name: 'first_open');
      await PrefsUtil.setFirstLaunchComplete();
      if (kDebugMode) {
        print('✅ First Open logged to Meta (Firebase tracks this automatically)');
      }
    }

    if (kDebugMode) {
      print('✅ App Open logged to Firebase & Meta');
    }
  }

  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
  }) async {
    // Firebase
    await firebase.logEvent(
      name: name,
      parameters: parameters,
    );

    // Meta
    await meta.logEvent(
      name: name,
      parameters: parameters?.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );

    if (kDebugMode) {
      print('✅ Event sent: $name');
    }
  }

  Future<void> logScreen(String screen) async {
    await firebase.logScreenView(
      screenName: screen,
      screenClass: screen,
    );

    await meta.logEvent(
      name: 'screen_view',
      parameters: {
        'screen': screen,
      },
    );
  }

  Future<void> logLogin(String method) async {
    await firebase.logLogin(loginMethod: method);

    await meta.logEvent(
      name: 'login',
      parameters: {
        'method': method,
      },
    );
  }
}