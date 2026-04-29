#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ==========================================
// NetworkLogger - 进程内网络请求监控插件
// 通过 NSURLProtocol 拦截所有 HTTP/HTTPS 请求
// 浮窗显示请求列表，支持复制全部日志
// ==========================================

#pragma mark - 数据模型

@interface NWRequest : NSObject
@property (nonatomic, strong) NSString *url;
@property (nonatomic, strong) NSString *method;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSDictionary *requestHeaders;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSString *requestBody;
@property (nonatomic, strong) NSString *responseBody;
@property (nonatomic, strong) NSString *timestamp;
@property (nonatomic, assign) double duration;
@end

@implementation NWRequest @end

#pragma mark - 全局存储

static NSMutableArray<NWRequest *> *NWLoggedRequests;
static UIWindow *NWFloatingWindow;
static BOOL NWIsWindowVisible = NO;
static CGFloat NWScreenW, NWScreenH;

#pragma mark - NSURLProtocol 拦截器

@interface NWLogProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSDate *startTime;
@end

@implementation NWLogProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"NWLogged" inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"NWLogged" inRequest:mutableReq];
    
    // 绕过系统代理，直接连接（避免被系统代理干扰）
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.connectionProxyDictionary = @{};
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    
    self.responseData = [NSMutableData data];
    self.startTime = [NSDate date];
    
    self.task = [session dataTaskWithRequest:mutableReq];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    
    NWRequest *entry = [NWRequest new];
    entry.url = self.request.URL.absoluteString;
    entry.method = self.request.HTTPMethod ?: @"GET";
    entry.statusCode = ((NSHTTPURLResponse *)response).statusCode;
    entry.responseHeaders = ((NSHTTPURLResponse *)response).allHeaderFields;
    entry.requestHeaders = self.request.allHTTPHeaderFields;
    entry.timestamp = [self dateToString:[NSDate date]];
    
    if (self.request.HTTPBody) {
        // 截取前 2KB 请求体
        NSData *body = self.request.HTTPBody.length > 2048
            ? [self.request.HTTPBody subdataWithRange:NSMakeRange(0, 2048)]
            : self.request.HTTPBody;
        entry.requestBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!entry.requestBody) entry.requestBody = @"[binary data]";
    }
    
    [NWLoggedRequests addObject:entry];
    
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    handler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.responseData appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionDataTask *)task didCompleteWithError:(NSError *)error {
    if (NWLoggedRequests.count > 0) {
        NWRequest *lastEntry = NWLoggedRequests.lastObject;
        lastEntry.duration = [[NSDate date] timeIntervalSinceDate:self.startTime] * 1000;
        
        if (self.responseData.length > 0) {
            // 截取前 10KB 响应体
            NSData *truncated = self.responseData.length > 10240
                ? [self.responseData subdataWithRange:NSMakeRange(0, 10240)]
                : self.responseData;
            lastEntry.responseBody = [[NSString alloc] initWithData:truncated encoding:NSUTF8StringEncoding];
            if (!lastEntry.responseBody) lastEntry.responseBody = @"[binary data]";
        }
        
        if (error) {
            lastEntry.responseBody = [NSString stringWithFormat:@"[ERROR] %@", error.localizedDescription];
        }
    }
    
    [self.client URLProtocolDidFinishLoading:self];
}

- (NSString *)dateToString:(NSDate *)date {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    return [fmt stringFromDate:date];
}

@end

#pragma mark - 浮窗按钮

static UIButton *NWBadgeBtn;

