#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>

// ==========================================
// NetworkLogger v4 - Full coverage
// - UI process: NSURLProtocol + swizzle + floating UI
// - Subprocess: auto-injected via Process hook, logs to file
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

// Subprocess log file path
static NSString *gSubLogPath(void) {
    return @"/var/mobile/Documents/NW_subprocess.log";
}

static void NWShowDetailList(void);
static void NWShowSubLog(void);
static void NWCopyAllLogs(void);
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

// Find our dylib's file path on disk
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
            // Write header
            fprintf(gSubLogFile, "NetworkLogger - Subprocess Log\n\n");
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
        // Subprocess: write to file
        NSString *line = [NSString stringWithFormat:@"[%@] %@ %@ → %ld\n",
            ts, self.request.HTTPMethod ?: @"GET",
            self.request.URL.absoluteString,
            (long)((NSHTTPURLResponse *)resp).statusCode];
        NWWriteSubLog(line);
    } else {
        // Main process: add to array
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
            if (!e.requestBody) e.requestBody = @"[binary]";
        }
        [gRequests addObject:e];
    }

    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    h(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)dt didReceiveData:(NSData *)data {
    [self.respData appendData:data];
    [self.client URLProtocol:self didLoadData:data];

    // Also log response headers once we have some data
    if (!gIsSubprocess && gRequests.count > 0) {
        NWRequest *last = gRequests.lastObject;
        if (!last.responseBody) {
            NSData *d = self.respData.length > 10240
                ? [self.respData subdataWithRange:NSMakeRange(0, 10240)] : self.respData;
            // Will be finalized in didCompleteWithError
        }
    }
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionDataTask *)t didCompleteWithError:(NSError *)err {
    NSString *ts = NWTimeStr([NSDate date]);

    if (gIsSubprocess) {
        // Subprocess: log completion
        NSString *line;
        if (err) {
            line = [NSString stringWithFormat:@"[%@] ERROR: %@\n\n", ts, err.localizedDescription];
        } else {
            long bytes = (long)self.respData.length;
            line = [NSString stringWithFormat:@"[%@] Done (%ld bytes)\n\n", ts, bytes];
        }
        NWWriteSubLog(line);
    } else if (gRequests.count > 0) {
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

#pragma mark - Session Swizzle (metaclass)

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

#pragma mark - Hook Process to inject DYLD_INSERT_LIBRARIES

static void NWHookProcess(void) {
    // Process (Swift) is bridged to NSTask (ObjC)
    Class processClass = NSClassFromString(@"NSTask");
    if (!processClass) processClass = NSClassFromString(@"Process");
    if (!processClass) return;

    NSString *dylibPath = NWFindDylibPath();
    if (!dylibPath) {
        NSLog(@"[NW] Cannot find dylib path for Process hook");
        return;
    }

    SEL launchSel = @selector(launch);
    Method m = class_getInstanceMethod(processClass, launchSel);
    if (!m) return;

    IMP origIMP = method_getImplementation(m);
    IMP newIMP = imp_implementationWithBlock(^void(id self) {
        // Inject our dylib into subprocess environment
        NSMutableDictionary *env = [[self valueForKey:@"environment"] mutableCopy];
        if (!env) env = [NSMutableDictionary new];

        NSString *existing = env[@"DYLD_INSERT_LIBRARIES"];
        if (existing.length > 0) {
            env[@"DYLD_INSERT_LIBRARIES"] = [NSString stringWithFormat:@"%@:%@", existing, dylibPath];
        } else {
            env[@"DYLD_INSERT_LIBRARIES"] = dylibPath;
        }
        [self setValue:env forKey:@"environment"];

        NSLog(@"[NW] Process launch → injected DYLD_INSERT_LIBRARIES: %@", dylibPath);

        ((void (*)(id, SEL))origIMP)(self, launchSel);
    });
    method_setImplementation(m, newIMP);
    NSLog(@"[NW] Hooked Process/NSTask launch");
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

#pragma mark - Table Helper

@interface NWTblHelper : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *container;
@end

@implementation NWTblHelper

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return gRequests.count; }

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
    NWRequest *r = gRequests[ip.row];
    NSString *icon = (r.statusCode >= 200 && r.statusCode < 400) ? @"\u2705" : (r.statusCode >= 400 ? @"\u274C" : @"\U0001F4E1");
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
    [gBadge setTitle:@"\U0001F4E1 0" forState:UIControlStateNormal];
    [gBadge setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    NWDragHandler *dh = [NWDragHandler new];
    dh.window = gFloatWin; dh.btnSize = CGSizeMake(sz, sz);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:dh action:@selector(handlePan:)];
    [gBadge addGestureRecognizer:pan];
    NWRetainObj(dh);

    [gBadge addTarget:NWSafeTarget(^{ NWShowDetailList(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [gFloatWin addSubview:gBadge];

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        NSString *title = [NSString stringWithFormat:@"\U0001F4E1 %lu", (unsigned long)gRequests.count];
        // Check if subprocess log exists
        if ([[NSFileManager defaultManager] fileExistsAtPath:gSubLogPath()]) {
            title = [title stringByAppendingString:@" \u2B50"]; // star indicator
        }
        [gBadge setTitle:title forState:UIControlStateNormal];
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
    tl.text = [NSString stringWithFormat:@"Network Logger (%lu)", (unsigned long)gRequests.count];
    tl.font = [UIFont boldSystemFontOfSize:16];
    tl.textColor = [UIColor labelColor];
    tl.textAlignment = NSTextAlignmentCenter;
    [topBar addSubview:tl];
    helper.titleLabel = tl;
    [container addSubview:topBar];

    CGFloat bottomH = 50 + safeBottom;
    UITableView *tbl = [[UITableView alloc] initWithFrame:CGRectMake(0, topH, gScrW, cH - topH - bottomH) style:UITableViewStylePlain];
    tbl.dataSource = helper; tbl.delegate = helper;
    tbl.rowHeight = UITableViewAutomaticDimension; tbl.estimatedRowHeight = 60;
    [container addSubview:tbl];
    helper.tableView = tbl;

    // Bottom bar with 3 buttons
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, cH - bottomH, gScrW, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(10, safeBottom, 70, 40);
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    clearBtn.backgroundColor = [UIColor systemRedColor];
    [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    clearBtn.layer.cornerRadius = 8;
    [clearBtn addTarget:NWSafeTarget(^{ [gRequests removeAllObjects]; tl.text = @"Network Logger (0)"; [helper.tableView reloadData]; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:clearBtn];

    UIButton *subBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    subBtn.frame = CGRectMake(90, safeBottom, 70, 40);
    [subBtn setTitle:@"Sub" forState:UIControlStateNormal];
    subBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    subBtn.backgroundColor = [UIColor systemOrangeColor];
    [subBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    subBtn.layer.cornerRadius = 8;
    [subBtn addTarget:NWSafeTarget(^{ NWShowSubLog(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:subBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(170, safeBottom, 70, 40);
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{ NWCopyAllLogs(); }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:copyBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(250, safeBottom, 70, 40);
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
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
        content = @"No subprocess log found.\n\nThe target app might not use Process/NSTask,\nor DYLD_INSERT_LIBRARIES was blocked.";
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
    copyBtn.frame = CGRectMake(gScrW / 2 - 110, 34, 100, 40);
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    copyBtn.backgroundColor = [UIColor systemBlueColor];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.layer.cornerRadius = 8;
    [copyBtn addTarget:NWSafeTarget(^{
        UIPasteboard.generalPasteboard.string = content;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(gScrW/2 - 50, gScrH/2, 100, 36)];
        toast.text = @"Copied!"; toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.textColor = [UIColor whiteColor]; toast.layer.cornerRadius = 8; toast.clipsToBounds = YES;
        [win addSubview:toast];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [toast removeFromSuperview]; });
    }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:copyBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(gScrW / 2 + 10, 34, 100, 40);
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
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
    [text appendFormat:@"=== REQUEST ===\n"];
    [text appendFormat:@"%@ %@\n", req.method, req.url];
    [text appendFormat:@"Time: %@ (%.0fms)\n\n", req.timestamp, req.duration];
    if (req.requestHeaders.count > 0) { [text appendString:@"-- Req Headers --\n"]; for (NSString *k in req.requestHeaders) [text appendFormat:@"%@: %@\n", k, req.requestHeaders[k]]; [text appendString:@"\n"]; }
    if (req.requestBody.length > 0) { [text appendFormat:@"-- Req Body --\n%@\n\n", req.requestBody]; }
    [text appendFormat:@"=== RESPONSE %ld ===\n\n", (long)req.statusCode];
    if (req.responseHeaders.count > 0) { [text appendString:@"-- Resp Headers --\n"]; for (NSString *k in req.responseHeaders) [text appendFormat:@"%@: %@\n", k, req.responseHeaders[k]]; [text appendString:@"\n"]; }
    if (req.responseBody.length > 0) { [text appendString:@"-- Resp Body --\n"]; [text appendString:req.responseBody]; }

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
    [copyBtn setTitle:@"Copy" forState:UIControlStateNormal];
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
    [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    closeBtn.backgroundColor = [UIColor systemGrayColor];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.layer.cornerRadius = 8;
    [closeBtn addTarget:NWSafeTarget(^{ win.hidden = YES; }) action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [bottomNav addSubview:closeBtn];
    [win addSubview:bottomNav];
}

#pragma mark - Copy All

static void NWCopyAllLogs(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"NetworkLogger v4 - Main Process: %lu requests\nDevice: %@ | OS: %@\n\n",
        (unsigned long)gRequests.count, [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    for (NSUInteger i = 0; i < gRequests.count; i++) {
        NWRequest *r = gRequests[i];
        [text appendFormat:@"#%lu %@ %@ [%ld] (%.0fms)\n", (unsigned long)(i+1), r.method, r.url, (long)r.statusCode, r.duration];
        if (r.requestHeaders.count > 0) { [text appendString:@"  ReqH: "]; for (NSString *k in r.requestHeaders) [text appendFormat:@"%@=%@ ", k, r.requestHeaders[k]]; [text appendString:@"\n"]; }
        if (r.responseHeaders.count > 0) { [text appendString:@"  RespH: "]; for (NSString *k in r.responseHeaders) [text appendFormat:@"%@=%@ ", k, r.responseHeaders[k]]; [text appendString:@"\n"]; }
        if (r.responseBody.length > 0) [text appendFormat:@"  RespB: %@\n", r.responseBody];
        [text appendString:@"\n"];
    }

    // Append subprocess log if exists
    NSString *subLog = [NSString stringWithContentsOfFile:gSubLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (subLog.length > 0) {
        [text appendString:@"=== SUBPROCESS LOG ===\n"];
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
    toast.text = [NSString stringWithFormat:@"Copied %lu!", (unsigned long)gRequests.count];
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

    // Network hooks (work in both UI and subprocess mode)
    [NSURLProtocol registerClass:[NWLogProtocol class]];
    NWSwizzleSession();

    if (NWHasUIKit()) {
        // === UI PROCESS MODE ===
        NSLog(@"[NetworkLogger] v4 - UI mode");
        NWHookProcess(); // Hook Process to inject into subprocesses
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NWCreateBadge();
        });
    } else {
        // === SUBPROCESS MODE ===
        gIsSubprocess = YES;
        NSLog(@"[NetworkLogger] v4 - Subprocess mode, logging to %@", gSubLogPath());
    }
}
