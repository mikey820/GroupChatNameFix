// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// v5.2.1-safehunt : CRASH-PROOF introspection of the rename/room control plane.
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

// ===========================================================================
// RENAME / GROUP-CHANGE / ROOM-MAPPING hooks — read-only, fully guarded.
// ===========================================================================
// NOTE: every object argument and the captured return are typed `void *`, never
// `id`, so ARC cannot emit retain/release (= isa deref) on a possible non-object.
static void (*orig_renameGroup)(id, SEL, void *, void *);
static void gc_renameGroup(id self, SEL _cmd, void *group, void *name) {
    @try { GCLOGB(@"*** RENAME group=%@ to=%@ dict=%@", GCSafe(group), GCSafe(name), GCDict(group)); }
    @catch (__unused id e) {}
    orig_renameGroup(self, _cmd, group, name);
}

static void (*orig_changeGroup)(id, SEL, void *, void *);
static void gc_changeGroup(id self, SEL _cmd, void *group, void *changes) {
    @try { GCLOGB(@"*** CHANGEGROUP group=%@ changes=%@", GCSafe(group), GCSafe(changes)); }
    @catch (__unused id e) {}
    orig_changeGroup(self, _cmd, group, changes);
}

static void (*orig_changeGroups)(id, SEL, void *);
static void gc_changeGroups(id self, SEL _cmd, void *groups) {
    @try { GCLOGB(@"*** CHANGEGROUPS %@", GCSafe(groups)); }
    @catch (__unused id e) {}
    orig_changeGroups(self, _cmd, groups);
}

static void * (*orig_mapRoom)(id, SEL, void *, int);
static void * gc_mapRoom(id self, SEL _cmd, void *room, int style) {
    void *r = orig_mapRoom(self, _cmd, room, style);
    @try { GCLOGB(@"MAPROOM room=%@ style=%d => %@", GCSafe(room), style, GCSafe(r)); }
    @catch (__unused id e) {}
    return r;
}

// useChatRoom:forGroupChatIdentifier: establishes the room<->group link on rename.
static void (*orig_useRoom)(id, SEL, void *, void *);
static void gc_useRoom(id self, SEL _cmd, void *room, void *groupId) {
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
        GCLog(@"=== GroupChatNameFix 5.2.1-safehunt (vm_read-guarded, void* args) loaded in %@ (classes=%d) ===",
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
