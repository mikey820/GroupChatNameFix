// GroupChatNameFix - iOS 6 (armv7s) tweak for imagent / iMessage.imservice + MobileSMS.
//
// v7.0.0 - now ALSO shows the modern group's NAME in the iOS 6 Messages UI.
// -----------------------------------------------------------------------------
// Two cooperating halves, one dylib (filtered into both imagent and MobileSMS):
//
//  imagent  (routing, unchanged from v6.1.0, PLUS name harvest):
//    - HARVEST gid: hook exported C JWDecodeDictionary; learn participants->gid.
//    - HARVEST name: same hook - when a decoded inbound dict carries the group
//      name, learn matchkey->name into /var/mobile/gcnf_names.plist.
//    - INJECT gid+gv=8 on send via -[MessageDeliveryController _sendMessage:...].
//
//  MobileSMS (display, NEW):
//    - hook -[CKTranscriptController setConversation:] (+ viewWillAppear:) and,
//      when the on-screen conversation's participant set matches a learned name,
//      set the navigation title to that name. iOS 6 ChatKit has no concept of a
//      named group, so it otherwise shows the participant list.
//
// The two halves are joined by a normalized participant "matchkey" (scheme- and
// formatting-insensitive) so the URIs imagent sees ("mailto:x", "tel:+1...") line
// up with the raw addresses ChatKit exposes ("x", "+1...").
//
// Testing the UI half in isolation: drop /var/mobile/gcnf_forcename.txt containing
// a single line of text; every 2+ person conversation will show that as its title.
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
#import <stdlib.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);
extern void MSHookFunction(void *symbol, void *replacement, void **result);
extern void *MSFindSymbol(void *image, const char *name);

static NSString *const kLogPath     = @"/var/mobile/GroupChatNameFix.log";
static NSString *const kGidPath     = @"/var/mobile/gcnf_gid.txt";          // manual gid override
static NSString *const kLearnedPath = @"/var/mobile/gcnf_learned.plist";    // auto-learned participants->gid
static NSString *const kNamesPath   = @"/var/mobile/gcnf_names.plist";      // auto-learned matchkey->name
static NSString *const kForceName   = @"/var/mobile/gcnf_forcename.txt";    // UI test override
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
// Normalized keys.
//   GCPKey   - URI-exact key for the participants->gid map (unchanged).
//   GCMatchKey/GCNormAddr - scheme/format-insensitive key shared by imagent's
//              harvest and MobileSMS's display so the two processes agree.
// ===========================================================================
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *gLearned = nil;   // key=participant-set -> gid
static NSMutableDictionary *gNames = nil;     // key=matchkey -> group name

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

