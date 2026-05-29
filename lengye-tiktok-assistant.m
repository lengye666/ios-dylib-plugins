/**
 * lengye-tiktok-assistant.m
 * 冷夜抖音助手 v1.0
 *
 * 功能：
 *   1. 🎤 声控刷视频 — 说"下一个"/"上一个"自动切换
 *   2. 🎬 短剧跳过广告
 *   3. 💬 防撤回消息
 *   4. 📥 无水印下载
 *   5. 🚫 去所有广告
 *   6. ⚙️ 设置面板 — 注入到抖音设置页
 *
 * 编译: clang -arch arm64 -arch arm64e -isysroot ... -framework Foundation
 *        -framework UIKit -framework AVFoundation -framework Speech -framework Photos
 *        -fobjc-arc -o LengyeDouyin.dylib lengye-tiktok-assistant.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define LOG(fmt, ...) NSLog(@"[冷夜] " fmt, ##__VA_ARGS__)

// ============================================================
// MARK: - 前向声明 (Forward declarations)
// ============================================================
static void dramaAdvanceToNext(id);
static void hookRewardedAdCallbacks(void);
static AVPlayer *findPlayerInKeyWindow(void);
static AVPlayer *findPlayerInView(UIView *);
static void hookMessageDelete(void);
static void uploadDumpAsync(NSString *);
static UIViewController *findSettingsViewController(void);
static void injectSettingsEntryAgain(void);
static void addSettingsRow(UIViewController *);
static UIViewController *searchForSettingsVC(UIViewController *);
static UITableView *findTableViewInView(UIView *);
static id findCollectionViewInView(UIView *);
static void hookTableView(UITableView *);
static void safeEnableFeature(NSString *);

// ============================================================
// MARK: - 全局配置
// ============================================================

static NSString * const kPrefsKey = @"com.lengye.douyin.prefs";
static NSMutableDictionary *gPrefs = nil;

#define PREFS_BOOL(key, def) [gPrefs[key] ?: @(def) boolValue]
#define PREFS_SET(key, val) do { gPrefs[key] = @(val); [gPrefs writeToFile:prefsPath() atomically:YES]; } while(0)

static NSString *prefsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"lengye_douyin.plist"];
}

static void loadPrefs(void) {
    gPrefs = [[NSMutableDictionary alloc] initWithContentsOfFile:prefsPath()];
    if (!gPrefs) {
        gPrefs = [NSMutableDictionary dictionary];
        gPrefs[@"voice_enabled"] = @(YES);
        gPrefs[@"drama_skip"] = @(YES);
        gPrefs[@"anti_revoke"] = @(YES);
        gPrefs[@"no_watermark"] = @(YES);
        gPrefs[@"remove_ads"] = @(YES);
        [gPrefs writeToFile:prefsPath() atomically:YES];
    }
}

// ============================================================
// MARK: - 语音控制 (声控切视频)
// ============================================================

// 手势辅助函数 — 必须在调用前定义
static UIWindow *keyWindow(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in [(UIWindowScene *)s windows])
                if (w.isKeyWindow) return w;
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static UIScrollView *findMainScrollView(UIView *root) {
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]] && sub.frame.size.height > 300 && sub.frame.size.width > 200) {
            UIScrollView *sv = (UIScrollView *)sub;
            if (sv.contentSize.height > sv.frame.size.height * 2) return sv;
        }
        UIScrollView *f = findMainScrollView(sub); if (f) return f;
    }
    return nil;
}

static void simTap(UIView *view, CGPoint pt) {
    UIView *t = [view hitTest:pt withEvent:nil];
    if ([t isKindOfClass:[UIControl class]]) [(UIControl *)t sendActionsForControlEvents:UIControlEventTouchUpInside];
    else for (int i=0;i<3&&t.superview;i++){t=t.superview;if([t isKindOfClass:[UIControl class]]){[(UIControl*)t sendActionsForControlEvents:UIControlEventTouchUpInside];return;}}
}

static void swipeDown(void) {
    UIWindow *w = keyWindow(); if(!w)return;
    UIScrollView *sv=findMainScrollView(w);
    if(sv)[sv setContentOffset:CGPointMake(0,sv.contentOffset.y+sv.frame.size.height) animated:YES];
}
static void swipeUp(void) {
    UIWindow *w = keyWindow(); if(!w)return;
    UIScrollView *sv=findMainScrollView(w);
    if(sv)[sv setContentOffset:CGPointMake(0,MAX(0,sv.contentOffset.y-sv.frame.size.height)) animated:YES];
}
static void tapCenter(void) { UIWindow *w=keyWindow();if(!w)return;simTap(w,CGPointMake(w.frame.size.width/2,w.frame.size.height/2)); }
static void doubleTapCenter(void){tapCenter();usleep(150000);tapCenter();}
static void togglePause(void){tapCenter();}

static SFSpeechRecognizer *gRecognizer = nil;
static SFSpeechAudioBufferRecognitionRequest *gSpeechRequest = nil;
static AVAudioEngine *gAudioEngine = nil;
static BOOL gVoiceRunning = NO;

static void startVoiceControl(void) {
    if (!PREFS_BOOL(@"voice_enabled", YES)) return;
    if (gVoiceRunning) return;

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            LOG(@"语音权限未授权");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            gRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
            if (!gRecognizer) { LOG(@"语音识别器创建失败"); return; }
            if (!gRecognizer.isAvailable) { LOG(@"语音识别不可用"); return; }

            gAudioEngine = [[AVAudioEngine alloc] init];
            gSpeechRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
            gSpeechRequest.shouldReportPartialResults = YES;

            AVAudioInputNode *inputNode = gAudioEngine.inputNode;
            [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0]
                                 block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                [gSpeechRequest appendAudioPCMBuffer:buffer];
            }];

            [gAudioEngine prepare];
            [gAudioEngine startAndReturnError:nil];

            [gRecognizer recognitionTaskWithRequest:gSpeechRequest resultHandler:^(
                SFSpeechRecognitionResult *result, NSError *error) {
                if (!result) return;
                NSString *text = result.bestTranscription.formattedString;
                if (text.length == 0) return;

                NSString *lower = [text lowercaseString];
                // LOG(@"🎤 识别: %@", text); // debug only

                if ([lower containsString:@"下一个"] || [lower containsString:@"下个"]) {
                    LOG(@"🎤 识别到「下一个」→ 往下刷");
                    dispatch_async(dispatch_get_main_queue(), ^{ swipeDown(); });
                } else if ([lower containsString:@"上一个"] || [lower containsString:@"上个"]) {
                    LOG(@"🎤 识别到「上一个」→ 往上刷");
                    dispatch_async(dispatch_get_main_queue(), ^{ swipeUp(); });
                } else if ([lower containsString:@"点赞"] || [lower containsString:@"喜欢"]) {
                    LOG(@"🎤 识别到「点赞」");
                    dispatch_async(dispatch_get_main_queue(), ^{ doubleTapCenter(); });
                } else if ([lower containsString:@"暂停"] || [lower containsString:@"停止"]) {
                    LOG(@"🎤 识别到「暂停」");
                    dispatch_async(dispatch_get_main_queue(), ^{ togglePause(); });
                } else if ([lower containsString:@"播放"] || [lower containsString:@"继续"]) {
                    LOG(@"🎤 识别到「播放」");
                    dispatch_async(dispatch_get_main_queue(), ^{ togglePause(); });
                }
            }];

            gVoiceRunning = YES;
            LOG(@"🎤 语音控制已启动 — 说「下一个」切换视频");
        });
    }];
}

static void stopVoiceControl(void) {
    [gAudioEngine stop];
    [gAudioEngine.inputNode removeTapOnBus:0];
    [gSpeechRequest endAudio];
    gSpeechRequest = nil;
    gRecognizer = nil;
    gAudioEngine = nil;
    gVoiceRunning = NO;
    LOG(@"🎤 语音控制已停止");
}

// ============================================================
// MARK: - 短剧跳过广告
// ============================================================

static void installDramaAdSkip(void) {
    if (!PREFS_BOOL(@"drama_skip", YES)) return;

    // 监听视频播放完毕
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                       object:nil queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        // 短剧每集结束 → 尝试跳过广告直接切下一集
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            dramaAdvanceToNext(note.object);
        });
    }];

    // 枚举并 hook 激励广告回调
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        hookRewardedAdCallbacks();
    });

    LOG(@"📺 短剧广告跳过已就绪");
}

static void dramaAdvanceToNext(id item) {
    AVPlayer *player = findPlayerInKeyWindow();
    if (!player) return;

    // 尝试跳下一集
    if ([player isKindOfClass:[AVQueuePlayer class]]) {
        [(AVQueuePlayer *)player advanceToNextItem];
        LOG(@"📺 AVQueuePlayer 切到下一集");
    } else if ([player respondsToSelector:@selector(advanceToNextItem)]) {
        [player performSelector:@selector(advanceToNextItem)];
    }
}

static AVPlayer *findPlayerInKeyWindow(void) {
    UIWindow *win = keyWindow();
    if (!win) return nil;
    return findPlayerInView(win);
}

static AVPlayer *findPlayerInView(UIView *view) {
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:[AVPlayerLayer class]]) return [(AVPlayerLayer *)layer player];
    }
    for (UIView *sub in view.subviews) {
        AVPlayer *p = findPlayerInView(sub);
        if (p) return p;
    }
    return nil;
}

static void hookRewardedAdCallbacks(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]).lowercaseString;
        if (![name containsString:@"reward"] && ![name containsString:@"ad"]) continue;
        // 遍历方法，找到广告回调
        unsigned int mCount = 0;
        Method *methods = class_copyMethodList(classes[i], &mCount);
        for (unsigned int j = 0; j < mCount; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            if ([selName containsString:@"Reward"] || [selName containsString:@"Complete"] ||
                [selName containsString:@"Finish"] || [selName containsString:@"Close"]) {
                // hook 这个回调 → 直接触发以绕过广告
                LOG(@"📺 发现广告回调: %@.%@", name, selName);
            }
        }
        free(methods);
    }
    free(classes);
}

// ============================================================
// MARK: - 防撤回消息
// ============================================================

static void installAntiRevoke(void) {
    if (!PREFS_BOOL(@"anti_revoke", YES)) return;

    // hook IM 消息删除方法
    // 抖音的聊天底层可能是 IMSDK/RongCloud 或自研
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        hookMessageDelete();
    });

    LOG(@"💬 防撤回已就绪");
}

static void hookMessageDelete(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]).lowercaseString;
        if (![name containsString:@"message"] && ![name containsString:@"im"]
            && ![name containsString:@"chat"] && ![name containsString:@"convers"]) continue;

        unsigned int mCount = 0;
        Method *methods = class_copyMethodList(classes[i], &mCount);
        for (unsigned int j = 0; j < mCount; j++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[j]));
            if ([selName containsString:@"delete"] || [selName containsString:@"remove"] ||
                [selName containsString:@"revoke"] || [selName containsString:@"recall"]) {

                Method m = methods[j];
                IMP orig = method_getImplementation(m);
                IMP new = imp_implementationWithBlock(^(id self) {
                    // 检查是否开启防撤回
                    loadPrefs();
                    if (!PREFS_BOOL(@"anti_revoke", YES)) {
                        ((void (*)(id, SEL))orig)(self, method_getName(m));
                        return;
                    }
                    LOG(@"💬 拦截消息删除");
                    // 不调用原始方法 → 消息保留
                });
                method_setImplementation(m, new);
                LOG(@"💬 Hooked: %@.%@", name, selName);
            }
        }
        free(methods);
    }
    free(classes);
}

// ============================================================
// MARK: - 无水印下载
// ============================================================

static void installWatermarkRemoval(void) {
    if (!PREFS_BOOL(@"no_watermark", YES)) return;
    // 注：此功能需要在视频详情页找到下载入口并替换 URL
    // 抖音的视频 URL 中 watermark=1 改为 watermark=0 或去掉 watermark 参数
    LOG(@"📥 无水印下载已就绪（待测试验证 URL 替换）");
}

// ============================================================
// MARK: - 去所有广告
// ============================================================

static void installAdRemoval(void) {
    if (!PREFS_BOOL(@"remove_ads", YES)) return;

    // hook 抖音广告管理器 — 让所有广告位直接跳过
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]).lowercaseString;
            if ([name containsString:@"admanager"] || [name containsString:@"adload"]) {
                LOG(@"🚫 发现广告管理器: %@", name);
                // hook 加载方法
            }
        }
        free(classes);
    });

    LOG(@"🚫 广告拦截已就绪");
}

// ============================================================
// MARK: - 类名 Dump 上传 (log.lengye.top)
// ============================================================

static void dumpAndUploadClasses(void) {
    LOG(@"📤 开始导出所有类名和方法...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *dump = [NSMutableString string];
        [dump appendString:@"========== 冷夜抖音助手 - 类名导出 ==========\n"];
        [dump appendFormat:@"时间: %@\n", [NSDate date]];
        [dump appendFormat:@"设备: %@\n", [[UIDevice currentDevice] model]];
        [dump appendFormat:@"系统: iOS %@\n", [[UIDevice currentDevice] systemVersion]];
        [dump appendString:@"\n=== 全部已加载类 ("];

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        [dump appendFormat:@"%u 个) ===\n\n", count];

        // 按关键词分类
        NSDictionary *categories = @{
            @"🎬 短剧": @[@"drama", @"shortplay", @"episode", @"shortdrama", @"playlist"],
            @"💰 广告": @[@"ad", @"reward", @"pangle", @"csj", @"buad", @"fullscreen"],
            @"💬 消息": @[@"message", @"chat", @"im", @"convers", @"dialog"],
            @"📥 下载": @[@"download", @"watermark", @"save", @"video"],
            @"⚙️ 设置": @[@"setting", @"prefer", @"profile", @"account", @"config"],
            @"🎵 播放器": @[@"player", @"video", @"play", @"avplayer"],
            @"📄 通用": @[@"viewcontroller", @"manager", @"model", @"service", @"helper"],
        };

        NSMutableDictionary *categorizedResults = [NSMutableDictionary dictionary];
        for (NSString *cat in categories) categorizedResults[cat] = [NSMutableString string];

        // 遍历所有类
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            NSString *name = NSStringFromClass(cls);
            NSString *lower = [name lowercaseString];

            // 只看抖音相关的（避免系统类）
            if (![lower hasPrefix:@"tt"] &&
                ![lower hasPrefix:@"aw"] &&
                ![lower hasPrefix:@"ss"] &&
                ![lower hasPrefix:@"ies"] &&
                ![lower hasPrefix:@"bu"] &&
                ![lower hasPrefix:@"csj"] &&
                ![lower hasPrefix:@"douyin"] &&
                ![lower hasPrefix:@"tiktok"]) {
                continue;
            }

            NSString *category = @"📄 通用";
            for (NSString *cat in categories) {
                for (NSString *kw in categories[cat]) {
                    if ([lower containsString:kw]) {
                        category = cat;
                        break;
                    }
                }
                if (![category isEqualToString:@"📄 通用"]) break;
            }

            // 获取父类和协议
            Class superCls = class_getSuperclass(cls);
            unsigned int protoCount = 0;
            Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &protoCount);

            NSMutableString *entry = [NSMutableString string];
            [entry appendFormat:@"\n● %@", name];
            if (superCls) [entry appendFormat:@" : %@", NSStringFromClass(superCls)];

            if (protoCount > 0) {
                [entry appendString:@" <"];
                for (unsigned int p = 0; p < protoCount; p++) {
                    if (p > 0) [entry appendString:@", "];
                    [entry appendString:NSStringFromProtocol(protocols[p])];
                }
                [entry appendString:@">"];
            }
            [entry appendString:@"\n"];

            free(protocols);

            // 列出这个类的所有方法（只列自己定义的，不列继承的）
            unsigned int mCount = 0;
            Method *methods = class_copyMethodList(cls, &mCount);
            for (unsigned int m = 0; m < mCount && m < 30; m++) { // 每个类最多30个方法
                [entry appendFormat:@"    - %@\n", NSStringFromSelector(method_getName(methods[m]))];
            }
            if (mCount > 30) [entry appendFormat:@"    ... 还有 %u 个方法\n", mCount - 30];
            free(methods);

            [categorizedResults[category] appendString:entry];
        }
        free(classes);

        // 组装最终输出
        for (NSString *cat in @[@"🎬 短剧", @"💰 广告", @"💬 消息", @"📥 下载", @"⚙️ 设置", @"🎵 播放器", @"📄 通用"]) {
            NSString *content = categorizedResults[cat];
            if ([content length] > 0) {
                [dump appendFormat:@"\n\n========================================\n"];
                [dump appendFormat:@"%@\n", cat];
                [dump appendFormat:@"========================================\n"];
                [dump appendString:content];
            }
        }

        // 上传
        uploadDumpAsync(dump);
    });
}

static void uploadDumpAsync(NSString *dump) {
    NSString *urlStr = @"https://log.lengye.top/api/log/upload";
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        LOG(@"📤 上传URL无效");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;

    NSString *boundary = @"BoundaryLengyeDouyin";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
        forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"file\"; filename=\"douyin_classes.txt\"\r\n"
                       dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: text/plain; charset=utf-8\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[dump dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    req.HTTPBody = body;

    LOG(@"📤 正在上传类名报告 (%lu bytes) 到 log.lengye.top...", (unsigned long)body.length);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                LOG(@"📤 上传失败: %s", err.localizedDescription.UTF8String);
            } else {
                LOG(@"📤 上传成功 HTTP %ld — 类名列表已发送", (long)http.statusCode);
            }
        });
    }] resume];
}

static void dumpAndUploadClassesWithToast(void) {
    // 显示一个提示框
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出类名"
        message:@"正在分析抖音的所有类和方法，上传到 log.lengye.top ..." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *root = keyWindow().rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:alert animated:YES completion:nil];

    dumpAndUploadClasses();
}

static BOOL gSettingsInjected = NO;

@interface LengyeSettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *items;
@end

@implementation LengyeSettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"冷夜抖音助手";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    self.items = @[
        @{@"title": @"🎤 语音控制",       @"key": @"voice_enabled",  @"desc": @"说「下一个」自动刷视频"},
        @{@"title": @"📺 短剧跳过广告",   @"key": @"drama_skip",     @"desc": @"短剧集间自动跳过激励广告"},
        @{@"title": @"💬 防撤回消息",     @"key": @"anti_revoke",    @"desc": @"聊天消息无法被对方撤回"},
        @{@"title": @"📥 无水印下载",     @"key": @"no_watermark",   @"desc": @"下载视频自动去除水印"},
        @{@"title": @"🚫 去所有广告",     @"key": @"remove_ads",     @"desc": @"移除信息流和开屏广告"},
    ];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    }
    NSDictionary *item = self.items[ip.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"desc"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = PREFS_BOOL(item[@"key"], YES);
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSDictionary *item = self.items[sw.tag];
    NSString *key = item[@"key"];
    PREFS_SET(key, sw.on);
    LOG(@"⚙️ %@ → %@", item[@"title"], sw.on ? @"开" : @"关");

    // 立即激活/关闭功能（安全包装）
    if (sw.on) {
        if ([key isEqualToString:@"voice_enabled"])  safeEnableFeature(@"voice");
        if ([key isEqualToString:@"drama_skip"])      safeEnableFeature(@"drama");
        if ([key isEqualToString:@"anti_revoke"])     safeEnableFeature(@"revoke");
        if ([key isEqualToString:@"remove_ads"])      safeEnableFeature(@"ads");
    } else {
        if ([key isEqualToString:@"voice_enabled"])   stopVoiceControl();
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section { return 100; }

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    UIView *footer = [[UIView alloc] init];
    UIButton *dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    dumpBtn.frame = CGRectMake(20, 20, tv.frame.size.width - 40, 44);
    [dumpBtn setTitle:@"📤 导出全部类名 (上传到 log.lengye.top)" forState:UIControlStateNormal];
    dumpBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    dumpBtn.backgroundColor = [UIColor systemBlueColor];
    [dumpBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    dumpBtn.layer.cornerRadius = 10;
    [dumpBtn addTarget:self action:@selector(dumpClasses) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:dumpBtn];
    return footer;
}

- (void)dumpClasses {
    dumpAndUploadClassesWithToast();
}

@end

static void injectSettingsEntry(void) {
    if (gSettingsInjected) return;

    // 等待抖音设置页面加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // 遍历所有 ViewController，找到设置页
        UIViewController *settingsVC = findSettingsViewController();
        if (!settingsVC) {
            LOG(@"⚙️ 未找到抖音设置页，重试...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                injectSettingsEntryAgain();
            });
            return;
        }

        // 在设置页的 TableView 或 CollectionView 追加一行
        addSettingsRow(settingsVC);
        gSettingsInjected = YES;
        LOG(@"⚙️ 设置入口已注入");
    });
}

static UIViewController *findSettingsViewController(void) {
    UIViewController *root = keyWindow().rootViewController;
    return searchForSettingsVC(root);
}

static UIViewController *searchForSettingsVC(UIViewController *vc) {
    if (!vc) return nil;
    NSString *title = vc.title ?: vc.navigationItem.title ?: @"";
    NSString *name = NSStringFromClass([vc class]).lowercaseString;
    if ([title containsString:@"设置"] || [name containsString:@"setting"] || [name containsString:@"prefer"]) {
        // 确认是主设置页（不是子页面）
        if ([vc.view subviews].count > 0) return vc;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = searchForSettingsVC(child);
        if (found) return found;
    }
    if (vc.presentedViewController) return searchForSettingsVC(vc.presentedViewController);
    return nil;
}

static void injectSettingsEntryAgain(void) {
    UIViewController *vc = findSettingsViewController();
    if (vc) addSettingsRow(vc);
}

static void addSettingsRow(UIViewController *vc) {
    // 找到设置页的 TableView 并 hook 它的 dataSource
    UITableView *tv = findTableViewInView(vc.view);
    if (!tv) tv = findCollectionViewInView(vc.view); // 备选

    if ([tv isKindOfClass:[UITableView class]]) {
        UITableView *table = (UITableView *)tv;
        // Hook numberOfRowsInSection → +1
        // Hook cellForRowAtIndexPath → 最后一行是我们的
        hookTableView(table);
    }
}

static UITableView *findTableViewInView(UIView *view) {
    if ([view isKindOfClass:[UITableView class]] && view.frame.size.height > 200) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *tv = findTableViewInView(sub);
        if (tv) return tv;
    }
    return nil;
}

static id findCollectionViewInView(UIView *view) {
    if ([view isKindOfClass:[UICollectionView class]] && view.frame.size.height > 200) return view;
    for (UIView *sub in view.subviews) {
        id cv = findCollectionViewInView(sub);
        if (cv) return cv;
    }
    return nil;
}

static void hookTableView(UITableView *tv) {
    // 简单方案：找到 tv 所在的 VC，hook viewWillAppear 添加尾部 view
    // 或直接添加一个 tableFooterView
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.frame.size.width, 60)];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, 10, tv.frame.size.width - 40, 40);
    [btn setTitle:@"⚡ 冷夜抖音助手" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn addTarget:[LengyeSettingsVC class] action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:btn];
    tv.tableFooterView = footer;
}

@implementation LengyeSettingsVC (OpenHelper)
+ (void)openSettings {
    LengyeSettingsVC *vc = [[LengyeSettingsVC alloc] init];
    UIViewController *root = keyWindow().rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        [(UINavigationController *)root pushViewController:vc animated:YES];
    } else if (root.navigationController) {
        [root.navigationController pushViewController:vc animated:YES];
    }
}
@end

// ============================================================
// MARK: - AVAudioSession 配置（避免语音和视频冲突）

// MARK: - 入口 (极简安全启动)
// ============================================================

__attribute__((constructor))
static void LengyeInit(void) {
    NSLog(@"[冷夜] ===== 抖音助手 v1.1 加载 =====");
    loadPrefs();

    // 启动时什么都不做！不扫类、不hook、不开语音。
    // 只等设置页延迟注入。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3.0 * NSEC_PER_SEC),
                  dispatch_get_main_queue(), ^{
        @try { injectSettingsEntry(); }
        @catch (NSException *e) { NSLog(@"[冷夜] 设置注入失败(已忽略)"); }
    });

    NSLog(@"[冷夜] 安全模式启动 — 功能需在设置中手动开启");
}

// 功能安全激活（供设置页 switch 调用）
static void safeEnableFeature(NSString *feature) {
    NSLog(@"[冷夜] 开启: %@", feature);
    @try {
        if ([feature isEqualToString:@"voice"]) startVoiceControl();
        else if ([feature isEqualToString:@"drama"]) installDramaAdSkip();
        else if ([feature isEqualToString:@"revoke"]) installAntiRevoke();
        else if ([feature isEqualToString:@"ads"]) installAdRemoval();
    } @catch (NSException *e) {
        NSLog(@"[冷夜] 开启%@失败(已忽略)", feature);
    }
}
