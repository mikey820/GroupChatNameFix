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
static NSString *const kRosterPath = @"/var/mobile/Library/Preferences/com.mikey820.groupchatnamefix.roster.plist";
static int gLogBudget = 800;   // keep the log bounded

// room id -> NSMutableArray of handle strings (the TRUE roster, accumulated
// from every participant + sender ever seen on that room). Persisted.
static NSMutableDictionary *gRoster;
static NSMutableSet *gDumpedClasses;

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

// FZPersonID from an FZMessage's senderInfo (a confirmed group member).
static NSString *GCMsgSender(id msg) {
    @try {
        id dict = nil;
        if ([msg respondsToSelector:@selector(dictionaryRepresentation)])
            dict = ((id(*)(id, SEL))objc_msgSend)(msg, @selector(dictionaryRepresentation));
        if ([dict isKindOfClass:[NSDictionary class]]) {
            id si = dict[@"senderInfo"];
            if ([si isKindOfClass:[NSDictionary class]]) return GCStr(si[@"FZPersonID"]);
        }
    } @catch (__unused id e) {}
    return nil;
}

// ---------------------------------------------------------------------------
// True-roster accumulation (persisted)
// ---------------------------------------------------------------------------
static void GCRosterLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kRosterPath];
    gRoster = [NSMutableDictionary dictionary];
    for (NSString *k in d) gRoster[k] = [d[k] mutableCopy];
}
static void GCRosterSave(void) {
    @try { [gRoster writeToFile:kRosterPath atomically:YES]; } @catch (__unused id e) {}
}
// add one handle to a room's accumulated roster; returns YES if it was new.
static BOOL GCRosterAdd(NSString *room, NSString *handle) {
    if (!room || !handle) return NO;
    NSMutableArray *list = gRoster[room];
    if (!list) { list = [NSMutableArray array]; gRoster[room] = list; }
    if ([list containsObject:handle]) return NO;
    [list addObject:handle];
    GCRosterSave();
    GCLOGB(@"ROSTER %@ += %@  (now %u)", room, handle, (unsigned)list.count);
    return YES;
}

