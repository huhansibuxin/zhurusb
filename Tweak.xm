#include <objc/runtime.h>
#include <sys/types.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#import <Foundation/Foundation.h>

/* ---- 外部符号 ---- */
#define PROC_PIDPATHINFO_MAXSIZE 4096
int  proc_pidpath(int pid, void *buffer, uint32_t buffersize);
void RBSProcessTerminate(pid_t pid, int reason, const char *description);
extern void _RBSSetForegroundProcessPID(pid_t pid, int state);

/* ---- 配置 ---- */
#define PREFS_FILE         "/var/mobile/Library/Preferences/com.block.procguard.prefs.plist"
#define DEFAULT_BUNDLE_ID  "com.alipay.iphoneclient"
#define DEFAULT_APP_NAME   "AlipayWallet"
#define BACKGROUND_TIMEOUT 60
#define SCAN_INTERVAL      1
#define PREFS_RELOAD_SEC   5
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

/* ==================== 偏好加载 ==================== */

static void resolve_bundle_to_name(const char *bundleID, char *out, size_t out_len) {
    NSString *nsBid = [NSString stringWithUTF8String:bundleID];
    if (!nsBid) return;

    id proxy = [NSClassFromString(@"LSApplicationProxy")
                applicationProxyForIdentifier:nsBid];
    if (!proxy) return;

    NSURL *bundleURL = [proxy bundleURL];
    if (!bundleURL) return;

    NSString *appDir  = [bundleURL lastPathComponent];
    NSString *appName = [appDir stringByDeletingPathExtension];

    const char *name = [appName UTF8String];
    if (name && strlen(name) > 0) {
        strncpy(out, name, out_len - 1);
    }
}

static void load_preferences(void) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_match_count; i++) free(g_match_names[i]);
    g_match_count = 0;
    pthread_mutex_unlock(&g_lock);

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@PREFS_FILE];
    NSArray *bundles = prefs ? prefs[@"appTargets"] : nil;

    if (!bundles || [bundles count] == 0) {
        size_t len = strlen(DEFAULT_APP_NAME) + 16;
        g_match_names[0] = (char *)malloc(len);
        snprintf(g_match_names[0], len, "/%s.app/", DEFAULT_APP_NAME);
        g_match_count = 1;
        printf("[ProcGuard] 无偏好设置，默认监控: %s\n", DEFAULT_APP_NAME);
        return;
    }

    int count = (int)[bundles count];
    printf("[ProcGuard] 偏好中有 %d 个 App\n", count);

    for (int i = 0; i < count && g_match_count < MAX_MONITOR; i++) {
        NSString *bid = bundles[i];
        if (!bid || [bid length] == 0) continue;

        const char *bidStr = [bid UTF8String];
        char appName[64] = {0};
        resolve_bundle_to_name(bidStr, appName, sizeof(appName));
        if (strlen(appName) == 0) {
            printf("[ProcGuard] 跳过无法解析: %s\n", bidStr);
            continue;
        }

        size_t len = strlen(appName) + 16;
        g_match_names[g_match_count] = (char *)malloc(len);
        snprintf(g_match_names[g_match_count], len, "/%s.app/", appName);
        printf("[ProcGuard] %s → %s\n", bidStr, appName);
        g_match_count++;
    }

    printf("[ProcGuard] 已加载 %d 个监控目标\n", g_match_count);
}

/* ==================== 监控线程 ==================== */

static void *worker(void *arg) {
    (void)arg;
    time_t last_reload = 0;
    while (1) {
        sleep(SCAN_INTERVAL);

        time_t now = time(NULL);
        if (now - last_reload >= PREFS_RELOAD_SEC) {
            last_reload = now;
            load_preferences();
        }

        pthread_mutex_lock(&g_lock);
        time_t check_now = time(NULL);
        for (int i = 0; i < MAX_MONITOR; i++) {
            AppMonitor *m = &g_monitors[i];
            if (m->pid <= 0 || m->is_foreground) continue;
            if ((check_now - m->bg_start_ts) >= BACKGROUND_TIMEOUT) {
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

%hookf(void, _RBSSetForegroundProcessPID, pid_t pid, int state) {
    %orig;

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

/* ==================== %ctor / %dtor ==================== */

%ctor {
    load_preferences();

    if (pthread_create(&g_worker, NULL, worker, NULL) == 0) {
        pthread_detach(g_worker);
        printf("[ProcGuard] 监控线程已启动\n");
    }

    printf("[ProcGuard] Hook _RBSSetForegroundProcessPID 成功\n");
}

%dtor {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_match_count; i++) free(g_match_names[i]);
    g_match_count = 0;
    pthread_mutex_unlock(&g_lock);
    pthread_mutex_destroy(&g_lock);
    printf("[ProcGuard] 已卸载\n");
}
