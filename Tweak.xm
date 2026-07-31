#include <substrate.h>
#include <signal.h>
#include <sys/types.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>

/* ---- 外部符号 ---- */
#define PROC_PIDPATHINFO_MAXSIZE 4096
int  proc_pidpath(int pid, void *buffer, uint32_t buffersize);
void RBSProcessTerminate(pid_t pid, int reason, const char *description);

/* ---- 配置 ---- */
#define PREFS_PLIST        "/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define PREFS_KEY          CFSTR("appTargets")
#define DARWIN_NOTIFY_NAME CFSTR("com.block.procguard-prefs-changed")

#define DEFAULT_BUNDLE_ID  "com.alipay.iphoneclient"
#define DEFAULT_APP_NAME   "AlipayWallet"
#define BACKGROUND_TIMEOUT 60
#define SCAN_INTERVAL      1
#define MAX_MONITOR        64

/* ---- 监控结构 ---- */
typedef struct {
    pid_t   pid;
    time_t  bg_start_ts;
    int     is_foreground;
    char    app_name[64];
} AppMonitor;

static AppMonitor      g_monitors[MAX_MONITOR];
static pthread_mutex_t g_lock   = PTHREAD_MUTEX_INITIALIZER;
static pthread_t       g_worker = 0;

static char *g_match_names[MAX_MONITOR];
static int   g_match_count = 0;

/* ---- Hook ---- */
static void (*orig_RBSSetForegroundProcessPID)(pid_t pid, int state);

/* ==================== 工具 ==================== */

static int find_by_pid(pid_t pid) {
    for (int i = 0; i < MAX_MONITOR; i++)
        if (g_monitors[i].pid == pid) return i;
    return -1;
}

static int find_empty(void) {
    for (int i = 0; i < MAX_MONITOR; i++)
        if (g_monitors[i].pid <= 0) return i;
    return -1;
}

static const char *match_app(const char *path) {
    for (int i = 0; i < g_match_count; i++) {
        if (strstr(path, g_match_names[i])) return g_match_names[i];
    }
    return NULL;
}

/* ==================== 监控线程 ==================== */

static void *worker(void *arg) {
    (void)arg;
    while (1) {
        sleep(SCAN_INTERVAL);
        pthread_mutex_lock(&g_lock);
        time_t now = time(NULL);
        for (int i = 0; i < MAX_MONITOR; i++) {
            AppMonitor *m = &g_monitors[i];
            if (m->pid <= 0 || m->is_foreground) continue;
            if ((now - m->bg_start_ts) >= BACKGROUND_TIMEOUT) {
                printf("[ProcGuard] %s 后台%ds超时, 终止 PID:%d\n",
                       m->app_name, BACKGROUND_TIMEOUT, m->pid);
                RBSProcessTerminate(m->pid, 4, "background timeout kill");
                memset(m, 0, sizeof(AppMonitor));
            }
        }
        pthread_mutex_unlock(&g_lock);
    }
    return NULL;
}

/* ==================== Hook ==================== */

static void hook_RBSSetForegroundProcessPID(pid_t pid, int state) {
    orig_RBSSetForegroundProcessPID(pid, state);
    if (pid <= 0) return;

    pthread_mutex_lock(&g_lock);

    int slot = find_by_pid(pid);

    if (state == 0) {
        if (slot < 0) {
            char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
            proc_pidpath(pid, pathbuf, sizeof(pathbuf));

            const char *app = match_app(pathbuf);
            if (!app) { pthread_mutex_unlock(&g_lock); return; }

            int new_slot = find_empty();
            if (new_slot < 0) { pthread_mutex_unlock(&g_lock); return; }

            AppMonitor *m  = &g_monitors[new_slot];
            m->pid          = pid;
            m->is_foreground = 0;
            m->bg_start_ts  = time(NULL);
            strncpy(m->app_name, app, sizeof(m->app_name) - 1);
            printf("[ProcGuard] 发现 %s PID:%d 切后台, %ds后终止\n",
                   app, pid, BACKGROUND_TIMEOUT);
        } else {
            AppMonitor *m = &g_monitors[slot];
            m->is_foreground = 0;
            m->bg_start_ts   = time(NULL);
            printf("[ProcGuard] %s 切后台 PID:%d\n", m->app_name, pid);
        }
    } else {
        if (slot >= 0) {
            printf("[ProcGuard] %s 切前台, 取消计时 PID:%d\n",
                   g_monitors[slot].app_name, pid);
            memset(&g_monitors[slot], 0, sizeof(AppMonitor));
        }
    }

    pthread_mutex_unlock(&g_lock);
}

