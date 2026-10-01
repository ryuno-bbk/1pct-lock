# 1% Lock

1% Lock is an iOS app that blocks distracting apps with Apple's Screen Time API. When you want to scroll anyway, it shows you a feed of people who are studying or training, and every post in that feed is checked by AI.

- App Store: https://apps.apple.com/app/id6792271074
- Demo video: https://youtu.be/s4XdOf6nt6A
- Devpost: https://devpost.com/software/1-lock

## What the app does

**Locking.** You pick the apps to block and how long to block them.

| Lock mode | Plan |
|---|---|
| Timer | Free |
| Schedule (up to 5, by time and weekday) | Pro |
| Location (while you are at a place you choose) | Pro |

**Unlocking.** Before a lock starts, you choose what it will take to end it early:

- Hold a button for 2 seconds
- Write one line about what you will do after the break
- Look at 5 posts from the feed, 3 seconds each
- Look at 5 images you picked yourself. They are stored only on the device
- Hard Lock (Pro): no way to unlock until the timer ends

While you look at posts or images, an "Actually, keep working" button stays on screen the whole time, as prominent as the unlock button.

**Social.** Photo posts, comments, likes, follows, notifications, a weekly report, and a ranking by cumulative lock time. Every new post, comment and report is sent to an AI moderation step, and posts that are about gambling, junk food, gaming or nights out are filtered out.

**Pro.** Scheduled locks, location locks and Hard Lock. Subscriptions run through RevenueCat.

## How it is built

### Targets

| Target | What it does |
|---|---|
| `AppBlocker` | The SwiftUI app: onboarding, feed, posting, profile, lock controls, paywall |
| `ShieldConfigurationExtension` | Draws the screen iOS shows when you open a blocked app: your own goal and a quote |
| `ShieldActionExtension` | Handles the button on that screen |
| `DeviceActivityMonitorExtension` | Starts and ends scheduled locks while the app is not running, and clears a timer lock that expired while the app was closed |
| `UsageReportExtension` | During onboarding, shows your real Screen Time next to your own estimate. The measured data never leaves the extension |
| `AreteWidgetExtension` | Home Screen and Lock Screen widget that shows a quote |

The app and its extensions share state through an App Group. Locks use three separate `ManagedSettingsStore`s (`timer`, `schedule`, `location`), and iOS applies the strictest combination of them.

### Backend

