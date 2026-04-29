#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ==========================================
// NetworkLogger - 进程内网络请求监控插件
// 通过 NSURLProtocol 拦截所有 HTTP/HTTPS 请求
// 浮窗显示请求列表，支持复制全部日志
// ==========================================

#pragma mark - Block Target Wrapper

// UIControl / UIGestureRecognizer 不 retain target
// 用这个 wrapper 转发 block，并手动保持强引用
@interface NWBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(void);
+ (instancetype)withBlock:(void (^)(void))block;
- (void)fire;
@end

@implementation NWBlockTarget
+ (instancetype)withBlock:(void (^)(void))block {
    NWBlockTarget *t = [NWBlockTarget new];
    t.block = block;
    return t;
}
- (void)fire { if (self.block) self.block(); }
@end

// 全局强引用数组，防止 block target 被释放
static NSMutableArray *gRetainedTargets;

static NWBlockTarget *NWSafeTarget(void (^block)(void)) {
    if (!gRetainedTargets) gRetainedTargets = [NSMutableArray new];
    NWBlockTarget *t = [NWBlockTarget withBlock:block];
    [gRetainedTargets addObject:t];
    return t;
}

static void NWRetainObj(id obj) {
    if (!gRetainedTargets) gRetainedTargets = [NSMutableArray new];
    [gRetainedTargets addObject:obj];
}

#pragma mark - Data Model

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

#pragma mark - Globals

static NSMutableArray<NWRequest *> *gRequests;
static UIWindow *gFloatWin;
static CGFloat gScrW, gScrH;

// Forward declarations
static void NWShowDetailList(void);
static void NWCopyAllLogs(void);
static void NWShowDetail(NWRequest *req);
static NSString *NWTimeStr(NSDate *date);

#pragma mark - NSURLProtocol Interceptor

@interface NWLogProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *respData;
@property (nonatomic, strong) NSDate *startTime;
@end

@implementation NWLogProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"NWLogged" inRequest:request]) return NO;
    NSString *s = request.URL.scheme.lowercaseString;
    return [s isEqualToString:@"http"] || [s isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"NWLogged" inRequest:req];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    self.respData = [NSMutableData data];
    self.startTime = [NSDate date];
    self.task = [session dataTaskWithRequest:req];
    [self.task resume];
}

- (void)stopLoading { [self.task cancel]; }

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)dt
    didReceiveResponse:(NSURLResponse *)resp completionHandler:(void (^)(NSURLSessionResponseDisposition))h {
    NWRequest *e = [NWRequest new];
    e.url = self.request.URL.absoluteString;
    e.method = self.request.HTTPMethod ?: @"GET";
    e.statusCode = ((NSHTTPURLResponse *)resp).statusCode;
    e.responseHeaders = ((NSHTTPURLResponse *)resp).allHeaderFields;
    e.requestHeaders = self.request.allHTTPHeaderFields;
    e.timestamp = NWTimeStr([NSDate date]);
    if (self.request.HTTPBody) {
        NSData *body = self.request.HTTPBody.length > 2048
            ? [self.request.HTTPBody subdataWithRange:NSMakeRange(0, 2048)] : self.request.HTTPBody;
        e.requestBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!e.requestBody) e.requestBody = @"[binary]";
    }
    [gRequests addObject:e];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    h(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)dt didReceiveData:(NSData *)data {
    [self.respData appendData:data];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionDataTask *)t didCompleteWithError:(NSError *)err {
    if (gRequests.count > 0) {
        NWRequest *last = gRequests.lastObject;
        last.duration = [[NSDate date] timeIntervalSinceDate:self.startTime] * 1000;
        if (self.respData.length > 0) {
            NSData *d = self.respData.length > 10240
                ? [self.respData subdataWithRange:NSMakeRange(0, 10240)] : self.respData;
            last.responseBody = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (!last.responseBody) last.responseBody = @"[binary]";
        }
        if (err) last.responseBody = [NSString stringWithFormat:@"[ERROR] %@", err.localizedDescription];
    }
    [self.client URLProtocolDidFinishLoading:self];
}
@end

