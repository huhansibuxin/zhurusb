#import <Foundation/Foundation.h>
#import <substrate.h>
#import <signal.h>
#import <time.h>
#import <os/lock.h>
#import <libproc.h>

#define SCAN_INTERVAL_SEC  2
#define FLOOD_INTERVAL     3
#define FLOOD_MAX_COUNT    2
#define BLOCK_DURATION     120

static dispatch_source_t scanTimer = nil;
static os_unfair_lock floodLock = OS_UNFAIR_LOCK_INIT;
static time_t lastKill = 0;
static int killCnt = 0;
static time_t blockUntil = 0;

static BOOL IsLocked(void) {
    os_unfair_lock_lock(&floodLock);
    BOOL locked = (time(NULL) < blockUntil);
    os_unfair_lock_unlock(&floodLock);
    return locked;
}

static void FloodCheck(void) {
    os_unfair_lock_lock(&floodLock);
    time_t now = time(NULL);
    if (now - lastKill > FLOOD_INTERVAL) {
        killCnt = 0;
        lastKill = now;
    }
    killCnt++;
    if (killCnt >= FLOOD_MAX_COUNT) {
        blockUntil = now + BLOCK_DURATION;
        NSLog(@"[RBD] 限流触发，封锁%ds", BLOCK_DURATION);
    }
    os_unfair_lock_unlock(&floodLock);
}

static void ScanAndKillAlipay(void) {
    if (IsLocked()) return;

    int numpids = proc_listallpids(NULL, 0);
    if (numpids <= 0) return;

    pid_t *pids = malloc(sizeof(pid_t) * numpids);
    if (!pids) return;

    numpids = proc_listallpids(pids, (int)(sizeof(pid_t) * numpids));

    for (int i = 0; i < numpids; i++) {
        if (pids[i] <= 0) continue;

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], pathbuf, sizeof(pathbuf)) <= 0) continue;

        if (strstr(pathbuf, "/AlipayWallet.app/") || strstr(pathbuf, "/AliPay.app/")) {
            @autoreleasepool {
                kill(pids[i], SIGKILL);
                FloodCheck();
                NSLog(@"[RBD] kill 支付宝 PID:%d", pids[i]);
            }
            break;
        }
    }
    free(pids);
}

%ctor {
    dispatch_queue_t q = dispatch_queue_create("com.rbd.alipayscan", DISPATCH_QUEUE_SERIAL);
    scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(scanTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
        SCAN_INTERVAL_SEC * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(scanTimer, ^{
        ScanAndKillAlipay();
    });
    dispatch_resume(scanTimer);
    NSLog(@"[BlockAlipayRBD] runningboardd 扫描已启动 (%ds)", SCAN_INTERVAL_SEC);
}

%dtor {
    if (scanTimer) {
        dispatch_source_cancel(scanTimer);
        scanTimer = nil;
    }
}
