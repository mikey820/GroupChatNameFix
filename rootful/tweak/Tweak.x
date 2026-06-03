// GroupChatNameFix - iOS 6 (armv7s) tweak for imagent / iMessage.imservice
//
// v6.1.0 - SELF-CONTAINED autonomous fix (no companion device, no manual config).
// -----------------------------------------------------------------------------
// v6.0.0 PROVED (real-hw dev35 sms.db ROWID A/B) that injecting gid+gv=8 into the
// outgoing Madrid payload threads iOS6's group messages into the modern named
// group instead of forking them. The send seam is:
//   -[MessageDeliveryController _sendMessage:messageString:messageDictionary:..]
//   -> _JWEncodeDictionary(messageDictionary) -> gzip -> encrypt -> APS
// iOS6's payload is {p=(participants); t=text; v=1} with NO gid.
//
// The only open question was WHERE iOS6 gets the group's gid (it's not in the
// FZMessage, and the rename c=190 is encrypted/ignored). ANSWER (from RE of the
// incoming path): every inbound message is decoded by the EXPORTED C function
//   id JWDecodeDictionary(NSData *plaintext)   // IMFoundation
// called from -[MessageServiceSession _handler:incomingMessage:...]. Decryption
// is end-to-end, so iOS6 receives EXACTLY what the modern sender encrypted -
// including gid/gv (the stripping only happens later, at FZMessage). So:
//
//   HARVEST: MSHookFunction JWDecodeDictionary; when an inbound dict has gid+p,
//            learn participants->gid and persist to /var/mobile/gcnf_learned.plist
//   INJECT : on send, look up the learned gid by the outgoing participant set and
//            add gid+gv=8 to a mutable copy of messageDictionary before encode.
//
// Net: once ANY modern member posts to the group, iOS6 self-heals and all its
// subsequent sends thread correctly - entirely on the iOS6 device.
// /var/mobile/gcnf_gid.txt (gid=..., gv=..., minpeople=...) still works as a
// manual override/test forcing a fixed gid for every group send.
// -----------------------------------------------------------------------------
// Crash-proofing (v5.x): hook args typed void*, validated via vm_read_overwrite
// + registered-class check before any objc_msgSend (ARC never sees raw non-objs).

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);
extern void MSHookFunction(void *symbol, void *replacement, void **result);
extern void *MSFindSymbol(void *image, const char *name);

static NSString *const kLogPath     = @"/var/mobile/GroupChatNameFix.log";
static NSString *const kGidPath     = @"/var/mobile/gcnf_gid.txt";        // manual override
static NSString *const kLearnedPath = @"/var/mobile/gcnf_learned.plist";  // auto-learned map
static int gLogBudget = 4000;

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

// ===========================================================================
// Learned participants->gid map (persisted), + manual override file.
// ===========================================================================
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *gLearned = nil;   // key=participant-set -> gid

static void GCLoadLearned(void) {
    if (gLearned) return;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kLearnedPath];
    gLearned = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

// Normalized key for a participant array: lowercased URIs, sorted, joined.
static NSString *GCPKey(id parr) {
    if (!GCIsObjectPtr((__bridge const void *)parr)) return nil;
    if (![parr respondsToSelector:@selector(count)]) return nil;
    @try {
        NSMutableArray *m = [NSMutableArray array];
        for (id e in (NSArray *)parr)
            if ([e isKindOfClass:[NSString class]]) [m addObject:[(NSString *)e lowercaseString]];
        if (m.count == 0) return nil;
        [m sortUsingSelector:@selector(compare:)];
        return [m componentsJoinedByString:@"|"];
    } @catch (__unused id e) { return nil; }
}

static NSString *GCLookupGid(NSString *key) {
    if (!key) return nil;
    NSString *r = nil;
    pthread_mutex_lock(&gLock);
    GCLoadLearned();
    r = gLearned[key];
    pthread_mutex_unlock(&gLock);
    return r;
}

static void GCStoreGid(NSString *key, NSString *gid) {
    if (!key || !gid) return;
    pthread_mutex_lock(&gLock);
    GCLoadLearned();
    BOOL changed = ![gLearned[key] isEqualToString:gid];
    if (changed) {
        gLearned[key] = gid;
        @try { [gLearned writeToFile:kLearnedPath atomically:YES]; } @catch (__unused id e) {}
    }
    pthread_mutex_unlock(&gLock);
    if (changed) GCLOGB(@"LEARNED gid=%@ for participants=%@", gid, key);
}

// Manual override: /var/mobile/gcnf_gid.txt with gid=... [gv=...] [minpeople=...]
static NSDictionary *GCManualOverride(void) {
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
    return out[@"gid"] ? out : nil;
}

