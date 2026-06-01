// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// v5.4.0-FIX : strip the stale roomName on outgoing GROUP sends.
// -----------------------------------------------------------------------------
// MECHANISM PROVEN (v5.3.x): renaming a group that contains a legacy iOS6 device
// migrates the modern group to a NEW room id; iOS6 is never notified and keeps
// sending with the OLD roomName (chatXXXX), so modern devices fork those into a
// separate convo. The new room id never reaches iOS6, so iOS6 cannot rejoin by
// learning it. ONLY fix path that doesn't need the new room: drop the stale room
// tag on iOS6's outgoing group messages so modern re-threads by participant set.
// This build does that (style 43 only), leaving the local `chat` arg intact so
// iOS6's own thread is unaffected. EXPERIMENT: verify on the different-number
// recipient that iOS6's messages now land in the renamed group.
// -----------------------------------------------------------------------------
// Finding from v5.2.1: when a modern device renames the group, iOS 6 fires NONE
// of renameGroup/changeGroup/changeGroups/useChatRoom. Only the per-message
// _mapRoomChatToGroupChat: fires and it returns nil (the fork). So the rename is
// handled on the incoming-message path and the visible break is on send. v5.3.0
// hooks didReceiveMessage:forChat:style: and sendMessage:toChat:style: and
// PROBES the IMDChat (guid/groupID/roomName/identifier/...) to find whether a
// stable group key ever reaches iOS 6, and what identity it stamps on sends.
// -----------------------------------------------------------------------------
// v5.2.0 still crashed (fault @0x22, same incoming path) even though logging was
// vm_read-guarded -- because the hook params/return were typed `id`, and ARC
// auto-emits objc_retain/objc_release on `id` values. That retain/release is
// itself an isa deref, and it ran on a non-object BEFORE our guarded logging.
// Fix: type every object arg + captured return as `void *` so ARC never touches
// them; only __bridge to id after GCIsObjectPtr confirms a real registered obj.
//
// Hard lesson from v5.0.0 and v5.1.0 (both crash-looped imagent and broke all
// messaging): on iOS 6 the arguments handed to IMDServiceSession / IMDaemonCore
// internal selectors are FREQUENTLY NOT Objective-C objects. They are C structs
// or char* buffers (e.g. a "chatXXXX" room name). Calling ANY objc_msgSend on
// them -- even -description / -respondsToSelector: -- dereferences garbage as an
// isa and faults:
//   * v5.0.0 didReceiveMessage: msg was a stack word = 0x22  -> fault @0x22
//   * v5.1.0 _mapRoomChatToGroupChat: room first bytes = "chat" -> fault @0x61686316
// And several of these selectors fire on the NORMAL incoming-message path, so a
// single fault crash-loops imagent => no send/receive at all.
//
// FIX: never trust a hook argument. Before any objc_msgSend, validate the
// pointer with vm_read_overwrite() -- a kernel read that returns a KERN_* error
// instead of faulting -- and confirm its isa is a member of the registered
// class list. Objects get -description; non-objects get a safe hex/ascii dump of
// their first bytes (which is exactly how we'll read a raw "chatXXXX" room id).
//
// Strictly read-only. No -valueForKey:, no mutation. Goal unchanged: capture the
// group RENAME event from a modern-iOS device and see whether iOS 6 ever
// receives a persistent group GUID it could re-transmit.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kLogPath = @"/var/mobile/GroupChatNameFix.log";
static int gLogBudget = 1500;

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

// ===========================================================================
// CRASH-PROOF memory + object validation (vm_read_overwrite never faults).
// ===========================================================================

// Safely read `len` bytes from `addr` into `out`. Returns NO on bad/unmapped
// memory instead of crashing. Rejects null-page and tiny pointers up front.
static BOOL GCSafeRead(const void *addr, void *out, size_t len) {
    if ((uintptr_t)addr < 0x1000) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)addr, (vm_size_t)len,
                                         (vm_address_t)out, &got);
    return (kr == KERN_SUCCESS && got == len);
}

