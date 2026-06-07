#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>

// ==========================================
// NetworkLogger v4 - 全量拦截 + 搜索 / 汉化 / 上传
// 默认关闭抓包，手动开启
// ==========================================

#pragma mark - Block Target Wrapper

@interface NWBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(void);
+ (instancetype)withBlock:(void (^)(void))block;
- (void)fire;
@end

@implementation NWBlockTarget
+ (instancetype)withBlock:(void (^)(void))block {
    NWBlockTarget *t = [NWBlockTarget new]; t.block = block; return t;
}
- (void)fire { if (self.block) self.block(); }
@end

static NSMutableArray *gRetainedTargets;
static NWBlockTarget *NWSafeTarget(void (^block)(void)) {
    if (!gRetainedTargets) gRetainedTargets = [NSMutableArray new];
    NWBlockTarget *t = [NWBlockTarget withBlock:block];
    [gRetainedTargets addObject:t]; return t;
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
static BOOL gIsSubprocess = NO;
static BOOL gCapturing = YES; // 默认开启抓包

static NSString *gSubLogPath(void) {
    return @"/var/mobile/Documents/NW_subprocess.log";
}

static void NWAddRequest(NWRequest *e) {
    if (!gCapturing) return; // 未开启抓包则不记录
    [gRequests addObject:e];
}
static void NWShowDetailList(void);
static void NWShowSubLog(void);
static void NWCopyAllLogs(void);
static void NWUploadLogs(void);
static void NWShowDetail(NWRequest *req);
static NSString *NWTimeStr(NSDate *date);

#pragma mark - Detection

static BOOL NWHasUIKit(void) {
    int count = _dyld_image_count();
    for (int i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UIKit.framework")) return YES;
    }
    return NO;
}

static NSString *NWFindDylibPath(void) {
    int count = _dyld_image_count();
    for (int i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "NetworkLogger")) {
            return [NSString stringWithUTF8String:name];
        }
    }
    return nil;
}

#pragma mark - Subprocess file logging

static void NWWriteSubLog(NSString *line) {
    static FILE *gSubLogFile = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSubLogFile = fopen(gSubLogPath().UTF8String, "w");
        if (gSubLogFile) {
            fprintf(gSubLogFile, "NetworkLogger - 子进程日志\n\n");
            fflush(gSubLogFile);
        }
    });
    if (gSubLogFile) {
        fwrite(line.UTF8String, 1, line.length, gSubLogFile);
        fflush(gSubLogFile);
    }
}

#pragma mark ======== NSURLProtocol Interceptor ========

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
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    self.respData = [NSMutableData data];
    self.startTime = [NSDate date];
    self.task = [session dataTaskWithRequest:req];
    [self.task resume];
}