static void NWCreateFloatingBadge(void) {
    NWScreenW = [UIScreen mainScreen].bounds.size.width;
    NWScreenH = [UIScreen mainScreen].bounds.size.height;
    
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;
    
    NWFloatingWindow = [[UIWindow alloc] initWithWindowScene:scene];
    NWFloatingWindow.windowLevel = UIWindowLevelStatusBar + 100;
    NWFloatingWindow.backgroundColor = [UIColor clearColor];
    NWFloatingWindow.clipsToBounds = YES;
    NWFloatingWindow.hidden = NO;
    // 允许手势穿透到下层
    NWFloatingWindow.userInteractionEnabled = YES;
    
    CGFloat size = 56;
    NWFloatingWindow.frame = CGRectMake(NWScreenW - size - 8, 50, size, size);
    NWFloatingWindow.layer.cornerRadius = size / 2;
    
    NWBadgeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    NWBadgeBtn.frame = NWFloatingWindow.bounds;
    NWBadgeBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
    NWBadgeBtn.layer.cornerRadius = size / 2;
    NWBadgeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [NWBadgeBtn setTitle:@"📡 0" forState:UIControlStateNormal];
    [NWBadgeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    
    // 拖动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:nil];
    __block CGPoint lastTouch;
    [pan addTarget:[NSBlockOperation blockOperationWithBlock:^{
        if (pan.state == UIGestureRecognizerStateBegan) {
            lastTouch = [pan locationInView:NWFloatingWindow];
        } else if (pan.state == UIGestureRecognizerStateChanged) {
            CGPoint touch = [pan locationInView:NWFloatingWindow];
            CGPoint origin = NWFloatingWindow.frame.origin;
            origin.x += touch.x - lastTouch.x;
            origin.y += touch.y - lastTouch.y;
            // 限制在屏幕内
            origin.x = MAX(0, MIN(NWScreenW - size, origin.x));
            origin.y = MAX(44, MIN(NWScreenH - size, origin.y));
            NWFloatingWindow.frame = CGRectMake(origin.x, origin.y, size, size);
        }
    }]];
    [NWBadgeBtn addGestureRecognizer:pan];
    
    // 点击展开详情
    [NWBadgeBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{
        NWShowDetailList();
    }] forControlEvents:UIControlEventTouchUpInside];
    
    [NWFloatingWindow addSubview:NWBadgeBtn];
    
    // 定时更新计数
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        NSUInteger count = NWLoggedRequests.count;
        [NWBadgeBtn setTitle:[NSString stringWithFormat:@"📡 %lu", (unsigned long)count]
                    forState:UIControlStateNormal];
    }];
}

#pragma mark - 详情列表

static void NWShowDetailList(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;
    
    UIWindow *detailWindow = [[UIWindow alloc] initWithWindowScene:scene];
    detailWindow.windowLevel = UIWindowLevelAlert + 200;
    detailWindow.frame = [UIScreen mainScreen].bounds;
    detailWindow.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    detailWindow.hidden = NO;
    
    // 半透明背景点击关闭
    UIControl *bg = [[UIControl alloc] initWithFrame:detailWindow.bounds];
    [bg addTarget:[NSBlockOperation blockOperationWithBlock:^{
        [UIView animateWithDuration:0.25 animations:^{
            tableView.alpha = 0;
            container.alpha = 0;
        } completion:^(BOOL f) {
            detailWindow.hidden = YES;
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [detailWindow addSubview:bg];
    
    // 内容容器
    CGFloat containerH = NWScreenH * 0.75;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, NWScreenH, NWScreenW, containerH)];
    container.backgroundColor = [UIColor systemBackgroundColor];
    
    // 顶部工具栏
    CGFloat toolbarH = 50;
    UIView *toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, NWScreenW, toolbarH)];
    toolbar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, NWScreenW * 0.5, toolbarH)];
    title.text = [NSString stringWithFormat:@"Network Logger (%lu)", (unsigned long)NWLoggedRequests.count];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textColor = [UIColor labelColor];
    [toolbar addSubview:title];
    
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(NWScreenW - 120, 8, 50, 34);
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [clearBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{
        [NWLoggedRequests removeAllObjects];
        title.text = @"Network Logger (0)";
        [tableView reloadData];
    }] forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:clearBtn];
    
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(NWScreenW - 60, 8, 50, 34);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [copyBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [copyBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{
        NWCopyAllLogs();
    }] forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:copyBtn];
    
    [container addSubview:toolbar];
    
    // UITableView
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, toolbarH, NWScreenW, containerH - toolbarH)
                                                          style:UITableViewStylePlain];
    tableView.dataSource = (id)[[NWTableDS alloc] init];
    tableView.delegate = (id)[[NWTableDelegate alloc] init];
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 60;
    [container addSubview:tableView];
    
    [detailWindow addSubview:container];
    
    // 动画弹出
    [UIView animateWithDuration:0.3 animations:^{
        container.frame = CGRectMake(0, NWScreenH - containerH, NWScreenW, containerH);
    }];
}