// Sorted snapshot of every registered class pointer (as integers, to keep ARC
// out of it), for membership testing -- pointer compare only, never deref'd.
static uintptr_t *gClassPtrs = NULL;
static int gClassCount = 0;
static int GCUIntCmp(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static void GCBuildClassList(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *tmp = (Class *)malloc(sizeof(Class) * n);
    if (!tmp) return;
    gClassCount = objc_getClassList(tmp, n);
    gClassPtrs = (uintptr_t *)malloc(sizeof(uintptr_t) * gClassCount);
    if (gClassPtrs)
        for (int i = 0; i < gClassCount; i++) gClassPtrs[i] = (uintptr_t)tmp[i];
    free(tmp);
    if (gClassPtrs) qsort(gClassPtrs, gClassCount, sizeof(uintptr_t), GCUIntCmp);
}
static BOOL GCIsRegisteredClass(uintptr_t c) {
    if (!gClassPtrs || gClassCount == 0) return NO;
    return bsearch(&c, gClassPtrs, gClassCount, sizeof(uintptr_t), GCUIntCmp) != NULL;
}

// Is `p` really an Objective-C object? Read its isa via vm_read (safe), mask it,
// and confirm the candidate class is one the runtime actually registered.
// Works on a raw void* so ARC never sees an unverified object pointer.
static BOOL GCIsObjectPtr(const void *p) {
    uintptr_t pv = (uintptr_t)p;
    if (pv < 0x1000 || (pv & 0x3)) return NO;            // null page / misaligned
    uintptr_t isa = 0;
    if (!GCSafeRead(p, &isa, sizeof(isa))) return NO;
    uintptr_t c = isa & ~(uintptr_t)0x3;                 // no tagged ptrs on 32-bit
    if (c < 0x1000) return NO;
    return GCIsRegisteredClass(c);
}

// Safe printable description of ANYTHING. Takes a RAW pointer so ARC never
// emits retain/release on a value that might not be an object (that auto-ARC
// memory management is itself an isa deref and crashed v5.2.0-rc1). We only
// bridge to `id` AFTER GCIsObjectPtr confirms it is a registered object.
static NSString *GCSafe(const void *p) {
    if (!p) return @"(nil)";
    if (GCIsObjectPtr(p)) {
        id o = (__bridge id)p;
        @try { return [o description] ?: @"(nil-desc)"; }
        @catch (__unused id e) { return @"(desc-threw)"; }
    }
    unsigned char buf[40] = {0};
    if (GCSafeRead(p, buf, sizeof(buf) - 1)) {
        // ascii view (printable run)
        char ascii[41]; int n = 0;
        for (int i = 0; i < (int)sizeof(buf) - 1; i++) {
            unsigned char ch = buf[i];
            ascii[n++] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '.';
        }
        ascii[n] = 0;
        return [NSString stringWithFormat:@"<non-obj %p bytes='%s' %02x%02x%02x%02x%02x%02x%02x%02x>",
                p, ascii, buf[0],buf[1],buf[2],buf[3],buf[4],buf[5],buf[6],buf[7]];
    }
    return [NSString stringWithFormat:@"<unreadable %p>", p];
}

// dictionaryRepresentation, but only if `p` is a verified object that responds.
static NSString *GCDict(const void *p) {
    if (!GCIsObjectPtr(p)) return @"(not-obj)";
    id o = (__bridge id)p;
    @try {
        if ([o respondsToSelector:@selector(dictionaryRepresentation)]) {
            id d = ((id(*)(id, SEL))objc_msgSend)(o, @selector(dictionaryRepresentation));
            return GCSafe((__bridge const void *)d);
        }
    } @catch (__unused id e) {}
    return @"(no-dict)";
}

// Safe class name of a pointer (isa already verified by GCIsObjectPtr).
static NSString *GCClass(const void *p) {
    if (!GCIsObjectPtr(p)) return @"(not-obj)";
    @try {
        const char *n = class_getName(object_getClass((__bridge id)p));
        return n ? [NSString stringWithUTF8String:n] : @"(no-name)";
    } @catch (__unused id e) { return @"(cls-threw)"; }
}

// Probe a (verified) object for the identity getters that might carry a stable
// group key. Each call is guarded by respondsToSelector: and the result is run
// back through GCSafe (so a non-object/garbage return can't crash us either).
static NSString *GCProbe(const void *p) {
    if (!GCIsObjectPtr(p)) return @"(not-obj)";
    id o = (__bridge id)p;
    static const char *sels[] = {
        "guid", "groupID", "groupChatIdentifier", "roomName", "identifier",
        "chatIdentifier", "name", "displayName", "service", "participants",
        "threadIdentifier", "properties", "dictionary", "messageDictionary",
        "rawDictionary", "originalDictionary", NULL
    };
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; sels[i]; i++) {
        SEL sel = sel_getUid(sels[i]);
        @try {
            if ([o respondsToSelector:sel]) {
                id v = ((id(*)(id, SEL))objc_msgSend)(o, sel);
                [s appendFormat:@"%s=%@ | ", sels[i], GCSafe((__bridge const void *)v)];
            }
        } @catch (__unused id e) {}
    }
    return s.length ? s : @"(no-known-getters)";
}