// ===========================================================================
// HARVEST: id JWDecodeDictionary(NSData *plaintext) -- every inbound payload.
// ===========================================================================
static void *(*orig_JWDecode)(void *);
static void *gc_JWDecode(void *data) {
    void *r = orig_JWDecode(data);
    @try {
        if (GCIsObjectPtr(r)) {
            id d = (__bridge id)r;
            if ([d isKindOfClass:[NSDictionary class]]) {
                id gid = [d objectForKey:@"gid"];
                id p   = [d objectForKey:@"p"];
                if ([gid isKindOfClass:[NSString class]] && p) {
                    NSString *key = GCPKey(p);
                    if (key) GCStoreGid(key, (NSString *)gid);
                }
            }
        }
    } @catch (__unused id e) {}
    return r;
}

// ===========================================================================
// INJECT: -[MessageDeliveryController _sendMessage:messageString:
//   messageDictionary:fromID:fromIdentity:toID:toToken:toSessionToken:toPeople:
//   ackBlock:completionBlock:]
// ===========================================================================
static void (*orig_mdc_send)(id, SEL, void *, void *, void *, void *, void *,
                             void *, void *, void *, void *, void *, void *);
static void gc_mdc_send(id self, SEL _cmd,
                        void *message, void *messageString, void *messageDictionary,
                        void *fromID, void *fromIdentity, void *toID, void *toToken,
                        void *toSessionToken, void *toPeople, void *ackBlock,
                        void *completionBlock) {
    void *dictToUse = messageDictionary;
    id injected = nil;
    @try {
        if (GCIsObjectPtr(messageDictionary)) {
            id orig = (__bridge id)messageDictionary;
            id p = [orig respondsToSelector:@selector(objectForKey:)] ? [orig objectForKey:@"p"] : nil;
            NSString *key = GCPKey(p);
            int npeople = 0;
            if ([p respondsToSelector:@selector(count)])
                npeople = (int)((NSUInteger(*)(id, SEL))objc_msgSend)(p, @selector(count));

            NSDictionary *ov = GCManualOverride();
            NSString *gid = nil, *gv = @"8";
            int minp = 2;
            if (ov) { gid = ov[@"gid"]; if (ov[@"gv"]) gv = ov[@"gv"]; if (ov[@"minpeople"]) minp = [ov[@"minpeople"] intValue]; }
            else    { gid = GCLookupGid(key); }

            if (gid && npeople >= minp && [orig respondsToSelector:@selector(mutableCopy)]) {
                NSMutableDictionary *md = [orig mutableCopy];
                md[@"gid"] = gid;
                md[@"gv"]  = gv;
                injected = md;
                dictToUse = (__bridge void *)md;
                GCLOGB(@"INJECT gid=%@ gv=%@ (%@) people=%d", gid, gv, ov ? @"manual" : @"learned", npeople);
            } else {
                GCLOGB(@"SEND people=%d key=%@ gid=%@ (no inject)", npeople, key, gid ?: @"(none)");
            }
        }
    } @catch (__unused id e) {}
    orig_mdc_send(self, _cmd, message, messageString, dictToUse, fromID, fromIdentity,
                  toID, toToken, toSessionToken, toPeople, ackBlock, completionBlock);
    (void)injected;
}

// ===========================================================================
static volatile int gBoundSend = 0, gBoundDecode = 0;
static const char *kMDCSel =
    "_sendMessage:messageString:messageDictionary:fromID:fromIdentity:toID:"
    "toToken:toSessionToken:toPeople:ackBlock:completionBlock:";

static void GCTryBind(void) {
    if (!gBoundSend) {
        Class c = objc_getClass("MessageDeliveryController");
        SEL sel = sel_getUid(kMDCSel);
        if (c && class_getInstanceMethod(c, sel)) {
            gBoundSend = 1;
            GCBuildClassList();
            MSHookMessageEx(c, sel, (IMP)gc_mdc_send, (IMP *)&orig_mdc_send);
            GCLog(@"HOOKED send -[MessageDeliveryController _sendMessage:...] (classes=%d)", gClassCount);
        }
    }
    if (!gBoundDecode) {
        void *sym = dlsym(RTLD_DEFAULT, "JWDecodeDictionary");
        if (!sym) { @try { sym = MSFindSymbol(NULL, "_JWDecodeDictionary"); } @catch (__unused id e) {} }
        if (sym) {
            gBoundDecode = 1;
            MSHookFunction(sym, (void *)gc_JWDecode, (void **)&orig_JWDecode);
            GCLog(@"HOOKED harvest JWDecodeDictionary @ %p", sym);
        }
    }
}
static void GCImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (gBoundSend && gBoundDecode) return;
    GCTryBind();
    if (!(gBoundSend && gBoundDecode))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{ GCTryBind(); });
}

%ctor {
    @autoreleasepool {
        GCBuildClassList();
        GCLog(@"=== GroupChatNameFix 6.1.0 (autonomous harvest+inject) loaded, classes=%d ===", gClassCount);
        GCTryBind();
        if (!(gBoundSend && gBoundDecode)) {
            _dyld_register_func_for_add_image(GCImageAdded);
            GCLog(@"armed dyld watcher (send=%d decode=%d)", gBoundSend, gBoundDecode);
        }
    }
}
