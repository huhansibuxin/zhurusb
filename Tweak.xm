#import <substrate.h>
#import <UIKit/UIKit.h>
#import <time.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define FLOOD_INTERVAL 3
#define FLOOD_MAX_COUNT 2
#define BLOCK_DURATION 120

// ── RBS 前向声明 ──
@interface RBSProcessPredicate : NSObject
+ (instancetype)predicateMatchingBundleIdentifier:(NSString *)bundleID;
+ (instancetype)predicateMatchingExecPath:(NSString *)path;
@end

@interface RBSProcessHandle : NSObject
@property (readonly) int pid;
@property (readonly) NSString *name;
+ (instancetype)handleForPredicate:(RBSProcessPredicate *)pred error:(NSError **)error;
- (BOOL)terminateWithError:(NSError **)error;
@end

@interface RBSProcessMonitorConfiguration : NSObject
@property (copy) NSArray<RBSProcessPredicate *> *predicates;
@property (copy) void (^updateHandler)(id monitor, RBSProcessHandle *handle, id update);
@end

@interface RBSProcessMonitor : NSObject
+ (instancetype)monitorWithConfiguration:(RBSProcessMonitorConfiguration *)config;
@end

// ── 全局状态 ──
static NSMutableDictionary *floodState = nil;  // key -> {lastTime, count, blockUntil}
static RBSProcessMonitor *currentMonitor = nil;

// ── 洪水限流 ──
static BOOL IsFloodBlocked(NSString *key) {
    NSDictionary *s = floodState[key];
    if (!s) return NO;
    return time(NULL) < [s[@"blockUntil"] intValue];
}

static void FloodTick(NSString *key) {
    NSMutableDictionary *s = floodState[key];
    if (!s) {
        s = [NSMutableDictionary dictionaryWithObjectsAndKeys:@(0), @"lastTime", @(0), @"count", @(0), @"blockUntil", nil];
        floodState[key] = s;
    }
    time_t now = time(NULL);
    time_t last = [s[@"lastTime"] intValue];
    if (now - last > FLOOD_INTERVAL) {
        s[@"count"] = @(0);
        s[@"lastTime"] = @(now);
    } else {
        s[@"lastTime"] = @(now);
    }
    int count = [s[@"count"] intValue] + 1;
    s[@"count"] = @(count);
    if (count >= FLOOD_MAX_COUNT) {
        s[@"blockUntil"] = @(now + BLOCK_DURATION);
    }
}

// ── 目标列表解析（prefs 存 "targets" 数组） ──
static NSArray<NSDictionary *> *LoadTargets(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSArray *raw = prefs[@"targets"];
    if (!raw || ![raw isKindOfClass:[NSArray class]]) {
        // 默认拦截支付宝
        return @[@{@"type": @"bundle", @"value": @"com.alipay.iphoneclient"}];
    }
    NSMutableArray *targets = [NSMutableArray array];
    for (id item in raw) {
        if ([item isKindOfClass:[NSString class]]) {
            NSString *val = [(NSString *)item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (val.length == 0) continue;
            NSString *type = [val hasPrefix:@"/"] ? @"exec" : @"bundle";
            [targets addObject:@{@"type": type, @"value": val}];
        }
    }
    return targets.count > 0 ? targets : @[@{@"type": @"bundle", @"value": @"com.alipay.iphoneclient"}];
}

// ── 重建 monitor ──
static void RebuildMonitor(void) {
    if (currentMonitor) { currentMonitor = nil; }
    NSArray *targets = LoadTargets();
    NSMutableArray *preds = [NSMutableArray array];
    for (NSDictionary *t in targets) {
        NSString *type = t[@"type"];
        NSString *value = t[@"value"];
        RBSProcessPredicate *pred = nil;
        if ([type isEqualToString:@"bundle"]) {
            pred = [RBSProcessPredicate predicateMatchingBundleIdentifier:value];
        } else {
            pred = [RBSProcessPredicate predicateMatchingExecPath:value];
        }
        if (pred) [preds addObject:pred];
    }
    if (preds.count == 0) return;

    RBSProcessMonitorConfiguration *cfg = [[RBSProcessMonitorConfiguration alloc] init];
    cfg.predicates = preds;
    cfg.updateHandler = ^(id monitor, RBSProcessHandle *handle, id update) {
        NSString *bid = handle.name;
        if (IsFloodBlocked(bid)) return;
        FloodTick(bid);
        NSError *err = nil;
        [handle terminateWithError:&err];
    };
    currentMonitor = [RBSProcessMonitor monitorWithConfiguration:cfg];
}

// ── Darwin 通知回调 ──
static void PrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    RebuildMonitor();
}

%ctor {
    floodState = [NSMutableDictionary dictionary];
    RebuildMonitor();

    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, PrefsChanged,
        CFSTR("com.block.procguard-prefs-changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
