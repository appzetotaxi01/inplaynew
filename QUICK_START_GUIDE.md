# ⚡ Quick Start Guide - WebView Master App

**Get your app running in 5 minutes!**

---

## 🎯 Step 1: Install Dependencies

```bash
flutter pub get
```

---

## 📝 Step 2: Configure Your App

Open **`lib/config/app_config.dart`** and edit:

### App Name
```dart
static const String appName = 'Your App Name Here';
```

### Website URL
```dart
static const String webUrl = 'https://yourwebsite.com';
```

### Primary Color
```dart
static const Color primaryColor = Color(0xFF6366F1); // Your color
```

### Onboarding Content
```dart
static final List<OnboardingPage> onboardingPages = [
  OnboardingPage(
    title: 'Welcome to Our App',
    description: 'Your description here',
    imagePath: 'assets/onboarding/onboarding_1.png',
  ),
  OnboardingPage(
    title: 'Second Slide',
    description: 'Another description',
    imagePath: 'assets/onboarding/onboarding_2.png',
  ),
  // Add more...
];
```

---

## 🖼️ Step 3: Add Your Images

Replace these files with your own:

1. **Logo**: `assets/images/logo.png`
   - Your app logo (512x512 px recommended)

2. **Onboarding Images**: 
   - `assets/onboarding/onboarding_1.png`
   - `assets/onboarding/onboarding_2.png`
   - `assets/onboarding/onboarding_3.png`
   - (1080x1920 px recommended)

---

## 🚀 Step 4: Run the App

```bash
flutter run
```

---

## ✅ Step 5: Test Features

### Test File Upload:
1. Navigate to a form with file upload on your website
2. Click the file input
3. You should see: **Camera | Gallery | Files**
4. Select and upload ✅

### Test Geolocation:
1. Navigate to a page that uses location
2. Location should work automatically ✅

### Test Offline Mode:
1. Turn off WiFi/Data
2. App shows offline screen ✅
3. Turn on internet
4. App reloads automatically ✅

---

## 🎨 Common Customizations

### Change Splash Duration
```dart
static const int splashDurationSeconds = 3; // Your seconds
```

### Change Exit Dialog Color
```dart
static const Color exitDialogButtonColor = primaryColor;
```

### Change Status Bar Color
```dart
// Light theme
static const Color statusBarColorLight = Color(0x00000000); // Transparent

// Dark theme
static const Color statusBarColorDark = Color(0x00000000); // Transparent
```

---

## 🔧 Build for Release

### Android APK:
```bash
flutter build apk --release
```
**Output**: `build/app/outputs/flutter-apk/app-release.apk`

### iOS:
```bash
flutter build ios --release
```
**Then**: Open Xcode and archive

---

## 📊 View Logs

### Android:
```bash
adb logcat | grep -i "webview\|file\|location\|camera"
```

### iOS:
Open Xcode → Run → View console logs

---

## 🚨 Troubleshooting

### Problem: File upload doesn't work

**Solution 1**: Reinstall app
```bash
adb uninstall com.webviewmasterapp
flutter run
```

**Solution 2**: Check permissions
```
Settings → Apps → Your App → Permissions
✅ Camera: Allowed
✅ Storage: Allowed
```

### Problem: Location doesn't work

**Solution**: Grant location permission
```
Settings → Apps → Your App → Permissions → Location → Allow
```

### Problem: App won't run

**Solution**: Clean and rebuild
```bash
flutter clean
flutter pub get
flutter run
```

### Problem: Build errors

**Solution**: Update dependencies
```bash
flutter pub upgrade
```

---

## 📚 Need More Help?

See these detailed guides:

1. **`README.md`** - Overview and quick reference
2. **`COMPLETE_PROJECT_DOCUMENTATION.md`** - Full documentation
   - Complete code explanation
   - Architecture details
   - How everything works
   - Step-by-step creation guide

3. **`PERMISSIONS_GUIDE.md`** - Permission setup
   - Android & iOS configuration
   - Troubleshooting permissions

---

## 💡 Pro Tips

1. **Always test on real devices** - Camera/gallery work better than emulators
2. **Check all permissions** - Grant all in Settings before testing
3. **Look at console logs** - Website logs appear in Flutter console
4. **One file to rule them all** - All customization in `app_config.dart`
5. **Test offline mode** - Turn off internet to see offline screen

---

## ✅ Checklist Before Release

- [ ] Updated app name in `app_config.dart`
- [ ] Updated website URL in `app_config.dart`
- [ ] Replaced logo image
- [ ] Replaced onboarding images
- [ ] Updated colors if needed
- [ ] Tested file upload (camera & gallery)
- [ ] Tested geolocation
- [ ] Tested offline mode
- [ ] Tested on real Android device
- [ ] Tested on real iOS device (if applicable)
- [ ] Built release APK/IPA
- [ ] Tested release build

---

## 🎉 You're Done!

Your WebView app is now ready with:
- ✅ Beautiful splash screen
- ✅ Onboarding slides
- ✅ Full-featured WebView
- ✅ File uploads (camera & gallery)
- ✅ Geolocation
- ✅ Offline detection
- ✅ Pull to refresh
- ✅ Dark/Light themes
- ✅ All permissions

**Happy coding! 🚀**

---

## 📞 Quick Commands Reference

```bash
# Install
flutter pub get

# Run
flutter run

# Clean
flutter clean

# Build APK
flutter build apk --release

# Build iOS
flutter build ios --release

# Logs
adb logcat | grep "🌐\|📁\|📍"
```

---

**Need detailed explanations? See `COMPLETE_PROJECT_DOCUMENTATION.md`**

