#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ==========================================
// TrollInstallerX 卡密验证绕过插件
// 无论输入什么卡密都返回验证成功
// ==========================================

#pragma mark - NSURLProtocol 拦截器

@interface TIXBypassProtocol : NSURLProtocol
@property (nonatomic, strong) NSMutableData *receivedData;
@end

@implementation TIXBypassProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *url = request.URL.absoluteString;
    // 只拦截卡密验证请求
    if ([url containsString:@"api.php"] && [url containsString:@"kmlogon"]) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSLog(@"[TIXBypass] 拦截卡密验证请求: %@", self.request.URL.absoluteString);

    // 构造假的验证成功响应
    NSDictionary *fakeJSON = @{
        @"code": @200,
        @"msg": @"验证成功",
        @"check": @"bypass_ok",
        @"time": @((long)[[NSDate date] timeIntervalSince1970])
    };

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:fakeJSON options:0 error:nil];
    NSHTTPURLResponse *httpResponse = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
          statusCode:200
         HTTPVersion:@"HTTP/1.1"
        headerFields:@{
            @"Content-Type": @"application/json; charset=utf-8",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)jsonData.length]
        }];

    // 模拟正常网络响应
    [self.client URLProtocol:self didReceiveResponse:httpResponse cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:jsonData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    // nothing
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void TIXBypassInit(void) {
    NSLog(@"[TIXBypass] 插件已加载 - 卡密验证绕过模式");

    // 注册 URL 拦截器（拦截所有 URLSession 请求）
    [NSURLProtocol registerClass:[TIXBypassProtocol class]];

    // 同时设置 UserDefaults（双保险）
    dispatch_async(dispatch_get_main_queue(), ^{
        // 标准 UserDefaults
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"kami_verified"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // TIX 自定义 UserDefaults
        NSString *tixPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        tixPath = [tixPath stringByAppendingPathComponent:@"Preferences/com.Alfie.TrollInstallerX.plist"];
        NSUserDefaults *tixDefaults = [[NSUserDefaults alloc] initWithSuiteName:tixPath];
        [tixDefaults setBool:YES forKey:@"kami_verified"];
        [tixDefaults synchronize];

        NSLog(@"[TIXBypass] UserDefaults 已设置");
    });
}