#pragma mark - Date Formatter

static NSString *NWTimeStr(NSDate *date) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss.SSS"; });
    return [fmt stringFromDate:date];
}

#pragma mark - Drag Handler

@interface NWDragHandler : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, assign) CGSize btnSize;
- (void)handlePan:(UIPanGestureRecognizer *)g;
@end

@implementation NWDragHandler
- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:g.view];
    CGPoint o = self.window.frame.origin;
    o.x += t.x; o.y += t.y;
    o.x = MAX(0, MIN(gScrW - self.btnSize.width, o.x));
    o.y = MAX(44, MIN(gScrH - self.btnSize.height, o.y));
    self.window.frame = CGRectMake(o.x, o.y, self.btnSize.width, self.btnSize.height);
    [g setTranslation:CGPointZero inView:g.view];
}
@end

#pragma mark - Table DataSource/Delegate

@interface NWTblHelper : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UIWindow *win;
@end

@implementation NWTblHelper

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return gRequests.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        c.textLabel.numberOfLines = 2;
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NWRequest *r = gRequests[ip.row];
    NSString *icon = (r.statusCode >= 200 && r.statusCode < 300) ? @"\u2705" : @"\u274C";
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@", icon, r.method, r.url];
    NSMutableString *sub = [NSMutableString stringWithFormat:@"%ld | %.0fms", (long)r.statusCode, r.duration];
    if (r.responseBody.length > 0) {
        NSString *p = r.responseBody.length > 80
            ? [[r.responseBody substringToIndex:80] stringByAppendingString:@"..."] : r.responseBody;
        [sub appendFormat:@"\n%@", p];
    }
    c.detailTextLabel.text = sub;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NWShowDetail(gRequests[ip.row]);
}
@end

#pragma mark - Floating Badge

static UIButton *gBadge;