// Dump participant-mutation selectors of an IMDChat once, so we can pin the
// repair API in the next build.
static void GCDumpChatMethods(id chat) {
    if (!chat) return;
    Class c = object_getClass(chat);
    NSString *cn = NSStringFromClass(c);
    @synchronized (gDumpedClasses) {
        if ([gDumpedClasses containsObject:cn]) return;
        [gDumpedClasses addObject:cn];
    }
    NSMutableArray *hits = [NSMutableArray array];
    Class cur = c; int depth = 0;
    while (cur && depth < 4) {
        unsigned int n = 0; Method *ms = class_copyMethodList(cur, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            NSString *l = [s lowercaseString];
            if ([l rangeOfString:@"particip"].location != NSNotFound ||
                [l rangeOfString:@"handle"].location != NSNotFound ||
                [l rangeOfString:@"member"].location != NSNotFound ||
                [l rangeOfString:@"recipient"].location != NSNotFound ||
                [l rangeOfString:@"addr"].location != NSNotFound ||
                [l rangeOfString:@"setroom"].location != NSNotFound) {
                [hits addObject:s];
            }
        }
        free(ms); cur = class_getSuperclass(cur); depth++;
    }
    GCLOGB(@"CHATMETHODS %@ : %@", cn, [hits componentsJoinedByString:@", "]);
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
                    GCDumpChatMethods(ch);
                    GCDumpAllMethodsOnce(ch, "chat");
                    GCProbeGUIDKeys(ch, "send.chat");
                    // pull this chat's known participants (FZPersonID strings) into the roster
                    id parts = [ch respondsToSelector:@selector(participants)]
                        ? ((id(*)(id, SEL))objc_msgSend)(ch, @selector(participants)) : nil;
                    NSMutableArray *chatHandles = [NSMutableArray array];
                    if ([parts isKindOfClass:[NSArray class]]) {
                        for (id p in (NSArray *)parts) {
                            NSString *h = nil;
                            for (NSString *sel in @[ @"ID", @"address", @"identifier" ]) {
                                SEL s = NSSelectorFromString(sel);
                                if ([p respondsToSelector:s]) {
                                    id v = ((id(*)(id, SEL))objc_msgSend)(p, s);
                                    if ((h = GCStr(v))) break;
                                }
                            }
                            if (h) { [chatHandles addObject:h]; GCRosterAdd(room, h); }
                        }
                    }
                    NSArray *trueRoster = gRoster[room];
                    GCLOGB(@"PROBE[%s] room=%@  chatParticipants=%@  TRUEroster=%@",
                           where, room, chatHandles, trueRoster);

                    // ---- THE FIX: add any true-roster members missing from this chat,
                    //      as real IMDHandle objects (participants must be IMDHandle,
                    //      not NSString — confirmed in v4.0.0). ----
                    NSMutableArray *missing = [NSMutableArray array];
                    for (NSString *h in trueRoster)
                        if (![chatHandles containsObject:h]) [missing addObject:h];
                    if (missing.count) {
                        unsigned before = (unsigned)[(NSArray *)parts count];
                        // Clone the countryCode from an existing handle if we can.
                        NSString *cc = @"us";
                        if (before > 0) {
                            id h0 = [(NSArray *)parts objectAtIndex:0];
                            if ([h0 respondsToSelector:@selector(countryCode)]) {
                                NSString *c = GCStr(((id(*)(id, SEL))objc_msgSend)(h0, @selector(countryCode)));
                                if (c) cc = c;
                            }
                        }
                        Class HC = NSClassFromString(@"IMDHandle");
                        NSMutableArray *newHandles = [NSMutableArray array];
                        for (NSString *hid in missing) {
                            id handle = nil;
                            @try {
                                if (HC && [HC instancesRespondToSelector:@selector(initWithID:unformattedID:countryCode:)]) {
                                    handle = [HC alloc];
                                    handle = ((id(*)(id, SEL, id, id, id))objc_msgSend)(
                                        handle, @selector(initWithID:unformattedID:countryCode:),
                                        hid, (id)nil, cc);
                                }
                            } @catch (__unused id e) { handle = nil; }
                            if (handle) [newHandles addObject:handle];
                        }
                        BOOL added = NO;
                        if (newHandles.count && [ch respondsToSelector:@selector(addParticipants:)]) {
                            @try {
                                ((void(*)(id, SEL, id))objc_msgSend)(ch, @selector(addParticipants:), newHandles);
                                added = YES;
                            } @catch (__unused id e) {}
                        }
                        if (!added && newHandles.count && [ch respondsToSelector:@selector(addParticipant:)]) {
                            @try {
                                for (id hh in newHandles)
                                    ((void(*)(id, SEL, id))objc_msgSend)(ch, @selector(addParticipant:), hh);
                                added = YES;
                            } @catch (__unused id e) {}
                        }
                        id parts2 = [ch respondsToSelector:@selector(participants)]
                            ? ((id(*)(id, SEL))objc_msgSend)(ch, @selector(participants)) : nil;
                        unsigned after = [parts2 isKindOfClass:[NSArray class]] ? (unsigned)[parts2 count] : 0;
                        GCLOGB(@"REPAIR[%s] room=%@ missing=%@ built=%u added=%d count %u->%u parts2=%@",
                               where, room, missing, (unsigned)newHandles.count, added, before, after, parts2);
                    }
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

// ---- GUID HUNT: capture the rename event + probe for hidden group identity ----

// KVC-probe an object for any key that might hold a modern group GUID.
static void GCProbeGUIDKeys(id obj, const char *what) {
    if (!obj) return;
    NSArray *keys = @[ @"groupID", @"groupGUID", @"groupChatGUID", @"originalGroupID",
                       @"chatGUID", @"guid", @"groupName", @"displayName", @"name",
                       @"originalGroupName", @"newGroupName", @"groupChatIdentifier",
                       @"chatIdentifier", @"roomName", @"properties", @"groupInfo" ];
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v) GCLOGB(@"  GUIDKEY[%s] %@ = %@", what, k, v);
        } @catch (__unused id e) {}
    }
}

