/**
 * 冷夜抖音助手 v4.2 — 默认关闭 + 抖音设置页开关
 * 编译: clang (不用 Theos)
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <objc/runtime.h>

#define LOG(fmt,...) NSLog(@"[冷夜] " fmt, ##__VA_ARGS__)

static BOOL lenBOOL(NSString*k){return[[NSUserDefaults standardUserDefaults]boolForKey:[@"len_" stringByAppendingString:k]];}

// ============================================================
// 声控 (默认关)
// ============================================================
static AVAudioEngine *gAE=nil;static SFSpeechRecognizer *gSR=nil;static SFSpeechAudioBufferRecognitionRequest *gRQ=nil;static BOOL gVo=NO;
static UIWindow *kw(void){for(UIScene*s in[UIApplication sharedApplication].connectedScenes)if([s isKindOfClass:[UIWindowScene class]])for(UIWindow*w in[(UIWindowScene*)s windows])if(w.isKeyWindow)return w;return[UIApplication sharedApplication].windows.firstObject;}
static UIScrollView*fs(UIView*r){for(UIView*s in r.subviews){if([s isKindOfClass:[UIScrollView class]]&&s.frame.size.height>300&&![s isKindOfClass:[UITableView class]]){UIScrollView*v=(UIScrollView*)s;if(v.contentSize.height>v.frame.size.height*2)return v;}UIScrollView*f=fs(s);if(f)return f;}return nil;}
static void vcStart(void){if(gVo)return;[SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st){if(st!=SFSpeechRecognizerAuthorizationStatusAuthorized)return;dispatch_async(dispatch_get_main_queue(),^{gSR=[[SFSpeechRecognizer alloc]initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];if(!gSR||!gSR.isAvailable)return;gAE=[[AVAudioEngine alloc]init];gRQ=[[SFSpeechAudioBufferRecognitionRequest alloc]init];gRQ.shouldReportPartialResults=YES;[gAE.inputNode installTapOnBus:0 bufferSize:1024 format:[gAE.inputNode outputFormatForBus:0] block:^(AVAudioPCMBuffer*b,AVAudioTime*t){[gRQ appendAudioPCMBuffer:b];}];[gAE prepare];[gAE startAndReturnError:nil];[gSR recognitionTaskWithRequest:gRQ resultHandler:^(SFSpeechRecognitionResult*r,NSError*e){if(!r)return;NSString*t=r.bestTranscription.formattedString.lowercaseString;if([t containsString:@"下一个"])dispatch_async(dispatch_get_main_queue(),^{UIWindow*w=kw();UIScrollView*s=fs(w);if(s)[s setContentOffset:CGPointMake(0,s.contentOffset.y+s.frame.size.height)animated:YES];});else if([t containsString:@"上一个"])dispatch_async(dispatch_get_main_queue(),^{UIWindow*w=kw();UIScrollView*s=fs(w);if(s)[s setContentOffset:CGPointMake(0,MAX(0,s.contentOffset.y-s.frame.size.height))animated:YES];});else if([t containsString:@"点赞"])dispatch_async(dispatch_get_main_queue(),^{UIWindow*w=kw();UIView*v=[w hitTest:CGPointMake(w.frame.size.width/2,w.frame.size.height/2)withEvent:nil];if([v isKindOfClass:[UIControl class]]){[(UIControl*)v sendActionsForControlEvents:UIControlEventTouchUpInside];usleep(150000);[(UIControl*)v sendActionsForControlEvents:UIControlEventTouchUpInside];}});}];gVo=YES;LOG(@"🎤 语音已开启");});}];}
static void vcStop(void){if(!gVo)return;[gAE stop];[gAE.inputNode removeTapOnBus:0];[gRQ endAudio];gRQ=nil;gSR=nil;gAE=nil;gVo=NO;LOG(@"🎤 语音已关闭");}
static void vcToggle(void){if(lenBOOL(@"voice"))vcStart();else vcStop();}

// ============================================================
// 设置页
// ============================================================
@interface LengyeSettingsVC: UIViewController<UITableViewDelegate,UITableViewDataSource>
@property(nonatomic,strong)UITableView*tv;@property(nonatomic,strong)NSArray*items;
@end
@implementation LengyeSettingsVC
- (void)viewDidLoad{[super viewDidLoad];self.title=@"冷夜抖音助手";self.view.backgroundColor=[UIColor systemBackgroundColor];
 self.tv=[[UITableView alloc]initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];self.tv.delegate=self;self.tv.dataSource=self;self.tv.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:self.tv];
 self.items=@[@{@"t":@"🎤 语音切视频",@"d":@"说「下一个」「上一个」切换视频",@"k":@"voice"},@{@"t":@"📺 短剧跳广告",@"d":@"自动跳过短剧激励广告",@"k":@"drama"}];}
-(NSInteger)tableView:(UITableView*)tv numberOfRowsInSection:(NSInteger)s{return self.items.count;}
-(UITableViewCell*)tableView:(UITableView*)tv cellForRowAtIndexPath:(NSIndexPath*)ip{static NSString*id=@"c";UITableViewCell*c=[tv dequeueReusableCellWithIdentifier:id];if(!c){c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];c.selectionStyle=UITableViewCellSelectionStyleNone;}NSDictionary*item=self.items[ip.row];c.textLabel.text=item[@"t"];c.detailTextLabel.text=item[@"d"];c.detailTextLabel.textColor=[UIColor secondaryLabelColor];c.detailTextLabel.numberOfLines=2;UISwitch*sw=[[UISwitch alloc]init];sw.on=lenBOOL(item[@"k"]);sw.tag=ip.row;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;return c;}
-(void)toggle:(UISwitch*)sw{NSDictionary*item=self.items[sw.tag];[[NSUserDefaults standardUserDefaults]setBool:sw.on forKey:[@"len_" stringByAppendingString:item[@"k"]]];LOG(@"⚙️ %@→%@",item[@"t"],sw.on?@"开":@"关");if([item[@"k"] isEqualToString:@"voice"])vcToggle();}
@end

// ============================================================
// 设置注入 — hook AWESettingsViewModel (运行时交换)
// ============================================================
static void injectSettings(void){
    Class svm=NSClassFromString(@"AWESettingsViewModel");if(!svm)return;
    SEL sel=NSSelectorFromString(@"sectionDataArray");
    Method m=class_getInstanceMethod(svm,sel);if(!m)return;
    IMP o=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^(id self){
        NSArray*orig=((NSArray*(*)(id,SEL))o)(self,sel);
        for(id sec in orig)if([(NSString*)[sec valueForKey:@"sectionHeaderTitle"] isEqualToString:@"冷夜助手"])return orig;
        id item=[[NSClassFromString(@"AWESettingItemModel") alloc]init];
        [item setValue:@"Lengye" forKey:@"identifier"];[item setValue:@"⚡ 冷夜抖音助手" forKey:@"title"];
        [item setValue:@"" forKey:@"detail"];[item setValue:@0 forKey:@"type"];
        [item setValue:@"ic_sapling_outlined" forKey:@"svgIconImageName"];
        [item setValue:@26 forKey:@"cellType"];[item setValue:@2 forKey:@"colorStyle"];[item setValue:@YES forKey:@"isEnable"];
        [item setValue:^{
            LengyeSettingsVC*vc=[[LengyeSettingsVC alloc]init];
            UIViewController*r=self;while([r isKindOfClass:[UIView class]]||![r isKindOfClass:[UIViewController class]])
                r=[r valueForKey:@"controllerDelegate"]?:[r valueForKey:@"delegate"];
            if(![r isKindOfClass:[UIViewController class]]){r=kw().rootViewController;while(r.presentedViewController)r=r.presentedViewController;}
            if([r isKindOfClass:[UINavigationController class]])[(UINavigationController*)r pushViewController:vc animated:YES];
            else if(r.navigationController)[r.navigationController pushViewController:vc animated:YES];
        } forKey:@"cellTappedBlock"];
        id section=[[NSClassFromString(@"AWESettingSectionModel") alloc]init];
        [section setValue:@[item] forKey:@"itemArray"];[section setValue:@0 forKey:@"type"];[section setValue:@40 forKey:@"sectionHeaderHeight"];
        NSMutableArray*na=[NSMutableArray arrayWithArray:orig];[na insertObject:section atIndex:0];return na;
    }));
    LOG(@"⚙️ 设置注入完成");
}

// ============================================================
// 短剧跳广告 — hook 真实类名（运行时交换）
// ============================================================
static void dramaHook(void){
    NSArray*sels=@[@"insertAd:",@"playNextEpisode",@"showAd"];
    NSArray*names=@[@"AWEShowPlayletImpl.RTSAdInsertUtil",@"AWEShowPlayletImpl.RTSFeedPlayletAutoPlayViewModel",@"AWEAwemeAutoUnlockRewardedAdvertisingController"];
    for(NSInteger i=0;i<names.count;i++){
        Class cls=NSClassFromString(names[i]);if(!cls)continue;
        SEL sel=NSSelectorFromString(sels[i]);Method m=class_getInstanceMethod(cls,sel);if(!m)continue;
        IMP o=method_getImplementation(m);
        method_setImplementation(m,imp_implementationWithBlock(^(id self,id arg){
            if(!lenBOOL(@"drama")){((void(*)(id,SEL,id))o)(self,sel,arg);return;}
            LOG(@"📺 跳过广告: %@",NSStringFromClass(cls));
        }));
        LOG(@"📺 Hooked: %@",names[i]);
    }
    // 兜底: AVPlayer结束自动切
    [[NSNotificationCenter defaultCenter]addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){if(!lenBOOL(@"drama"))return;AVPlayerItem*item=n.object;for(UIWindow*w in[UIApplication sharedApplication].windows)for(CALayer*l in w.layer.sublayers)if([l isKindOfClass:[AVPlayerLayer class]]){AVPlayer*p=[(AVPlayerLayer*)l player];if(p.currentItem==item&&[p isKindOfClass:[AVQueuePlayer class]]){[(AVQueuePlayer*)p advanceToNextItem];return;}}}];
}

// ============================================================
// 入口
// ============================================================
__attribute__((constructor))
static void init42(void){
    LOG(@"v4.2 加载 — 所有功能默认关闭");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        injectSettings();
        dramaHook();
        LOG(@"✅ 已就绪 — 抖音设置 → 冷夜抖音助手 → 手动开启");
    });
    [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){vcStop();}];
    [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){if(lenBOOL(@"voice"))dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{vcStart();});}];
}
