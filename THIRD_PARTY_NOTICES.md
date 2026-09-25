# Third-party notices

The source code in this repository is licensed under the GNU Affero General Public License v3.0 (see `LICENSE`). This file lists the material that is not covered by that license, or that keeps its own license.

## Fonts

| Font | File | License | License text |
|---|---|---|---|
| Montserrat Black Italic | `AppBlocker/Resources/Fonts/Montserrat-BlackItalic.ttf` | SIL Open Font License 1.1 | `AppBlocker/Resources/Fonts/Montserrat-OFL.txt` |
| Yusei Magic Regular | `AppBlocker/Resources/Fonts/YuseiMagic-Regular.ttf` | SIL Open Font License 1.1 | `AppBlocker/Resources/Fonts/YuseiMagic-OFL.txt` |

Both fonts stay under the SIL Open Font License. They are not relicensed under the AGPL.

## Fluent Emoji (Microsoft)

The star image in `AppBlocker/Assets.xcassets/RatingStar.imageset` is `assets/Star/3D/star_3d.png` from https://github.com/microsoft/fluentui-emoji, used under the MIT License:

```
MIT License

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Images replaced with placeholders

The App Store build uses some images that cannot be redistributed in a public repository. Here they are replaced with plain placeholder images that keep the same file names, so the project still builds and runs.

| Folder | Files | In the App Store build |
|---|---|---|
| `AppBlocker/Resources/Backgrounds/` | 14 background images | Licensed stock photos |
| `AppBlocker/Assets.xcassets/ReferralIcons/` | 4 icons | The Instagram, TikTok, YouTube and App Store icons, shown in the "how did you hear about us" question |

The app stores a post's background as its position in the list in `AppBlocker/Shared/Helpers/BackgroundImageProvider.swift`. If you replace the background images, keep the same number of files in the same order.

Instagram, TikTok, YouTube and App Store are trademarks of their respective owners. The app uses these names only as answer options.

## Swift packages

These are downloaded by Xcode at build time and are not stored in this repository. Each is under its own license.

- supabase-swift: https://github.com/supabase/supabase-swift
- RevenueCat purchases-ios: https://github.com/RevenueCat/purchases-ios-spm
- Google Mobile Ads SDK: https://github.com/googleads/swift-package-manager-google-mobile-ads

## Quotes

`AppBlocker/Resources/Quotes.json` and `Supabase/seed_quotes.sql` contain 68 short sayings that the app shows, all labeled "Anonymous". Many of them are well-known sayings that were not written by the author of this app, so they are not covered by the AGPL.

## App name and icons

The names "1%" and "1% Lock" and the app's icons and logos are not covered by the AGPL. This includes the images in `AppBlocker/Assets.xcassets/AppIcon*.appiconset`, `IconPreview*.imageset`, `Original*.imageset`, `OnePercentIcon.imageset` and `HeroClassicGlyph.imageset`, and `ShieldConfigurationExtension/ShieldIcon.png`. All rights to them are reserved. Under section 7(e) of the AGPL, no rights are granted to use the name or the logos as trademarks.
