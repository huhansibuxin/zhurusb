#import <substrate.h>
#import <UIKit/UIKit.h>
#import <RunningBoardServices/RBSProcessMonitor.h>
#import <RunningBoardServices/RBSProcessHandle.h>
#import <RunningBoardServices/RBSProcessPredicate.h>
#import <time.h>
#import <libkern/OSAtomic.h>

static NSString *const AlipayBundleID = @"com.alipay.iphoneclient";

#define FLOOD_INTERVAL     3
#define FLOOD_MAX_COUNT    2
#define BLOCK_DURATION     120

static dispatch_queue_t sb_block_alipay_queue;
static OSSpinLock floodLock = OS_SPINLOCK_INIT;
static time_t lastTrigger = 0;
static int triggerCnt = 0;
static time_t blockUntil = 0;
static NSMutableSet *processedPids;
static id rbsMonitor = nil;

static BOOL IsLocked() {
    OSSpinLockLock(&floodLock);
    time_t now = time(NULL);
    BOOL locked = (now < blockUntil);
    OSSpinLockUnlock(&floodLock);
    return locked;
}

static void ResetFlood() {
    OSSpinLockLock(&floodLock);
    triggerCnt = 0;
    lastTrigger = time(NULL);
    OSSpinLockUnlock(&floodLock);
}

static void FloodCheck() {
    OSSpinLockLock(&floodLock);
    time_t now = time(NULL);
    if (now - lastTrigger > FLOOD_INTERVAL) {
        triggerCnt = 0;
        lastTrigger = now;
    }
    triggerCnt++;
    if (triggerCnt >= FLOOD_MAX_COUNT) {
        blockUntil = now + BLOCK_DURATION;
        NSLog(@"[SB] 频繁唤醒触发限流，封锁%ds", BLOCK_DURATION);
    }
    OSSpinLockUnlock(&floodLock);
}

static void SafeTerminateProcess(RBSProcessHandle *handle) {
    if (!handle) return;

    pid_t pid = [handle pid];
    NSString *bid = [handle bundleIdentifier];
    if (![bid isEqualToString:AlipayBundleID]) return;

    BOOL isForeground = [handle isForeground];
    if (isForeground) {
        NSLog(@"[SB] 支付宝前台运行，跳过终止 PID:%d", pid);
        ResetFlood();
        return;
    }

    if ([handle respondsToSelector:@selector(terminateForReason:description:error:)]) {
        NSError *error = nil;
        BOOL success = [handle terminateForReason:4 description:@"block background suspend" error:&error];
        if (success) {
            NSLog(@"[SB] 成功终止支付宝后台进程 PID:%d", pid);
        } else {
            NSLog(@"[SB] 终止失败: %@ (PID:%d)", error.localizedDescription, pid);
        }
    } else {
        NSLog(@"[SB] RBS接口不兼容，无法终止 PID:%d", pid);
    }
}

%hook UIApplication
- (BOOL)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme hasPrefix:@"alipay"] || [scheme hasPrefix:@"tbopen"]) {
        NSLog(@"[SB] 拦截URL唤起支付宝 %@", url);
        if (completion) completion(NO);
        return NO;
    }
    return %orig;
}
%end

%ctor {
    sb_block_alipay_queue = dispatch_queue_create("com.sb.blockalipay.queue", DISPATCH_QUEUE_SERIAL);
    processedPids = [NSMutableSet new];

    dispatch_async(sb_block_alipay_queue, ^{
        Class RBSMonitorCls = objc_getClass("RBSProcessMonitor");
        Class RBSConfigCls = objc_getClass("RBSProcessMonitorConfiguration");
        Class RBSPredicateCls = objc_getClass("RBSProcessPredicate");

        if (!RBSMonitorCls || !RBSConfigCls || !RBSPredicateCls) {
            NSLog(@"[SB] RBS类不可用，无法启动监视器");
            return;
        }

        id predicate = [RBSPredicateCls predicateMatchingBundleID:AlipayBundleID];
        if (!predicate) {
            NSLog(@"[SB] 创建RBS谓词失败");
            return;
        }

        id config = [[RBSConfigCls alloc] init];
        [config setPredicate:predicate];
        [config setEventHandler:^(RBSProcessHandle *handle) {
            if (!handle) return;
            pid_t pid = [handle pid];

            dispatch_async(sb_block_alipay_queue, ^{
                if ([processedPids containsObject:@(pid)]) return;
                [processedPids addObject:@(pid)];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                    sb_block_alipay_queue, ^{
                        if (!IsLocked()) {
                            FloodCheck();
                            SafeTerminateProcess(handle);
                        }
                        [processedPids removeObject:@(pid)];
                    });
            });
        }];

        rbsMonitor = [[RBSMonitorCls alloc] initWithConfiguration:config];
        [rbsMonitor start];
        NSLog(@"[BlockAlipaySB] RBS监视器启动成功");
    });
}

%dtor {
    dispatch_async(sb_block_alipay_queue, ^{
        if (rbsMonitor && [rbsMonitor respondsToSelector:@selector(stop)]) {
            [rbsMonitor stop];
            NSLog(@"[SB] RBS监视器已停止");
        }
        rbsMonitor = nil;
        processedPids = nil;
    });
}