// One address -> canonical token. Strips a scheme ("mailto:"/"tel:"/...) and,
// for phone numbers, keeps the last 10 digits; emails keep local@domain lower.
static NSString *GCNormAddr(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return nil;
    NSString *a = [s lowercaseString];
    NSRange colon = [a rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location < 8)   // strip scheme
        a = [a substringFromIndex:colon.location + 1];
    a = [a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([a rangeOfString:@"@"].location != NSNotFound) return a;  // email: as-is
    NSMutableString *digits = [NSMutableString string];           // phone: digits only
    for (NSUInteger i = 0; i < a.length; i++) {
        unichar c = [a characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (digits.length >= 10) return [digits substringFromIndex:digits.length - 10];
    return digits.length ? digits : a;
}

// Build a match key from an array of address strings (URIs or raw).
static NSString *GCMatchKey(id addrs) {
    if (!addrs || ![addrs respondsToSelector:@selector(count)]) return nil;
    @try {
        NSMutableArray *m = [NSMutableArray array];
        for (id e in (NSArray *)addrs) {
            NSString *t = GCNormAddr([e isKindOfClass:[NSString class]] ? e : [e description]);
            if (t.length) [m addObject:t];
        }
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

// matchkey -> name map (written by imagent harvest, read by MobileSMS display).
static void GCLoadNames(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kNamesPath];
    if (d) gNames = [d mutableCopy];
    else if (!gNames) gNames = [NSMutableDictionary dictionary];
}

static void GCStoreName(NSString *key, NSString *name) {
    if (key.length == 0 || name.length == 0) return;
    pthread_mutex_lock(&gLock);
    GCLoadNames();
    BOOL changed = ![gNames[key] isEqualToString:name];
    if (changed) {
        gNames[key] = name;
        @try { [gNames writeToFile:kNamesPath atomically:YES]; } @catch (__unused id e) {}
    }
    pthread_mutex_unlock(&gLock);
    if (changed) GCLOGB(@"LEARNED name=%@ for matchkey=%@", name, key);
}

static NSString *GCLookupName(NSString *key) {
    if (!key) return nil;
    NSString *r = nil;
    pthread_mutex_lock(&gLock);
    GCLoadNames();           // re-read each lookup: imagent may have just updated it
    r = gNames[key];
    pthread_mutex_unlock(&gLock);
    return r;
}

// Manual gid override: /var/mobile/gcnf_gid.txt with gid=... [gv=...] [minpeople=...]
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
// Learns participants->gid AND matchkey->name. Candidate name keys are probed
// and logged so the real one is confirmed against live traffic.
// ===========================================================================
static void *(*orig_JWDecode)(void *);
static NSString *GCExtractName(id d) {
    // direct keys seen across Madrid group payloads
    for (NSString *k in @[@"n", @"gn", @"nr", @"name"]) {
        id v = [d objectForKey:k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    }
    // some clients nest a group action under "tg"/"gc"
    for (NSString *k in @[@"tg", @"gc"]) {
        id sub = [d objectForKey:k];
        if ([sub isKindOfClass:[NSDictionary class]]) {
            for (NSString *kk in @[@"n", @"gn", @"name", @"nr"]) {
                id v = [sub objectForKey:kk];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
            }
        }
    }
    return nil;
}
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
                    // probe: show the shape of gid-bearing payloads while we learn names
                    GCLOGB(@"DECODE gid-dict keys=%@", [[d allKeys] componentsJoinedByString:@","]);
                    NSString *nm = GCExtractName(d);
                    if (nm) {
                        NSString *mk = GCMatchKey(p);
                        if (mk) GCStoreName(mk, nm);
                    }
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
// DISPLAY (MobileSMS): override the transcript title for a known named group.
// ===========================================================================
// Safe objc_msgSend helper returning id.
static id GCSend0(id obj, SEL s) {
    if (!GCIsObjectPtr((__bridge const void *)obj) || ![obj respondsToSelector:s]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(obj, s);
}

// Pull the recipient address strings out of a CKConversation.
static NSArray *GCConversationAddresses(id conv) {
    if (!GCIsObjectPtr((__bridge const void *)conv)) return nil;
    NSArray *ents = nil;
    @try {
        if ([conv respondsToSelector:@selector(__copyEntities)])
            ents = (__bridge_transfer NSArray *)(void *)
                   ((void *(*)(id, SEL))objc_msgSend)(conv, @selector(__copyEntities));
    } @catch (__unused id e) { ents = nil; }
    if (![ents respondsToSelector:@selector(count)]) return nil;
    NSMutableArray *addrs = [NSMutableArray array];
    @try {
        for (id ent in ents) {
            id a = GCSend0(ent, @selector(rawAddress));
            if (![a isKindOfClass:[NSString class]]) a = GCSend0(ent, @selector(name));
            if ([a isKindOfClass:[NSString class]]) [addrs addObject:a];
        }
    } @catch (__unused id e) {}
    return addrs.count ? addrs : nil;
}

static NSString *GCForceName(void) {
    NSError *e = nil;
    NSString *s = [NSString stringWithContentsOfFile:kForceName encoding:NSUTF8StringEncoding error:&e];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : nil;
}

// Resolve the display name to use for a transcript controller's conversation.
static NSString *GCTitleForConversation(id conv) {
    NSArray *addrs = GCConversationAddresses(conv);
    if (addrs.count < 2) {                       // 1:1 chats are left untouched
        if (addrs.count) GCLOGB(@"UI conv addrs=%@ (not a group, skip)",
                                [addrs componentsJoinedByString:@","]);
        return nil;
    }
    NSString *forced = GCForceName();
    if (forced) { GCLOGB(@"UI force-name -> %@", forced); return forced; }
    NSString *mk = GCMatchKey(addrs);
    NSString *nm = GCLookupName(mk);
    GCLOGB(@"UI conv matchkey=%@ name=%@", mk, nm ?: @"(none)");
    return nm;
}

static void GCApplyTitle(id transcriptVC, NSString *name) {
    if (!name.length || !GCIsObjectPtr((__bridge const void *)transcriptVC)) return;
    @try {
        if ([transcriptVC respondsToSelector:@selector(setTitle:)])
            ((void(*)(id, SEL, id))objc_msgSend)(transcriptVC, @selector(setTitle:), name);
        id navItem = GCSend0(transcriptVC, @selector(navigationItem));
        if (navItem && [navItem respondsToSelector:@selector(setTitle:)])
            ((void(*)(id, SEL, id))objc_msgSend)(navItem, @selector(setTitle:), name);
        GCLOGB(@"UI applied title=%@", name);
    } @catch (__unused id e) {}
}

// Hook -[CKTranscriptController setConversation:]
static void (*orig_tc_setConv)(id, SEL, void *);
static void gc_tc_setConv(id self, SEL _cmd, void *conv) {
    orig_tc_setConv(self, _cmd, conv);
    @try {
        id c = GCIsObjectPtr(conv) ? (__bridge id)conv : nil;
        NSString *nm = GCTitleForConversation(c);
        if (nm) {
            // hold onto it so viewWillAppear: can re-assert after the OS recomputes
            objc_setAssociatedObject(self, (void *)&orig_tc_setConv, nm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            GCApplyTitle(self, nm);
        }
    } @catch (__unused id e) {}
}

// Hook -[CKTranscriptController viewWillAppear:] to re-assert (title is often
// recomputed from recipients right before the view shows). Only bound if the
// class DIRECTLY implements it (see GCDirectlyImplements) so we never end up
// retargeting UIViewController's shared implementation.
static void (*orig_tc_vwa)(id, SEL, BOOL);
static void gc_tc_vwa(id self, SEL _cmd, BOOL animated) {
    orig_tc_vwa(self, _cmd, animated);
    @try {
        NSString *nm = objc_getAssociatedObject(self, (void *)&orig_tc_setConv);
        if (![nm isKindOfClass:[NSString class]] || !nm.length) {
            id conv = GCSend0(self, @selector(conversation));
            nm = GCTitleForConversation(conv);
        }
        if (nm.length) GCApplyTitle(self, nm);
    } @catch (__unused id e) {}
}

// Hook -[CKMessagesController _showTranscriptController:animated:] - the moment
// the transcript is actually presented, which is the safest re-assert point.
static void (*orig_mc_showTC)(id, SEL, void *, BOOL);
static void gc_mc_showTC(id self, SEL _cmd, void *tc, BOOL animated) {
    orig_mc_showTC(self, _cmd, tc, animated);
    @try {
        id vc = GCIsObjectPtr(tc) ? (__bridge id)tc : nil;
        if (vc) {
            id conv = GCSend0(vc, @selector(conversation));
            NSString *nm = GCTitleForConversation(conv);
            if (nm.length) GCApplyTitle(vc, nm);
        }
    } @catch (__unused id e) {}
}

// ===========================================================================
static volatile int gBoundSend = 0, gBoundDecode = 0, gBoundUI = 0;
static const char *kMDCSel =
    "_sendMessage:messageString:messageDictionary:fromID:fromIdentity:toID:"
    "toToken:toSessionToken:toPeople:ackBlock:completionBlock:";

static BOOL GCInMobileSMS(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.MobileSMS"]) return YES;
    const char *prog = getprogname();
    return prog && strcmp(prog, "MobileSMS") == 0;
}

static void GCBindIMAgent(void) {
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

// True only if `c` itself defines `s` (not merely inherits it) - so we never
// retarget a superclass IMP shared by every subclass.
static BOOL GCDirectlyImplements(Class c, SEL s) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++)
        if (method_getName(ms[i]) == s) { found = YES; break; }
    if (ms) free(ms);
    return found;
}

static void GCBindUI(void) {
    if (gBoundUI) return;
    Class tc = objc_getClass("CKTranscriptController");
    SEL setConv = sel_getUid("setConversation:");
    if (!tc || !GCDirectlyImplements(tc, setConv)) return;  // ChatKit not up yet

    gBoundUI = 1;
    GCBuildClassList();
    MSHookMessageEx(tc, setConv, (IMP)gc_tc_setConv, (IMP *)&orig_tc_setConv);
    GCLog(@"HOOKED display -[CKTranscriptController setConversation:]");

    SEL vwa = sel_getUid("viewWillAppear:");
    if (GCDirectlyImplements(tc, vwa)) {
        MSHookMessageEx(tc, vwa, (IMP)gc_tc_vwa, (IMP *)&orig_tc_vwa);
        GCLog(@"HOOKED display -[CKTranscriptController viewWillAppear:]");
    }

    Class mc = objc_getClass("CKMessagesController");
    SEL showTC = sel_getUid("_showTranscriptController:animated:");
    if (GCDirectlyImplements(mc, showTC)) {
        MSHookMessageEx(mc, showTC, (IMP)gc_mc_showTC, (IMP *)&orig_mc_showTC);
        GCLog(@"HOOKED display -[CKMessagesController _showTranscriptController:animated:]");
    }
}

static BOOL gIsUI = NO;
static void GCTryBind(void) {
    if (gIsUI) GCBindUI();
    else       GCBindIMAgent();
}
static BOOL GCAllBound(void) {
    return gIsUI ? (gBoundUI != 0) : (gBoundSend && gBoundDecode);
}
static void GCImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (GCAllBound()) return;
    GCTryBind();
    if (!GCAllBound())
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{ GCTryBind(); });
}

%ctor {
    @autoreleasepool {
        gIsUI = GCInMobileSMS();
        GCBuildClassList();
        GCLog(@"=== GroupChatNameFix 7.0.0 loaded in %s (classes=%d) ===",
              gIsUI ? "MobileSMS[display]" : "imagent[routing]", gClassCount);
        GCTryBind();
        if (!GCAllBound()) {
            _dyld_register_func_for_add_image(GCImageAdded);
            GCLog(@"armed dyld watcher (ui=%d send=%d decode=%d)", gBoundUI, gBoundSend, gBoundDecode);
        }
    }
}
