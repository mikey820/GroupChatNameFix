// GroupChatNameFix - iOS 6 (armv7s) tweak for imagent / iMessage.imservice
//
// v6.0.0 - BREAKTHROUGH via static RE of the dyld_shared_cache.
// -----------------------------------------------------------------------------
// The long-held belief that iOS6's outgoing Madrid wire-body is built in C (no
// ObjC seam) was WRONG. Disassembling iMessage.imservice from the shared cache
// shows the real send path:
//
//   -[MessageServiceSession sendMessage:toChat:style:]
//     -> -[MessageDeliveryController sendMessage:toPeople:fromID:fromIdentity:..]
//       -> -[MessageDeliveryController _sendMessage:...:type:..]
//         -> -[MessageDeliveryController _sendMessage:messageString:
//                messageDictionary:fromID:fromIdentity:toID:toToken:
//                toSessionToken:toPeople:ackBlock:completionBlock:]
//              messageDictionary  --_JWEncodeDictionary-->  gzip --> encrypt --> APS
//
// `messageDictionary` is the PLAINTEXT Madrid payload, a normal NSDictionary,
// passed into an ObjC method immediately before serialization. iOS6's payload
// vocabulary (from __cfstring): c,p,guid,name,Group,v,t,x,s,u,from,to,pair/otr.
// It has NO `gid`/`gv` -- the keys modern iOS uses to thread NAMED groups. We
// inject them here: drop a mutable copy of messageDictionary carrying
// gid=<group UUID> + gv=8 so iOS6's encrypted payload looks like a modern named
// -group member's, and modern devices thread it into the renamed group instead
// of forking it.
//
// Config (read fresh per send, no rebuild needed): /var/mobile/gcnf_gid.txt
//     gid=2DA6132C-4E52-402E-AC30-577D90B31727
//     gv=8
//     n=Bruh                 (optional group name)
//     minpeople=2            (optional; only inject when toPeople count >= this)
// Absent/empty file => pure passthrough (clean A/B baseline).
// -----------------------------------------------------------------------------
// Crash-proofing retained from v5.x: every hook arg is typed `void *` (never id,
// so ARC emits no retain/release isa-deref on a possible non-object); we only
// __bridge to id AFTER GCIsObjectPtr validates the isa via vm_read_overwrite.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kLogPath = @"/var/mobile/GroupChatNameFix.log";
static NSString *const kGidPath = @"/var/mobile/gcnf_gid.txt";
static int gLogBudget = 2000;

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
static BOOL GCSafeRead(const void *addr, void *out, size_t len) {
    if ((uintptr_t)addr < 0x1000) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)addr, (vm_size_t)len,
                                         (vm_address_t)out, &got);
    return (kr == KERN_SUCCESS && got == len);
}

