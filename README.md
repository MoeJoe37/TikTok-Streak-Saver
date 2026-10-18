# Streak Saver

An Android app that keeps your TikTok streaks alive. Pick the people you keep streaks with, pick the videos to send them, and set a time. Every day at that time, Streak Saver checks each person's chat and shares a video with anyone you have not messaged yet that day.

## Features

- **Log in with TikTok** inside the app (phone, email or username; Google and Apple sign-in are blocked by TikTok inside apps).
- **People:** choose from your TikTok inbox, with profile pictures, or add anyone by `@username`.
- **Videos:** paste TikTok video links to build a library with thumbnails. Assign one or more videos per person, or leave it empty to send a random one from the library.
- **Schedule:** one daily time. The app sends only to people you have not messaged that day, so a streak you kept up yourself is left alone.
- **Native sharing:** videos go through TikTok's Share panel, so they arrive as a video card. If that fails, the link is sent in the chat instead so the streak still counts.
- **Activity log** of every run, with what was sent to whom.
- **Background checks:** warns when battery saver, MIUI Autostart, background restrictions or exact-alarm permission could stop the scheduled send, and opens the right settings page to fix each one.
- Light and dark theme, portrait only.

## How it works

TikTok has no public API for direct messages, so the app drives the TikTok website (desktop version) in a hidden WebView using your logged-in session:

1. An exact daily alarm wakes the app, even when it is closed.
2. For each selected person it opens their chat and reads today's messages to see if you already sent something.
3. If not, it opens the chosen video, shares it to that person, then reopens the chat to confirm it arrived.

All data (people, videos, schedule, log) stays on the device. Your TikTok session lives only in the app's WebView cookies.

## Build

Requires Flutter 3.44+ and the Android SDK.

```bash
flutter pub get
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Install it with:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Run the tests with `flutter test`.

## Project layout

| File | Purpose |
|---|---|
| `lib/main.dart` | UI: login, People, Videos and Schedule tabs, background-blocker sheet |
| `lib/store.dart` | Saved state and the daily send plan |
| `lib/tiktok.dart` | Hidden WebView automation of tiktok.com and the daily alarm |
| `android/.../MainActivity.kt` | Detects and opens battery, autostart and alarm settings |

## Good to know

- **TikTok page changes break it.** The page selectors live in one `SEL` block at the top of `lib/tiktok.dart`. When sends start failing, the Activity log shows which step stopped, and that block is where to fix it.
- **Terms of service.** Automating messages is against TikTok's terms and could get an account flagged. Use it at your own risk.
- **Sideload only.** The app uses the `USE_EXACT_ALARM` permission, which Google Play restricts to alarm and calendar apps.
- **Xiaomi / MIUI:** besides the settings the app checks, lock Streak Saver in the recent-apps screen so the memory cleaner leaves it alone.

## License

See [LICENSE](LICENSE).