// ===========================================================================
// RENAME / GROUP-CHANGE / ROOM-MAPPING hooks — read-only, fully guarded.
// ===========================================================================
// NOTE: every object argument and the captured return are typed `void *`, never
// `id`, so ARC cannot emit retain/release (= isa deref) on a possible non-object.

// RECEIVE — the decisive hook. We dump the incoming message and, crucially,
// PROBE the IMDChat it lands in for any stable group key (guid/groupID/...).
// This answers: does iOS 6 ever receive a group identifier after a rename?
static void (*orig_didRecv)(id, SEL, void *, void *, int);
static void gc_didRecv(id self, SEL _cmd, void *msg, void *chat, int style) {
    @try {
        GCLOGB(@"RECV style=%d chat<%@>=%@\n    chat.probe=%@\n    msg<%@>.probe=%@\n    msg.dict=%@",
               style, GCClass(chat), GCSafe(chat), GCProbe(chat),
               GCClass(msg), GCProbe(msg), GCDict(msg));
    } @catch (__unused id e) {}
    orig_didRecv(self, _cmd, msg, chat, style);
}

// SEND — THE FIX. On a group send (style 43) the outgoing FZMessage carries a
// stale roomName (the pre-rename room). Modern devices migrated to a new room on
// rename and reject the stale one into a fork. We CLEAR the roomName on the
// outgoing message so the wire payload is participant-keyed; modern then threads
// it by participant set into the renamed group. iOS 6's own local thread is keyed
// by the `chat` arg (left untouched), so iOS 6's view is unaffected.
static BOOL gFixEnabled = NO;           // room-strip disabled (proven insufficient); observe only
static void (*orig_sendMsg)(id, SEL, void *, void *, int);
static void gc_sendMsg(id self, SEL _cmd, void *msg, void *chat, int style) {
    @try {
        BOOL isGroup = (style == 43);
        id oldRoom = nil;
        if (gFixEnabled && isGroup && GCIsObjectPtr(msg)) {
            id m = (__bridge id)msg;
            if ([m respondsToSelector:@selector(roomName)] &&
                [m respondsToSelector:@selector(setRoomName:)]) {
                oldRoom = ((id(*)(id, SEL))objc_msgSend)(m, @selector(roomName));
                // Only strip a real stale room ("chatXXXX"); never touch nil.
                if (GCIsObjectPtr((__bridge const void *)oldRoom)) {
                    ((void(*)(id, SEL, id))objc_msgSend)(m, @selector(setRoomName:), nil);
                    GCLOGB(@"SEND-FIX style=%d strippedRoom=%@ chat<%@>=%@",
                           style, GCSafe((__bridge const void *)oldRoom),
                           GCClass(chat), GCSafe(chat));
                }
            }
        }
        if (!oldRoom) {
            GCLOGB(@"SEND style=%d chat<%@>=%@ msg.dict=%@",
                   style, GCClass(chat), GCSafe(chat), GCDict(msg));
        }
    } @catch (__unused id e) {}
    orig_sendMsg(self, _cmd, msg, chat, style);
}

