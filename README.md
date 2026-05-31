# GroupChatNameFix

An iOS 6 (armv7) MobileSubstrate tweak that fixes a long-standing iMessage
group-chat bug.

## The bug

1. A group iMessage is created that includes an iOS 6 device.
2. Someone on a newer iOS **renames** the group.
3. From then on, every message the **iOS 6** device sends shows up for everyone
   else as a **brand-new conversation** — even though the iOS 6 device itself
   still sees one continuous thread.

## Why it happens

On iOS 6 a group conversation is keyed by a group id (`gid`) derived from the
participant set. Naming a group on a newer iOS migrates the conversation to a
new canonical `gid` (and group version `gv`). iOS 6 adopts the new *name* but
keeps stamping its old, participant-derived `gid` on outgoing messages, so
modern recipients — now keyed on the new `gid` — treat them as a new thread.

## The fix

The tweak injects into `imagent` and:

1. **Learns** the canonical `(gid, gv)` from incoming group messages, keyed by
   the normalised participant roster.
2. **Rewrites** the `gid` (and `gv`) on the *outgoing* wire dictionary to match
   the learned canonical value before the message leaves the device.

Only the on-the-wire dictionary is changed; the local message database and
thread matching are untouched.

The learned map is persisted to
`/var/mobile/Library/Preferences/com.mikey820.groupchatnamefix.plist` and a
diagnostic log is written to `/var/mobile/GroupChatNameFix.log`.

## Building

GitHub Actions (`.github/workflows/build.yml`) builds a rootful `.deb` for
armv7 / iOS 6.0+ using Theos, the iPhoneOS 9.3 SDK and L1ghtmann's Linux ARM
toolchain, and publishes it to Releases.

## Status

The fix is built on the documented iMessage/Madrid internals
(`gid`/`gv`/`p` wire keys). Because group-rename behaviour can only be verified
with several devices in a real renamed group, v1 also dumps the live
IMDaemonCore selectors and the in/out group dictionaries to its log so the hook
points can be pinned exactly if needed.
