// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// v5.1.0-safehunt : CONTROL-PLANE-ONLY read-only diagnostic.
// ----------------------------------------------------------
// Why v5.0.0 still crashed: its didReceiveMessage:forChat:style: hook fired on
// EVERY incoming message and sent objc_msgSend (respondsToSelector:) to the
// `msg` argument. Crash report (imagent 2026-06-01 15:51:53) shows frame0 =
// libobjc objc_msgSend called DIRECTLY from our dylib, on the IMDaemonCore ->
// iMessage -> libdispatch incoming path, with a garbage stack-address receiver
// (isa read as 0x22) -> EXC_BAD_ACCESS. So the per-message receive hook gets a
// non-object on some control traffic and faults. Because it fires on every
// message, that fault takes down ALL messaging.
//
// This build REMOVES both per-message hooks (didReceiveMessage + sendMessage).
// It keeps ONLY the rare-firing, read-only control-plane selectors that carry
// the group-rename / room-mapping event:
//   renameGroup:to:, changeGroup:changes:, changeGroups:,
//   _mapRoomChatToGroupChat:style:, useChatRoom:forGroupChatIdentifier:
// These fire only on group-metadata changes, never on normal traffic, so even
// in the worst case they cannot break ordinary sending/receiving.
//
// Logging uses only proven-safe calls (-description, guarded
// -dictionaryRepresentation). No -valueForKey:, no mutation.
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
        GCLog(@"=== GroupChatNameFix 5.1.0-safehunt (CONTROL-PLANE-ONLY) loaded in %@ ===",
              [[NSProcessInfo processInfo] processName]);
        NSString *S = @"IMDServiceSession";
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
    }
}
