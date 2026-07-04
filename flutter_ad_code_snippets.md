Here are the exact Flutter code snippets from `webview_screen.dart` that you requested to diagnose the "position syncs correctly but ad space stays blank" issue.

### 1. State Variables & Setup
Here is the state declaration tracking the ad unit IDs and dynamic position:

```dart
  // Banner Ad (React Sync)
  final Map<String, BannerAd?> _bannerAds = {};
  final Map<String, String> _adUnitIds = {
    'inplay-cinema': 'ca-app-pub-9015405021941451/2275514393',
    'inplay-bhojpuri': 'ca-app-pub-9015405021941451/2275514393',
    'content-details': 'ca-app-pub-9015405021941451/2275514393',
  };
  String? _activePage;
  bool _isAdLoaded = false;
  bool _showAd = false;
  double _adY = -1000;
  double _adWidth = 320;
  double _adHeight = 50;
  double _currentScrollY = 0;
```

### 2. The `updateAdPosition` JavaScript Handler
This handler is registered on the `InAppWebViewController` inside the `onWebViewCreated` callback:

```dart
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
    
    if (_activePage != page) {
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
    }
  },
);
```

### 3. The `BannerAd` Construction and `.load()`
This is the logic handling ad loading and listening for load failure/success:

```dart
  void _loadAndShowAd(String page) {
    if (_bannerAds[page] == null) {
      _bannerAds[page] = BannerAd(
        adUnitId: _adUnitIds[page] ?? 'ca-app-pub-9015405021941451/2275514393',
        size: AdSize.banner, // 320x50
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (_) {
            if (mounted && _activePage == page) {
              setState(() => _isAdLoaded = true);
            }
          },
          onAdFailedToLoad: (ad, error) {
            debugPrint('Ad failed: $error');
            ad.dispose();
            _bannerAds[page] = null;
          },
        ),
      )..load();
    } else {
      if (mounted) {
         setState(() => _isAdLoaded = true);
      }
    }
  }

  void _hideAdForPage(String page) {
    if (_activePage == page) {
      setState(() {
        _showAd = false;
        _adY = -1000;
      });
    }
  }
```

### 4. The `Positioned` / `AdWidget` Overlay
This is the render block inside the main `Stack` widget of the Scaffold body that determines if and where the ad gets painted on top of the `InAppWebView`:

```dart
if (_showAd &&
    _isAdLoaded &&
    _activePage != null &&
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
```
