// 冷夜抖音助手 v4.1 — 默认关闭，手动开启
// 设置页：原生 TableView + Switch，注入到抖音设置

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ============================================================
// 配置存储
// ============================================================
static BOOL lenBool(NSString *k) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:[@"len_" stringByAppendingString:k]];
}
static void lenSet(NSString *k, BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:[@"len_" stringByAppendingString:k]];
}

// ============================================================
// 设置页 VC
// ============================================================
@interface LengyeSettingsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) NSArray *items;
@end

@implementation LengyeSettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"冷夜抖音助手";

    // 适配暗色模式
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tv.delegate = self;
    self.tv.dataSource = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tv];

    self.items = @[
        @{@"t":@"🎤 语音切视频", @"d":@"说「下一个」「上一个」切换视频，说「点赞」双击点赞", @"k":@"voice"},
        @{@"t":@"📺 短剧跳广告", @"d":@"自动跳过短剧集间的激励广告", @"k":@"drama"},
    ];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *id = @"c";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:id];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *item = self.items[ip.row];
    c.textLabel.text = item[@"t"];
    c.detailTextLabel.text = item[@"d"];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.numberOfLines = 2;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = lenBool(item[@"k"]);
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (void)toggle:(UISwitch *)sw {
    NSDictionary *item = self.items[sw.tag];
    lenSet(item[@"k"], sw.on);
    NSLog(@"[冷夜] %@ → %@", item[@"t"], sw.on ? @"开" : @"关");

    // 立即生效
    if ([item[@"k"] isEqualToString:@"voice"]) {
        if (sw.on) voiceStart(); else voiceStop();
    }
    // drama 开关由 hook 里的 lenBool 实时检查
}

@end

// ============================================================
// 设置入口 — 注入抖音设置页
// ============================================================

%hook AWESettingsViewModel
- (NSArray *)sectionDataArray {
    NSArray *orig = %orig;
    for (id sec in orig) {
        if ([[sec valueForKey:@"sectionHeaderTitle"] isEqualToString:@"冷夜助手"]) return orig;
    }

    id item = [[%c(AWESettingItemModel) alloc] init];
    [item setValue:@"LengyeSettings" forKey:@"identifier"];
    [item setValue:@"⚡ 冷夜抖音助手" forKey:@"title"];
    [item setValue:@"" forKey:@"detail"];
    [item setValue:@0 forKey:@"type"];
    [item setValue:@"ic_sapling_outlined" forKey:@"svgIconImageName"];
    [item setValue:@26 forKey:@"cellType"];
    [item setValue:@2 forKey:@"colorStyle"];
    [item setValue:@YES forKey:@"isEnable"];
    [item setValue:^{
        LengyeSettingsVC *vc = [[LengyeSettingsVC alloc] init];
        UIViewController *root = [self valueForKey:@"controllerDelegate"];
        if (!root) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
                if ([s isKindOfClass:[UIWindowScene class]])
                    root = [(UIWindowScene *)s windows].firstObject.rootViewController;
        }
        while (root.presentedViewController) root = root.presentedViewController;
        if ([root isKindOfClass:[UINavigationController class]])
            [(UINavigationController *)root pushViewController:vc animated:YES];
        else if (root.navigationController)
            [root.navigationController pushViewController:vc animated:YES];
    } forKey:@"cellTappedBlock"];

    id section = [[%c(AWESettingSectionModel) alloc] init];
    [section setValue:@[item] forKey:@"itemArray"];
    [section setValue:@0 forKey:@"type"];
    [section setValue:@40 forKey:@"sectionHeaderHeight"];

    NSMutableArray *new = [NSMutableArray arrayWithArray:orig];
    [new insertObject:section atIndex:0];
    return new;
}
%end

// ============================================================
// 短剧跳广告 — %hook 真实类名，读取开关
// ============================================================

%hook AWEShowPlayletImpl.RTSAdInsertUtil
- (void)insertAd:(id)adModel {
    if (!lenBool(@"drama")) { %orig; return; }
    NSLog(@"[冷夜] 📺 跳过短剧广告");
}
%end

%hook AWEShowPlayletImpl.RTSFeedPlayletAutoPlayViewModel
- (void)playNextEpisode {
    if (!lenBool(@"drama")) { %orig; return; }
    %orig;
    NSLog(@"[冷夜] 📺 自动下一集");
}
%end

%hook AWEAwemeAutoUnlockRewardedAdvertisingController
- (void)showAd {
    if (!lenBool(@"drama")) { %orig; return; }
    NSLog(@"[冷夜] 📺 跳过解锁广告");
}
%end

// ============================================================
// 播放结束 → 自动切集 兜底
// ============================================================
__attribute__((constructor))
static void initV4(void) {
    NSLog(@"[冷夜] v4.1 加载 — 所有功能默认关闭");
    NSLog(@"[冷夜] 抖音设置 → 冷夜抖音助手 → 手动开启");

    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (!lenBool(@"drama")) return;
        AVPlayerItem *item = n.object;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            for (CALayer *l in w.layer.sublayers) {
                if ([l isKindOfClass:[AVPlayerLayer class]]) {
                    AVPlayer *p = [(AVPlayerLayer *)l player];
                    if (p.currentItem == item && [p isKindOfClass:[AVQueuePlayer class]]) {
                        [(AVQueuePlayer *)p advanceToNextItem];
                        return;
                    }
                }
            }
        }
    }];
}