- (void)stopLoading { [self.task cancel]; }

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)dt
    didReceiveResponse:(NSURLResponse *)resp completionHandler:(void (^)(NSURLSessionResponseDisposition))h {

    NSString *ts = NWTimeStr([NSDate date]);

    if (gIsSubprocess) {
        NSString *line = [NSString stringWithFormat:@"[%@] %@ %@ → %ld\n",
            ts, self.request.HTTPMethod ?: @"GET",
            self.request.URL.absoluteString,
            (long)((NSHTTPURLResponse *)resp).statusCode];
        NWWriteSubLog(line);
    } else {
        NWRequest *e = [NWRequest new];
        e.url = self.request.URL.absoluteString;
        e.method = self.request.HTTPMethod ?: @"GET";
        e.statusCode = ((NSHTTPURLResponse *)resp).statusCode;
        e.responseHeaders = ((NSHTTPURLResponse *)resp).allHeaderFields;
        e.requestHeaders = self.request.allHTTPHeaderFields;
        e.timestamp = ts;
        if (self.request.HTTPBody) {
            NSData *body = self.request.HTTPBody.length > 2048
                ? [self.request.HTTPBody subdataWithRange:NSMakeRange(0, 2048)] : self.request.HTTPBody;
            e.requestBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (!e.requestBody) e.requestBody = @"[二进制]";
        }
        NWAddRequest(e);
    }

    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    h(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)dt didReceiveData:(NSData *)data {
    [self.respData appendData:data];
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)err {
    NSString *ts = NWTimeStr([NSDate date]);

    if (gIsSubprocess) {
        NSString *line;
        if (err) {
            line = [NSString stringWithFormat:@"[%@] 错误: %@\n\n", ts, err.localizedDescription];
        } else {
            long bytes = (long)self.respData.length;
            line = [NSString stringWithFormat:@"[%@] 完成 (%ld 字节)\n\n", ts, bytes];
        }
        NWWriteSubLog(line);
    } else if (gRequests.count > 0) {
        NWRequest *last = gRequests.lastObject;
        last.duration = [[NSDate date] timeIntervalSinceDate:self.startTime] * 1000;
        if (self.respData.length > 0) {
            NSData *d = self.respData.length > 10240
                ? [self.respData subdataWithRange:NSMakeRange(0, 10240)] : self.respData;
            last.responseBody = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (!last.responseBody) last.responseBody = @"[二进制]";
        }
        if (err) last.responseBody = [NSString stringWithFormat:@"[错误] %@", err.localizedDescription];
    }
    [self.client URLProtocolDidFinishLoading:self];
}
@end

#pragma mark - Session Swizzle

static void NWSwizzleSession(void) {
    Class metaCls = object_getClass([NSURLSession class]);

    SEL sel1 = @selector(sessionWithConfiguration:delegate:delegateQueue:);
    Method m1 = class_getInstanceMethod(metaCls, sel1);
    if (m1) {
        IMP origIMP = method_getImplementation(m1);
        IMP newIMP = imp_implementationWithBlock(^id(id self, NSURLSessionConfiguration *config, id delegate, NSOperationQueue *queue) {
            if (config) {
                NSMutableArray *classes = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
                if (![classes containsObject:[NWLogProtocol class]]) {
                    [classes insertObject:[NWLogProtocol class] atIndex:0];
                }
                config.protocolClasses = [classes copy];
            }
            return ((id (*)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *))origIMP)(self, sel1, config, delegate, queue);
        });
        method_setImplementation(m1, newIMP);
    }

    SEL sel2 = @selector(sessionWithConfiguration:);
    Method m2 = class_getInstanceMethod(metaCls, sel2);
    if (m2) {
        IMP origIMP2 = method_getImplementation(m2);
        IMP newIMP2 = imp_implementationWithBlock(^id(id self, NSURLSessionConfiguration *config) {
            if (config) {
                NSMutableArray *classes = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
                if (![classes containsObject:[NWLogProtocol class]]) {
                    [classes insertObject:[NWLogProtocol class] atIndex:0];
                }
                config.protocolClasses = [classes copy];
            }
            return ((id (*)(id, SEL, NSURLSessionConfiguration *))origIMP2)(self, sel2, config);
        });
        method_setImplementation(m2, newIMP2);
    }
}

#pragma mark - Task-Level Swizzle