#pragma mark - UITableViewDataSource

@interface NWTableDS : NSObject <UITableViewDataSource>
@end

@implementation NWTableDS

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return NWLoggedRequests.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"NWCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    NWRequest *req = NWLoggedRequests[indexPath.row];
    
    NSString *statusIcon = (req.statusCode >= 200 && req.statusCode < 300) ? @"✅" : @"❌";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@", statusIcon, req.method, req.url];
    
    NSMutableString *detail = [NSMutableString string];
    [detail appendFormat:@"%ld | %.0fms", (long)req.statusCode, req.duration];
    if (req.responseBody.length > 0) {
        NSString *preview = req.responseBody.length > 80
            ? [[req.responseBody substringToIndex:80] stringByAppendingString:@"..."]
            : req.responseBody;
        [detail appendFormat:@"\n%@", preview];
    }
    cell.detailTextLabel.text = detail;
    
    return cell;
}

@end

#pragma mark - UITableViewDelegate

@interface NWTableDelegate : NSObject <UITableViewDelegate>
@end

@implementation NWTableDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NWRequest *req = NWLoggedRequests[indexPath.row];
    NWShowRequestDetail(req);
}

@end

#pragma mark - 请求详情页

static void NWShowRequestDetail(NWRequest *req) {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;
    
    UIWindow *win = [[UIWindow alloc] initWithWindowScene:scene];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.frame = [UIScreen mainScreen].bounds;
    win.backgroundColor = [UIColor systemBackgroundColor];
    win.hidden = NO;
    
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, NWScreenW, NWScreenH - 44)];
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, NWScreenW, NWScreenH - 44)];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tv.textColor = [UIColor labelColor];
    
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"═══ REQUEST ═══\n"];
    [text appendFormat:@"%@ %@\n", req.method, req.url];
    [text appendFormat:@"Time: %@ (%.0fms)\n\n", req.timestamp, req.duration];
    
    if (req.requestHeaders.count > 0) {
        [text appendString:@"── Request Headers ──\n"];
        for (NSString *key in req.requestHeaders) {
            [text appendFormat:@"%@: %@\n", key, req.requestHeaders[key]];
        }
        [text appendString:@"\n"];
    }
    
    if (req.requestBody.length > 0) {
        [text appendString:@"── Request Body ──\n"];
        [text appendFormat:@"%@\n\n", req.requestBody];
    }
    
    [text appendFormat:@"═══ RESPONSE %ld ═══\n\n", (long)req.statusCode];
    
    if (req.responseHeaders.count > 0) {
        [text appendString:@"── Response Headers ──\n"];
        for (NSString *key in req.responseHeaders) {
            [text appendFormat:@"%@: %@\n", key, req.responseHeaders[key]];
        }
        [text appendString:@"\n"];
    }
    
    if (req.responseBody.length > 0) {
        [text appendString:@"── Response Body ──\n"];
        [text appendString:req.responseBody];
    }
    
    tv.text = text;
    [scroll addSubview:tv];
    [win addSubview:scroll];
    
    // 导航栏
    UIView *nav = [[UIView alloc] initWithFrame:CGRectMake(0, 0, NWScreenW, 44)];
    nav.backgroundColor = [UIColor secondarySystemBackgroundColor];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(8, 4, 60, 36);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [closeBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{
        win.hidden = YES;
    }] forControlEvents:UIControlEventTouchUpInside];
    [nav addSubview:closeBtn];
    
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(NWScreenW - 68, 4, 60, 36);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [copyBtn addTarget:[NSBlockOperation blockOperationWithBlock:^{
        UIPasteboard.generalPasteboard.string = text;
        // 简单 toast
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(NWScreenW/2 - 60, NWScreenH/2, 120, 36)];
        toast.text = @"已复制 ✅";
        toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.textColor = [UIColor whiteColor];
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        [win addSubview:toast];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [toast removeFromSuperview];
        });
    }] forControlEvents:UIControlEventTouchUpInside];
    [nav addSubview:copyBtn];
    
    [win addSubview:nav];
}