/* ==================== 偏好解析 ==================== */

static void resolve_bundle_to_name(const char *bundleID, char *out, size_t out_len) {
    Class nsStrCls = objc_getClass("NSString");
    id nsBid = ((id(*)(id, SEL, const char*))objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)nsStrCls, sel_registerName("alloc")),
        sel_registerName("initWithUTF8String:"), bundleID
    );

    Class lsCls = objc_getClass("LSApplicationProxy");
    id proxy = ((id(*)(id, SEL, id))objc_msgSend)(
        (id)lsCls, sel_registerName("applicationProxyForIdentifier:"), nsBid
    );
    if (!proxy) return;

    id bundleURL = ((id(*)(id, SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
    if (!bundleURL) return;

    id appDir  = ((id(*)(id, SEL))objc_msgSend)(bundleURL, sel_registerName("lastPathComponent"));
    id appName = ((id(*)(id, SEL))objc_msgSend)(appDir, sel_registerName("stringByDeletingPathExtension"));

    const char *name = ((const char*(*)(id, SEL))objc_msgSend)(appName, sel_registerName("UTF8String"));
    if (name && strlen(name) > 0) {
        strncpy(out, name, out_len - 1);
    }
}

static void load_preferences(void) {
    CFArrayRef bundles = CFPreferencesCopyAppValue(PREFS_KEY, CFSTR("com.block.procguard.prefs"));

    if (!bundles || CFGetTypeID(bundles) != CFArrayGetTypeID()) {
        /* 无偏好：默认支付宝 */
        size_t len = strlen(DEFAULT_APP_NAME) + 16;
        g_match_names[0] = malloc(len);
        snprintf(g_match_names[0], len, "/%s.app/", DEFAULT_APP_NAME);
        g_match_count = 1;
        printf("[ProcGuard] 无偏好设置，默认监控: %s\n", DEFAULT_APP_NAME);
        if (bundles) CFRelease(bundles);
        return;
    }

    CFIndex count = CFArrayGetCount(bundles);
    printf("[ProcGuard] 偏好中有 %ld 个 App\n", count);

    for (CFIndex i = 0; i < count && g_match_count < MAX_MONITOR; i++) {
        CFStringRef bid = CFArrayGetValueAtIndex(bundles, i);
        if (CFGetTypeID(bid) != CFStringGetTypeID()) continue;

        char buf[256] = {0};
        CFStringGetCString(bid, buf, sizeof(buf), kCFStringEncodingUTF8);
        if (strlen(buf) == 0) continue;

        char appName[64] = {0};
        resolve_bundle_to_name(buf, appName, sizeof(appName));
        if (strlen(appName) == 0) {
            printf("[ProcGuard] 跳过无法解析的: %s\n", buf);
            continue;
        }

        size_t len = strlen(appName) + 16;
        g_match_names[g_match_count] = malloc(len);
        snprintf(g_match_names[g_match_count], len, "/%s.app/", appName);
        printf("[ProcGuard] %s → %s\n", buf, appName);
        g_match_count++;
    }

    CFRelease(bundles);
    printf("[ProcGuard] 已加载 %d 个监控目标\n", g_match_count);
}

static void clear_preferences(void) {
    for (int i = 0; i < g_match_count; i++) free(g_match_names[i]);
    g_match_count = 0;
    memset(g_monitors, 0, sizeof(g_monitors));
}

static void prefs_changed(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    pthread_mutex_lock(&g_lock);
    clear_preferences();
    pthread_mutex_unlock(&g_lock);
    load_preferences();
    printf("[ProcGuard] 偏好已热更新\n");
}

/* ==================== %ctor / %dtor ==================== */

%ctor {
    load_preferences();

    if (pthread_create(&g_worker, NULL, worker, NULL) == 0) {
        pthread_detach(g_worker);
        printf("[ProcGuard] 监控线程已启动\n");
    }

    MSHookFunction(
        MSFindSymbol(NULL, "_RBSSetForegroundProcessPID"),
        (void *)hook_RBSSetForegroundProcessPID,
        (void **)&orig_RBSSetForegroundProcessPID
    );
    printf("[ProcGuard] Hook _RBSSetForegroundProcessPID 成功\n");

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, prefs_changed, DARWIN_NOTIFY_NAME,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately
    );
    printf("[ProcGuard] Darwin 通知监听已注册\n");
}

%dtor {
    pthread_mutex_lock(&g_lock);
    clear_preferences();
    pthread_mutex_unlock(&g_lock);
    pthread_mutex_destroy(&g_lock);
    printf("[ProcGuard] 已卸载\n");
}
