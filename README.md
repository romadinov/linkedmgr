# LinkedMgr

A macOS app for planning and auto-publishing LinkedIn posts: a content plan of
working-day slots, posts written ahead with text and pictures, tags for people and
companies, and an optional first comment (e.g. the link).

## Build

```sh
xcodegen generate
xcodebuild -project LinkedMgr.xcodeproj -scheme LinkedMgr -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/LinkedMgr.app /Applications/
```

Requires macOS 15+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Run tests with `xcodebuild … test`.

## One-time LinkedIn setup

LinkedIn only allows posting through a registered developer app, so you make your own:

1. Go to <https://www.linkedin.com/developers/apps> → **Create app**. It must be
   associated with a LinkedIn company page (any page you admin).
2. **Products** tab: add **Share on LinkedIn** and **Sign In with LinkedIn using OpenID Connect**
   (both self-serve, approved instantly).
3. **Auth** tab: add the redirect URL `http://127.0.0.1:8765/callback`.
4. In LinkedMgr → Settings → LinkedIn, paste the Client ID and Client Secret, then **Connect LinkedIn**.

Sign-ins last 60 days (self-serve apps get no refresh token); the app warns a week before.

## How it works

- **Content plan** — Settings → Schedule sets a time for each posting weekday (defaults:
  Mon–Fri mid-morning) and days off. The plan shows every slot for the next weeks; fill a
  slot with a draft, or use *Fill Empty Slots with Drafts*. Any post can also take a custom time.
- **Pictures** — Photos library, Files, drag-and-drop, or the iPhone camera via
  *File ▸ Import from iPhone or iPad ▸ Take Photo* (Continuity Camera). HEIC is converted
  to JPEG; up to 20 per post (LinkedIn's multi-image limit).
- **Tags** — save people and companies under *People & Companies*, then insert with the
  **@ Tag** menu. Tags are stored as `@[Name](urn:li:…)`; the name must match their
  LinkedIn name exactly.
  - Companies: *Look Up* resolves a company page URL to its URN (if LinkedIn allows it for
    your app); otherwise copy the numeric ID by hand (see the hint in the app).
  - People: LinkedIn's self-serve API can't look up other members, so a person without a
    URN is published as plain text and you get a notification to add the tag by editing
    the post on LinkedIn.
- **First comment** — posted as you, N minutes after the post (default 1).
- **Publishing** — LinkedIn has no scheduled publishing for members, so LinkedMgr must
  be running: it lives in the menu bar (turn on *Open at login*), keeps the Mac from
  idle-sleeping just before a slot, and publishes on wake if a slot passed less than the
  grace window ago (default 2 h); older ones are marked *Missed*. *Wake This Mac Before
  Posting Time* sets a daily `pmset` wake.

Data lives in `~/Library/Application Support/` (SwiftData store + `LinkedMgr/Images`);
the client secret and token are in the Keychain.