static void NWSwizzleTasks(void) {
    SEL sel1 = @selector(dataTaskWithRequest:completionHandler:);
    Method mt1 = class_getInstanceMethod([NSURLSession class], sel1);
    if (mt1) {
        IMP origIMP = method_getImplementation(mt1);
        IMP newIMP = imp_implementationWithBlock(^NSURLSessionDataTask *(NSURLSession *sess, NSURLRequest *req, void (^origCompletion)(NSData *, NSURLResponse *, NSError *)) {
            __block NSDate *start = [NSDate date];
            NSString *ts = NWTimeStr([NSDate date]);

            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                double dur = [[NSDate date] timeIntervalSinceDate:start] * 1000;
                NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;

                if (gIsSubprocess) {
                    NSString *line = [NSString stringWithFormat:@"[%s] %@ %@ → %ld\n", ts.UTF8String, req.HTTPMethod ?: @"GET", req.URL.absoluteString, (long)(http ? http.statusCode : 0)];
                    NWWriteSubLog(line);
                } else {
                    NWRequest *e = [NWRequest new];
                    e.url = req.URL.absoluteString;
                    e.method = req.HTTPMethod ?: @"GET";
                    e.statusCode = http ? http.statusCode : (err ? -1 : 0);
                    e.responseHeaders = http ? http.allHeaderFields : nil;
                    e.requestHeaders = req.allHTTPHeaderFields;
                    e.timestamp = ts;
                    e.duration = dur;
                    if (req.HTTPBody && req.HTTPBody.length > 0) {
                        NSData *body = req.HTTPBody.length > 2048 ? [req.HTTPBody subdataWithRange:NSMakeRange(0, 2048)] : req.HTTPBody;
                        e.requestBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"[二进制]";
                    }
                    if (data && data.length > 0) {
                        NSData *d = data.length > 10240 ? [data subdataWithRange:NSMakeRange(0, 10240)] : data;
                        e.responseBody = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"[二进制]";
                    }
                    if (err) e.responseBody = [NSString stringWithFormat:@"[错误] %@", err.localizedDescription];
                    NWAddRequest(e);
                }

                if (origCompletion) origCompletion(data, resp, err);
            };

            return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))origIMP)(sess, sel1, req, wrapped);
        });
        method_setImplementation(mt1, newIMP);
    }

    SEL sel2 = @selector(dataTaskWithURL:completionHandler:);
    Method mt2 = class_getInstanceMethod([NSURLSession class], sel2);
    if (mt2) {
        IMP origIMP2 = method_getImplementation(mt2);
        IMP newIMP2 = imp_implementationWithBlock(^NSURLSessionDataTask *(NSURLSession *sess, NSURL *url, void (^origCompletion)(NSData *, NSURLResponse *, NSError *)) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            return [sess dataTaskWithRequest:req completionHandler:origCompletion];
        });
        method_setImplementation(mt2, newIMP2);
    }
}

#pragma mark - Hook Process

static void NWHookProcess(void) {
    Class processClass = NSClassFromString(@"NSTask");
    if (!processClass) processClass = NSClassFromString(@"Process");
    if (!processClass) return;

    NSString *dylibPath = NWFindDylibPath();
    if (!dylibPath) {
        NSLog(@"[NW] 找不到 dylib 路径，跳过 Process hook");
        return;
    }

    SEL launchSel = @selector(launch);
    Method m = class_getInstanceMethod(processClass, launchSel);
    if (!m) return;

    IMP origIMP = method_getImplementation(m);
    IMP newIMP = imp_implementationWithBlock(^void(id self) {
        NSMutableDictionary *env = [[self valueForKey:@"environment"] mutableCopy];
        if (!env) env = [NSMutableDictionary new];

        NSString *existing = env[@"DYLD_INSERT_LIBRARIES"];
        if (existing.length > 0) {
            env[@"DYLD_INSERT_LIBRARIES"] = [NSString stringWithFormat:@"%@:%@", existing, dylibPath];
        } else {
            env[@"DYLD_INSERT_LIBRARIES"] = dylibPath;
        }
        [self setValue:env forKey:@"environment"];

        NSLog(@"[NW] 子进程启动 → 注入 DYLD_INSERT_LIBRARIES: %@", dylibPath);

        ((void (*)(id, SEL))origIMP)(self, launchSel);
    });
    method_setImplementation(m, newIMP);
    NSLog(@"[NW] 已 Hook Process/NSTask launch");
}

#pragma mark - Date

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

#pragma mark - Table Helper (带搜索功能)

@interface NWTblHelper : NSObject <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSMutableArray<NWRequest *> *filteredData;
@property (nonatomic, assign) BOOL isFiltering;
@end