static void NWCreateBadge(void) {
    gScrW = [UIScreen mainScreen].bounds.size.width;
    gScrH = [UIScreen mainScreen].bounds.size.height;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;

    gFloatWin = [[UIWindow alloc] initWithWindowScene:scene];
    gFloatWin.windowLevel = UIWindowLevelStatusBar + 100;
    gFloatWin.backgroundColor = [UIColor clearColor];
    gFloatWin.clipsToBounds = YES;
    gFloatWin.hidden = NO;
    gFloatWin.userInteractionEnabled = YES;

    CGFloat sz = 56;
    gFloatWin.frame = CGRectMake(gScrW - sz - 8, 50, sz, sz);
    gFloatWin.layer.cornerRadius = sz / 2;

    gBadge = [UIButton buttonWithType:UIButtonTypeCustom];
    gBadge.frame = gFloatWin.bounds;
    gBadge.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
    gBadge.layer.cornerRadius = sz / 2;
    gBadge.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [gBadge setTitle:@"\U0001F4E1 0" forState:UIControlStateNormal];
    [gBadge setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    // Drag
    NWDragHandler *dh = [NWDragHandler new];
    dh.window = gFloatWin;
    dh.btnSize = CGSizeMake(sz, sz);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:dh action:@selector(handlePan:)];
    [gBadge addGestureRecognizer:pan];
    NWRetainObj(dh); // gesture 不 retain target

    // Tap
    [gBadge addTarget:NWSafeTarget(^{ NWShowDetailList(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];

    [gFloatWin addSubview:gBadge];

    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        [gBadge setTitle:[NSString stringWithFormat:@"\U0001F4E1 %lu", (unsigned long)gRequests.count]
                forState:UIControlStateNormal];
    }];
}

#pragma mark - Detail List

static void NWShowDetailList(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;

    UIWindow *win = [[UIWindow alloc] initWithWindowScene:scene];
    win.windowLevel = UIWindowLevelAlert + 200;
    win.frame = [UIScreen mainScreen].bounds;
    win.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    win.hidden = NO;

    NWTblHelper *helper = [NWTblHelper new];
    helper.win = win;
    NWRetainObj(helper);

    // Background dismiss
    UIControl *bg = [[UIControl alloc] initWithFrame:win.bounds];
    [bg addTarget:NWSafeTarget(^{ [UIView animateWithDuration:0.25 animations:^{ helper.tableView.alpha = 0; helper.container.alpha = 0; } completion:^(BOOL f) { win.hidden = YES; }]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:bg];

    // Container
    CGFloat cH = gScrH * 0.75;
    CGFloat safeBottom = 34; // iPhone 14 Pro home indicator
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, gScrH, gScrW, cH)];
    container.backgroundColor = [UIColor systemBackgroundColor];
    helper.container = container;

    // Top title bar
    CGFloat topH = 50;
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, gScrW, topH)];
    topBar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, gScrW - 32, topH)];
    tl.text = [NSString stringWithFormat:@"Network Logger (%lu)", (unsigned long)gRequests.count];
    tl.font = [UIFont boldSystemFontOfSize:16];
    tl.textColor = [UIColor labelColor];
    tl.textAlignment = NSTextAlignmentCenter;
    [topBar addSubview:tl];
    helper.titleLabel = tl;
    [container addSubview:topBar];

    // Table (between top bar and bottom buttons)
    CGFloat bottomH = 50 + safeBottom;
    UITableView *tbl = [[UITableView alloc] initWithFrame:CGRectMake(0, topH, gScrW, cH - topH - bottomH) style:UITableViewStylePlain];
    tbl.dataSource = helper;
    tbl.delegate = helper;
    tbl.rowHeight = UITableViewAutomaticDimension;
    tbl.estimatedRowHeight = 60;
    [container addSubview:tbl];
    helper.tableView = tbl;

    // Bottom button bar
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, cH - bottomH, gScrW, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(gScrW / 2 - 110, safeBottom, 100, 40);
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    clearBtn.backgroundColor = [UIColor systemRedColor];
    [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    clearBtn.layer.cornerRadius = 8;
    [clearBtn addTarget:NWSafeTarget(^{ [gRequests removeAllObjects]; tl.text = @"Network Logger (0)"; [helper.tableView reloadData]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:clearBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(gScrW / 2 + 10, safeBottom, 100, 40);
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{ NWCopyAllLogs(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:copyBtn];

    [container addSubview:bottomBar];

    [win addSubview:container];
    [UIView animateWithDuration:0.3 animations:^{ container.frame = CGRectMake(0, gScrH - cH, gScrW, cH); }];
}

#pragma mark - Request Detail

static void NWShowDetail(NWRequest *req) {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    if (!scene) return;

    UIWindow *win = [[UIWindow alloc] initWithWindowScene:scene];
    win.windowLevel = UIWindowLevelAlert + 300;
    win.frame = [UIScreen mainScreen].bounds;
    win.backgroundColor = [UIColor systemBackgroundColor];
    win.hidden = NO;
    NWRetainObj(win);

    NSMutableString *text = [NSMutableString string];
    [text appendString:@"=== REQUEST ===\n"];
    [text appendFormat:@"%@ %@\n", req.method, req.url];
    [text appendFormat:@"Time: %@ (%.0fms)\n\n", req.timestamp, req.duration];
    if (req.requestHeaders.count > 0) {
        [text appendString:@"-- Request Headers --\n"];
        for (NSString *k in req.requestHeaders) [text appendFormat:@"%@: %@\n", k, req.requestHeaders[k]];
        [text appendString:@"\n"];
    }
    if (req.requestBody.length > 0) { [text appendFormat:@"-- Request Body --\n%@\n\n", req.requestBody]; }
    [text appendFormat:@"=== RESPONSE %ld ===\n\n", (long)req.statusCode];
    if (req.responseHeaders.count > 0) {
        [text appendString:@"-- Response Headers --\n"];
        for (NSString *k in req.responseHeaders) [text appendFormat:@"%@: %@\n", k, req.responseHeaders[k]];
        [text appendString:@"\n"];
    }
    if (req.responseBody.length > 0) { [text appendString:@"-- Response Body --\n"]; [text appendString:req.responseBody]; }

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 44, gScrW, gScrH - 44)];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tv.textColor = [UIColor labelColor];
    tv.text = text;
    [win addSubview:tv];

    UIView *nav = [[UIView alloc] initWithFrame:CGRectMake(0, 0, gScrW, 44)];
    nav.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(8, 4, 60, 36);
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [closeBtn addTarget:NWSafeTarget(^{ win.hidden = YES; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [nav addSubview:closeBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(gScrW - 68, 4, 60, 36);
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [copyBtn addTarget:NWSafeTarget(^{
        UIPasteboard.generalPasteboard.string = text;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 50, gScrH/2, 100, 36)];
        toast.text = @"Copied!";
        toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.textColor = [UIColor whiteColor];
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        [win addSubview:toast];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [toast removeFromSuperview]; });
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [nav addSubview:copyBtn];
    [win addSubview:nav];
}

#pragma mark - Copy All

static void NWCopyAllLogs(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"NetworkLogger - %lu requests\nDevice: %@ | OS: %@\n\n",
        (unsigned long)gRequests.count, [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    NSMutableArray *jsonArr = [NSMutableArray new];
    for (NSUInteger i = 0; i < gRequests.count; i++) {
        NWRequest *r = gRequests[i];
        [text appendFormat:@"-------- #%lu --------\n", (unsigned long)(i+1)];
        [text appendFormat:@"%@ %@ [%ld] (%.0fms)\n", r.method, r.url, (long)r.statusCode, r.duration];
        [text appendFormat:@"Time: %@\n", r.timestamp];
        if (r.requestHeaders.count > 0) { [text appendString:@"Req Headers:\n"]; for (NSString *k in r.requestHeaders) [text appendFormat:@"  %@: %@\n", k, r.requestHeaders[k]]; }
        if (r.requestBody.length > 0) [text appendFormat:@"Req Body: %@\n", r.requestBody];
        if (r.responseHeaders.count > 0) { [text appendString:@"Resp Headers:\n"]; for (NSString *k in r.responseHeaders) [text appendFormat:@"  %@: %@\n", k, r.responseHeaders[k]]; }
        if (r.responseBody.length > 0) [text appendFormat:@"Resp Body:\n%@\n", r.responseBody];
        [text appendString:@"\n"];

        NSMutableDictionary *d = [NSMutableDictionary new];
        d[@"method"] = r.method; d[@"url"] = r.url; d[@"status"] = @(r.statusCode);
        d[@"timestamp"] = r.timestamp; d[@"duration_ms"] = @(r.duration);
        if (r.requestHeaders) d[@"requestHeaders"] = r.requestHeaders;
        if (r.responseHeaders) d[@"responseHeaders"] = r.responseHeaders;
        if (r.requestBody) d[@"requestBody"] = r.requestBody;
        if (r.responseBody) d[@"responseBody"] = r.responseBody;
        [jsonArr addObject:d];
    }

    [text appendString:@"=== JSON ===\n"];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:jsonArr options:NSJSONWritingPrettyPrinted error:nil];
    if (jd) [text appendString:[[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]];

    UIPasteboard.generalPasteboard.string = text;

    // Toast
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    UIWindow *tw = [[UIWindow alloc] initWithWindowScene:scene];
    tw.windowLevel = UIWindowLevelAlert + 400;
    tw.frame = [UIScreen mainScreen].bounds;
    tw.hidden = NO;
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 100, gScrH/2, 200, 44)];
    toast.text = [NSString stringWithFormat:@"Copied %lu records!", (unsigned long)gRequests.count];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    toast.textColor = [UIColor whiteColor];
    toast.layer.cornerRadius = 12;
    toast.clipsToBounds = YES;
    [tw addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tw.hidden = YES; });
}

#pragma mark - Entry

__attribute__((constructor))
static void NWLoggerInit(void) {
    NSLog(@"[NetworkLogger] loaded");
    gRequests = [NSMutableArray new];
    [NSURLProtocol registerClass:[NWLogProtocol class]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NWCreateBadge();
    });
}
