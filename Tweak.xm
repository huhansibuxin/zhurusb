#import <substrate.h>
#import <UIKit/UIKit.h>
#import <time.h>

static NSString *const AlipayBundleID = @"com.alipay.iphoneclient";

// 限流配置
#define FLOOD_INTERVAL 3        // 3秒内
#define FLOOD_MAX_COUNT 2       // 超过2次判定为风暴
#define BLOCK_DURATION 120      // 封禁时长 120秒

static time_t lastTriggerTime = 0;
static int triggerCount = 0;
static time_t blockUntilTime = 0;

static BOOL IsFloodProtectActive()
{
    time_t now = time(NULL);
    return now < blockUntilTime;
}

static void ResetFloodState()
{
    triggerCount = 0;
    lastTriggerTime = time(NULL);
}

static void CheckFlood()
{
    time_t now = time(NULL);
    if (now - lastTriggerTime > FLOOD_INTERVAL)
    {
        ResetFloodState();
    }
    triggerCount++;
    if (triggerCount >= FLOOD_MAX_COUNT)
    {
        blockUntilTime = now + BLOCK_DURATION;
        NSLog(@"[SB限流] 检测到频繁唤醒，封禁支付宝 %d 秒", BLOCK_DURATION);
    }
}

#pragma mark 拦截 alipays:// tbopen:// 外部跨App唤起

%hook UIApplication
- (BOOL)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion
{
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme hasPrefix:@"alipay"] || [scheme hasPrefix:@"tbopen"])
    {
        NSLog(@"[SB] 拦截外部URL唤起支付宝 : %@", url);
        if (completion) completion(NO);
        return NO;
    }
    return %orig;
}
%end

#pragma mark 监控应用状态，后台自动Kill，前台放行 + 洪水限流

%hook SBMainWorkspace
- (void)setApplicationProcessState:(id)state forApplication:(id)app
{
    %orig;
    NSString *bid = [app bundleIdentifier];
    if (![bid isEqualToString:AlipayBundleID]) return;
    BOOL foreground = [state isForeground];
    pid_t pid = [[state processIdentifier] intValue];
    if (pid <= 5) return;
    if (!foreground)
    {
        CheckFlood();
        if (IsFloodProtectActive())
        {
            NSLog(@"[SB限流生效] 支付宝频繁唤醒封禁中，Kill PID = %d", pid);
            kill(pid, SIGKILL);
        }
        else
        {
            NSLog(@"[SB兜底] 支付宝后台运行，Kill PID = %d", pid);
            kill(pid, SIGKILL);
        }
    }
    else
    {
        NSLog(@"[SB放行] 支付宝前台运行，重置限流统计");
        ResetFloodState();
    }
}
%end
