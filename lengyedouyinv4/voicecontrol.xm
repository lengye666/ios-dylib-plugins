// 冷夜抖音助手 v4.1 — 声控模块（默认关闭）
// 由设置页开关控制

#import <UIKit/UIKit.h>
#import <Speech/Speech.h>

static AVAudioEngine *_a = nil; static SFSpeechRecognizer *_r = nil;
static SFSpeechAudioBufferRecognitionRequest *_q = nil; static BOOL _on = NO;

static UIWindow *vk(void){for(UIScene*s in[UIApplication sharedApplication].connectedScenes)if([s isKindOfClass:[UIWindowScene class]])for(UIWindow*w in[(UIWindowScene*)s windows])if(w.isKeyWindow)return w;return[UIApplication sharedApplication].windows.firstObject;}
static UIScrollView *vf(UIView*r){for(UIView*s in r.subviews){if([s isKindOfClass:[UIScrollView class]]&&s.frame.size.height>300&&![s isKindOfClass:[UITableView class]]){UIScrollView*v=(UIScrollView*)s;if(v.contentSize.height>v.frame.size.height*2)return v;}UIScrollView*f=vf(s);if(f)return f;}return nil;}
static void vd(void){UIWindow*w=vk();if(!w)return;UIScrollView*s=vf(w);if(s)[s setContentOffset:CGPointMake(0,s.contentOffset.y+s.frame.size.height)animated:YES];}
static void vu(void){UIWindow*w=vk();if(!w)return;UIScrollView*s=vf(w);if(s)[s setContentOffset:CGPointMake(0,MAX(0,s.contentOffset.y-s.frame.size.height))animated:YES];}
static void vt(void){UIWindow*w=vk();if(!w)return;UIView*t=[w hitTest:CGPointMake(w.frame.size.width/2,w.frame.size.height/2)withEvent:nil];if([t isKindOfClass:[UIControl class]]){[(UIControl*)t sendActionsForControlEvents:UIControlEventTouchUpInside];usleep(150000);[(UIControl*)t sendActionsForControlEvents:UIControlEventTouchUpInside];}}

void voiceStart(void) {
    if (_on) return;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s){if(s!=SFSpeechRecognizerAuthorizationStatusAuthorized)return;
    dispatch_async(dispatch_get_main_queue(),^{
        _r=[[SFSpeechRecognizer alloc]initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
        if(!_r||!_r.isAvailable)return;
        _a=[[AVAudioEngine alloc]init];_q=[[SFSpeechAudioBufferRecognitionRequest alloc]init];_q.shouldReportPartialResults=YES;
        [_a.inputNode installTapOnBus:0 bufferSize:1024 format:[_a.inputNode outputFormatForBus:0] block:^(AVAudioPCMBuffer*b,AVAudioTime*t){[_q appendAudioPCMBuffer:b];}];
        [_a prepare];[_a startAndReturnError:nil];
        [_r recognitionTaskWithRequest:_q resultHandler:^(SFSpeechRecognitionResult*r,NSError*e){if(!r)return;NSString*t=r.bestTranscription.formattedString.lowercaseString;
            if([t containsString:@"下一个"])dispatch_async(dispatch_get_main_queue(),^{vd();});
            else if([t containsString:@"上一个"])dispatch_async(dispatch_get_main_queue(),^{vu();});
            else if([t containsString:@"点赞"])dispatch_async(dispatch_get_main_queue(),^{vt();});
        }];
        _on=YES;NSLog(@"[冷夜] 🎤 语音已开启");
    });}];
}
void voiceStop(void) {if(!_on)return;[_a stop];[_a.inputNode removeTapOnBus:0];[_q endAudio];_q=nil;_r=nil;_a=nil;_on=NO;NSLog(@"[冷夜] 🎤 语音已关闭");}

__attribute__((constructor))
static void vcInit(void) {
    NSLog(@"[冷夜] 声控模块待命 — 请到设置中开启");
    // 默认不启动

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){voiceStop();}];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"len_voice"])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{voiceStart();});
    }];
}
