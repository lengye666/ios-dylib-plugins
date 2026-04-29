#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// ==========================================
// NetworkLogger - 进程内网络请求监控插件
// 通过 NSURLProtocol 拦截所有 HTTP/HTTPS 请求
// 浮窗显示请求列表，支持复制全部日志
// ==========================================

#pragma mark - Block Target Wrapper

// Objective-C 的 addTarget:action: 不支持 block，用这个 wrapper 转发
@interface NWBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(void);
+ (instancetype)withBlock:(void (^)(void))block;
@end

@implementation NWBlockTarget
+ (instancetype)withBlock:(void (^)(void))block {
    NWBlockTarget *t = [NWBlockTarget new];
    t.block = block;
    return t;
}
- (void)fire { if (self.block) self.block(); }
@end

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
static CGFloat NWScreenW, NWScreenH;

// Forward declarations
static void NWShowDetailList(void);
static void NWCopyAllLogs(void);
static void NWShowRequestDetail(NWRequest *req);
static NSString *NWDateToString(NSDate *date);

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
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"NWLogged" inRequest:mutableReq];

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
    entry.timestamp = NWDateToString([NSDate date]);

    if (self.request.HTTPBody) {
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

@end

#pragma mark - 日期格式化

static NSString *NWDateToString(NSDate *date) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    return [fmt stringFromDate:date];
}

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

    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:[NWBlockTarget withBlock:^{
            // handled in delegate method below
        }] action:@selector(fire)];
    // 用更简单的方式：直接用 gesture delegate
    pan = [[UIPanGestureRecognizer alloc] initWithTarget:NWBadgeBtn action:@selector(fire)];
    [NWBadgeBtn addGestureRecognizer:pan];

    // 点击展示列表
    [NWBadgeBtn addTarget:[NWBlockTarget withBlock:^{ NWShowDetailList(); }]
               action:@selector(fire)
     forControlEvents:UIControlEventTouchUpInside];

    [NWFloatingWindow addSubview:NWBadgeBtn];

    // 定时更新计数
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        NSUInteger count = NWLoggedRequests.count;
        [NWBadgeBtn setTitle:[NSString stringWithFormat:@"📡 %lu", (unsigned long)count]
                    forState:UIControlStateNormal];
    }];
}

#pragma mark - UITableViewDelegate helper

@interface NWTableHelper : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIWindow *parentWindow;
@property (nonatomic, strong) UIView *container;
@end

@implementation NWTableHelper

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

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NWRequest *req = NWLoggedRequests[indexPath.row];
    NWShowRequestDetail(req);
}

@end

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

    // helper 持有引用防止释放
    NWTableHelper *helper = [NWTableHelper new];

    // 半透明背景点击关闭
    UIControl *bg = [[UIControl alloc] initWithFrame:detailWindow.bounds];
    [bg addTarget:[NWBlockTarget withBlock:^{
        [UIView animateWithDuration:0.25 animations:^{
            helper.tableView.alpha = 0;
            helper.container.alpha = 0;
        } completion:^(BOOL f) {
            detailWindow.hidden = YES;
        }];
    }] action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [detailWindow addSubview:bg];

    // 内容容器
    CGFloat containerH = NWScreenH * 0.75;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, NWScreenH, NWScreenW, containerH)];
    container.backgroundColor = [UIColor systemBackgroundColor];
    helper.container = container;

    // 顶部工具栏
    CGFloat toolbarH = 50;
    UIView *toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, NWScreenW, toolbarH)];
    toolbar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, NWScreenW * 0.5, toolbarH)];
    titleLabel.text = [NSString stringWithFormat:@"Network Logger (%lu)", (unsigned long)NWLoggedRequests.count];
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    [toolbar addSubview:titleLabel];
    helper.titleLabel = titleLabel;

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(NWScreenW - 120, 8, 50, 34);
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [clearBtn addTarget:[NWBlockTarget withBlock:^{
        [NWLoggedRequests removeAllObjects];
        titleLabel.text = @"Network Logger (0)";
        [helper.tableView reloadData];
    }] action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:clearBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(NWScreenW - 60, 8, 50, 34);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [copyBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [copyBtn addTarget:[NWBlockTarget withBlock:^{ NWCopyAllLogs(); }]
            action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:copyBtn];

    [container addSubview:toolbar];

    // UITableView
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, toolbarH, NWScreenW, containerH - toolbarH)
                                                          style:UITableViewStylePlain];
    tableView.dataSource = helper;
    tableView.delegate = helper;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 60;
    [container addSubview:tableView];
    helper.tableView = tableView;

    [detailWindow addSubview:container];

    // 动画弹出
    [UIView animateWithDuration:0.3 animations:^{
        container.frame = CGRectMake(0, NWScreenH - containerH, NWScreenW, containerH);
    }];
}

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

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 44, NWScreenW, NWScreenH - 44)];
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

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, NWScreenW, NWScreenH - 44)];
    scroll.contentSize = tv.frame.size;
    [scroll addSubview:tv];
    [win addSubview:scroll];

    // 导航栏
    UIView *nav = [[UIView alloc] initWithFrame:CGRectMake(0, 0, NWScreenW, 44)];
    nav.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(8, 4, 60, 36);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [closeBtn addTarget:[NWBlockTarget withBlock:^{ win.hidden = YES; }]
             action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [nav addSubview:closeBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(NWScreenW - 68, 4, 60, 36);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [copyBtn addTarget:[NWBlockTarget withBlock:^{
        UIPasteboard.generalPasteboard.string = text;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(NWScreenW / 2 - 50, NWScreenH / 2, 100, 36)];
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
    }] action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
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

    NSMutableArray *jsonArr = [NSMutableArray new];

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

    [text appendString:@"═══ JSON ═══\n"];
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

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(NWScreenW / 2 - 100, NWScreenH / 2, 200, 44)];
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
    [NSURLProtocol registerClass:[NWLogProtocol class]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NWCreateFloatingBadge();
    });
}