#pragma mark - 复制全部日志

static void NWCopyAllLogs(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"NetworkLogger Export - %lu requests\n", (unsigned long)NWLoggedRequests.count];
    [text appendFormat:@"Device: %@ | OS: %@\n\n", 
        [[UIDevice currentDevice] model], 
        [[UIDevice currentDevice] systemVersion]];
    
    for (NSUInteger i = 0; i < NWLoggedRequests.count; i++) {
        NWRequest *req = NWLoggedRequests[i];
        [text appendFormat:@"────────── #%lu ──────────\n", (unsigned long)(i + 1)];
        [text appendFormat:@"%@ %@  [%ld] (%.0fms)\n", req.method, req.url, (long)req.statusCode, req.duration];
        [text appendFormat:@"Time: %@\n", req.timestamp];
        
        if (req.requestHeaders.count > 0) {
            [text appendString:@"Request Headers:\n"];
            for (NSString *key in req.requestHeaders) {
                [text appendFormat:@"  %@: %@\n", key, req.requestHeaders[key]];
            }
        }
        
        if (req.requestBody.length > 0) {
            [text appendFormat:@"Request Body: %@\n", req.requestBody];
        }
        
        if (req.responseHeaders.count > 0) {
            [text appendString:@"Response Headers:\n"];
            for (NSString *key in req.responseHeaders) {
                [text appendFormat:@"  %@: %@\n", key, req.responseHeaders[key]];
            }
        }
        
        if (req.responseBody.length > 0) {
            [text appendFormat:@"Response Body:\n%@\n", req.responseBody];
        }
        
        [text appendString:@"\n"];
    }
    
    [text appendFormat:@"═══ JSON ═══\n"];
    
    // 同时生成 JSON 格式
    NSMutableArray *jsonArr = [NSMutableArray new];
    for (NWRequest *req in NWLoggedRequests) {
        NSMutableDictionary *dict = [NSMutableDictionary new];
        dict[@"method"] = req.method;
        dict[@"url"] = req.url;
        dict[@"statusCode"] = @(req.statusCode);
        dict[@"timestamp"] = req.timestamp;
        dict[@"duration_ms"] = @(req.duration);
        if (req.requestHeaders) dict[@"requestHeaders"] = req.requestHeaders;
        if (req.responseHeaders) dict[@"responseHeaders"] = req.responseHeaders;
        if (req.requestBody) dict[@"requestBody"] = req.requestBody;
        if (req.responseBody) dict[@"responseBody"] = req.responseBody;
        [jsonArr addObject:dict];
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonArr options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData) {
        [text appendString:[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]];
    }
    
    UIPasteboard.generalPasteboard.string = text;
    
    // Toast
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    UIWindow *topWin = [[UIWindow alloc] initWithWindowScene:scene];
    topWin.windowLevel = UIWindowLevelAlert + 400;
    topWin.frame = [UIScreen mainScreen].bounds;
    topWin.hidden = NO;
    
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(NWScreenW/2 - 100, NWScreenH/2, 200, 44)];
    toast.text = [NSString stringWithFormat:@"已复制 %lu 条记录 ✅", (unsigned long)NWLoggedRequests.count];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    toast.textColor = [UIColor whiteColor];
    toast.layer.cornerRadius = 12;
    toast.clipsToBounds = YES;
    [topWin addSubview:toast];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        topWin.hidden = YES;
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void NWLoggerInit(void) {
    NSLog(@"[NetworkLogger] 插件已加载 - 开始监控网络请求");
    
    NWLoggedRequests = [NSMutableArray new];
    
    // 注册 URL 拦截器
    [NSURLProtocol registerClass:[NWLogProtocol class]];
    
    // 延迟创建浮窗
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NWCreateFloatingBadge();
    });
}
