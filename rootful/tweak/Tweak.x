// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// Problem
// -------
// A group iMessage that includes an iOS 6 device works fine until someone on a
// newer iOS *renames* the group. After that, every message the iOS 6 device
// sends shows up for everyone else as a brand-new conversation (the iOS 6
// device itself still sees one continuous thread).
//
// Real mechanism (confirmed from the live IMDaemonCore runtime on iOS 6.1.4 —
// see the v1 selector dump)
// -------------------------------------------------------------------------
// iOS 6 represents an iMessage group two ways inside imagent (IMDServiceSession):
//
//   * a "group chat identifier" derived from the participant set, and
//   * a server "chat room" (roomName, e.g. "chatXXXXXXXXXXXXXXXX") used once
//     the group is named.
//
// The two are linked by an in-memory table:
//     -useChatRoom:forGroupChatIdentifier:      (establishes the mapping)
//     -chatRoomForGroupChatIdentifier:          (group id  -> room)
//     -groupChatIdentifierForChatRoom:          (room      -> group id)
//
// When the rename is received, -useChatRoom:forGroupChatIdentifier: records the
// room. Incoming messages then arrive on the room (one thread, name adopted).
// But when iOS 6 *sends*, imagent asks -chatRoomForGroupChatIdentifier: whether
// there is a named room to route to. That mapping is volatile (lost across
// imagent relaunches / reboots), so it returns nil, and the message goes out on
// the bare participant group chat instead of the room. Recipients, keyed on the
// room, treat it as a new conversation.
//
// Fix
// ---
//   1. LEARN  the group<->room mapping from -useChatRoom:forGroupChatIdentifier:
//      and from any incoming/sent IMDChat that already carries a roomName, and
//      PERSIST it to disk (this is what survives the imagent relaunch).
//   2. RESTORE the mapping when imagent asks: if -chatRoomForGroupChatIdentifier:
//      (or the reverse) returns nil, supply the persisted value.
//   3. BACKSTOP: just before a send, if the target IMDChat has participants we
//      know a room for but its own roomName is empty, stamp the room on with
//      -setRoomName: so routing goes to the room.
//
// Everything is guarded and logged; if a precondition never triggers the log
// says exactly what the live objects looked like so the next build can adjust.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kByPartPath = @"/var/mobile/Library/Preferences/com.mikey820.groupchatnamefix.byparticipants.plist";
static NSString *const kGrpRoomPath = @"/var/mobile/Library/Preferences/com.mikey820.groupchatnamefix.grouptoroom.plist";
static NSString *const kLogPath     = @"/var/mobile/GroupChatNameFix.log";

static NSMutableDictionary *gByPart;     // participantsKey -> roomName (NSString)
static NSMutableDictionary *gGrpToRoom;  // groupChatIdentifier -> roomName (NSString)
static dispatch_queue_t     gQueue;      // serialises map access + file IO
static int                  gLogBudget = 400;

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// objc helpers (typed objc_msgSend wrappers, all selector-guarded by caller)
// ---------------------------------------------------------------------------
static id GCget(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
}
static void GCset(id obj, SEL sel, id val) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return;
    ((void(*)(id, SEL, id))objc_msgSend)(obj, sel, val);
}
static NSString *GCstr(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] ? v : nil;
    return nil;
}

// ---------------------------------------------------------------------------
// Participant-roster -> stable key
// ---------------------------------------------------------------------------
static NSString *GCNormHandle(NSString *h) {
    if (![h isKindOfClass:[NSString class]] || h.length == 0) return nil;
    NSString *s = [h lowercaseString];
    if ([s rangeOfString:@"@"].location != NSNotFound) return s; // email / iCloud id
    NSMutableString *d = [NSMutableString string];               // phone number
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [d appendFormat:@"%C", c];
    }
    if (d.length == 0) return s;
    if (d.length > 10) return [d substringFromIndex:d.length - 10]; // dodge +1/country diffs
    return d;
}

static void GCCollectHandles(id obj, NSMutableSet *out, int depth) {
    if (!obj || depth > 4) return;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *n = GCNormHandle(obj);
        if (n) [out addObject:n];
    } else if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id e in (id<NSFastEnumeration>)obj) GCCollectHandles(e, out, depth + 1);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)obj allValues]) GCCollectHandles(v, out, depth + 1);
    } else {
        // IMHandle / IMDHandle-like objects: pull an identifier string.
        for (NSString *selName in @[ @"ID", @"address", @"identifier", @"handle" ]) {
            SEL s = NSSelectorFromString(selName);
            if ([obj respondsToSelector:s]) {
                id v = ((id(*)(id, SEL))objc_msgSend)(obj, s);
                if ([v isKindOfClass:[NSString class]]) {
                    NSString *n = GCNormHandle(v);
                    if (n) { [out addObject:n]; return; }
                }
            }
        }
    }
}