// Dump the COMPLETE method list of a class once (unfiltered) for the rename hunt.
static void GCDumpAllMethodsOnce(id obj, const char *tag) {
    if (!obj) return;
    Class c = object_getClass(obj);
    NSString *cn = [NSString stringWithFormat:@"ALL:%@", NSStringFromClass(c)];
    @synchronized (gDumpedClasses) {
        if ([gDumpedClasses containsObject:cn]) return;
        [gDumpedClasses addObject:cn];
    }
    unsigned int n = 0; Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *all = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) [all addObject:NSStringFromSelector(method_getName(ms[i]))];
    free(ms);
    GCLOGB(@"ALLMETHODS[%s] %@ (%u): %@", tag, NSStringFromClass(c), n,
           [all componentsJoinedByString:@", "]);
}

static void (*orig_renameGroup)(id, SEL, id, id);
static void gc_renameGroup(id self, SEL _cmd, id group, id name) {
    @try {
        GCLOGB(@"*** RENAME renameGroup:%@ to:%@", group, name);
        GCProbeGUIDKeys(group, "rename.group");
    } @catch (__unused id e) {}
    orig_renameGroup(self, _cmd, group, name);
}

static void (*orig_changeGroup)(id, SEL, id, id);
static void gc_changeGroup(id self, SEL _cmd, id group, id changes) {
    @try {
        GCLOGB(@"*** CHANGE changeGroup:%@ changes:%@", group, changes);
        GCProbeGUIDKeys(group, "change.group");
    } @catch (__unused id e) {}
    orig_changeGroup(self, _cmd, group, changes);
}

static void (*orig_changeGroups)(id, SEL, id);
static void gc_changeGroups(id self, SEL _cmd, id groups) {
    @try { GCLOGB(@"*** CHANGEGROUPS changeGroups:%@", groups); } @catch (__unused id e) {}
    orig_changeGroups(self, _cmd, groups);
}

static id (*orig_mapRoom)(id, SEL, id, int);
static id gc_mapRoom(id self, SEL _cmd, id room, int style) {
    id r = orig_mapRoom(self, _cmd, room, style);
    @try { GCLOGB(@"_mapRoomChatToGroupChat:%@ style:%d => %@", room, style, r); }
    @catch (__unused id e) {}
    return r;
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
        NSString *room = GCRoomFromChatArg(chat);
        NSString *sender = GCMsgSender(msg);
        // flags 32773 = normal text; group control/rename messages carry other
        // flags. Dump the full dict + GUID-keys so we catch the rename event.
        id dict = [msg respondsToSelector:@selector(dictionaryRepresentation)]
            ? ((id(*)(id, SEL))objc_msgSend)(msg, @selector(dictionaryRepresentation)) : nil;
        id flags = [dict isKindOfClass:[NSDictionary class]] ? dict[@"flags"] : nil;
        BOOL hasBody = [dict isKindOfClass:[NSDictionary class]] && (dict[@"bodyData"] || dict[@"plainBody"]);
        GCLOGB(@"recv forChat=%@ sender=%@ flags=%@ hasBody=%d", GCStr(chat), sender, flags, hasBody);
        // A control message (no body) is very likely the rename/group-update.
        if (!hasBody) {
            GCLOGB(@"  CONTROL dict=%@", dict);
            GCProbeGUIDKeys(msg, "recv.msg");
        }
        if (room && sender) GCRosterAdd(room, sender);   // confirmed group member
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
        gDumpedClasses = [NSMutableSet set];
        GCRosterLoad();
        GCLog(@"=== GroupChatNameFix 4.2.0-guidhunt loaded in %@ (roster rooms=%u) ===",
              [[NSProcessInfo processInfo] processName], (unsigned)gRoster.count);
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
        // GUID hunt: rename / group-change / room-mapping
        GCHook1(S, @selector(renameGroup:to:),
                (IMP)gc_renameGroup, &orig_renameGroup, "hunt-rename");
        GCHook1(S, @selector(changeGroup:changes:),
                (IMP)gc_changeGroup, &orig_changeGroup, "hunt-change");
        GCHook1(S, @selector(changeGroups:),
                (IMP)gc_changeGroups, &orig_changeGroups, "hunt-changes");
        GCHook1(S, @selector(_mapRoomChatToGroupChat:style:),
                (IMP)gc_mapRoom, &orig_mapRoom, "hunt-maproom");
    }
}
