// GroupChatNameFix - iOS 6 (armv7) tweak for /usr/libexec/imagent
//
// Problem
// -------
// On iOS 6, an iMessage group conversation is keyed by a group id (`gid`) that
// the OS derives from the participant set. When someone on a newer iOS *names*
// the group, iMessage migrates the conversation to a brand-new canonical `gid`
// (with a group-version `gv`) and announces it. iOS 6 shows the new name (it
// implements the group-name-update path) but keeps stamping its OLD,
// participant-derived `gid` on everything it sends. Recipients, now keyed on
// the new `gid`, therefore see every message from the iOS 6 device as a
// separate, brand-new conversation.
//
// Fix
// ---
// imagent builds the outgoing Madrid wire dictionary (keys gid, gv, p, t, x,
// r, ...). We:
//   1. LEARN: whenever a group message ARRIVES, remember the canonical
//      (gid, gv) for that participant roster `p`.
//   2. STAMP: whenever a group message is about to be SENT, if we have a
//      learned canonical gid for that same roster and it differs from what the
//      OS computed, rewrite gid (and gv) on the outgoing dictionary.
//
// The rewrite only touches the on-the-wire dictionary, so iOS 6's own local
// database / thread matching is left untouched (the conversation stays a
// single local thread, exactly as it behaves today).
//
// NOTE ON METHOD NAMES
// --------------------
// The exact selectors that build the send dictionary / deliver incoming
// messages could not be confirmed against this device offline (frameworks live
// in the dyld shared cache; no strings/otool on device). So the hooks below
// target a set of *candidate* classes/selectors, each guarded by
// instancesRespondToSelector: and wrapped in @try/@catch — anything that does
// not exist is simply skipped, so installation is always safe. On load the
// tweak ALSO dumps the real, relevant selectors of the live IMDaemonCore
// classes to the log, so the fix can be pinned to the exact methods in a
// follow-up build if the candidates do not line up.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// substrate.h is not bundled with theos; theos auto-links the substrate symbol
// for tweaks, so we only need to declare the one function we call.
extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.mikey820.groupchatnamefix.plist";
static NSString *const kLogPath  = @"/var/mobile/GroupChatNameFix.log";

static NSMutableDictionary *gLearned;       // participantsKey -> @{ @"gid":..., @"gv":... }
static dispatch_queue_t     gQueue;         // serialises gLearned + file IO
static int                  gDumpBudget = 40; // cap verbose full-dict dumps

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

static void GCCollectHandles(id obj, NSMutableSet *out) {
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *n = GCNormHandle(obj);
        if (n) [out addObject:n];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id e in (NSArray *)obj) GCCollectHandles(e, out);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id v in [(NSDictionary *)obj allValues]) GCCollectHandles(v, out);
    }
}

static NSString *GCParticipantsKey(id pValue) {
    if (!pValue) return nil;
    NSMutableSet *set = [NSMutableSet set];
    GCCollectHandles(pValue, set);
    if (set.count == 0) return nil;
    NSArray *sorted = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
    return [sorted componentsJoinedByString:@","];
}

static BOOL GCIsGroup(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    if (d[@"gid"]) return YES;
    NSMutableSet *set = [NSMutableSet set];
    GCCollectHandles(d[@"p"], set);
    return set.count >= 3;
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------
static void GCLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    gLearned = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static void GCSaveLocked(void) {
    @try { [gLearned writeToFile:kPrefPath atomically:YES]; } @catch (__unused id e) {}
}

// ---------------------------------------------------------------------------
// Learn from an incoming dictionary
// ---------------------------------------------------------------------------
static void GCLearnFromDict(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return;
    if (!GCIsGroup(d)) return;
    id gid = d[@"gid"];
    id pv  = d[@"p"];
    if (!gid || !pv) return;
    NSString *key = GCParticipantsKey(pv);
    if (key.length == 0) return;
    id gv = d[@"gv"];

    dispatch_async(gQueue, ^{
        NSDictionary *prev = gLearned[key];
        if (prev && [prev[@"gid"] isEqual:gid] &&
            ((!gv && !prev[@"gv"]) || [prev[@"gv"] isEqual:gv])) {
            return; // unchanged
        }
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"gid"] = gid;
        if (gv) entry[@"gv"] = gv;
        gLearned[key] = entry;
        GCSaveLocked();
        GCLog(@"LEARN gid=%@ gv=%@ key=%@", gid, gv, key);
    });
}

static void GCMaybeDumpIncoming(NSDictionary *d) {
    if (!GCIsGroup(d)) return;
    if (gDumpBudget-- > 0) GCLog(@"IN  dict=%@", d);
}

// ===========================================================================
// OUTGOING hook  -dictionaryRepresentationForSending
// ===========================================================================
static NSDictionary *(*orig_dictForSending)(id, SEL);
static NSDictionary *gc_dictForSending(id self, SEL _cmd) {
    NSDictionary *d = orig_dictForSending(self, _cmd);
    @try {
        if ([d isKindOfClass:[NSDictionary class]] && GCIsGroup(d)) {
            if (gDumpBudget-- > 0) GCLog(@"OUT dict(before)=%@", d);
            NSString *key = GCParticipantsKey(d[@"p"]);
            __block NSDictionary *learned = nil;
            if (key.length) dispatch_sync(gQueue, ^{ learned = [gLearned[key] copy]; });
            if (learned) {
                id newGid = learned[@"gid"];
                id curGid = d[@"gid"];
                if (newGid && (!curGid || ![curGid isEqual:newGid])) {
                    NSMutableDictionary *m = [d mutableCopy];
                    m[@"gid"] = newGid;
                    if (learned[@"gv"]) m[@"gv"] = learned[@"gv"];
                    GCLog(@"OUT rewrite gid %@ -> %@ (gv=%@) key=%@",
                          curGid, newGid, learned[@"gv"], key);
                    return m;
                }
            }
        }
    } @catch (__unused id e) {}
    return d;
}