static uintptr_t *gClassPtrs = NULL;
static int gClassCount = 0;
static int GCUIntCmp(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static void GCBuildClassList(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    if (gClassPtrs) { free(gClassPtrs); gClassPtrs = NULL; gClassCount = 0; }
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
static BOOL GCIsObjectPtr(const void *p) {
    uintptr_t pv = (uintptr_t)p;
    if (pv < 0x1000 || (pv & 0x3)) return NO;
    uintptr_t isa = 0;
    if (!GCSafeRead(p, &isa, sizeof(isa))) return NO;
    uintptr_t c = isa & ~(uintptr_t)0x3;
    if (c < 0x1000) return NO;
    return GCIsRegisteredClass(c);
}
static NSString *GCSafe(const void *p) {
    if (!p) return @"(nil)";
    if (GCIsObjectPtr(p)) {
        id o = (__bridge id)p;
        @try { return [o description] ?: @"(nil-desc)"; }
        @catch (__unused id e) { return @"(desc-threw)"; }
    }
    unsigned char buf[40] = {0};
    if (GCSafeRead(p, buf, sizeof(buf) - 1)) {
        char ascii[41]; int n = 0;
        for (int i = 0; i < (int)sizeof(buf) - 1; i++) {
            unsigned char ch = buf[i];
            ascii[n++] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '.';
        }
        ascii[n] = 0;
        return [NSString stringWithFormat:@"<non-obj %p '%s'>", p, ascii];
    }
    return [NSString stringWithFormat:@"<unreadable %p>", p];
}

// ===========================================================================
// Config: parse /var/mobile/gcnf_gid.txt fresh on each send (re-pointable over
// SSH without a rebuild). Returns nil if absent/empty.
// ===========================================================================
static NSDictionary *GCReadConfig(void) {
    NSError *e = nil;
    NSString *cfg = [NSString stringWithContentsOfFile:kGidPath encoding:NSUTF8StringEncoding error:&e];
    if (!cfg || cfg.length == 0) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *raw in [cfg componentsSeparatedByString:@"\n"]) {
        NSRange eq = [raw rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[raw substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *v = [[raw substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        if (k.length && v.length) out[k] = v;
    }
    return out[@"gid"] ? out : nil;   // gid is required
}

// ===========================================================================
// THE HOOK: -[MessageDeliveryController
//   _sendMessage:messageString:messageDictionary:fromID:fromIdentity:toID:
//    toToken:toSessionToken:toPeople:ackBlock:completionBlock:]
// messageDictionary is the plaintext payload, serialized right after this call.
// We log it, and (if configured + group) substitute a mutable copy carrying
// gid/gv so modern devices thread the message into the renamed named-group.
// ===========================================================================
static void (*orig_mdc_send)(id, SEL, void *, void *, void *, void *, void *,
                             void *, void *, void *, void *, void *, void *);
static void gc_mdc_send(id self, SEL _cmd,
                        void *message, void *messageString, void *messageDictionary,
                        void *fromID, void *fromIdentity, void *toID, void *toToken,
                        void *toSessionToken, void *toPeople, void *ackBlock,
                        void *completionBlock) {
    void *dictToUse = messageDictionary;
    id injected = nil;   // strong holder: keeps the substituted dict alive through orig call
    @try {
        int npeople = 0;
        if (GCIsObjectPtr(toPeople)) {
            id arr = (__bridge id)toPeople;
            if ([arr respondsToSelector:@selector(count)])
                npeople = (int)((NSUInteger(*)(id, SEL))objc_msgSend)(arr, @selector(count));
        }
        GCLOGB(@"MDC-SEND people=%d toID=%@\n    toPeople=%@\n    dict=%@",
               npeople, GCSafe(toID), GCSafe(toPeople), GCSafe(messageDictionary));

        NSDictionary *cfg = GCReadConfig();
        if (cfg && GCIsObjectPtr(messageDictionary)) {
            int minp = cfg[@"minpeople"] ? [cfg[@"minpeople"] intValue] : 2;
            if (npeople >= minp) {
                id orig = (__bridge id)messageDictionary;
                if ([orig respondsToSelector:@selector(mutableCopy)]) {
                    NSMutableDictionary *md = [orig mutableCopy];
                    md[@"gid"] = cfg[@"gid"];
                    md[@"gv"]  = cfg[@"gv"] ?: @"8";
                    if (cfg[@"n"]) md[@"n"] = cfg[@"n"];
                    injected = md;                       // strong ref (method scope) keeps it alive
                    dictToUse = (__bridge void *)md;
                    GCLOGB(@"INJECT gid=%@ gv=%@ n=%@ -> %@",
                           cfg[@"gid"], md[@"gv"], cfg[@"n"] ?: @"(none)", md);
                }
            }
        }
    } @catch (__unused id e) {}
    orig_mdc_send(self, _cmd, message, messageString, dictToUse, fromID, fromIdentity,
                  toID, toToken, toSessionToken, toPeople, ackBlock, completionBlock);
    (void)injected;   // kept alive across the orig call above
}

// ===========================================================================
static const char *kMDCSel =
    "_sendMessage:messageString:messageDictionary:fromID:fromIdentity:toID:"
    "toToken:toSessionToken:toPeople:ackBlock:completionBlock:";

// iMessage.imservice (which defines MessageDeliveryController) loads lazily into
// imagent on first iMessage activity, so the class is absent at %ctor. Bind when
// it appears: try now, and on every dyld image-load until bound.
static volatile int gBound = 0;
static void GCTryBind(void) {
    if (gBound) return;
    Class c = objc_getClass("MessageDeliveryController");
    if (!c) return;
    SEL sel = sel_getUid(kMDCSel);
    if (!class_getInstanceMethod(c, sel)) return;
    gBound = 1;
    GCBuildClassList();   // rebuild so membership includes the just-loaded plugin classes
    MSHookMessageEx(c, sel, (IMP)gc_mdc_send, (IMP *)&orig_mdc_send);
    GCLog(@"HOOKED -[MessageDeliveryController _sendMessage:...messageDictionary:...] (classes=%d)", gClassCount);
}
static void GCImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (gBound) return;
    GCTryBind();
    if (!gBound)   // objc may register the image's classes just after this callback
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{ GCTryBind(); });
}

%ctor {
    @autoreleasepool {
        GCBuildClassList();
        GCLog(@"=== GroupChatNameFix 6.0.0 (gid/gv inject) loaded, classes=%d ===", gClassCount);
        GCTryBind();
        if (!gBound) {
            _dyld_register_func_for_add_image(GCImageAdded);
            GCLog(@"MessageDeliveryController not yet loaded; armed dyld image-load watcher");
        }
    }
}
