// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// Confirmed mechanism (from on-device runtime diagnostics, v2.1.0)
// ----------------------------------------------------------------
// In iOS 6's imagent the group send/receive entry points are:
//     -[IMDServiceSession sendMessage:toChat:style:]
//     -[IMDServiceSession processMessageForSending:toChat:style:completionBlock:]
//     -[IMDServiceSession didReceiveMessage:forChat:style:]
// where:
//     * the message  is an FZMessage (has -roomName / -setRoomName:), and
//     * the "chat"   argument is an NSString: the group's room id, e.g.
//       "chat659667617220016130"  (NOT an IMDChat object).
//
// A named group conversation is keyed on its room id. iOS 6 receives on the
// room fine (one local thread, name adopted). But on SEND, the FZMessage that
// is actually transmitted has roomName == nil: the device routes locally via
// the toChat: room id, yet the copy placed on the wire loses its roomName.
// Recipients receive a group message with no room, so they cannot thread it
// into the named conversation and show it as a brand-new thread instead.
//
// Observed for a single outgoing message (same GUID, two phases):
//     send.msg  flags=0x10000c  roomName='chat659667617220016130'   (local)
//     send.msg  flags=0x100005  roomName='(null)'  messageID:81      (wire) <-- bug
//
// Fix
// ---
// On the send path, before the original runs, stamp the FZMessage's roomName
// with the room id taken from the toChat: argument whenever the message's own
// roomName is empty. Only group rooms (identifiers beginning with "chat") are
// touched, so 1:1 conversations are never affected.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kLogPath = @"/var/mobile/GroupChatNameFix.log";
static int gLogBudget = 600;   // keep the log bounded

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
// Helpers
// ---------------------------------------------------------------------------
static NSString *GCStr(id v) {
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? v : nil;
}

// The room id for a group conversation. iOS 6 names group rooms "chatNNNN...";
// 1:1 chats use the bare handle (phone/email), which we deliberately skip.
static NSString *GCRoomFromChatArg(id chat) {
    NSString *s = GCStr(chat);
    return (s && [s hasPrefix:@"chat"]) ? s : nil;
}

static NSString *GCMsgRoom(id msg) {
    if (![msg respondsToSelector:@selector(roomName)]) return nil;
    return GCStr(((id(*)(id, SEL))objc_msgSend)(msg, @selector(roomName)));
}

// Dump the full wire dictionary of an FZMessage so we can see the group-identity
// fields that actually thread the conversation.
static void GCDumpMsgDict(id msg, const char *where) {
    @try {
        id dict = nil;
        if ([msg respondsToSelector:@selector(dictionaryRepresentation)])
            dict = ((id(*)(id, SEL))objc_msgSend)(msg, @selector(dictionaryRepresentation));
        else if ([msg respondsToSelector:@selector(copyDictionaryRepresentation)])
            dict = ((id(*)(id, SEL))objc_msgSend)(msg, @selector(copyDictionaryRepresentation));
        GCLOGB(@"DICT[%s] keys=%@ :: %@", where,
               [dict isKindOfClass:[NSDictionary class]] ? [[dict allKeys] componentsJoinedByString:@","] : @"?",
               dict);
    } @catch (__unused id e) {}
}

// The actual fix: ensure an outgoing group FZMessage carries its room id.
static void GCStampOutgoing(id msg, id chat, const char *where) {
    @try {
        NSString *room = GCRoomFromChatArg(chat);
        if (!room) return;                                   // not a group room
        if (![msg respondsToSelector:@selector(setRoomName:)]) return;
        if (GCMsgRoom(msg)) return;                          // already has one
        GCDumpMsgDict(msg, "out-before");
        ((void(*)(id, SEL, id))objc_msgSend)(msg, @selector(setRoomName:), room);
        GCDumpMsgDict(msg, "out-after");
        GCLOGB(@"FIX[%s] stamped roomName=%@ (was empty) guid=%@",
               where, room, [msg respondsToSelector:@selector(guid)]
                   ? ((id(*)(id, SEL))objc_msgSend)(msg, @selector(guid)) : @"?");
    } @catch (__unused id e) {}
}