static NSString *GCParticipantsKeyFromChat(id chat) {
    @try {
        id parts = GCget(chat, @selector(participants));
        if (!parts) return nil;
        NSMutableSet *set = [NSMutableSet set];
        GCCollectHandles(parts, set, 0);
        if (set.count < 2) return nil; // need a real multi-party roster
        NSArray *sorted = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
        return [sorted componentsJoinedByString:@","];
    } @catch (__unused id e) { return nil; }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------
static void GCLoad(void) {
    NSDictionary *a = [NSDictionary dictionaryWithContentsOfFile:kByPartPath];
    NSDictionary *b = [NSDictionary dictionaryWithContentsOfFile:kGrpRoomPath];
    gByPart    = a ? [a mutableCopy] : [NSMutableDictionary dictionary];
    gGrpToRoom = b ? [b mutableCopy] : [NSMutableDictionary dictionary];
}
static void GCSaveLocked(void) {
    @try {
        [gByPart    writeToFile:kByPartPath  atomically:YES];
        [gGrpToRoom writeToFile:kGrpRoomPath atomically:YES];
    } @catch (__unused id e) {}
}

// learn group-id -> room (plist-safe: both must be strings)
static void GCLearnGroupRoom(NSString *groupId, NSString *room) {
    groupId = GCstr(groupId); room = GCstr(room);
    if (!groupId || !room) return;
    dispatch_async(gQueue, ^{
        if ([gGrpToRoom[groupId] isEqual:room]) return;
        gGrpToRoom[groupId] = room;
        GCSaveLocked();
        GCLog(@"LEARN group->room  %@  =>  %@", groupId, room);
    });
}
static void GCLearnPartRoom(NSString *partKey, NSString *room) {
    partKey = GCstr(partKey); room = GCstr(room);
    if (!partKey || !room) return;
    dispatch_async(gQueue, ^{
        if ([gByPart[partKey] isEqual:room]) return;
        gByPart[partKey] = room;
        GCSaveLocked();
        GCLog(@"LEARN parts->room  %@  =>  %@", partKey, room);
    });
}

// Learn whatever a live IMDChat can tell us (called on send & receive).
static void GCLearnFromChat(id chat, const char *where) {
    if (!chat) return;
    @try {
        NSString *room    = GCstr(GCget(chat, @selector(roomName)));
        NSString *chatId  = GCstr(GCget(chat, @selector(chatIdentifier)));
        NSString *guid    = GCstr(GCget(chat, @selector(guid)));
        NSString *partKey = GCParticipantsKeyFromChat(chat);
        GCLOGB(@"CHAT[%s] room=%@ chatId=%@ guid=%@ parts=%@",
               where, room, chatId, guid, partKey);
        if (room) {
            if (partKey) GCLearnPartRoom(partKey, room);
            if (chatId)  GCLearnGroupRoom(chatId, room);
        }
    } @catch (__unused id e) {}
}

static NSString *GCLookupRoomForChat(id chat) {
    @try {
        NSString *chatId  = GCstr(GCget(chat, @selector(chatIdentifier)));
        NSString *partKey = GCParticipantsKeyFromChat(chat);
        __block NSString *room = nil;
        dispatch_sync(gQueue, ^{
            if (chatId)  room = gGrpToRoom[chatId];
            if (!room && partKey) room = gByPart[partKey];
        });
        return GCstr(room);
    } @catch (__unused id e) { return nil; }
}

// ===========================================================================
// LEARN the mapping directly  -useChatRoom:forGroupChatIdentifier:
// ===========================================================================
static void (*orig_useRoom)(id, SEL, id, id);
static void gc_useRoom(id self, SEL _cmd, id room, id groupId) {
    @try {
        GCLog(@"useChatRoom: %@ (%@)  forGroupChatIdentifier: %@ (%@)",
              room, [room class], groupId, [groupId class]);
        GCLearnGroupRoom(GCstr(groupId), GCstr(room));
    } @catch (__unused id e) {}
    orig_useRoom(self, _cmd, room, groupId);
}

// ===========================================================================
// RESTORE  -chatRoomForGroupChatIdentifier:   (group id -> room)
// ===========================================================================
static id (*orig_roomForGroup)(id, SEL, id);
static id gc_roomForGroup(id self, SEL _cmd, id groupId) {
    id room = orig_roomForGroup(self, _cmd, groupId);
    @try {
        if (!GCstr(room)) {
            __block NSString *learned = nil;
            NSString *gid = GCstr(groupId);
            if (gid) dispatch_sync(gQueue, ^{ learned = gGrpToRoom[gid]; });
            if (learned) {
                GCLog(@"RESTORE room for group %@ -> %@ (orig nil)", gid, learned);
                return learned;
            }
        } else {
            // opportunistically learn the live mapping too
            GCLearnGroupRoom(GCstr(groupId), GCstr(room));
        }
    } @catch (__unused id e) {}
    return room;
}

// ===========================================================================
// RESTORE  -groupChatIdentifierForChatRoom:   (room -> group id)  [symmetry]
// ===========================================================================
static id (*orig_groupForRoom)(id, SEL, id);
static id gc_groupForRoom(id self, SEL _cmd, id room) {
    id gid = orig_groupForRoom(self, _cmd, room);
    @try {
        if (GCstr(gid) && GCstr(room)) GCLearnGroupRoom(GCstr(gid), GCstr(room));
    } @catch (__unused id e) {}
    return gid;
}

// ===========================================================================
// LEARN on receive  -didReceiveMessage:forChat:style:
// ===========================================================================
static void (*orig_didRecv)(id, SEL, id, id, int);
static void gc_didRecv(id self, SEL _cmd, id msg, id chat, int style) {
    @try { GCLearnFromChat(chat, "recv"); } @catch (__unused id e) {}
    orig_didRecv(self, _cmd, msg, chat, style);
}

// ===========================================================================
// BACKSTOP on send  -sendMessage:toChat:style:
//                   -processMessageForSending:toChat:style:completionBlock:
// ===========================================================================
static void GCFixOutgoingChat(id chat, const char *where) {
    @try {
        GCLearnFromChat(chat, where);
        NSString *room = GCstr(GCget(chat, @selector(roomName)));
        if (room) return;                       // already a proper room chat
        NSString *learned = GCLookupRoomForChat(chat);
        if (learned && [chat respondsToSelector:@selector(setRoomName:)]) {
            GCset(chat, @selector(setRoomName:), learned);
            GCLog(@"FIX[%s] stamped roomName=%@ on outgoing chat (chatId=%@)",
                  where, learned, GCstr(GCget(chat, @selector(chatIdentifier))));
        }
    } @catch (__unused id e) {}
}

static void (*orig_sendMsg)(id, SEL, id, id, int);
static void gc_sendMsg(id self, SEL _cmd, id msg, id chat, int style) {
    GCFixOutgoingChat(chat, "send");
    orig_sendMsg(self, _cmd, msg, chat, style);
}

static void (*orig_procSend)(id, SEL, id, id, int, id);
static void gc_procSend(id self, SEL _cmd, id msg, id chat, int style, id block) {
    GCFixOutgoingChat(chat, "procSend");
    orig_procSend(self, _cmd, msg, chat, style, block);
}

// ---------------------------------------------------------------------------
// Hook helper
// ---------------------------------------------------------------------------
static BOOL GCHook1(NSString *cn, SEL sel, IMP repl, void *slot, const char *tag) {
    Class c = NSClassFromString(cn);
    if (c && [c instancesRespondToSelector:sel]) {
        MSHookMessageEx(c, sel, repl, (IMP *)slot);
        GCLog(@"HOOKED -[%@ %@]  [%s]", cn, NSStringFromSelector(sel), tag);
        return YES;
    }
    GCLog(@"MISS  -[%@ %@]  [%s]", cn, NSStringFromSelector(sel), tag);
    return NO;
}

%ctor {
    @autoreleasepool {
        gQueue = dispatch_queue_create("com.mikey820.groupchatnamefix.q", DISPATCH_QUEUE_SERIAL);
        GCLoad();
        GCLog(@"=== GroupChatNameFix 2.0.0 loaded in %@ (byPart=%lu grpRoom=%lu) ===",
              [[NSProcessInfo processInfo] processName],
              (unsigned long)gByPart.count, (unsigned long)gGrpToRoom.count);

        NSString *S = @"IMDServiceSession";
        GCHook1(S, @selector(useChatRoom:forGroupChatIdentifier:),
                (IMP)gc_useRoom, &orig_useRoom, "learn-map");
        GCHook1(S, @selector(chatRoomForGroupChatIdentifier:),
                (IMP)gc_roomForGroup, &orig_roomForGroup, "restore-room");
        GCHook1(S, @selector(groupChatIdentifierForChatRoom:),
                (IMP)gc_groupForRoom, &orig_groupForRoom, "restore-group");
        GCHook1(S, @selector(didReceiveMessage:forChat:style:),
                (IMP)gc_didRecv, &orig_didRecv, "learn-recv");
        GCHook1(S, @selector(sendMessage:toChat:style:),
                (IMP)gc_sendMsg, &orig_sendMsg, "fix-send");
        GCHook1(S, @selector(processMessageForSending:toChat:style:completionBlock:),
                (IMP)gc_procSend, &orig_procSend, "fix-procsend");
    }
}