The backend is [Supabase](https://supabase.com):

- **Postgres** with row-level security on every table. The feed, comments, ranking and stats are SQL functions (RPCs). The full schema history is in `Supabase/migrations/`.
- **Storage** for avatars and post images.
- **Edge Functions** (TypeScript on Deno) in `Supabase/functions/`:

| Function | What it does |
|---|---|
| `moderate-post` | Checks every new post, comment and report with Claude (Anthropic Messages API) |
| `review-appeal` | Gives a second AI review when a user appeals a moderation decision |
| `revenuecat-webhook` | Keeps `users.is_pro` in sync with RevenueCat events |
| `send-push` | Sends push notifications through APNs when a row is added to `user_notifications` |
| `delete-account` | Deletes the user's files and account |

### Purchases and ads

- **RevenueCat** handles entitlements, the paywall offerings and receipt validation. The RevenueCat app user ID is the Supabase user ID in lowercase, so the webhook can match events to `users.id`.
- **Google AdMob** shows one native ad for every 10 feed items. Ads are always non-personalized, and the app never shows the App Tracking Transparency prompt.

## Repository layout

```
AppBlocker/                        iOS app (SwiftUI)
ShieldConfigurationExtension/      block screen UI
ShieldActionExtension/             block screen button
DeviceActivityMonitorExtension/    scheduled locks in the background
UsageReportExtension/              Screen Time report for onboarding
AreteWidget/                       widget
AppBlocker.xcodeproj/              Xcode project (with shared schemes and Package.resolved)
Supabase/migrations/               database schema, 000 to 083, run in order
Supabase/functions/                Edge Functions
Supabase/seed_quotes.sql           the 68 quotes that ship with the app
```

## Where to look in the code

| What | Where |
|---|---|
| Block screen that shows your own goal | `ShieldConfigurationExtension/ShieldConfigurationExtension.swift` |
| Scheduled locks while the app is closed, including the Pro check | `DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.swift` |
| Unlock methods | `AppBlocker/Core/Models/UnlockChallenge.swift` |
| Feed unlock and the "Actually, keep working" button | `AppBlocker/Features/BlockMode/Challenges/ScrollChallengeView.swift` |
| Onboarding Screen Time report (the measured data stays inside the extension) | `UsageReportExtension/TotalActivityReport.swift` |
| Feed ranking | `Supabase/migrations/076_feed_official_and_lang_exclusive.sql` |
| Lock time ranking (lists the top 10% only) | `Supabase/migrations/082_block_ranking.sql` |
| AI moderation: Haiku first, Sonnet only when Haiku is unsure | `Supabase/functions/moderate-post/index.ts`, `Supabase/migrations/055_haiku_cascade.sql`, rubric in `074_ethos_aesthetic_pass.sql` |
| Daily limits that stop one account from running up the AI bill | `Supabase/migrations/066_cost_attack_hardening.sql` |
| RevenueCat login with the Supabase user ID | `AppBlocker/Core/Services/PurchaseService.swift` |
| Paywall, including the trial eligibility check | `AppBlocker/Features/Paywall/ProPaywallView.swift` |
| RevenueCat webhook that updates `users.is_pro` | `Supabase/functions/revenuecat-webhook/index.ts` |
| Users cannot set `is_pro` themselves | `protect_users_is_pro()` in `Supabase/migrations/015_security_audit.sql` |
| Guard against webhooks arriving out of order | `Supabase/migrations/040_revenuecat_event_ordering.sql` |

## What broke, and what changed

- **Buying Pro did not unlock anything (found in sandbox testing, before launch).** The code checked for an entitlement called `pro`, but the one in the RevenueCat dashboard was named `1% Pro`. The purchase went through, nothing unlocked, and the webhook skipped every event without an error. Entitlement IDs cannot be renamed, so the app and the webhook now both use `1% Pro` (`RevenueCatConfig.swift`, `revenuecat-webhook/index.ts`).
- **Webhooks can arrive out of order.** RevenueCat does not guarantee the order, so a late `EXPIRATION` could arrive after a newer `INITIAL_PURCHASE` and switch Pro off. The database now stores the timestamp of the last event it applied and ignores anything older (`040_revenuecat_event_ordering.sql`).
- **One account could run up the AI bill.** Every post triggers an AI check, and the first limit was 100 posts a day. It is now 5 posts a day, with separate daily limits for comments, reports and appeals (`066_cost_attack_hardening.sql`, `057_post_limit_5_ethos_stage_quote.sql`).

## Trying the app

The fastest way is the App Store build: https://apps.apple.com/app/id6792271074. It is iPhone only and supports English and Japanese. The yearly plan includes a 3-day free trial that unlocks all Pro features.

## Building from source

### Requirements

- Xcode 26.2 or later, with the Metal Toolchain component installed (the project compiles a Metal shader).
- A physical iPhone. The project compiles for the Simulator, but the Screen Time APIs need a real device.
- An Apple Developer team with the Family Controls capability. TestFlight and App Store builds also need Apple to approve the Family Controls (Distribution) entitlement.
- iOS 18.6 or later. The onboarding Screen Time report needs iOS 26.2 or later.

### Why you need your own backend

Sign in with Apple is the only way to sign in, and Supabase only accepts sign-ins from bundle IDs that are registered in the project's Apple provider settings. A build with your own bundle ID cannot sign in to the production backend, so building from source means setting up your own Supabase project as described below.

### 1. Signing and identifiers

- Team: replace `DEVELOPMENT_TEAM = 975VS4NHMJ` in `AppBlocker.xcodeproj/project.pbxproj` with your own team ID.
- Bundle IDs: replace `com.jeimii.AppBlocker` and `com.jeimii.AppBlocker.*`. The extension IDs must start with the app's ID.
- App Group: replace `group.com.ryunosuke.appblocker.shared` in these 11 files:
  - `AppBlocker/AppBlocker.entitlements`
  - `AreteWidgetExtension.entitlements`
  - `DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.entitlements`
  - `ShieldActionExtension/ShieldActionExtension.entitlements`
  - `ShieldConfigurationExtension/ShieldConfigurationExtension.entitlements`
  - `UsageReportExtension/UsageReportExtension.entitlements`
  - `AppBlocker/Shared/Constants/AppGroupIdentifier.swift`
  - `AreteWidget/WidgetSharedTypes.swift`
  - `DeviceActivityMonitorExtension/DeviceActivityMonitorExtension.swift`
  - `ShieldConfigurationExtension/ShieldConfigurationExtension.swift`
  - `UsageReportExtension/TotalActivityReport.swift`

### 2. App configuration

| Value | File |
|---|---|
| Supabase URL and publishable key | `AppBlocker/Core/Services/SupabaseManager.swift` |
| RevenueCat public SDK key | `AppBlocker/Core/Services/RevenueCatConfig.swift` |
| RevenueCat entitlement ID (`1% Pro`). It must match `PRO_ENTITLEMENT` in `Supabase/functions/revenuecat-webhook/index.ts` | `AppBlocker/Core/Services/RevenueCatConfig.swift` |
| App Store product IDs | `AppBlocker/Core/Services/RevenueCatConfig.swift` |
| AdMob app ID | `AppBlocker/Info.plist` (`GADApplicationIdentifier`) |
| AdMob native ad unit for Release builds (Debug builds use Google's test unit) | `AppBlocker/Core/Services/NativeAdService.swift` |
| Terms, privacy policy and support email | `AppBlocker/Shared/Constants/LegalLinks.swift` |

The paywall reads the offering marked as Current in RevenueCat, so no offering ID is hard-coded.

### 3. Backend (Supabase)

1. Create a Supabase project.
2. Under Authentication, enable the Apple provider and add your bundle ID under Client IDs.
3. Under Database > Webhooks, enable webhooks. Migration 079 calls `supabase_functions.http_request`, which is available once they are enabled.
4. In the SQL Editor, run `Supabase/migrations/000_baseline_quotes_authors.sql` first, then `001` to `083` in order.
   - Before running `079`, replace the project URL in it and the `__PUSH_WEBHOOK_SECRET__` placeholder with your own values.
   - `081` includes a weekly `pg_cron` schedule that is commented out. Enable `pg_cron` and uncomment it if you want weekly report notifications.
5. Run `Supabase/seed_quotes.sql` to load the quotes.
6. Deploy the Edge Functions and set their secrets:

| Function | Deploy with | Secrets to set |
|---|---|---|
| `moderate-post` | `--no-verify-jwt` | `ANTHROPIC_API_KEY`, `MODERATION_WEBHOOK_SECRET` |
| `review-appeal` | default (JWT required) | `ANTHROPIC_API_KEY` |
| `revenuecat-webhook` | `--no-verify-jwt` | `REVENUECAT_WEBHOOK_AUTH`, and optionally `REVENUECAT_SECRET_API_KEY` and `RC_ALLOW_SANDBOX` |
| `send-push` | `--no-verify-jwt` | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`, `PUSH_WEBHOOK_SECRET` |
| `delete-account` | default (JWT required) | none |

   The functions also read `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`, which Supabase provides. The folder is named `Supabase` with a capital S, so on a case-sensitive file system point the CLI at it or rename it to `supabase`.

7. Create three Database Webhooks for moderation: on INSERT into `user_posts`, `user_comments` and `user_reports`, send a POST request to the `moderate-post` function with the header `x-moderation-secret` set to `MODERATION_WEBHOOK_SECRET`.
8. In RevenueCat, create the entitlement and products, mark one offering as Current, and add a webhook that points to the `revenuecat-webhook` function. The whole `Authorization` header value must equal `REVENUECAT_WEBHOOK_AUTH`.
9. To test Pro features on your own backend without a purchase, run `update public.users set is_pro = true where id = '<your user id>';` in the SQL Editor.

Migrations 001 to 083 were written and applied one at a time on the production project. `000` was rebuilt from the original schema script, because those two tables existed before the migrations folder was started. A full run on an empty project has not been tested end to end yet.

## Notes

- Code comments are in English, translated from the original Japanese. The UI is in English and Japanese.
- The Xcode project is called `AppBlocker`, and some files use `Arete`, an earlier name of the app.
- Some images in the App Store build cannot be redistributed, so this repository has placeholder images with the same file names. See `THIRD_PARTY_NOTICES.md`.
- Internal operator tools are not included: the web console for reviewing moderation appeals and the scripts for managing the app's own accounts and content. The app does not need them to run.

## License

Copyright (C) 2026 Ryunosuke Ishigami

The source code is licensed under the GNU Affero General Public License v3.0. See `LICENSE`.

Fonts, the star emoji image, the quotes, the app name and the app icons are not covered by that license. See `THIRD_PARTY_NOTICES.md`.
