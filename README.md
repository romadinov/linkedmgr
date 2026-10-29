# LinkedMgr

A macOS app for planning and auto-publishing LinkedIn posts: a content plan of
working-day slots, posts written ahead with text and pictures, tags for people and
companies, and an optional first comment (e.g. the link).

## Setup, step by step

Requires macOS 15+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. **Install** — `./install.sh` builds a Release copy into `/Applications` and opens it.
   (It must live in /Applications: the background publisher is registered against that path.)
2. **Create a LinkedIn developer app** at <https://www.linkedin.com/developers/apps> → *Create app*.
   It must be linked to a company page; any page you admin works, or create a placeholder
   (linkedin.com/company/setup/new). Nothing is ever posted to it — posts go to your profile.
3. **Products tab** — add *Share on LinkedIn* and *Sign In with LinkedIn using OpenID Connect*
   (self-serve, approved instantly).
4. **Auth tab** — under *Authorized redirect URLs* add exactly `http://127.0.0.1:8765/callback`.
   Copy the *Client ID* and *Primary Client Secret*.
5. **LinkedMgr ▸ Settings ▸ LinkedIn** — paste both, click *Connect LinkedIn*, approve in the
   browser. Sign-ins last 60 days (no refresh token for self-serve apps); the app warns a week ahead.
6. **Settings ▸ General ▸ Background publisher ▸ Turn On.** macOS shows “Background item
   added”; if the status says *Needs approval*, enable **LinkedMgr** in System Settings ▸ General ▸
   Login Items & Extensions (*Allow in the Background*). Status must read *Running*.
7. **Allow notifications** when asked (System Settings ▸ Notifications ▸ LinkedMgr) — that's how
   you hear about published, failed and missed posts, and tags to add by hand.
8. **Settings ▸ Schedule** — set posting days/times and days off; optionally
   *Wake This Mac Before Posting Time* (asks for your admin password, sets a daily `pmset` wake).
9. **Energy settings** — the Mac must be awake at posting time. On a desktop or a laptop on
   power, System Settings ▸ Energy ▸ *Prevent automatic sleeping when the display is off*
   is the most reliable option.
10. **Smoke test** — write a throwaway post with two pictures and a comment, *Publish Now*,
    check it on LinkedIn, then delete it there.

To update after code changes, run `./install.sh` again; the publisher restarts itself on the
new binary within 30 s. Tests: `xcodebuild -scheme LinkedMgr -derivedDataPath build test`.

## Background publisher

The app's own binary run by launchd with `--agent` (plist in
`Contents/Library/LaunchAgents`, registered with `SMAppService`). It's a per-user agent — it
needs your login session for the Keychain token, so it runs whenever you're logged in,
with or without the app window, and launchd restarts it if it dies. Every 30 s it opens the
database fresh, publishes anything due, and posts pending first comments; *Publish Now* and
*Retry* ping it to act immediately. Network errors and LinkedIn 429/5xx are retried until the
grace window ends.

Watch it work:

```sh
launchctl print gui/$(id -u)/com.ideahelix.linkedmgr.agent | head -20   # state, pid
log stream --info --predicate 'subsystem == "com.ideahelix.linkedmgr"'  # live log
```

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
- **Publishing** — LinkedIn has no scheduled publishing for members, so the background
  publisher does it. It keeps the Mac from idle-sleeping in the 20 minutes before a slot,
  and publishes on wake if a slot passed less than the grace window ago (default 2 h);
  older ones are marked *Missed*.

Data lives in `~/Library/Application Support/LinkedMgr/` (`LinkedMgr.store` + `Images/`);
the client secret and token are in the Keychain.
