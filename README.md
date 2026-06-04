# GroupChatNameFix

A MobileSubstrate tweak for **iOS 6** (armv7/armv7s, jailbroken) that (1) fixes group
iMessages from the iOS 6 device showing up as a **separate / duplicated conversation**
for everyone else once a modern‑iOS member gives the group a name, and (2) **shows that
group name** in the iOS 6 Messages app instead of the bare participant list.

> TL;DR — after someone on modern iOS names (or renames) a group that includes an
> iOS 6 device, every message the iOS 6 device sends lands in a brand‑new thread for
> the other members. This tweak makes those messages thread into the real named group
> again. It is **fully autonomous**, no companion app, no manual configuration.

---

## The bug

Modern iOS threads a **named** group chat by a stable group identifier — a `gid`
(a UUID) carried inside the encrypted iMessage payload, with `gv` (group version) `= 8`.

iOS 6's 2012‑era "Madrid" iMessage payload predates that. Its outgoing group payload is
only:

```
{ p = ( participant URIs ); t = "text"; v = 1; }
```

No `gid`. So once a group has a name, modern devices can't match iOS 6's gid‑less
messages to the named group and bucket them by participant set into a **separate
("forked") thread** instead. iOS 6 itself always looks normal, it only ever has the one
chat; the split is only visible to the modern recipients.

## The fix

iOS 6 actually already receives the `gid` — it's inside every **incoming** group message
(decryption is end‑to‑end, so iOS 6 gets exactly what the modern sender encrypted; the
`gid` is only discarded later, when iOS 6 builds its internal message object). So the
tweak:

1. **Harvests** the gid from incoming messages. It hooks the exported C function
   `JWDecodeDictionary` (in `IMFoundation`), which decodes every inbound payload. When a
   decoded payload carries `gid` + participants, the tweak stores a
   `participants → gid` mapping (persisted to `/var/mobile/gcnf_learned.plist`).

2. **Injects** the gid on send. It hooks
   `-[MessageDeliveryController _sendMessage:messageString:messageDictionary:…]`
   (in the `iMessage.imservice` plugin), looks up the learned gid for the outgoing
   participant set, and adds `gid` + `gv = 8` to the payload dictionary **before** it is
   serialized (`_JWEncodeDictionary`), gzipped and encrypted.

Net effect: once **any** modern member posts in a group, the iOS 6 device learns that
group's gid and every subsequent send threads correctly, and because a group's gid is
**stable across renames**, learning it once fixes the group permanently.

It is purely additive: only outgoing **group** sends (2+ participants) are touched;
1‑to‑1 messages and all incoming messages are untouched.

## Showing the group name (v7.0.0)

iOS 6's `ChatKit` has no concept of a *named* group, so the Messages app titles a group
transcript with the participant list. But the name actually arrives — it rides in the same
end‑to‑end payload as the `gid`. So the tweak now also:

1. **Harvests the name.** The same `JWDecodeDictionary` hook that learns the `gid` also
   pulls the group name out of decoded inbound payloads and persists a
   `participants → name` map to `/var/mobile/gcnf_names.plist`.
2. **Displays it.** A second injection into **`MobileSMS`** sets the learned name both on
   the open conversation (hooks `-[CKTranscriptController setConversation:]`, re‑asserted
   from `-[CKMessagesController _showTranscriptController:animated:]`) and on each row of
   the main Messages list (hooks `-[CKConversationListController
   tableView:cellForRowAtIndexPath:]`).

The routing and display halves are joined by a scheme/format‑insensitive participant key.
`imagent`'s participant list includes the device's **own** handle while `ChatKit`'s
recipient list does not — and the account aliases aren't readable from inside the
`imagent` daemon (its `IMAccountController` is an empty client proxy). So `imagent` stores
the key with self included, and the **`MobileSMS`** side — where the account aliases *are*
available — reconciles at lookup time: it tries the on‑screen recipients, then retries with
each of the device's own handles added, matching the stored key exactly. Display is
cosmetic and entirely on the iOS 6 device — no protocol effect.

## Install

https://mikey820.github.io/repo/

- **Sileo / Cydia / Zebra:** add the repo, search *GroupChatNameFix*, install.
- **Manual:** download the `.deb` from
  [Releases](https://github.com/mikey820/GroupChatNameFix/releases) and
  `dpkg -i` it, then respring (or `killall imagent`).

Requirements: jailbroken **iOS 6**, `mobilesubstrate`. The tweak injects into
`imagent` (routing) and `MobileSMS` (name display).

## Files

| path | purpose |
|------|---------|
| `/Library/MobileSubstrate/DynamicLibraries/GroupChatNameFix.dylib` | the tweak (loads into `imagent` + `MobileSMS`) |
| `/var/mobile/gcnf_learned.plist` | auto‑learned `participants → gid` map (persisted) |
| `/var/mobile/gcnf_names.plist` | auto‑learned `participants → name` map (persisted) |
| `/var/mobile/gcnf_gid.txt` | **optional** manual gid override (see below) |
| `/var/mobile/gcnf_forcename.txt` | **optional** UI test: force this string as every group's title |
| `/var/mobile/GroupChatNameFix.log` | diagnostic log |

### Manual override (optional)

Normally nothing is needed. To force a specific gid for every group send (e.g. for
testing), create `/var/mobile/gcnf_gid.txt`:

```
gid=2DA6132C-4E52-402E-AC30-577D90B31727
gv=8
minpeople=2
```

If present, this takes precedence over the learned map. Delete the file to return to
fully automatic operation.

## Caveats

- **First‑message learning.** For each group, iOS 6 must *receive* one modern message
  before it knows that group's gid. A send made before that (or in a brand‑new group
  with no inbound yet) can still fork; it self‑heals on the next inbound. The learned map
  survives reboots.
- **Same participants, multiple named groups.** The map is keyed by participant set, so
  if the exact same members share several named groups, sends route to the
  most‑recently‑seen gid for that set. Fine for normal use (one group per set).

## How it was found

The relevant code is **not** in `IMDaemonCore` (a thin shim), it lives in the
`iMessage.imservice` plugin and `IMFoundation`, which on iOS 6 exist only inside the
`dyld_shared_cache`. The send/receive paths and the `gid` injection seam were located by
pulling the cache off the device and analysing it with a small custom dyld‑cache reader +
Thumb‑2 disassembler. This cache stores embedded
DATA/literal‑pool pointers with a constant slide of `0x30A8000` (subtract before mapping;
code/section/symbol addresses are **not** slid).

## Build

CI (`.github/workflows/build.yml`) builds with Theos + the iPhoneOS 14.5 SDK and the
L1ghtmann Linux iOS toolchain on Ubuntu, then repacks the `.deb` with **gzip**
compression (iOS 6's `dpkg` cannot unpack the lzma/xz that newer `dpkg-deb` emits) and
publishes it to Releases.

## License / credits

By mikey820. iMessage protocol details cross‑checked against open reverse‑engineering of
the Madrid/`gid` group format.