// Dump everything iOS 6 knows about this group room: the registry IMDChat's
// full dictionary, and what the session maps the room <-> group id to.
static void GCProbeGroup(id session, NSString *room, const char *where) {
    @try {
        // session: room -> group identifier (this is likely the wire identity)
        if ([session respondsToSelector:@selector(groupChatIdentifierForChatRoom:)]) {
            id gid = ((id(*)(id, SEL, id))objc_msgSend)(session, @selector(groupChatIdentifierForChatRoom:), room);
            GCLOGB(@"PROBE[%s] groupChatIdentifierForChatRoom(%@) = %@", where, room, gid);
        }
        if ([session respondsToSelector:@selector(chatRoomForGroupChatIdentifier:)]) {
            id r = ((id(*)(id, SEL, id))objc_msgSend)(session, @selector(chatRoomForGroupChatIdentifier:), room);
            GCLOGB(@"PROBE[%s] chatRoomForGroupChatIdentifier(%@) = %@", where, room, r);
        }
        if ([session respondsToSelector:@selector(shouldImitateGroupChatUsingChatRooms)]) {
            BOOL b = ((BOOL(*)(id, SEL))objc_msgSend)(session, @selector(shouldImitateGroupChatUsingChatRooms));
            GCLOGB(@"PROBE[%s] shouldImitateGroupChatUsingChatRooms = %d", where, b);
        }
        // registry: full IMDChat dict for this room
        Class reg = NSClassFromString(@"IMDChatRegistry");
        id shared = nil;
        if (reg && [reg respondsToSelector:@selector(sharedInstance)])
            shared = ((id(*)(id, SEL))objc_msgSend)(reg, @selector(sharedInstance));
        if (shared && [shared respondsToSelector:@selector(existingChatWithGUID:)]) {
            for (NSString *g in @[ room,
                                   [NSString stringWithFormat:@"iMessage;+;%@", room],
                                   [NSString stringWithFormat:@"iMessage;-;%@", room] ]) {
                id ch = ((id(*)(id, SEL, id))objc_msgSend)(shared, @selector(existingChatWithGUID:), g);
                if (ch) {
                    id d = [ch respondsToSelector:@selector(dictionaryRepresentation)]
                        ? ((id(*)(id, SEL))objc_msgSend)(ch, @selector(dictionaryRepresentation)) : nil;
                    GCLOGB(@"PROBE[%s] chatWithGUID(%@) = %@ :: dict=%@", where, g, ch, d);
                    break;
                }
            }
        }
    } @catch (__unused id e) {}
}

// ===========================================================================
// SEND hooks  (the fix + deep probe)
// ===========================================================================
static void (*orig_sendMsg)(id, SEL, id, id, int);
static void gc_sendMsg(id self, SEL _cmd, id msg, id chat, int style) {
    NSString *room = GCRoomFromChatArg(chat);
    if (room) GCProbeGroup(self, room, "send");
    GCStampOutgoing(msg, chat, "send");
    orig_sendMsg(self, _cmd, msg, chat, style);
}

// Deeper send: -sendMessage:toChatID:identifier:style:  (closer to the wire)
static void (*orig_sendToChatID)(id, SEL, id, id, id, int);
static void gc_sendToChatID(id self, SEL _cmd, id msg, id chatID, id identifier, int style) {
    @try { GCLOGB(@"sendMessage:toChatID:%@ identifier:%@ style:%d msgRoom=%@",
                  chatID, identifier, style, GCMsgRoom(msg)); }
    @catch (__unused id e) {}
    orig_sendToChatID(self, _cmd, msg, chatID, identifier, style);
}

// Routing dictionary builder — likely where wire group identity is assembled.
static void (*orig_handleRouting)(id, SEL, id);
static void gc_handleRouting(id self, SEL _cmd, id dict) {
    @try { GCLOGB(@"_handleRoutingWithDictionary: %@", dict); } @catch (__unused id e) {}
    orig_handleRouting(self, _cmd, dict);
}

static void (*orig_procSend)(id, SEL, id, id, int, id);
static void gc_procSend(id self, SEL _cmd, id msg, id chat, int style, id block) {
    GCStampOutgoing(msg, chat, "procSend");
    orig_procSend(self, _cmd, msg, chat, style, block);
}

// ===========================================================================
// RECEIVE hook  (diagnostic only — confirms threading, never modifies)
// ===========================================================================
static void (*orig_didRecv)(id, SEL, id, id, int);
static void gc_didRecv(id self, SEL _cmd, id msg, id chat, int style) {
    @try {
        GCLOGB(@"recv forChat=%@ msgRoom=%@", GCStr(chat), GCMsgRoom(msg));
        GCDumpMsgDict(msg, "in");
    } @catch (__unused id e) {}
    orig_didRecv(self, _cmd, msg, chat, style);
}

// ---------------------------------------------------------------------------
// Hook installation
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
        GCLog(@"=== GroupChatNameFix 3.2.0-diag loaded in %@ ===",
              [[NSProcessInfo processInfo] processName]);
        NSString *S = @"IMDServiceSession";
        GCHook1(S, @selector(sendMessage:toChat:style:),
                (IMP)gc_sendMsg, &orig_sendMsg, "fix-send");
        GCHook1(S, @selector(processMessageForSending:toChat:style:completionBlock:),
                (IMP)gc_procSend, &orig_procSend, "fix-procsend");
        GCHook1(S, @selector(didReceiveMessage:forChat:style:),
                (IMP)gc_didRecv, &orig_didRecv, "diag-recv");
        GCHook1(S, @selector(sendMessage:toChatID:identifier:style:),
                (IMP)gc_sendToChatID, &orig_sendToChatID, "diag-sendChatID");
        GCHook1(S, @selector(_handleRoutingWithDictionary:),
                (IMP)gc_handleRouting, &orig_handleRouting, "diag-routing");
    }
}
