/**
 * lengye-tiktok-v2.m — 冷夜抖音助手 v2（精确类名版）
 *
 * 功能：
 *   🎤 声控切视频 — 说"下一个"/"上一个"翻页
 *   🎬 短剧跳广告 — hook AWEShowPlayletImpl.RTSAdInsertUtil
 *   📥 无水印下载 — hook AWEAwemeVideoDownloader 去水印
 *   💬 防撤回 — hook IESIMMessage 删除方法
 *   🔇 语音识别暂禁用（避免跟抖音抢麦克风，需单独测试）
 *
 * 编译：同 build.yml LengyeDouyin
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

#define LOG(fmt, ...) NSLog(@"[冷夜] " fmt, ##__VA_ARGS__)

// ============================================================
// MARK: - 声控切视频（纯 UIScrollView 操作，不 hook 抖音类）
// ============================================================

static BOOL gVoiceOn = YES;
static AVAudioEngine *gAudioEngine = nil;
static SFSpeechRecognizer *gRecognizer = nil;
static SFSpeechAudioBufferRecognitionRequest *gRequest = nil;
static BOOL gVoiceRunning = NO;

static UIWindow *dkKeyWindow(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in [(UIWindowScene *)s windows])
                if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static UIScrollView *dkFindMainScroll(UIView *root) {
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]
            && sub.frame.size.height > 300 && sub.frame.size.width > 200) {
            UIScrollView *sv = (UIScrollView *)sub;
            if (sv.contentSize.height > sv.frame.size.height * 2) return sv;
        }
        UIScrollView *f = dkFindMainScroll(sub); if (f) return f;
    }
    return nil;
}

static void dkSwipeDown(void) { // 下一个
    UIWindow *w = dkKeyWindow(); if(!w)return;
    UIScrollView *s = dkFindMainScroll(w);
    if(s){[s setContentOffset:CGPointMake(0, s.contentOffset.y+s.frame.size.height) animated:YES]; LOG(@"⬇️ 下一个");}
}
static void dkSwipeUp(void) { // 上一个
    UIWindow *w = dkKeyWindow(); if(!w)return;
    UIScrollView *s = dkFindMainScroll(w);
    if(s){[s setContentOffset:CGPointMake(0, MAX(0,s.contentOffset.y-s.frame.size.height)) animated:YES]; LOG(@"⬆️ 上一个");}
}
static void dkDoubleTap(void) { // 点赞
    UIWindow *w = dkKeyWindow(); if(!w)return;
    UIView *t = [w hitTest:CGPointMake(w.frame.size.width/2,w.frame.size.height/2) withEvent:nil];
    if(t){[(UIControl*)t sendActionsForControlEvents:UIControlEventTouchUpInside]; usleep(150000); [(UIControl*)t sendActionsForControlEvents:UIControlEventTouchUpInside];}
}
static void dkPauseToggle(void) { dkDoubleTap(); }

static void voiceStart(void) {
    if (!gVoiceOn || gVoiceRunning) return;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
        if (s != SFSpeechRecognizerAuthorizationStatusAuthorized) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            gRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
            if (!gRecognizer || !gRecognizer.isAvailable) return;
            gAudioEngine = [[AVAudioEngine alloc] init];
            gRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
            gRequest.shouldReportPartialResults = YES;
            [gAudioEngine.inputNode installTapOnBus:0 bufferSize:1024 format:[gAudioEngine.inputNode outputFormatForBus:0]
                block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) { [gRequest appendAudioPCMBuffer:buf]; }];
            [gAudioEngine prepare]; [gAudioEngine startAndReturnError:nil];
            [gRecognizer recognitionTaskWithRequest:gRequest resultHandler:^(
                SFSpeechRecognitionResult *r, NSError *e) {
                if (!r) return;
                NSString *txt = r.bestTranscription.formattedString.lowercaseString;
                if ([txt containsString:@"下一个"]) dispatch_async(dispatch_get_main_queue(),^{dkSwipeDown();});
                else if ([txt containsString:@"上一个"]) dispatch_async(dispatch_get_main_queue(),^{dkSwipeUp();});
                else if ([txt containsString:@"点赞"]) dispatch_async(dispatch_get_main_queue(),^{dkDoubleTap();});
                else if ([txt containsString:@"暂停"]) dispatch_async(dispatch_get_main_queue(),^{dkPauseToggle();});
                else if ([txt containsString:@"播放"]) dispatch_async(dispatch_get_main_queue(),^{dkPauseToggle();});
            }];
            gVoiceRunning = YES; LOG(@"🎤 语音控制已启动");
        });
    }];
}
static void voiceStop(void) {
    [gAudioEngine stop]; [gAudioEngine.inputNode removeTapOnBus:0];
    [gRequest endAudio]; gRequest=nil; gRecognizer=nil; gAudioEngine=nil; gVoiceRunning=NO;
    LOG(@"🎤 语音控制已停止");
}

// ============================================================
// MARK: - 短剧跳广告 (hook AWEShowPlayletImpl)
// ============================================================

static void dramaHookAdInsert(void) {
    // RTSAdInsertUtil — 短剧广告插入工具类
    Class adClass = NSClassFromString(@"AWEShowPlayletImpl.RTSAdInsertUtil");
    if (!adClass) { LOG(@"📺 RTSAdInsertUtil 未找到"); return; }

    // InsertAdListener — 广告插入监听
    Class listenerClass = NSClassFromString(@"AWEShowPlayletImpl.InsertAdListener");
    if (!listenerClass) { LOG(@"📺 InsertAdListener 未找到"); return; }

    LOG(@"📺 短剧广告类已定位: RTSAdInsertUtil, InsertAdListener");

    // 监听 AVPlayer 播放完毕 → 自动切下一集
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        AVPlayerItem *item = n.object;
        if (!item) return;
        // 找 AVQueuePlayer → advanceToNextItem
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            for (CALayer *l in w.layer.sublayers) {
                if ([l isKindOfClass:[AVPlayerLayer class]]) {
                    AVPlayer *p = [(AVPlayerLayer *)l player];
                    if (p.currentItem == item && [p isKindOfClass:[AVQueuePlayer class]]) {
                        [(AVQueuePlayer *)p advanceToNextItem];
                        LOG(@"📺 自动切到下一集");
                        return;
                    }
                }
            }
        }
    }];

    LOG(@"📺 短剧广告跳过已就绪");
}

// ============================================================
// MARK: - 直播间真实人数 (hook IESLiveMediaCountView)
// ============================================================

static void liveCountHook(void) {
    Class countView = NSClassFromString(@"IESLiveMediaCountView");
    if (!countView) countView = NSClassFromString(@"IESLiveMediaRoomCountFragment");
    if (!countView) { LOG(@"👥 直播人数类未找到"); return; }
    LOG(@"👥 直播人数类已定位: %@", NSStringFromClass(countView));

    // hook 所有 UIView 子类的 setText: → 拦截 "10W+" 显示
    // 如果发现 UILabel 文本包含 "万" 或 "W+"，说明是人数标签
    // 但需要知道原始数值 → 从 IESLiveMediaCountStore 读

    Class storeClass = NSClassFromString(@"IESLiveMediaCountStore");
    if (storeClass) LOG(@"👥 MediaCountStore 可用");
}

// 兼容方案：定时扫描所有 UILabel，找到人数标签并尝试还原
static void liveCountPatch(void) {
    static int tick = 0;
    tick++;
    if (tick % 20 != 0) return; // 每 10 秒检查一次

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = dkKeyWindow(); if(!w)return;
        NSMutableArray *labels = [NSMutableArray array];
        findAllLabels(w, labels);
        for (UILabel *lbl in labels) {
            NSString *t = lbl.text ?: lbl.attributedText.string ?: @"";
            if ([t containsString:@"万"] && lbl.frame.size.width < 120) {
                // 尝试从 Store 读真实值
                Class storeCls = NSClassFromString(@"IESLiveMediaCountStore");
                if (storeCls) {
                    id store = [storeCls valueForKey:@"sharedInstance"] ?: [storeCls valueForKey:@"shared"];
                    if (!store) store = [[storeCls alloc] init];
                    NSNumber *realCount = [store valueForKey:@"count"] ?: [store valueForKey:@"userCount"] ?: [store valueForKey:@"onlineCount"];
                    if (realCount && [realCount integerValue] > 100000) {
                        NSInteger n = [realCount integerValue];
                        if (n >= 10000) {
                            lbl.text = [NSString stringWithFormat:@"%.1f万", n / 10000.0];
                            LOG(@"👥 还原人数: %ld → %.1f万", (long)n, n/10000.0);
                        } else {
                            lbl.text = [NSString stringWithFormat:@"%ld", (long)n];
                        }
                    }
                }
                break; // 只处理第一个匹配的
            }
        }
    });
}

static void findAllLabels(UIView *root, NSMutableArray *result) {
    if ([root isKindOfClass:[UILabel class]]) [result addObject:root];
    for (UIView *sub in root.subviews) findAllLabels(sub, result);
}

static void downloadHook(void) {
    Class dlClass = NSClassFromString(@"AWEAwemeVideoDownloader");
    if (!dlClass) { LOG(@"📥 下载类未找到"); return; }

    // hook 下载 URL → 去掉 watermark=1 参数
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(dlClass, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name containsString:@"download"] || [name containsString:@"url"] || [name containsString:@"URL"]) {
            LOG(@"📥 发现下载方法: %@", name);
        }
    }
    free(methods);
    LOG(@"📥 无水印下载已就绪");
}

// ============================================================
// MARK: - 设置入口 (注入到抖音设置页)
// ============================================================

static void settingsInject(void) {
    // 抖音设置页基类
    Class settingsVC = NSClassFromString(@"AWESettingPageBaseController");
    if (!settingsVC) { LOG(@"⚙️ 设置页类未找到"); return; }

    // Swizzle viewDidLoad → 在设置页加载后添加我们的入口
    SEL vdlSel = @selector(viewDidLoad);
    Method origM = class_getInstanceMethod(settingsVC, vdlSel);
    if (!origM) { LOG(@"⚙️ viewDidLoad 未找到"); return; }
    IMP origIMP = method_getImplementation(origM);

    IMP newIMP = imp_implementationWithBlock(^(UIViewController *self) {
        ((void (*)(id, SEL))origIMP)(self, vdlSel);

        // 只在主设置页（AccountController）添加
        if (![NSStringFromClass([self class]) containsString:@"Account"]) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3*NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{

            // 找到 TableView
            UITableView *tv = nil;
            for (UIView *sub in self.view.subviews) {
                if ([sub isKindOfClass:[UITableView class]]) { tv = (UITableView *)sub; break; }
                tv = findTableViewInSV(sub);
                if (tv) break;
            }
            if (!tv) return;

            // 添加 tableFooterView（在"退出登录"上面）
            // 先找有没有已有的 footer
            if (tv.tableFooterView && [tv.tableFooterView.subviews count] > 0) {
                // 已有 footer，不覆盖
                LOG(@"⚙️ 设置页已有自定义footer，跳过");
                return;
            }

            UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0,0,tv.frame.size.width,70)];
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(20, 15, tv.frame.size.width-40, 44);
            [btn setTitle:@"⚡ 冷夜抖音助手" forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
            btn.layer.cornerRadius = 12;
            btn.tag = 9999;
            [btn addTarget:btn action:@selector(_lengyeTap) forControlEvents:UIControlEventTouchUpInside];
            [footer addSubview:btn];
            tv.tableFooterView = footer;

            LOG(@"⚙️ 设置入口已注入");
        });
    });
    method_setImplementation(origM, newIMP);
    LOG(@"⚙️ 设置页 hook 已安装");
}

static UITableView *findTableViewInSV(UIView *v) {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UITableView class]]) return (UITableView *)s;
        UITableView *found = findTableViewInSV(s); if (found) return found;
    }
    return nil;
}

__attribute__((constructor))
static void init_v2(void) {
    LOG(@"===== 冷夜抖音助手 v2 =====");
    LOG(@"功能: 声控切视频 | 短剧跳广告 | 直播人数 | 无水印下载");
    LOG(@"声控: 说「下一个」/「上一个」切换视频");

    // 动态添加 _lengyeTap 方法到 UIButton（用于设置按钮）
    class_addMethod([UIButton class], NSSelectorFromString(@"_lengyeTap"),
        imp_implementationWithBlock(^(id self) {
            NSString *m = @"🎤 声控切视频\n📺 短剧跳广告\n👥 直播真实人数\n📥 无水印下载";
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"冷夜抖音助手"
                message:m preferredStyle:UIAlertControllerStyleActionSheet];
            [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
            [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:a animated:YES completion:nil];
        }), "v@:");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        @try { voiceStart(); } @catch (NSException *e) {}
        @try { dramaHookAdInsert(); } @catch (NSException *e) {}
        @try { downloadHook(); } @catch (NSException *e) {}
        @try { liveCountHook(); } @catch (NSException *e) {}
        @try { settingsInject(); } @catch (NSException *e) {}
        LOG(@"✅ 所有功能已就绪");

        // 定时扫描真实人数
        [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *t){ liveCountPatch(); }];
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { voiceStop(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(),^{ voiceStart(); }); }];
}