// renameGroup:to: + useChatRoom: kept as cheap insurance (they fire only if the
// iOS 6 device itself initiates the change; observed NOT to fire on an incoming
// rename, but harmless to keep watching).
static void (*orig_renameGroup)(id, SEL, void *, void *);
static void gc_renameGroup(id self, SEL _cmd, void *group, void *name) {
    @try { GCLOGB(@"*** RENAME group.probe=%@ to=%@", GCProbe(group), GCSafe(name)); }
    @catch (__unused id e) {}
    orig_renameGroup(self, _cmd, group, name);
}

static void (*orig_useRoom)(id, SEL, void *, void *);
static void gc_useRoom(id self, SEL _cmd, void *room, void *groupId) {
    @try { GCLOGB(@"*** USEROOM room=%@ forGroupChatIdentifier=%@", GCSafe(room), GCSafe(groupId)); }
    @catch (__unused id e) {}
    orig_useRoom(self, _cmd, room, groupId);
}

// --- chat-lifecycle hooks: where iOS6 would LEARN a renamed group's new room ---
static void (*orig_didInvite)(id, SEL, void *, void *, int);
static void gc_didInvite(id self, SEL _cmd, void *inv, void *chat, int style) {
    @try { GCLOGB(@"*** INVITE chat<%@>=%@ style=%d inv=%@", GCClass(chat), GCSafe(chat), style, GCSafe(inv)); }
    @catch (__unused id e) {}
    orig_didInvite(self, _cmd, inv, chat, style);
}

static void (*orig_didJoin)(id, SEL, void *, int);
static void gc_didJoin(id self, SEL _cmd, void *chat, int style) {
    @try { GCLOGB(@"*** JOIN chat<%@>=%@ style=%d", GCClass(chat), GCSafe(chat), style); }
    @catch (__unused id e) {}
    orig_didJoin(self, _cmd, chat, style);
}

static void (*orig_didJoinHI)(id, SEL, void *, int, void *);
static void gc_didJoinHI(id self, SEL _cmd, void *chat, int style, void *hi) {
    @try { GCLOGB(@"*** JOIN-HI chat<%@>=%@ style=%d hi=%@", GCClass(chat), GCSafe(chat), style, GCSafe(hi)); }
    @catch (__unused id e) {}
    orig_didJoinHI(self, _cmd, chat, style, hi);
}

static void (*orig_chatStatus)(id, SEL, void *, void *, int);
static void gc_chatStatus(id self, SEL _cmd, void *status, void *chat, int style) {
    @try { GCLOGB(@"*** CHATSTATUS chat<%@>=%@ status=%p style=%d", GCClass(chat), GCSafe(chat), status, style); }
    @catch (__unused id e) {}
    orig_chatStatus(self, _cmd, status, chat, style);
}

static void (*orig_chatStatusHI)(id, SEL, void *, void *, int, void *);
static void gc_chatStatusHI(id self, SEL _cmd, void *status, void *chat, int style, void *hi) {
    @try { GCLOGB(@"*** CHATSTATUS-HI chat<%@>=%@ status=%p style=%d hi=%@", GCClass(chat), GCSafe(chat), status, style, GCSafe(hi)); }
    @catch (__unused id e) {}
    orig_chatStatusHI(self, _cmd, status, chat, style, hi);
}

