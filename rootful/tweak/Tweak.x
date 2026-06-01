// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// v5.0.0-safehunt : STRICTLY READ-ONLY diagnostic.
// -------------------------------------------------
// Earlier builds mutated the live IMDChat (addParticipants:) and KVC-probed
// objects with -valueForKey:. On incoming CONTROL messages that path caused
// EXC_BAD_ACCESS inside our dylib and crash-looped imagent (no send/receive).
//
// This build does NOTHING but log, using only proven-safe calls:
//   * -description                       (every NSObject responds)
//   * -dictionaryRepresentation          (guarded by respondsToSelector:)
//   * known IMDServiceSession selectors   (guarded)
// No -valueForKey:. No object mutation. So it cannot destabilise imagent.
//
// Goal: capture the group RENAME event coming from a modern-iOS device, to see
// whether iOS 6 ever receives a persistent group GUID it could re-transmit. If
// it does, a real fix becomes possible; if the rename arrives as nothing but a
// name string + room id, the split is a protocol limitation of iOS 6.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kLogPath = @"/var/mobile/GroupChatNameFix.log";
static int gLogBudget = 1200;

static void GCLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused id e) {}
    NSLog(@"[GroupChatNameFix] %@", msg);
}
#define GCLOGB(...) do { if (gLogBudget-- > 0) GCLog(__VA_ARGS__); } while (0)

// Safe: description only. Never valueForKey:, never mutate.
static NSString *GCDesc(id o) {
    if (!o) return @"(nil)";
    @try { return [o description] ?: @"(nil-desc)"; }
    @catch (__unused id e) { return @"(desc-threw)"; }
}

// Safe: dictionaryRepresentation if the object advertises it.
static id GCDict(id o) {
    @try {
        if ([o respondsToSelector:@selector(dictionaryRepresentation)])
            return ((id(*)(id, SEL))objc_msgSend)(o, @selector(dictionaryRepresentation));
    } @catch (__unused id e) {}
    return nil;
}

// ===========================================================================
// RECEIVE — capture control (no-body) messages; that's where a rename lands.
// ===========================================================================
static void (*orig_didRecv)(id, SEL, id, id, int);
static void gc_didRecv(id self, SEL _cmd, id msg, id chat, int style) {
    @try {
        id d = GCDict(msg);
        BOOL hasBody = [d isKindOfClass:[NSDictionary class]] && (d[@"bodyData"] || d[@"plainBody"]);
        id flags = [d isKindOfClass:[NSDictionary class]] ? d[@"flags"] : nil;
        if (!hasBody) {
            // Control traffic (group updates, renames, participant changes).
            GCLOGB(@"*** RECV-CONTROL chat=%@ style=%d flags=%@ dict=%@",
                   GCDesc(chat), style, flags, GCDesc(d));
        } else {
            GCLOGB(@"recv chat=%@ flags=%@ (body)", GCDesc(chat), flags);
        }
    } @catch (__unused id e) {}
    orig_didRecv(self, _cmd, msg, chat, style);
}

// ===========================================================================
// RENAME / GROUP-CHANGE hooks — the heart of the hunt (read-only).
// ===========================================================================
static void (*orig_renameGroup)(id, SEL, id, id);
static void gc_renameGroup(id self, SEL _cmd, id group, id name) {
    @try { GCLOGB(@"*** RENAME group=%@ to=%@ groupDict=%@",
                  GCDesc(group), GCDesc(name), GCDesc(GCDict(group))); }
    @catch (__unused id e) {}
    orig_renameGroup(self, _cmd, group, name);
}

static void (*orig_changeGroup)(id, SEL, id, id);
static void gc_changeGroup(id self, SEL _cmd, id group, id changes) {
    @try { GCLOGB(@"*** CHANGEGROUP group=%@ changes=%@", GCDesc(group), GCDesc(changes)); }
    @catch (__unused id e) {}
    orig_changeGroup(self, _cmd, group, changes);
}

static void (*orig_changeGroups)(id, SEL, id);
static void gc_changeGroups(id self, SEL _cmd, id groups) {
    @try { GCLOGB(@"*** CHANGEGROUPS %@", GCDesc(groups)); }
    @catch (__unused id e) {}
    orig_changeGroups(self, _cmd, groups);
}

static id (*orig_mapRoom)(id, SEL, id, int);
static id gc_mapRoom(id self, SEL _cmd, id room, int style) {
    id r = orig_mapRoom(self, _cmd, room, style);
    @try { GCLOGB(@"_mapRoomChatToGroupChat room=%@ style=%d => %@",
                  GCDesc(room), style, GCDesc(r)); }
    @catch (__unused id e) {}
    return r;
}

// useChatRoom:forGroupChatIdentifier: establishes the room<->group link on rename.
static void (*orig_useRoom)(id, SEL, id, id);
static void gc_useRoom(id self, SEL _cmd, id room, id groupId) {
    @try { GCLOGB(@"*** USEROOM room=%@ forGroupChatIdentifier=%@", GCDesc(room), GCDesc(groupId)); }
    @catch (__unused id e) {}
    orig_useRoom(self, _cmd, room, groupId);
}

// ===========================================================================
// SEND — observe only (no stamping, no repair).
// ===========================================================================
static void (*orig_sendToChatID)(id, SEL, id, id, id, int);
static void gc_sendToChatID(id self, SEL _cmd, id msg, id chatID, id identifier, int style) {
    @try { GCLOGB(@"SEND toChatID=%@ identifier=%@ style=%d", GCDesc(chatID), GCDesc(identifier), style); }
    @catch (__unused id e) {}
    orig_sendToChatID(self, _cmd, msg, chatID, identifier, style);
}

// ---------------------------------------------------------------------------
static BOOL GCHook1(NSString *cn, SEL sel, IMP repl, void *slot, const char *tag) {
    Class c = NSClassFromString(cn);
    if (c && [c instancesRespondToSelector:sel]) {
        MSHookMessageEx(c, sel, repl, (IMP *)slot);
        GCLog(@"HOOKED -[%@ %@] [%s]", cn, NSStringFromSelector(sel), tag);
        return YES;
    }
    GCLog(@"MISS  -[%@ %@] [%s]", cn, NSStringFromSelector(sel), tag);
    return NO;
}

%ctor {
    @autoreleasepool {
        GCLog(@"=== GroupChatNameFix 5.0.0-safehunt (READ-ONLY) loaded in %@ ===",
              [[NSProcessInfo processInfo] processName]);
        NSString *S = @"IMDServiceSession";
        GCHook1(S, @selector(didReceiveMessage:forChat:style:),
                (IMP)gc_didRecv, &orig_didRecv, "recv");
        GCHook1(S, @selector(renameGroup:to:),
                (IMP)gc_renameGroup, &orig_renameGroup, "rename");
        GCHook1(S, @selector(changeGroup:changes:),
                (IMP)gc_changeGroup, &orig_changeGroup, "change");
        GCHook1(S, @selector(changeGroups:),
                (IMP)gc_changeGroups, &orig_changeGroups, "changes");
        GCHook1(S, @selector(_mapRoomChatToGroupChat:style:),
                (IMP)gc_mapRoom, &orig_mapRoom, "maproom");
        GCHook1(S, @selector(useChatRoom:forGroupChatIdentifier:),
                (IMP)gc_useRoom, &orig_useRoom, "useroom");
        GCHook1(S, @selector(sendMessage:toChatID:identifier:style:),
                (IMP)gc_sendToChatID, &orig_sendToChatID, "send");
    }
}
