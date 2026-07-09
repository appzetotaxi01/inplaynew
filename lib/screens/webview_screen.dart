import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/permission_handler_util.dart';
import 'package:webview_master_app/utils/connectivity_util.dart';
import 'package:webview_master_app/utils/status_bar_util.dart';
import 'package:webview_master_app/utils/notification_service.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/download_service.dart';
import 'package:webview_master_app/widgets/offline_screen.dart';
import 'package:webview_master_app/widgets/exit_dialog.dart';
import 'package:share_plus/share_plus.dart';

/// WebView Screen - Main screen that loads the configured web URL
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  double _loadingProgress = 0.0;

  bool _isOnline = true;
  bool _phoneListenerInjected = false;
  bool _linkInterceptorInjected = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  Timer? _adStalenessTimer;

  // Banner Ad (React Sync)
  final Map<String, BannerAd?> _bannerAds = {};
  final Map<String, bool> _adLoaded = {}; // per-page loaded flag, replaces the shared _isAdLoaded
  final Map<String, String> _adUnitIds = {
    'inplay-cinema': 'ca-app-pub-9015405021941451/5625869957',
    'inplay-bhojpuri': 'ca-app-pub-9015405021941451/5625869957',
    'content-details': 'ca-app-pub-9015405021941451/5625869957',
  };
  String? _activePage;
  bool _showAd = false;
  double _adY = -1000;
  double _adWidth = 320;
  double _adHeight = 50;
  double _currentScrollY = 0;

  void _loadAndShowAd(String page) {
    if (_bannerAds[page] != null) return; // already loading/loaded

    _adLoaded[page] = false;
    _bannerAds[page] = BannerAd(
      adUnitId: _adUnitIds[page] ?? 'ca-app-pub-9015405021941451/5625869957',
      size: AdSize.banner, // 320x50
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) {
            setState(() => _adLoaded[page] = true);
          }
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('Ad failed for $page: $error');
          ad.dispose();
          if (mounted) {
            setState(() {
              _bannerAds[page] = null;
              _adLoaded[page] = false;
            });
          }
          // Retry after a short delay instead of waiting for the user to leave and revisit the page
          Future.delayed(const Duration(seconds: 30), () {
            if (mounted && _activePage == page) _loadAndShowAd(page);
          });
        },
      ),
    )..load();
  }

  void _armStalenessWatchdog() {
    _adStalenessTimer?.cancel();
    _adStalenessTimer = Timer(const Duration(milliseconds: 2000), () {
      if (mounted && _showAd) {
        setState(() {
          _showAd = false;
          _adY = -1000;
        });
      }
    });
  }

  void _hideAdForPage(String page) {
    _adStalenessTimer?.cancel();
    if (_activePage == page) {
      setState(() {
        _showAd = false;
        _adY = -1000;
      });
    }
  }

  // Track pending download requests from API calls
  final Map<String, Map<String, dynamic>> _pendingDownloadRequests = {};

  // Track API request bodies captured from JavaScript
  final Map<String, String> _apiRequestBodies = {};

  // Pull to refresh controller
  late final PullToRefreshController _pullToRefreshController;

  @override
  void initState() {
    super.initState();
    // Initialize pull-to-refresh controller
    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: AppConfig.primaryColor),
      onRefresh: () async {
        if (_webViewController != null) {
          await _webViewController!.loadUrl(
            urlRequest: URLRequest(url: WebUri(AppConfig.webUrl)),
          );
        }
      },
    );
    _checkConnectivity();
    _initializeNotifications();
    _listenToConnectivityChanges();
  }

  Future<void> _handleBackNavigation() async {
    if (_webViewController != null) {
      final canGoBack = await _webViewController!.canGoBack();
      if (canGoBack) {
        _webViewController!.goBack();
        return;
      }
    }

    // Show exit confirmation dialog using centralized widget
    if (!mounted) return;

    final shouldExit = await ExitDialog.show(context);
    if (shouldExit == true) {
      SystemNavigator.pop();
    }
  }

  /// Initialize notification service
  Future<void> _initializeNotifications() async {
    try {
      await NotificationService().initialize();
      await NotificationService().requestPermission();
      debugPrint('✅ Notification service ready');
      await _saveFCMToken();
    } catch (e) {
      debugPrint('❌ Error initializing notifications: $e');
    }
  }

  /// Save FCM token to backend
  Future<void> _saveFCMToken() async {
    try {
      debugPrint('Saving FCM token to backend...');
      final success = await NotificationService().saveFCMTokenToBackend();
      if (success) {
        debugPrint('✅ FCM token saved successfully');
      } else {
        debugPrint('⚠️ Failed to save FCM token');
      }
    } catch (e) {
      debugPrint('❌ Error saving FCM token: $e');
    }
  }

  /// Handle blob URL download by extracting blob data via JavaScript
  Future<void> _handleBlobDownload({
    required InAppWebViewController controller,
    required String blobUrl,
    String? suggestedFilename,
    String? mimeType,
    bool isReceiptDownload = false,
  }) async {
    if (!mounted) return;

    final downloadService = DownloadService();

    try {
      debugPrint('🔵 Extracting blob data from: $blobUrl');

      // Create a completer to wait for JavaScript callback
      final completer = Completer<Map<String, dynamic>>();
      final handlerName =
          'blobDownloadHandler_${DateTime.now().millisecondsSinceEpoch}';

      // Add JavaScript handler to receive blob data
      controller.addJavaScriptHandler(
        handlerName: handlerName,
        callback: (args) {
          if (args.isNotEmpty) {
            try {
              final result =
                  jsonDecode(args[0].toString()) as Map<String, dynamic>;
              if (!completer.isCompleted) {
                completer.complete(result);
              }
            } catch (e) {
              debugPrint('❌ Error parsing blob data: $e');
              if (!completer.isCompleted) {
                completer.completeError(e);
              }
            }
          } else {
            if (!completer.isCompleted) {
              completer
                  .completeError(Exception('No data received from JavaScript'));
            }
          }
        },
      );

      // Execute JavaScript to extract blob
      final blobDataScript = '''
        (function() {
          try {
            var handlerName = '$handlerName';
            var blobUrl = '$blobUrl';
            var mimeType = '${mimeType ?? 'application/pdf'}';

            function sendResult(success, data, error, mime, size) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler(handlerName, JSON.stringify({
                    success: success,
                    data: data || null,
                    error: error || null,
                    mimeType: mime || mimeType,
                    size: size || 0
                  }));
                } else {
                  console.error('Flutter handler not available');
                }
              } catch (e) {
                console.error('Error sending result:', e);
              }
            }

            function extractBlob() {
              try {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', blobUrl, true);
                xhr.responseType = 'blob';

                xhr.onload = function() {
                  try {
                    if (xhr.status === 200 || xhr.status === 0) {
                      var blob = xhr.response;
                      if (!blob || blob.size === 0) {
                        sendResult(false, null, 'Blob is empty or null', mimeType, 0);
                        return;
                      }
                      var reader = new FileReader();
                      reader.onloadend = function() {
                        try {
                          sendResult(true, reader.result, null, blob.type || mimeType, blob.size);
                        } catch (e) {
                          sendResult(false, null, 'Error in onloadend: ' + (e.message || e.toString()), mimeType, 0);
                        }
                      };
                      reader.onerror = function() {
                        sendResult(false, null, 'Failed to read blob data', mimeType, 0);
                      };
                      reader.readAsDataURL(blob);
                    } else {
                      sendResult(false, null, 'HTTP error: ' + xhr.status, mimeType, 0);
                    }
                  } catch (e) {
                    sendResult(false, null, 'Error in onload: ' + (e.message || e.toString()), mimeType, 0);
                  }
                };

                xhr.onerror = function() {
                  sendResult(false, null, 'Network error loading blob', mimeType, 0);
                };

                xhr.ontimeout = function() {
                  sendResult(false, null, 'Timeout loading blob', mimeType, 0);
                };

                xhr.timeout = 30000;
                xhr.send();
              } catch (error) {
                sendResult(false, null, error.message || 'Unknown error', mimeType, 0);
              }
            }

            extractBlob();
          } catch (e) {
            console.error('Error in blob extraction script:', e);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('$handlerName', JSON.stringify({
                success: false,
                error: 'Script error: ' + (e.message || e.toString())
              }));
            }
          }
        })();
      ''';

      await controller.evaluateJavascript(source: blobDataScript);

      // Wait for JavaScript callback (with timeout)
      final resultMap = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout waiting for blob data');
        },
      );

      if (resultMap['success'] != true) {
        throw Exception(resultMap['error'] ?? 'Failed to extract blob data');
      }

      final base64Data = resultMap['data'] as String;
      final blobMimeType =
          resultMap['mimeType'] as String? ?? mimeType ?? 'application/pdf';

      // Extract base64 data (remove data URL prefix)
      final base64Content =
          base64Data.contains(',') ? base64Data.split(',')[1] : base64Data;

      // Determine filename
      String filename = suggestedFilename ?? 'receipt.pdf';
      if (!filename.contains('.')) {
        // Add extension based on MIME type
        if (blobMimeType.contains('pdf')) {
          filename = '$filename.pdf';
        } else if (blobMimeType.contains('image')) {
          filename = '$filename.png';
        }
      }

      // Get download directory (try public Downloads for receipts, fallback to app-specific)
      bool hasPermission = false;
      if (isReceiptDownload) {
        hasPermission = await PermissionHandlerUtil.checkStoragePermission();
        if (!hasPermission) {
          hasPermission =
              await PermissionHandlerUtil.requestStoragePermission();
        }
      }

      Directory downloadDir;
      if (isReceiptDownload && hasPermission) {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: true);
      } else {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: false);
      }

      final filePath = '${downloadDir.path}/$filename';
      debugPrint('💾 Saving blob to: $filePath');

      // Decode base64 and save to file
      final bytes = base64Decode(base64Content);
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // For Android, try to add file to MediaStore to make it visible in Downloads
      if (Platform.isAndroid && isReceiptDownload) {
        try {
          final downloadService = DownloadService();
          await downloadService.addFileToMediaStore(
              filePath, filename, blobMimeType);
        } catch (e) {
          debugPrint('⚠️ Could not add file to MediaStore: $e');
        }
      }

      if (!mounted) return;

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isReceiptDownload
                          ? 'Receipt saved to Downloads'
                          : 'File saved to Downloads',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                filename,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'OPEN',
            textColor: Colors.white,
            onPressed: () async {
              await downloadService.openFile(filePath);
            },
          ),
        ),
      );
      debugPrint('✅ Blob download successful: $filePath');
    } catch (e) {
      debugPrint('❌ Error downloading blob: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _injectShareInterceptorScript(
      InAppWebViewController controller) async {
    try {
      const script = r"""
        (function() {
          if (window.__shareInterceptorInstalled) return;
          window.__shareInterceptorInstalled = true;

          // Override the navigator.share API
          navigator.share = function(data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              return window.flutter_inappwebview.callHandler('share', JSON.stringify(data));
            }
            return Promise.reject('WebView sharing not initialized');
          };
        })();
      """;
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('❌ Failed to inject share interceptor: $e');
    }
  }

  Future<void> _injectPhoneCaptureScript(
      InAppWebViewController controller) async {
    if (_phoneListenerInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__phoneCaptureInstalled) {
            return;
          }
          window.__phoneCaptureInstalled = true;

          function callFlutter(phoneValue) {
            if (!phoneValue) {
              return;
            }
            var phone = String(phoneValue).trim();
            if (!phone) {
              return;
            }

            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('savePhoneNumber', phone);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.savePhoneNumber
              && window.webkit.messageHandlers.savePhoneNumber.postMessage) {
              window.webkit.messageHandlers.savePhoneNumber.postMessage(phone);
            }
          }

          function attachToInput(input) {
            if (!input || input.__phoneListenerAttached) {
              return;
            }
            input.__phoneListenerAttached = true;

            var notify = function() {
              callFlutter(input.value);
            };

            input.addEventListener('change', notify);
            input.addEventListener('blur', notify);
            input.addEventListener('keyup', function() {
              var digits = (input.value || '').replace(/\D/g, '');
              if (digits.length >= 10) {
                callFlutter(input.value);
              }
            });
          }

          function attachToForms() {
            document.querySelectorAll('form').forEach(function(form) {
              if (form.__phoneSubmitAttached) {
                return;
              }
              form.__phoneSubmitAttached = true;
              form.addEventListener('submit', function() {
                var formData = new FormData(form);
                var phone = formData.get('phone')
                  || formData.get('mobile')
                  || formData.get('phone_number')
                  || '';
                if (!phone) {
                  var input = form.querySelector(
                    'input[type="tel"], input[name*="phone"], input[name*="mobile"], input[id*="phone"], input[id*="mobile"]'
                  );
                  if (input) {
                    phone = input.value;
                  }
                }
                callFlutter(phone);
              });
            });
          }

          function scanAndAttach() {
            var selectors = [
              'input[type="tel"]',
              'input[name*="phone"]',
              'input[name*="mobile"]',
              'input[id*="phone"]',
              'input[id*="mobile"]'
            ];
            selectors.forEach(function(selector) {
              document.querySelectorAll(selector).forEach(attachToInput);
            });
            attachToForms();
          }

          var observer = new MutationObserver(function() {
            scanAndAttach();
          });

          observer.observe(document.documentElement || document.body, {
            childList: true,
            subtree: true
          });

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scanAndAttach);
          } else {
            scanAndAttach();
          }
        })();
      """;

      await controller.evaluateJavascript(source: script);
      _phoneListenerInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject phone capture script: $e');
      _phoneListenerInjected = false;
    }
  }

  /// Inject JavaScript to intercept API requests and capture POST bodies and RESPONSES
  Future<void> _injectApiInterceptorScript(
      InAppWebViewController controller) async {
    try {
      const script = r"""
        (function() {
          if (window.__apiInterceptorInstalled) {
            return;
          }
          window.__apiInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(handlerName, data);
            }
          }

          // Intercept fetch API
          var originalFetch = window.fetch;
          window.fetch = async function(url, options) {
            var urlString = typeof url === 'string' ? url : url.url || url.toString();
            var isLogin = urlString.includes('/auth/login') || 
                          urlString.includes('/users/login') ||
                          urlString.includes('/user/auth/login') ||
                          urlString.includes('/auth/verify-otp') ||
                          urlString.includes('/auth/signup-verify');
            
            // Call original fetch
            try {
              var response = await originalFetch.apply(this, arguments);
              
              // Clone the response to read it without consuming the original stream
              var clone = response.clone();
              
              if (isLogin) {
                 clone.json().then(data => {
                    callFlutterHandler('captureLoginResponse', JSON.stringify({
                      url: urlString,
                      body: data
                    }));
                 }).catch(err => {
                    console.error('Error reading login response:', err);
                 });
              }

              return response;
            } catch (e) {
              throw e;
            }
          };

          // Intercept XMLHttpRequest
          var originalXHROpen = XMLHttpRequest.prototype.open;
          var originalXHRSend = XMLHttpRequest.prototype.send;
          
          XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
            this._method = method;
            this._url = url;
            return originalXHROpen.apply(this, arguments);
          };
          
          XMLHttpRequest.prototype.send = function(data) {
            var self = this;
            var url = this._url;
            
            if (url && (url.includes('/auth/login') || 
                        url.includes('/users/login') ||
                        url.includes('/auth/verify-otp') ||
                        url.includes('/auth/signup-verify'))) {
               this.addEventListener('load', function() {
                  try {
                    var responseBody = self.responseText;
                    // Try parsing JSON
                    try {
                       var json = JSON.parse(responseBody);
                       callFlutterHandler('captureLoginResponse', JSON.stringify({
                          url: url,
                          body: json
                       }));
                    } catch(e) {
                       // Not JSON
                    }
                  } catch(e) {
                     console.error('Error capturing XHR login response:', e);
                  }
               });
            }
            
            return originalXHRSend.apply(this, arguments);
          };
        })();
      """;

      await controller.evaluateJavascript(source: script);

      // Add JavaScript handler to receive captured API requests
      controller.addJavaScriptHandler(
        handlerName: 'captureApiRequest',
        callback: (args) {
          // Existing existing handler logic...
        },
      );

      // Add Handler for Login Response
      controller.addJavaScriptHandler(
        handlerName: 'captureLoginResponse',
        callback: (args) async {
          if (args.isNotEmpty) {
            try {
              final data = jsonDecode(args[0].toString());
              final url = data['url'];
              final body = data['body'];

              debugPrint('📥 Captured API Response for: $url');
              // debugPrint('📥 Body: $body');

              // Handle common token keys (token, accessToken, data.token, etc.)
              String? token;
              if (body != null) {
                if (body['token'] != null) {
                  token = body['token'].toString();
                } else if (body['accessToken'] != null) {
                  token = body['accessToken'].toString();
                } else if (body['data'] != null &&
                    body['data']['token'] != null) {
                  token = body['data']['token'].toString();
                } else if (body['data'] != null &&
                    body['data']['accessToken'] != null) {
                  token = body['data']['accessToken'].toString();
                } else if (body['data'] != null &&
                    body['data']['user'] != null &&
                    body['data']['user']['token'] != null) {
                  token = body['data']['user']['token'].toString();
                }
              }

              if (token != null) {
                await PrefsUtil.setAccessToken(token);
                debugPrint('✅ Access token captured and saved from: $url');
                // After saving token, save FCM token to backend immediately
                await _saveFCMToken();
              } else {
                debugPrint('⚠️ No token found in captured response from: $url');
              }
            } catch (e) {
              debugPrint('❌ Error parsing login response: $e');
            }
          }
        },
      );

      await _saveFCMToken();

      debugPrint('✅ API interceptor script injected successfully');
    } catch (e) {
      debugPrint('❌ Failed to inject API interceptor script: $e');
    }
  }

  /// Inject JavaScript to intercept phone, email, and WhatsApp button clicks
  Future<void> _injectLinkInterceptorScript(
      InAppWebViewController controller) async {
    if (_linkInterceptorInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__linkInterceptorInstalled) {
            return;
          }
          window.__linkInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(handlerName, data);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers[handlerName]
              && window.webkit.messageHandlers[handlerName].postMessage) {
              window.webkit.messageHandlers[handlerName].postMessage(data);
            }
          }
          
          // Intercept clicks on links
          document.addEventListener('click', function(e) {
            var target = e.target;
            while (target && target.tagName !== 'A') {
              target = target.parentElement;
            }
            
            if (target && target.tagName === 'A') {
              var href = target.getAttribute('href');
              if (href) {
                 if (href.startsWith('tel:') || 
                     href.startsWith('mailto:') || 
                     href.includes('wa.me') || 
                     href.includes('whatsapp.com')) {
                   // Let default handling or other interceptors work
                 }
              }
            }
          }, true);
        })();
      """;

      await controller.evaluateJavascript(source: script);
      _linkInterceptorInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject link interceptor script: $e');
      _linkInterceptorInjected = false;
    }
  }

  @override
  void dispose() {
    _adStalenessTimer?.cancel();
    for (var ad in _bannerAds.values) {
      ad?.dispose();
    }
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  /// Check initial connectivity status
  Future<void> _checkConnectivity() async {
    final isConnected = await ConnectivityUtil.isConnected();
    if (mounted) {
      setState(() {
        _isOnline = isConnected;
      });
    }
  }

  /// Listen to connectivity changes
  void _listenToConnectivityChanges() {
    _connectivitySubscription = ConnectivityUtil.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final isConnected = ConnectivityUtil.isConnectivityResultConnected(
        results,
      );

      if (mounted) {
        setState(() {
          _isOnline = isConnected;
        });
      }
    });
  }

  /// Retry loading the page
  Future<void> _retryLoad() async {
    await _checkConnectivity();
    if (_isOnline) {
      _webViewController?.reload();
    }
  }

  /// Check if URL should be launched externally (phone, email, WhatsApp, social media)
  bool _shouldLaunchExternally(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();

    // Phone calls, Email, SMS
    if (scheme == 'tel' ||
        scheme == 'callto' ||
        scheme == 'mailto' ||
        scheme == 'sms') {
      return true;
    }

    // WhatsApp
    if (scheme == 'whatsapp' ||
        scheme == 'whatsapp-api' ||
        host.contains('whatsapp.com') ||
        host.contains('wa.me')) {
      return true;
    }

    // Social media platforms
    final socialMediaDomains = [
      'facebook.com',
      'fb.com',
      'twitter.com',
      'x.com',
      'instagram.com',
      'linkedin.com',
      'youtube.com',
      'tiktok.com',
      'snapchat.com',
      'pinterest.com',
      'telegram.org',
      't.me',
      'messenger.com',
      'viber.com',
      'line.me',
      'wechat.com',
      'skype.com',
    ];

    for (var domain in socialMediaDomains) {
      if (host.contains(domain)) {
        return true;
      }
    }

    // Messaging apps
    if (['tg', 'telegram', 'viber', 'skype'].contains(scheme)) {
      return true;
    }

    // Payment & Stores
    if (['market', 'itms-apps', 'itms-appss'].contains(scheme) ||
        host.contains('play.google.com') ||
        host.contains('apps.apple.com')) {
      return true;
    }

    // UPI Payment Schemes
    if ([
      'upi',
      'tez',
      'phonepe',
      'paytm',
      'bhim',
      'cred',
      'mobikwik',
      'amazonpay'
    ].contains(scheme)) {
      return true;
    }

    // Check for UPI deep links in URL
    final urlString = uri.toString().toLowerCase();
    if (urlString.contains('upi://') || urlString.contains('upi:pay')) {
      return true;
    }

    return false;
  }

  /// Handle Razorpay UPI app SVG URL clicks
  /// Detects URLs like https://cdn.razorpay.com/app/paytm.svg and converts to UPI deep links
  Future<Uri?> _handleRazorpayUPIAppClick(Uri uri) async {
    try {
      final urlString = uri.toString().toLowerCase();
      final host = uri.host.toLowerCase();

      // Check if it's a Razorpay CDN URL for UPI apps
      // FIX: Use path.endsWith or contains check to handle query parameters
      if (host.contains('razorpay.com') &&
          urlString.contains('/app/') &&
          (uri.path.endsWith('.svg') || urlString.contains('.svg'))) {
        debugPrint('💳 Detected Razorpay UPI app SVG URL: $urlString');

        // Extract app name from URL (e.g., "paytm" from "https://cdn.razorpay.com/app/paytm.svg")
        final pathSegments = uri.pathSegments;
        String? appName;

        for (var segment in pathSegments) {
          if (segment.endsWith('.svg')) {
            appName = segment.replaceAll('.svg', '').toLowerCase();
            break;
          }
        }

        if (appName != null && appName.isNotEmpty) {
          debugPrint('💳 Extracted UPI app name: $appName');

          final normalizedAppName = appName
              .replaceAll('-', '')
              .replaceAll('_', '')
              .replaceAll(' ', '')
              .toLowerCase();

          final upiAppMap = {
            'paytm': 'paytm',
            'phonepe': 'phonepe',
            'googlepay': 'tez',
            'gpay': 'tez',
            'tez': 'tez',
            'bhim': 'bhim',
            'cred': 'cred',
            'mobikwik': 'mobikwik',
            'amazonpay': 'amazonpay',
            'amazon': 'amazonpay',
            'pop': 'pop',
            'moneyview': 'moneyview',
            'popupi': 'pop',
          };

          var upiScheme = upiAppMap[appName] ?? upiAppMap[normalizedAppName];

          if (upiScheme != null) {
            // Try to extract UPI payment parameters from JavaScript context
            try {
              if (_webViewController != null) {
                final upiParamsScript = '''
                  (function() {
                    try {
                      // Look for Razorpay payment data
                      var razorpayData = window.Razorpay || window.razorpay || {};
                      var paymentData = razorpayData.paymentData || {};
                      var upiParams = {};
                      
                      // Check URL parameters
                      var urlParams = new URLSearchParams(window.location.search);
                      if (urlParams.get('pa')) upiParams.pa = urlParams.get('pa');
                      if (urlParams.get('pn')) upiParams.pn = urlParams.get('pn');
                      
                      // Check in payment data
                      if (paymentData.upi && paymentData.upi.vpa) upiParams.pa = paymentData.upi.vpa;
                      
                      // Also scan page text for VPA if needed
                      // Return parameters as JSON string
                      return Object.keys(upiParams).length > 0 ? JSON.stringify(upiParams) : null;
                    } catch(e) { return null; }
                  })();
                ''';

                final upiParamsResult = await _webViewController!
                    .evaluateJavascript(source: upiParamsScript);

                if (upiParamsResult != null &&
                    upiParamsResult.toString() != 'null') {
                  try {
                    final paramsJson = jsonDecode(upiParamsResult.toString())
                        as Map<String, dynamic>;
                    if (paramsJson.isNotEmpty) {
                      final upiUri = Uri(
                        scheme: 'upi',
                        host: 'pay',
                        queryParameters: paramsJson.map(
                            (key, value) => MapEntry(key, value.toString())),
                      );
                      debugPrint('💳 Using UPI parameters from page: $upiUri');
                      return upiUri;
                    }
                  } catch (e) {
                    debugPrint('⚠️ Error parsing UPI params: $e');
                  }
                }
              }
            } catch (e) {
              debugPrint('⚠️ Could not get page context: $e');
            }

            // Fallback: If we can't find params, try to launch the app directly
            // Note: Launching 'paytm://' usually opens the app home screen.
            final upiUri = Uri(scheme: 'upi', host: 'pay');
            debugPrint('💳 Launching UPI Payment (generic): $upiUri');
            return upiUri;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error handling Razorpay UPI app click: $e');
      return null;
    }
  }

  /// Handle UPI app launches
  Future<bool> _handleUPIAppLaunch(Uri uri) async {
    try {
      final scheme = uri.scheme.toLowerCase();

      // List of known UPI schemes
      final knownUpiSchemes = [
        'upi',
        'tez',
        'phonepe',
        'paytm',
        'bhim',
        'cred',
        'mobikwik',
        'amazonpay',
        'gpay'
      ];

      if (knownUpiSchemes.contains(scheme) ||
          uri.toString().startsWith('upi://')) {
        debugPrint('💳 Detected UPI/Payment link: $uri');

        // Try launching external application mode
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          debugPrint('✅ UPI app launched');
          return true;
        } else {
          // Fallback attempt without checking canLaunchUrl (sometimes works on legacy Android or specific config)
          try {
            debugPrint(
                '⚠️ canLaunchUrl returned false, attempting launch anyway...');
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            return true;
          } catch (e) {
            debugPrint('❌ Failed to launch UPI app: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content:
                        Text('Could not open payment app. Is it installed?')),
              );
            }
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error handling UPI app launch: $e');
      return false;
    }
  }

  /// Handle Android Intent URLs specifically
  Future<void> _handleIntentUrl(Uri uri) async {
    try {
      debugPrint('🤖 Attempting to launch intent: $uri');
      // On Android, launchUrl with externalApplication mode handles intents if the app is installed
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (e) {
      debugPrint('❌ Failed to launch intent directly: $e');
    }

    // Fallback handling if launch failed
    try {
      final intentString = uri.toString();
      String? fallbackUrl;

      // Try different patterns for browser_fallback_url
      final patterns = ['browser_fallback_url=', 'S.browser_fallback_url='];

      for (var pattern in patterns) {
        if (intentString.contains(pattern)) {
          final fallbackBlock = intentString
              .substring(intentString.indexOf(pattern) + pattern.length);
          final endIndex = fallbackBlock.indexOf(';');

          if (endIndex != -1) {
            final fallbackUrlEncoded = fallbackBlock.substring(0, endIndex);
            fallbackUrl = Uri.decodeFull(fallbackUrlEncoded);
            break;
          }
        }
      }

      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        debugPrint('🔄 Intent failed, using fallback: $fallbackUrl');
        final fallbackUri = Uri.parse(fallbackUrl);

        // Launch fallback URL externally (e.g. Chrome) to avoid WebView redirect loops
        // and provide better UX for things like Maps directions.
        await _launchExternalUrl(fallbackUri);
      } else {
        debugPrint('⚠️ No fallback URL found in intent');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open map application.')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to handle intent fallback: $e');
    }
  }

  /// Launch URL externally using url_launcher
  Future<void> _launchExternalUrl(Uri uri) async {
    try {
      if (await _handleUPIAppLaunch(uri)) return;

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('✅ External URL launched successfully: $uri');
      } else {
        // Try launching anyway for intent schemes or special cases
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('❌ Cannot launch URL: $uri');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot open: ${uri.scheme}://...'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error launching external URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    StatusBarUtil.updateStatusBar(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        _handleBackNavigation();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _isOnline
                    ? Stack(
                        children: [
                          InAppWebView(
                            initialUrlRequest: URLRequest(
                              url: WebUri(AppConfig.webUrl),
                            ),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              javaScriptCanOpenWindowsAutomatically: true,
                              domStorageEnabled: true,
                              databaseEnabled: true,
                              mediaPlaybackRequiresUserGesture: false,
                              allowsInlineMediaPlayback: true,
                              useOnDownloadStart: true,
                              geolocationEnabled: true,
                              supportZoom: true,
                              builtInZoomControls: true,
                              displayZoomControls: false,
                              safeBrowsingEnabled: true,
                              mixedContentMode:
                                  MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                              allowFileAccess: true,
                              allowFileAccessFromFileURLs: true,
                              allowUniversalAccessFromFileURLs: true,
                              useOnLoadResource: true,
                              useShouldOverrideUrlLoading: true,
                            ),
                            pullToRefreshController: _pullToRefreshController,
                            onCreateWindow:
                                (controller, createWindowRequest) async {
                              final urlRequest = createWindowRequest.request;
                              var url = urlRequest.url;
                              debugPrint('🪟 onCreateWindow: url=$url');

                              if (url == null) return false;

                              // Check for Razorpay UPI app SVG URLs FIRST
                              // Use stricter check that handles query params
                              if (url.host.contains('razorpay.com') &&
                                  url.toString().contains('/app/') &&
                                  (url.path.endsWith('.svg') ||
                                      url.toString().contains('.svg'))) {
                                debugPrint(
                                    '💳 onCreateWindow: Detected Razorpay UPI app SVG, intercepting...');
                                final upiAppUri =
                                    await _handleRazorpayUPIAppClick(url);
                                if (upiAppUri != null) {
                                  await _launchExternalUrl(upiAppUri);
                                  return false;
                                }
                              }

                              // Handle non-HTTP schemes
                              final allowedSchemes = [
                                'http',
                                'https',
                                'file',
                                'chrome',
                                'data',
                                'javascript'
                              ];
                              if (!allowedSchemes
                                  .contains(url.scheme.toLowerCase())) {
                                if (await canLaunchUrl(url)) {
                                  await launchUrl(url,
                                      mode: LaunchMode.externalApplication);
                                  return false;
                                }
                              }

                              if (_shouldLaunchExternally(url)) {
                                await _launchExternalUrl(url);
                                return false;
                              }

                              controller.loadUrl(urlRequest: urlRequest);
                              return true;
                            },
                            shouldOverrideUrlLoading:
                                (controller, navigationAction) async {
                              final urlRequest = navigationAction.request;
                              final uri = urlRequest.url;

                              if (uri == null)
                                return NavigationActionPolicy.ALLOW;

                              debugPrint('➡️ Navigating: $uri');

                              // 1. Check for Intent Scheme (Android)
                              if (uri.scheme.toLowerCase() == 'intent') {
                                await _handleIntentUrl(uri);
                                return NavigationActionPolicy.CANCEL;
                              }

                              // 2. Check for Phone/Tel Scheme
                              if (uri.scheme.toLowerCase() == 'tel') {
                                debugPrint(
                                    '🤖 Detected Intent scheme, launching...');
                                try {
                                  await launchUrl(uri,
                                      mode: LaunchMode.externalApplication);
                                  return NavigationActionPolicy.CANCEL;
                                } catch (e) {
                                  debugPrint('❌ Failed to launch intent: $e');
                                  // Continue to allow fallback URL processing if handled by webview?
                                  // Usually fallback urls are inside the intent string, complex to parse here.
                                }
                              }

                              // 2. Check for UPI deep links
                              if (uri.scheme.toLowerCase() == 'upi') {
                                debugPrint('💳 Detected UPI URL: $uri');
                                await _launchExternalUrl(uri);
                                return NavigationActionPolicy.CANCEL;
                              }

                              // 3. Check for Razorpay UPI SVG
                              final upiAppUri =
                                  await _handleRazorpayUPIAppClick(uri);
                              if (upiAppUri != null) {
                                await _launchExternalUrl(upiAppUri);
                                return NavigationActionPolicy.CANCEL;
                              }

                              // 4. Handle other non-HTTP schemes
                              final allowedSchemes = [
                                'http',
                                'https',
                                'file',
                                'chrome',
                                'data',
                                'javascript',
                                'about'
                              ];
                              if (!allowedSchemes
                                  .contains(uri.scheme.toLowerCase())) {
                                await _launchExternalUrl(uri);
                                return NavigationActionPolicy.CANCEL;
                              }

                              // 5. External launch check
                              if (_shouldLaunchExternally(uri)) {
                                await _launchExternalUrl(uri);
                                return NavigationActionPolicy.CANCEL;
                              }

                              return NavigationActionPolicy.ALLOW;
                            },
                            onWebViewCreated: (controller) async {
                              _webViewController = controller;

                              debugPrint('✅ WebView created');

                              controller.addJavaScriptHandler(
                                handlerName: 'updateAdPosition',
                                callback: (args) {
                                  if (args.isEmpty || args[0] is! Map) return;
                                  final data = Map<String, dynamic>.from(args[0] as Map);
                                  final page = data['page'] as String?;
                                  final y = (data['y'] as num?)?.toDouble() ?? -1000;
                                  final width = (data['width'] as num?)?.toDouble();
                                  final height = (data['height'] as num?)?.toDouble() ?? 50;
                                  final visible = data['visible'] == true;
                                  
                                  debugPrint('[AdSync] page=$page y=$y w=$width h=$height visible=$visible');

                                  if (page == null) return;
                                  
                                  if (!visible || y < -50) {
                                    _hideAdForPage(page);
                                    return;
                                  }
                                  
                                  // Retry on page change OR if this page's ad isn't loaded/loading (covers past failures)
                                  if (_activePage != page || _bannerAds[page] == null) {
                                    _loadAndShowAd(page);
                                  }
                                  
                                  if (mounted) {
                                    setState(() {
                                      _activePage = page;
                                      _adY = y;
                                      _adWidth = width ?? MediaQuery.of(context).size.width;
                                      _adHeight = height; // expect 50
                                      _showAd = true;
                                    });
                                    _armStalenessWatchdog();
                                  }
                                },
                              );

                              await _saveFCMToken();
                            },
                            onLoadStart: (controller, url) {
                              setState(() {
                                _isLoading = true;
                                _phoneListenerInjected = false;
                                _linkInterceptorInjected = false;
                              });
                              debugPrint('🌐 Loading started: $url');
                            },
                            onLoadStop: (controller, url) async {
                              _pullToRefreshController.endRefreshing();
                              setState(() {
                                _isLoading = false;
                                _loadingProgress = 1.0;
                              });
                              debugPrint('✅ Loading finished: $url');
                              await _injectShareInterceptorScript(controller);

                              // Add the Share Handler
                              controller.addJavaScriptHandler(
                                handlerName: 'share',
                                callback: (args) {
                                  if (args.isNotEmpty) {
                                    try {
                                      final data =
                                          jsonDecode(args[0].toString());
                                      final String title =
                                          data['title'] ?? 'Check this out!';
                                      final String text = data['text'] ?? '';
                                      final String urlQuery = data['url'] ?? '';

                                      Share.share('$text $urlQuery'.trim(),
                                          subject: title);
                                    } catch (e) {
                                      debugPrint(
                                          '❌ Error in share handler: $e');
                                    }
                                  }
                                },
                              );

                              await _injectPhoneCaptureScript(controller);
                              await _injectLinkInterceptorScript(controller);
                              await _injectApiInterceptorScript(controller);
                            },
                            onProgressChanged: (controller, progress) {
                              setState(() {
                                _loadingProgress = progress / 100;
                                // Hide loader when progress reaches 100%
                                if (progress >= 100) {
                                  _isLoading = false;
                                  _pullToRefreshController.endRefreshing();
                                }
                              });
                              debugPrint('📊 Loading progress: $progress%');
                            },
                            onScrollChanged: (controller, x, y) {
                              setState(() {
                                _currentScrollY = y.toDouble();
                              });
                            },
                            onLoadError: (controller, url, code, message) {
                              _pullToRefreshController.endRefreshing();
                              setState(() {
                                _isLoading = false;
                              });
                              debugPrint(
                                  '❌ Load error: $message (code: $code)');
                            },
                            onGeolocationPermissionsShowPrompt:
                                (controller, origin) async {
                              return GeolocationPermissionShowPromptResponse(
                                  origin: origin, allow: true, retain: true);
                            },
                            onDownloadStartRequest:
                                (controller, downloadStartRequest) async {
                              try {
                                final url = downloadStartRequest.url.toString();
                                final suggestedFilename =
                                    downloadStartRequest.suggestedFilename;
                                final mimeType = downloadStartRequest.mimeType;
                                final contentDisposition =
                                    downloadStartRequest.contentDisposition;

                                debugPrint('📥 Download requested: $url');
                                debugPrint(
                                    '📄 Suggested filename: $suggestedFilename');
                                debugPrint('📋 MIME type: $mimeType');
                                debugPrint(
                                    '📋 Content-Disposition: $contentDisposition');

                                // Handle blob URLs - they need to be extracted via JavaScript
                                if (url.startsWith('blob:')) {
                                  debugPrint(
                                      '🔵 Blob URL detected, extracting blob data...');
                                  await _handleBlobDownload(
                                    controller: controller,
                                    blobUrl: url,
                                    suggestedFilename:
                                        suggestedFilename ?? 'receipt.pdf',
                                    mimeType: mimeType ?? 'application/pdf',
                                    isReceiptDownload: true,
                                  );
                                  return;
                                }

                                // Check if it's a receipt download
                                final isReceiptDownload =
                                    url.contains('receipt') ||
                                        url.contains('download-receipt') ||
                                        url.contains('invoice') ||
                                        (suggestedFilename != null &&
                                            (suggestedFilename
                                                    .toLowerCase()
                                                    .contains('receipt') ||
                                                suggestedFilename
                                                    .toLowerCase()
                                                    .contains('invoice')));

                                if (!mounted) return;

                                // For Android 10+, app-specific directories don't require permission
                                // Only request permission if we need public Downloads folder
                                // But we'll try public Downloads first, fallback to app-specific if needed
                                bool hasPermission = false;
                                bool canDownload = true;

                                if (isReceiptDownload) {
                                  // For receipts, try to get permission for public Downloads
                                  hasPermission = await PermissionHandlerUtil
                                      .checkStoragePermission();
                                  if (!hasPermission) {
                                    final granted = await PermissionHandlerUtil
                                        .requestStoragePermission();
                                    if (!granted) {
                                      // Permission denied, but we can still download to app-specific folder
                                      debugPrint(
                                          '⚠️ Permission denied, will use app-specific Downloads folder');
                                      hasPermission = false;
                                      canDownload =
                                          true; // Still allow download to app folder
                                    } else {
                                      hasPermission = true;
                                    }
                                  } else {
                                    hasPermission = true;
                                  }
                                } else {
                                  // For other files, app-specific directory doesn't need permission
                                  canDownload = true;
                                }

                                if (!canDownload) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Cannot download file. Please check storage permissions in app settings.'),
                                        backgroundColor: Colors.orange,
                                        duration: Duration(seconds: 3),
                                      ),
                                    );
                                  }
                                  return;
                                }

                                // Show download progress
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Row(
                                        children: [
                                          const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                      Colors.white),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              isReceiptDownload
                                                  ? 'Downloading receipt...'
                                                  : 'Downloading file...',
                                              style: const TextStyle(
                                                  color: Colors.white),
                                            ),
                                          ),
                                        ],
                                      ),
                                      backgroundColor: Colors.blue,
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }

                                // Download the file
                                // For Android 10+, app-specific directories don't require permission
                                // Try public Downloads for receipts if permission granted, otherwise use app-specific
                                final downloadService = DownloadService();
                                DownloadResult result;

                                if (isReceiptDownload && hasPermission) {
                                  // Try public Downloads folder first
                                  debugPrint(
                                      '📥 Attempting to download receipt to public Downloads folder...');
                                  result = await downloadService.downloadFile(
                                    url: url,
                                    contentDisposition: contentDisposition,
                                    context: context,
                                    usePublicDownloads:
                                        true, // Try public Downloads
                                    onProgress: (received, total) {
                                      if (total > 0) {
                                        final progress =
                                            (received / total * 100)
                                                .toStringAsFixed(1);
                                        debugPrint(
                                            '📥 Download progress: $progress%');
                                      }
                                    },
                                  );

                                  // If public Downloads failed, fallback to app-specific folder
                                  if (!result.success) {
                                    debugPrint(
                                        '⚠️ Public Downloads failed, using app-specific folder...');
                                    result = await downloadService.downloadFile(
                                      url: url,
                                      contentDisposition: contentDisposition,
                                      context: context,
                                      usePublicDownloads:
                                          false, // Use app-specific folder (no permission needed)
                                      onProgress: (received, total) {
                                        if (total > 0) {
                                          final progress =
                                              (received / total * 100)
                                                  .toStringAsFixed(1);
                                          debugPrint(
                                              '📥 Download progress: $progress%');
                                        }
                                      },
                                    );
                                  }
                                } else {
                                  // Use app-specific folder (no permission needed for Android 10+)
                                  debugPrint(
                                      '📥 Downloading to app-specific Downloads folder (no permission needed)...');
                                  result = await downloadService.downloadFile(
                                    url: url,
                                    contentDisposition: contentDisposition,
                                    context: context,
                                    usePublicDownloads:
                                        false, // Use app-specific folder
                                    onProgress: (received, total) {
                                      if (total > 0) {
                                        final progress =
                                            (received / total * 100)
                                                .toStringAsFixed(1);
                                        debugPrint(
                                            '📥 Download progress: $progress%');
                                      }
                                    },
                                  );
                                }

                                if (!mounted) return;

                                if (result.success && result.filePath != null) {
                                  // Show success message
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.check_circle,
                                                  color: Colors.white),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  isReceiptDownload
                                                      ? 'Receipt saved to Downloads'
                                                      : 'File saved to Downloads',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (result.filename != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              result.filename!,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ],
                                      ),
                                      backgroundColor: Colors.green,
                                      duration: const Duration(seconds: 4),
                                      behavior: SnackBarBehavior.floating,
                                      action: SnackBarAction(
                                        label: 'OPEN',
                                        textColor: Colors.white,
                                        onPressed: () async {
                                          if (result.filePath != null) {
                                            await downloadService
                                                .openFile(result.filePath!);
                                          }
                                        },
                                      ),
                                    ),
                                  );
                                  debugPrint(
                                      '✅ Download successful: ${result.filePath}');
                                } else {
                                  // Show error message
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        result.error ?? 'Download failed',
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                      backgroundColor: Colors.red,
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                  debugPrint(
                                      '❌ Download failed: ${result.error}');
                                }
                              } catch (e) {
                                debugPrint('❌ Error handling download: $e');
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Download failed: $e'),
                                      backgroundColor: Colors.red,
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                          // Loading indicator overlay - only show when loading
                          if (_isLoading)
                            Container(
                              color: Colors.white.withOpacity(0.9),
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: _loadingProgress < 1.0 &&
                                              _loadingProgress > 0
                                          ? _loadingProgress
                                          : null,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          AppConfig.primaryColor),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Loading...',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: AppConfig.primaryColor,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_showAd &&
                              _activePage != null &&
                              (_adLoaded[_activePage] ?? false) &&
                              _bannerAds[_activePage] != null)
                            Positioned(
                              top: _adY, // FROM REACT
                              left: 0,
                              right: 0,
                              height: 50, // MUST match React NATIVE_BANNER_HEIGHT
                              child: Center(
                                child: SizedBox(
                                  width: _adWidth,
                                  height: 50,
                                  child: AdWidget(ad: _bannerAds[_activePage]!),
                                ),
                              ),
                            ),
                        ],
                      )
                    : OfflineScreen(
                        onRetry: _retryLoad), // Use your existing OfflineScreen
              ),
            ],
          ),
        ),
      ),
    );
  }
}