@implementation NWTblHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _filteredData = [NSMutableArray new];
        _isFiltering = NO;
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.isFiltering ? self.filteredData.count : gRequests.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
        c.textLabel.numberOfLines = 3;
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NWRequest *r = self.isFiltering ? self.filteredData[ip.row] : gRequests[ip.row];
    NSString *icon = (r.statusCode >= 200 && r.statusCode < 400) ? @"✅" : (r.statusCode >= 400 ? @"❌" : @"📡");
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@", icon, r.method, r.url];
    NSMutableString *sub = [NSMutableString stringWithFormat:@"%ld | %.0fms", (long)r.statusCode, r.duration];
    if (r.responseBody.length > 0) {
        NSString *p = r.responseBody.length > 60
            ? [[r.responseBody substringToIndex:60] stringByAppendingString:@"..."] : r.responseBody;
        [sub appendFormat:@"\n%@", p];
    }
    c.detailTextLabel.text = sub;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NWRequest *r = self.isFiltering ? self.filteredData[ip.row] : gRequests[ip.row];
    NWShowDetail(r);
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.isFiltering = NO;
        [self.filteredData removeAllObjects];
    } else {
        self.isFiltering = YES;
        NSString *lowerSearch = searchText.lowercaseString;
        [self.filteredData removeAllObjects];
        for (NWRequest *r in gRequests) {
            NSString *urlLower = r.url.lowercaseString;
            NSString *methodLower = r.method.lowercaseString;
            NSString *bodyLower = r.responseBody.lowercaseString;
            if ([urlLower containsString:lowerSearch] ||
                [methodLower containsString:lowerSearch] ||
                [bodyLower containsString:lowerSearch]) {
                [self.filteredData addObject:r];
            }
        }
    }
    [self.tableView reloadData];
    self.titleLabel.text = [NSString stringWithFormat:@"网络日志 (%lu%@)",
                            (unsigned long)(self.isFiltering ? self.filteredData.count : gRequests.count),
                            self.isFiltering ? [NSString stringWithFormat:@"/%lu", (unsigned long)gRequests.count] : @""];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
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
    gFloatWin.windowLevel = UIWindowLevelAlert + 100;
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
    [gBadge setTitle:@"📡 0" forState:UIControlStateNormal];
    [gBadge setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    NWDragHandler *dh = [NWDragHandler new];
    dh.window = gFloatWin; dh.btnSize = CGSizeMake(sz, sz);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:dh action:@selector(handlePan:)];
    [gBadge addGestureRecognizer:pan];
    NWRetainObj(dh);

    [gBadge addTarget:NWSafeTarget(^{ NWShowDetailList(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [gFloatWin addSubview:gBadge];

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        NSString *title = [NSString stringWithFormat:@"📡 %lu", (unsigned long)gRequests.count];
        if ([[NSFileManager defaultManager] fileExistsAtPath:gSubLogPath()]) {
            title = [title stringByAppendingString:@" ⭐"];
        }
        [gBadge setTitle:title forState:UIControlStateNormal];
    }];
}

#pragma mark - Detail List (带搜索 + 上传)

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

    NWTblHelper *helper = [[NWTblHelper alloc] init];
    NWRetainObj(helper);

    UIControl *bg = [[UIControl alloc] initWithFrame:win.bounds];
    [bg addTarget:NWSafeTarget(^{ [UIView animateWithDuration:0.25 animations:^{ helper.tableView.alpha = 0; helper.container.alpha = 0; } completion:^(BOOL f) { win.hidden = YES; }]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:bg];

    CGFloat cH = gScrH * 0.75;
    CGFloat safeBottom = 34;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, gScrH, gScrW, cH)];
    container.backgroundColor = [UIColor systemBackgroundColor];
    helper.container = container;

    CGFloat topH = 50;
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, gScrW, topH)];
    topBar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, gScrW - 32, topH)];
    tl.text = [NSString stringWithFormat:@"网络日志 (%lu)", (unsigned long)gRequests.count];
    tl.font = [UIFont boldSystemFontOfSize:16];
    tl.textColor = [UIColor labelColor];
    tl.textAlignment = NSTextAlignmentCenter;
    [topBar addSubview:tl];
    helper.titleLabel = tl;
    [container addSubview:topBar];

    // 搜索栏
    UISearchBar *searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, topH, gScrW, 44)];
    searchBar.placeholder = @"搜索 URL / 方法 / 响应内容...";
    searchBar.delegate = helper;
    searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    searchBar.barTintColor = [UIColor systemBackgroundColor];
    searchBar.searchTextField.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [container addSubview:searchBar];
    helper.searchBar = searchBar;

    CGFloat searchH = 44;
    CGFloat bottomH = 50 + safeBottom;
    UITableView *tbl = [[UITableView alloc] initWithFrame:CGRectMake(0, topH + searchH, gScrW, cH - topH - searchH - bottomH) style:UITableViewStylePlain];
    tbl.dataSource = helper; tbl.delegate = helper;
    tbl.rowHeight = UITableViewAutomaticDimension; tbl.estimatedRowHeight = 60;
    [container addSubview:tbl];
    helper.tableView = tbl;

    // 底部按钮栏（5个按钮）
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, cH - bottomH, gScrW, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    CGFloat btnW = (gScrW - 50) / 5;

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(8, safeBottom, btnW, 40);
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    clearBtn.backgroundColor = [UIColor systemRedColor];
    [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    clearBtn.layer.cornerRadius = 8;
    [clearBtn addTarget:NWSafeTarget(^{ [gRequests removeAllObjects];
        helper.isFiltering = NO; [helper.filteredData removeAllObjects];
        tl.text = @"网络日志 (0)"; [helper.tableView reloadData]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:clearBtn];

    UIButton *capBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    capBtn.frame = CGRectMake(8 + (btnW + 8) * 1, safeBottom, btnW, 40);
    capBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    capBtn.layer.cornerRadius = 8;
    [capBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    // 根据当前状态设置按钮样式
    if (gCapturing) {
        capBtn.backgroundColor = [UIColor systemRedColor];
        [capBtn setTitle:@"⏹ 停止" forState:UIControlStateNormal];
    } else {
        capBtn.backgroundColor = [UIColor systemGreenColor];
        [capBtn setTitle:@"▶ 抓包" forState:UIControlStateNormal];
    }
    [capBtn addTarget:NWSafeTarget(^{
        gCapturing = !gCapturing;
        // 更新按钮样式
        if (gCapturing) {
            capBtn.backgroundColor = [UIColor systemRedColor];
            [capBtn setTitle:@"⏹ 停止" forState:UIControlStateNormal];
        } else {
            capBtn.backgroundColor = [UIColor systemGreenColor];
            [capBtn setTitle:@"▶ 抓包" forState:UIControlStateNormal];
        }
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:capBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(8 + (btnW + 8) * 2, safeBottom, btnW, 40);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{ NWCopyAllLogs(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:copyBtn];

    UIButton *uploadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    uploadBtn.frame = CGRectMake(8 + (btnW + 8) * 3, safeBottom, btnW, 40);
    [uploadBtn setTitle:@"上传" forState:UIControlStateNormal];
    uploadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    uploadBtn.backgroundColor = [UIColor systemGreenColor];
    [uploadBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    uploadBtn.layer.cornerRadius = 8;
    [uploadBtn addTarget:NWSafeTarget(^{ NWUploadLogs(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:uploadBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(8 + (btnW + 8) * 4, safeBottom, btnW, 40);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    closeBtn.backgroundColor = [UIColor systemGrayColor];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.layer.cornerRadius = 8;
    [closeBtn addTarget:NWSafeTarget(^{ [UIView animateWithDuration:0.25 animations:^{ helper.tableView.alpha = 0; helper.container.alpha = 0; } completion:^(BOOL f) { win.hidden = YES; }]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:closeBtn];

    [container addSubview:bottomBar];
    [win addSubview:container];
    [UIView animateWithDuration:0.3 animations:^{ container.frame = CGRectMake(0, gScrH - cH, gScrW, cH); }];
}

#pragma mark - Subprocess Log Viewer

static void NWShowSubLog(void) {
    NSString *content = [NSString stringWithContentsOfFile:gSubLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!content || content.length == 0) {
        content = @"未找到子进程日志。\n\n目标应用可能未使用 Process/NSTask，\n或 DYLD_INSERT_LIBRARIES 被阻止。";
    }

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

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, gScrW, gScrH - 90)];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tv.textColor = [UIColor labelColor];
    tv.text = content;
    [win addSubview:tv];

    CGFloat bottomH = 50 + 34;
    UIView *bottomNav = [[UIView alloc] initWithFrame:CGRectMake(0, gScrH - bottomH, gScrW, bottomH)];
    bottomNav.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(gScrW / 2 - 130, 34, 120, 40);
    [copyBtn setTitle:@"复制日志" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{
        UIPasteboard.generalPasteboard.string = content;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 50, gScrH/2, 100, 36)];
        toast.text = @"已复制!"; toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.textColor = [UIColor whiteColor]; toast.layer.cornerRadius = 8; toast.clipsToBounds = YES;
        [win addSubview:toast];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [toast removeFromSuperview]; });
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:copyBtn];

    UIButton *uploadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    uploadBtn.frame = CGRectMake(gScrW / 2, 34, 120, 40);
    [uploadBtn setTitle:@"上传日志" forState:UIControlStateNormal];
    uploadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    uploadBtn.backgroundColor = [UIColor systemGreenColor];
    [uploadBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    uploadBtn.layer.cornerRadius = 8;
    [uploadBtn addTarget:NWSafeTarget(^{
        NWUploadLogs();
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:uploadBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(gScrW / 2 + 130, 34, 100, 40);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    closeBtn.backgroundColor = [UIColor systemGrayColor];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.layer.cornerRadius = 8;
    [closeBtn addTarget:NWSafeTarget(^{ win.hidden = YES; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:closeBtn];
    [win addSubview:bottomNav];
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
    [text appendFormat:@"=== 请求 ===\n"];
    [text appendFormat:@"%@ %@\n", req.method, req.url];
    [text appendFormat:@"时间: %@ (%.0fms)\n\n", req.timestamp, req.duration];
    if (req.requestHeaders.count > 0) { [text appendString:@"-- 请求头 --\n"]; for (NSString *k in req.requestHeaders) [text appendFormat:@"%@: %@\n", k, req.requestHeaders[k]]; [text appendString:@"\n"]; }
    if (req.requestBody.length > 0) { [text appendFormat:@"-- 请求体 --\n%@\n\n", req.requestBody]; }
    [text appendFormat:@"=== 响应 %ld ===\n\n", (long)req.statusCode];
    if (req.responseHeaders.count > 0) { [text appendString:@"-- 响应头 --\n"]; for (NSString *k in req.responseHeaders) [text appendFormat:@"%@: %@\n", k, req.responseHeaders[k]]; [text appendString:@"\n"]; }
    if (req.responseBody.length > 0) { [text appendString:@"-- 响应体 --\n"]; [text appendString:req.responseBody]; }

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, gScrW, gScrH - 90)];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tv.textColor = [UIColor labelColor];
    tv.text = text;
    [win addSubview:tv];

    CGFloat bottomH = 50 + 34;
    UIView *bottomNav = [[UIView alloc] initWithFrame:CGRectMake(0, gScrH - bottomH, gScrW, bottomH)];
    bottomNav.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(gScrW / 2 - 110, 34, 100, 40);
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{
        UIPasteboard.generalPasteboard.string = text;
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:copyBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(gScrW / 2 + 10, 34, 100, 40);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    closeBtn.backgroundColor = [UIColor systemGrayColor];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.layer.cornerRadius = 8;
    [closeBtn addTarget:NWSafeTarget(^{ win.hidden = YES; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:closeBtn];
    [win addSubview:bottomNav];
}

#pragma mark - 上传日志到 log.lengye.top

static void NWUploadLogs(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"NetworkLogger v4 - 主进程: %lu 个请求\n设备: %@ | 系统: %@\n\n",
        (unsigned long)gRequests.count, [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    for (NSUInteger i = 0; i < gRequests.count; i++) {
        NWRequest *r = gRequests[i];
        [text appendFormat:@"=== 请求 #%lu ===\n", (unsigned long)(i+1)];
        [text appendFormat:@"%@ %@ [%ld] (%.0fms)\n", r.method, r.url, (long)r.statusCode, r.duration];
        [text appendFormat:@"时间: %@\n", r.timestamp];
        if (r.requestHeaders.count > 0) { [text appendString:@"请求头:\n"]; for (NSString *k in r.requestHeaders) [text appendFormat:@"  %@: %@\n", k, r.requestHeaders[k]]; }
        if (r.requestBody.length > 0) [text appendFormat:@"请求体: %@\n", r.requestBody];
        if (r.responseHeaders.count > 0) { [text appendString:@"响应头:\n"]; for (NSString *k in r.responseHeaders) [text appendFormat:@"  %@: %@\n", k, r.responseHeaders[k]]; }
        if (r.responseBody.length > 0) [text appendFormat:@"响应体: %@\n", r.responseBody];
        [text appendString:@"\n"];
    }

    // 追加子进程日志
    NSString *subLog = [NSString stringWithContentsOfFile:gSubLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (subLog.length > 0) {
        [text appendString:@"=== 子进程日志 ===\n"];
        [text appendString:subLog];
    }

    NSURL *uploadURL = [NSURL URLWithString:@"https://log.lengye.top"];
    NSMutableURLRequest *uploadReq = [NSMutableURLRequest requestWithURL:uploadURL];
    uploadReq.HTTPMethod = @"POST";
    [uploadReq setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [uploadReq setValue:@"NetworkLogger-iOS" forHTTPHeaderField:@"User-Agent"];
    uploadReq.HTTPBody = [text dataUsingEncoding:NSUTF8StringEncoding];

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }

    // 显示"上传中"提示
    __block UIWindow *tw = [[UIWindow alloc] initWithWindowScene:scene];
    tw.windowLevel = UIWindowLevelAlert + 400;
    tw.frame = [UIScreen mainScreen].bounds; tw.hidden = NO;
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 80, gScrH/2, 160, 44)];
    toast.text = @"⏫ 上传中...";
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    toast.textColor = [UIColor whiteColor]; toast.layer.cornerRadius = 12; toast.clipsToBounds = YES;
    [tw addSubview:toast];

    [[[NSURLSession sharedSession] dataTaskWithRequest:uploadReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (error) {
                toast.text = [NSString stringWithFormat:@"❌ 上传失败: %@", error.localizedDescription];
            } else if (httpResp.statusCode >= 200 && httpResp.statusCode < 400) {
                toast.text = [NSString stringWithFormat:@"✅ 上传成功 (%lu 条)", (unsigned long)gRequests.count];
            } else {
                toast.text = [NSString stringWithFormat:@"❌ 服务器错误: %ld", (long)httpResp.statusCode];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tw.hidden = YES; });
        });
    }] resume];
}

#pragma mark - Copy All

static void NWCopyAllLogs(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"NetworkLogger v4 - 主进程: %lu 个请求\n设备: %@ | 系统: %@\n\n",
        (unsigned long)gRequests.count, [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    for (NSUInteger i = 0; i < gRequests.count; i++) {
        NWRequest *r = gRequests[i];
        [text appendFormat:@"#%lu %@ %@ [%ld] (%.0fms)\n", (unsigned long)(i+1), r.method, r.url, (long)r.statusCode, r.duration];
        if (r.requestHeaders.count > 0) { [text appendString:@"  请求头: "]; for (NSString *k in r.requestHeaders) [text appendFormat:@"%@=%@ ", k, r.requestHeaders[k]]; [text appendString:@"\n"]; }
        if (r.responseHeaders.count > 0) { [text appendString:@"  响应头: "]; for (NSString *k in r.responseHeaders) [text appendFormat:@"%@=%@ ", k, r.responseHeaders[k]]; [text appendString:@"\n"]; }
        if (r.responseBody.length > 0) [text appendFormat:@"  响应体: %@\n", r.responseBody];
        [text appendString:@"\n"];
    }

    NSString *subLog = [NSString stringWithContentsOfFile:gSubLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (subLog.length > 0) {
        [text appendString:@"=== 子进程日志 ===\n"];
        [text appendString:subLog];
    }

    UIPasteboard.generalPasteboard.string = text;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    UIWindow *tw = [[UIWindow alloc] initWithWindowScene:scene];
    tw.windowLevel = UIWindowLevelAlert + 400;
    tw.frame = [UIScreen mainScreen].bounds; tw.hidden = NO;
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 100, gScrH/2, 200, 44)];
    toast.text = [NSString stringWithFormat:@"已复制 %lu 条!", (unsigned long)gRequests.count];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    toast.textColor = [UIColor whiteColor]; toast.layer.cornerRadius = 12; toast.clipsToBounds = YES;
    [tw addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tw.hidden = YES; });
}

#pragma mark - Entry

__attribute__((constructor))
static void NWLoggerInit(void) {
    gRequests = [NSMutableArray new];

    [NSURLProtocol registerClass:[NWLogProtocol class]];
    NWSwizzleSession();
    NWSwizzleTasks();

    if (NWHasUIKit()) {
        NSLog(@"[NetworkLogger] v4 - UI 模式");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NWCreateBadge();
        });
    } else {
        gIsSubprocess = YES;
        NSLog(@"[NetworkLogger] v4 - 子进程模式，日志写入 %@", gSubLogPath());
    }
}