static void (*orig_regChat)(id, SEL, void *, int);
static void gc_regChat(id self, SEL _cmd, void *chat, int style) {
    @try { GCLOGB(@"*** REGCHAT chat<%@>=%@ style=%d", GCClass(chat), GCSafe(chat), style); }
    @catch (__unused id e) {}
    orig_regChat(self, _cmd, chat, style);
}

static void (*orig_regChatHI)(id, SEL, void *, int, void *);
static void gc_regChatHI(id self, SEL _cmd, void *chat, int style, void *hi) {
    @try { GCLOGB(@"*** REGCHAT-HI chat<%@>=%@ style=%d hi=%@", GCClass(chat), GCSafe(chat), style, GCSafe(hi)); }
    @catch (__unused id e) {}
    orig_regChatHI(self, _cmd, chat, style, hi);
}

static void (*orig_member)(id, SEL, void *, void *, void *, int);
static void gc_member(id self, SEL _cmd, void *status, void *handle, void *chat, int style) {
    @try { GCLOGB(@"*** MEMBER chat<%@>=%@ handle=%@ status=%p style=%d", GCClass(chat), GCSafe(chat), GCSafe(handle), status, style); }
    @catch (__unused id e) {}
    orig_member(self, _cmd, status, handle, chat, style);
}

static void (*orig_routing)(id, SEL, void *, void *, void *);
static void gc_routing(id self, SEL _cmd, void *msgGUID, void *chatGUID, void *err) {
    @try { GCLOGB(@"*** ROUTING msgGUID=%@ chatGUID=%@", GCSafe(msgGUID), GCSafe(chatGUID)); }
    @catch (__unused id e) {}
    orig_routing(self, _cmd, msgGUID, chatGUID, err);
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
        GCBuildClassList();
        GCLog(@"=== GroupChatNameFix 5.7.0-hunt (chat-lifecycle: invite/join/status/register/route) loaded in %@ (classes=%d) ===",
              [[NSProcessInfo processInfo] processName], gClassCount);
        NSString *S = @"IMDServiceSession";
        GCHook1(S, @selector(didReceiveMessage:forChat:style:),
                (IMP)gc_didRecv, &orig_didRecv, "recv");
        GCHook1(S, @selector(sendMessage:toChat:style:),
                (IMP)gc_sendMsg, &orig_sendMsg, "send");
        GCHook1(S, @selector(didReceiveInvitation:forChat:style:),
                (IMP)gc_didInvite, &orig_didInvite, "invite");
        GCHook1(S, @selector(didJoinChat:style:),
                (IMP)gc_didJoin, &orig_didJoin, "join");
        GCHook1(S, @selector(didJoinChat:style:handleInfo:),
                (IMP)gc_didJoinHI, &orig_didJoinHI, "join-hi");
        GCHook1(S, @selector(didUpdateChatStatus:chat:style:),
                (IMP)gc_chatStatus, &orig_chatStatus, "status");
        GCHook1(S, @selector(didUpdateChatStatus:chat:style:handleInfo:),
                (IMP)gc_chatStatusHI, &orig_chatStatusHI, "status-hi");
        GCHook1(S, @selector(registerChat:style:),
                (IMP)gc_regChat, &orig_regChat, "regchat");
        GCHook1(S, @selector(registerChat:style:handleInfo:),
                (IMP)gc_regChatHI, &orig_regChatHI, "regchat-hi");
        GCHook1(S, @selector(didChangeMemberStatus:forHandle:forChat:style:),
                (IMP)gc_member, &orig_member, "member");
        GCHook1(S, @selector(_updateRoutingForMessageGUID:chatGUID:error:),
                (IMP)gc_routing, &orig_routing, "routing");
        GCHook1(S, @selector(renameGroup:to:),
                (IMP)gc_renameGroup, &orig_renameGroup, "rename");
        GCHook1(S, @selector(useChatRoom:forGroupChatIdentifier:),
                (IMP)gc_useRoom, &orig_useRoom, "useroom");
    }
}
