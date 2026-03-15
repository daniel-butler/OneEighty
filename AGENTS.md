# OneEighty

## Project Structure
- **OneEighty/** — iOS app (SwiftUI, min deployment iOS 26.2)
- **OneEightyWatch Watch App/** — watchOS companion
- **OneEightyWidget/** — WidgetKit live activity
- BPM range: 150–230 SPM
- Bundle ID: com.danielbutler.OneEighty

## Build & Test
```bash
# Build for simulator
xcodebuild build -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ./build

# Run tests
xcodebuild test -scheme OneEighty -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## iOS 26 Simulator Install Workaround

The iPhone 17 Pro simulator (iOS 26) requires device family 4 in the app's Info.plist, but Xcode strips family 4 from iOS builds (it's traditionally Apple Watch-only). `simctl install` fails with:

> "app is compatible with (1, 2) but this device supports (4)"

**Fix:** After building, patch the .app's Info.plist before installing:
```bash
APP_PATH=./build/Build/Products/Debug-iphonesimulator/OneEighty.app
/usr/libexec/PlistBuddy -c "Add UIDeviceFamily: integer 4" "$APP_PATH/Info.plist"
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.danielbutler.OneEighty
```

Note: `xcodebuild test` bypasses this issue (it installs via a different mechanism).

## iOS 26 Simulator Landscape Rotation

The app renders in landscape-right orientation on iPhone 17 Pro (iOS 26) even though no orientation lock is set. The `simctl io screenshot` captures in native portrait pixels, but the UI content is rotated 90deg CW. When using idb for touch interaction, coordinates are in portrait point space but the accessibility tree is in landscape. The mapping is:

```
portrait_x = landscape_y
portrait_y = 874 - landscape_x
```

Use `idb ui describe-all` to get landscape accessibility frames, then convert.
