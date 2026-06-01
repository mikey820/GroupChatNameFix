// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// v5.2.0-safehunt : CRASH-PROOF introspection of the rename/room control plane.
// -----------------------------------------------------------------------------
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

// Sorted snapshot of every registered Class pointer, for membership testing
// (pointer compare only -- we never dereference an unverified class).
static Class *gClasses = NULL;
static int gClassCount = 0;
static int GCClassCmp(const void *a, const void *b) {
    uintptr_t x = (uintptr_t)*(Class *)a, y = (uintptr_t)*(Class *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static void GCBuildClassList(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    gClasses = (Class *)malloc(sizeof(Class) * n);
    if (!gClasses) return;
    gClassCount = objc_getClassList(gClasses, n);
    qsort(gClasses, gClassCount, sizeof(Class), GCClassCmp);
}
static BOOL GCIsRegisteredClass(Class c) {
    if (!gClasses || gClassCount == 0) return NO;
    return bsearch(&c, gClasses, gClassCount, sizeof(Class), GCClassCmp) != NULL;
}

// Is `o` really an Objective-C object? Read its isa via vm_read (safe), mask it,
// and confirm the candidate class is one the runtime actually registered.
static BOOL GCIsObject(id o) {
    if (!o || ((uintptr_t)o & 0x3)) return NO;          // null / misaligned
    uintptr_t isa = 0;
    if (!GCSafeRead((void *)o, &isa, sizeof(isa))) return NO;
    Class c = (Class)(isa & ~(uintptr_t)0x3);            // no tagged ptrs on 32-bit
    if ((uintptr_t)c < 0x1000) return NO;
    return GCIsRegisteredClass(c);
}

// Safe printable description of ANYTHING: real objects -> -description; other
// pointers -> first bytes as ascii+hex; unreadable -> just the pointer.
static NSString *GCSafe(id o) {
    if (!o) return @"(nil)";
    if (GCIsObject(o)) {
        @try { return [o description] ?: @"(nil-desc)"; }
        @catch (__unused id e) { return @"(desc-threw)"; }
    }
    unsigned char buf[40] = {0};
    if (GCSafeRead((void *)o, buf, sizeof(buf) - 1)) {
        // ascii view (printable run)
        char ascii[41]; int n = 0;
        for (int i = 0; i < (int)sizeof(buf) - 1; i++) {
            unsigned char ch = buf[i];
            ascii[n++] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '.';
        }
        ascii[n] = 0;
        return [NSString stringWithFormat:@"<non-obj %p bytes='%s' %02x%02x%02x%02x%02x%02x%02x%02x>",
                (void *)o, ascii, buf[0],buf[1],buf[2],buf[3],buf[4],buf[5],buf[6],buf[7]];
    }
    return [NSString stringWithFormat:@"<unreadable %p>", (void *)o];
}

// dictionaryRepresentation, but only if `o` is a verified object that responds.
static NSString *GCDict(id o) {
    if (!GCIsObject(o)) return @"(not-obj)";
    @try {
        if ([o respondsToSelector:@selector(dictionaryRepresentation)]) {
            id d = ((id(*)(id, SEL))objc_msgSend)(o, @selector(dictionaryRepresentation));
            return GCSafe(d);
        }
    } @catch (__unused id e) {}
    return @"(no-dict)";
}

// ===========================================================================
// RENAME / GROUP-CHANGE / ROOM-MAPPING hooks — read-only, fully guarded.
// ===========================================================================
static void (*orig_renameGroup)(id, SEL, id, id);
static void gc_renameGroup(id self, SEL _cmd, id group, id name) {
    @try { GCLOGB(@"*** RENAME group=%@ to=%@ dict=%@", GCSafe(group), GCSafe(name), GCDict(group)); }
    @catch (__unused id e) {}
    orig_renameGroup(self, _cmd, group, name);
}

static void (*orig_changeGroup)(id, SEL, id, id);
static void gc_changeGroup(id self, SEL _cmd, id group, id changes) {
    @try { GCLOGB(@"*** CHANGEGROUP group=%@ changes=%@", GCSafe(group), GCSafe(changes)); }
    @catch (__unused id e) {}
    orig_changeGroup(self, _cmd, group, changes);
}

static void (*orig_changeGroups)(id, SEL, id);
static void gc_changeGroups(id self, SEL _cmd, id groups) {
    @try { GCLOGB(@"*** CHANGEGROUPS %@", GCSafe(groups)); }
    @catch (__unused id e) {}
    orig_changeGroups(self, _cmd, groups);
}

static id (*orig_mapRoom)(id, SEL, id, int);
static id gc_mapRoom(id self, SEL _cmd, id room, int style) {
    id r = orig_mapRoom(self, _cmd, room, style);
    @try { GCLOGB(@"MAPROOM room=%@ style=%d => %@", GCSafe(room), style, GCSafe(r)); }
    @catch (__unused id e) {}
    return r;
}

// useChatRoom:forGroupChatIdentifier: establishes the room<->group link on rename.
static void (*orig_useRoom)(id, SEL, id, id);
static void gc_useRoom(id self, SEL _cmd, id room, id groupId) {
    @try { GCLOGB(@"*** USEROOM room=%@ forGroupChatIdentifier=%@", GCSafe(room), GCSafe(groupId)); }
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
        GCBuildClassList();
        GCLog(@"=== GroupChatNameFix 5.2.0-safehunt (vm_read-guarded) loaded in %@ (classes=%d) ===",
              [[NSProcessInfo processInfo] processName], gClassCount);
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