// ===========================================================================
// INCOMING hooks (learn) - several candidates, all idempotent
// ===========================================================================
static NSDictionary *GCDictFromArg(id arg) {
    if ([arg isKindOfClass:[NSDictionary class]]) return arg;
    if ([arg respondsToSelector:@selector(dictionaryRepresentation)])
        return ((id(*)(id, SEL))objc_msgSend)(arg, @selector(dictionaryRepresentation));
    if ([arg respondsToSelector:@selector(dictionaryRepresentationForSending)])
        return ((id(*)(id, SEL))objc_msgSend)(arg, @selector(dictionaryRepresentationForSending));
    return nil;
}

static void (*orig_procRecv)(id, SEL, id, id);            // processReceivedMessage:forAccount:
static void gc_procRecv(id self, SEL _cmd, id msg, id account) {
    @try { NSDictionary *d = GCDictFromArg(msg); GCMaybeDumpIncoming(d); GCLearnFromDict(d); }
    @catch (__unused id e) {}
    orig_procRecv(self, _cmd, msg, account);
}

static void (*orig_procIn)(id, SEL, id);                  // _processIncomingMessage:
static void gc_procIn(id self, SEL _cmd, id msg) {
    @try { NSDictionary *d = GCDictFromArg(msg); GCMaybeDumpIncoming(d); GCLearnFromDict(d); }
    @catch (__unused id e) {}
    orig_procIn(self, _cmd, msg);
}

// service:account:incomingMessage:fromIDQueryController:  (IDS delivery)
static void (*orig_idsIncoming)(id, SEL, id, id, id, id);
static void gc_idsIncoming(id self, SEL _cmd, id service, id account, id msg, id qc) {
    @try { NSDictionary *d = GCDictFromArg(msg); GCMaybeDumpIncoming(d); GCLearnFromDict(d); }
    @catch (__unused id e) {}
    orig_idsIncoming(self, _cmd, service, account, msg, qc);
}

// ---------------------------------------------------------------------------
// Hook installation + runtime selector discovery
// ---------------------------------------------------------------------------
static BOOL GCHook(NSArray *classNames, SEL sel, IMP repl, void *origSlot, const char *label) {
    for (NSString *cn in classNames) {
        Class c = NSClassFromString(cn);
        if (c && [c instancesRespondToSelector:sel]) {
            MSHookMessageEx(c, sel, repl, (IMP *)origSlot);
            GCLog(@"HOOKED %@ on %@ [%s]", NSStringFromSelector(sel), cn, label);
            return YES;
        }
    }
    GCLog(@"MISS  no class implements %@ [%s] (tried: %@)",
          NSStringFromSelector(sel), label, [classNames componentsJoinedByString:@", "]);
    return NO;
}

// Dump the selectors of a live class that look relevant, so we can pin the
// exact method names from the device's own runtime.
static void GCDumpClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { GCLog(@"DUMP %@ : ABSENT", name); return; }
    NSArray *needles = @[ @"group", @"gid", @"guid", @"send", @"receiv",
                          @"incoming", @"dictionary", @"process", @"madrid", @"name" ];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) {
        NSString *s = NSStringFromSelector(method_getName(ms[i]));
        NSString *l = [s lowercaseString];
        for (NSString *nd in needles) {
            if ([l rangeOfString:nd].location != NSNotFound) { [hits addObject:s]; break; }
        }
    }
    free(ms);
    GCLog(@"DUMP %@ (%u methods) relevant: %@", name, n,
          hits.count ? [hits componentsJoinedByString:@", "] : @"(none)");
}

%ctor {
    @autoreleasepool {
        gQueue = dispatch_queue_create("com.mikey820.groupchatnamefix.q", DISPATCH_QUEUE_SERIAL);
        GCLoad();
        GCLog(@"=== GroupChatNameFix 1.0.0 loaded in %@ (%lu learned) ===",
              [[NSProcessInfo processInfo] processName], (unsigned long)gLearned.count);

        // Discover the real selectors from the live runtime (for refinement).
        for (NSString *cn in @[ @"IMDMessage", @"IMDChat", @"IMDChatRegistry",
                                @"IMDMessageStore", @"IMDServiceSession",
                                @"IMDAccount", @"IMDAccountController",
                                @"IMDMessageProcessingController",
                                @"IMMessage", @"IMChat" ]) {
            GCDumpClass(cn);
        }

        // OUTGOING: stamp the canonical gid onto the wire dictionary.
        GCHook(@[ @"IMDMessage", @"IMDChat", @"IMDMessageStore",
                  @"IMDPersistentMessage", @"IMMessage", @"IMMessageItem" ],
               @selector(dictionaryRepresentationForSending),
               (IMP)gc_dictForSending, &orig_dictForSending, "send");

        // INCOMING: learn canonical gid per participant roster.
        GCHook(@[ @"IMDMessageProcessingController", @"IMDServiceSession",
                  @"IMDAccountController" ],
               @selector(processReceivedMessage:forAccount:),
               (IMP)gc_procRecv, &orig_procRecv, "recv");

        GCHook(@[ @"IMDMessageProcessingController", @"IMDServiceSession" ],
               @selector(_processIncomingMessage:),
               (IMP)gc_procIn, &orig_procIn, "procIn");

        GCHook(@[ @"IMDServiceSession", @"IMDAccountController",
                  @"IMDMessageProcessingController" ],
               @selector(service:account:incomingMessage:fromIDQueryController:),
               (IMP)gc_idsIncoming, &orig_idsIncoming, "ids");
    }
}
