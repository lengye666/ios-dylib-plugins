/**
 * douyin-drama-skip.m v2
 * 抖音短剧跳广告插件 — 无感版
 *
 * 原理：劫持激励广告的回调，让系统认为"广告已看完"
 * 不做任何 UI 点击，完全无感。
 *
 * 编译：见 build.yml
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

#define LOG(fmt, ...) NSLog(@"[DramaSkip] " fmt, ##__VA_ARGS__)

// ==========================================
// 策略 1：劫持穿山甲(BU)激励视频广告回调
// ==========================================

// 穿山甲 SDK 的关键回调协议
// 这些是 objc protocol 的 selector，方法存在就 hook
static NSArray *rewardedAdSelectors(void) {
    return @[
        // 穿山甲 - 激励视频广告
        @"rewardedVideoAdDidLoad:",
        @"rewardedVideoAdVideoDidLoad:",
        @"rewardedVideoAdDidVisible:",
        @"rewardedVideoAdDidClose:",
        @"rewardedVideoAdDidClick:",
        @"rewardedVideoAd:rewardDidSuccessWithInfo:",
        @"rewardedVideoAdDidPlayFinish:didFailWithError:",
        @"rewardedVideoAdServerRewardDidSucceed:verify:",

        // 穿山甲 - 全屏视频广告
        @"fullscreenVideoAdVideoDataDidLoad:",
        @"fullscreenVideoAd:rewardDidSuccessWithInfo:",

        // 抖音内部广告系统
        @"adDidFinish:",
        @"rewardAdDidComplete:",
        @"dramaUnlockAdFinished:",
        @"onAdComplete:",
        @"onRewardedAdComplete:",

        // 通用激励广告
        @"rewardedAdDidEarnReward:",
        @"rewardedAdDidDismiss:",
        @"adDidReward:",
    ];
}

static void installAdHook(void) {
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = allClasses[i];
        NSString *className = NSStringFromClass(cls);

        // 只看广告相关的类
        NSString *lower = [className lowercaseString];
        if (![lower containsString:@"reward"] &&
            ![lower containsString:@"ad"] &&
            ![lower containsString:@"bu"] &&
            ![lower containsString:@"pangle"] &&
            ![lower containsString:@"csj"] &&
            ![lower containsString:@"fullscreen"]) {
            continue;
        }

        for (NSString *selName in rewardedAdSelectors()) {
            SEL sel = NSSelectorFromString(selName);
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) {
                // 也查 class method
                method = class_getClassMethod(cls, sel);
            }
            if (!method) continue;

            // 找到目标 → 记录但不 hook，运行时动态替换
            LOG(@"发现广告回调方法: [%s %s]", class_getName(cls), selName.UTF8String);
            hookRewardedAdCallback(cls, sel);
        }
    }

    free(allClasses);
}

static void hookRewardedAdCallback(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) method = class_getClassMethod(cls, sel);
    if (!method) return;

    IMP origIMP = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    // 创建一个替换 IMP：什么都不做，但触发"奖励发放"逻辑
    // 穿山甲广告的典型回调 "rewardedVideoAdServerRewardDidSucceed:verify:"
    // 有两个参数 (id self, SEL _cmd, id ad, BOOL verify)
    IMP newIMP = imp_implementationWithBlock(^(id self, id arg1, BOOL verify) {
        LOG(@"🎯 拦截广告回调: [%s %s]", class_getName(cls), sel_getName(sel));

        // 立即调用原始实现 → 让系统以为广告已完成
        // 某些情况下直接调原方法即可触发解锁
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (types && strlen(types) > 2) {
                    // 根据方法签名调用原实现
                    char returnType = types[0];
                    if (returnType == 'v') { // void return
                        ((void (*)(id, SEL, id, BOOL))origIMP)(self, sel, arg1, verify);
                    }
                }
                LOG(@"✅ 广告回调已释放: 下一集应解锁");
            } @catch (NSException *e) {
                LOG(@"⚠️ 释放广告回调异常: %s", e.description.UTF8String);
            }
        });
    });

    method_setImplementation(method, newIMP);
    LOG(@"📌 已hook: [%s %s]", class_getName(cls), sel_getName(sel));
}

// ==========================================
// 策略 2：劫持视频播放完毕 → 直接切下一集
// ==========================================

static void installPlayerHook(void) {
    // 监听所有 AVPlayerItem 播放完毕通知
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        LOG(@"视频播放完毕 → 触发无感切集");

        // 延迟 0.1 秒，确保播放器释放资源
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            tryAutoPlayNext(note.object);
        });
    }];
}

static void tryAutoPlayNext(id playerItem) {
    // 查找持有这个 AVPlayerItem 的播放器
    AVPlayer *player = nil;
    for (id window in [UIApplication sharedApplication].windows) {
        if (![window respondsToSelector:@selector(rootViewController)]) continue;
        player = findPlayerInViewTree(window);
        if (player) break;
    }

    if (!player) return;

    // 方案 A：尝试调用播放器的"下一集"方法
    if ([player respondsToSelector:NSSelectorFromString(@"advanceToNextItem")]) {
        [player performSelector:NSSelectorFromString(@"advanceToNextItem")];
        LOG(@"调用 advanceToNextItem");
        return;
    }

    // 方案 B：替换当前 item 为队列中的下一个
    NSArray *items = [player items];
    if (items.count > 1) {
        NSInteger currentIdx = [items indexOfObject:player.currentItem];
        if (currentIdx != NSNotFound && currentIdx + 1 < (NSInteger)items.count) {
            [player advanceToNextItem];
            LOG(@"AVQueuePlayer 切换到下一集");
            return;
        }
    }

    // 方案 C：找到 player 所在的 ViewController → 调用其"下一集"方法
    UIViewController *vc = findViewControllerForPlayer(player);
    if (vc) {
        // 尝试常见的下一集方法名
        for (NSString *selName in @[@"playNextEpisode", @"_playNextVideo",
                                     @"nextEpisode", @"onNextButtonTapped",
                                     @"dramaNextAction"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([vc respondsToSelector:sel]) {
                [vc performSelector:sel];
                LOG(@"调用 [%s %s]", class_getName([vc class]), selName.UTF8String);
                return;
            }
        }
    }
}

static AVPlayer *findPlayerInViewTree(UIView *view) {
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            return [(AVPlayerLayer *)layer player];
        }
    }
    for (UIView *subview in view.subviews) {
        AVPlayer *player = findPlayerInViewTree(subview);
        if (player) return player;
    }
    return nil;
}

static UIViewController *findViewControllerForPlayer(AVPlayer *player) {
    for (id window in [UIApplication sharedApplication].windows) {
        if (![window respondsToSelector:@selector(rootViewController)]) continue;
        UIViewController *root = [window rootViewController];
        UIViewController *vc = searchVC(root, player);
        if (vc) return vc;
    }
    return nil;
}

static UIViewController *searchVC(UIViewController *vc, AVPlayer *targetPlayer) {
    if (!vc) return nil;

    // 检查这个 VC 的 view 里有没有目标 AVPlayer
    AVPlayer *found = findPlayerInViewTree(vc.view);
    if (found == targetPlayer) return vc;
    if (found && targetPlayer == nil) return vc;

    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *result = searchVC(child, targetPlayer);
        if (result) return result;
    }

    if (vc.presentedViewController) {
        UIViewController *result = searchVC(vc.presentedViewController, targetPlayer);
        if (result) return result;
    }

    return nil;
}

// ==========================================
// 策略 3：ViewWillDisappear 探测短剧页面
// ==========================================

static IMP gOrigViewDidAppear = NULL;

static void swizViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) {
        ((void (*)(id, SEL, BOOL))gOrigViewDidAppear)(self, _cmd, animated);
    }

    NSString *name = NSStringFromClass([self class]);
    if ([name rangeOfString:@"Drama" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [name rangeOfString:@"ShortPlay" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        LOG(@"进入短剧页面: %s", class_getName([self class]));
    }
}

// ==========================================
// 策略 4：直接 hook AVQueuePlayer advanceToNextItem
// ==========================================

static void installQueuePlayerHook(void) {
    // AVQueuePlayer.advanceToNextItem 是获取下一集的方法
    // 如果它被广告拦截了，我们 hook 它强制放行
    Method m = class_getInstanceMethod([AVQueuePlayer class], @selector(advanceToNextItem));
    if (m) {
        LOG(@"发现 AVQueuePlayer (可能是短剧播放器)");
    }
}

// ==========================================
// 入口
// ==========================================

__attribute__((constructor))
static void DramaSkipInit(void) {
    LOG(@"===== 抖音短剧跳广告 v2 (无感版) =====");

    // 主策略：hook 广告回调
    // 延迟执行以确保所有类已加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        installAdHook();
    });

    // 策略 2：视频播放完毕直接切
    installPlayerHook();

    // 策略 3：AVQueuePlayer hook
    installQueuePlayerHook();

    // 策略 4：监听短剧页面（调试用）
    Method vdaMethod = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (vdaMethod) {
        gOrigViewDidAppear = method_getImplementation(vdaMethod);
        method_setImplementation(vdaMethod, (IMP)swizViewDidAppear);
    }

    LOG(@"初始化完成 ✅");
}
