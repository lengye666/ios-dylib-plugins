#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ==========================================
// 通用卡密验证绕过插件
// 适用于任何 iOS App 的卡密/激活验证系统
// ==========================================

#pragma mark - NSURLProtocol 拦截器

@interface KamiBypassProtocol : NSURLProtocol
@end

@implementation KamiBypassProtocol

// 判断 URL 是否可能是卡密验证请求
+ (BOOL)isKamiRequest:(NSString *)urlString {
    NSArray *keywords = @[
        @"kmlogon",
        @"kami",
        @"cardkey",
        @"verify",
        @"check_kami",
        @"checkkami",
        @"auth",
        @"activate",
        @"license",
        @"valid",
        @"register_km",
        @"卡密",
        @"验证",
        @"激活",
    ];

    for (NSString *kw in keywords) {
        if ([urlString rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [self isKamiRequest:request.URL.absoluteString];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *url = self.request.URL.absoluteString;
    NSLog(@"[KamiBypass] 拦截卡密验证请求: %@", url);

    // 构造通用的验证成功响应
    // 兼容多种卡密系统的响应格式
    NSDictionary *fakeJSON = @{
        @"code": @200,
        @"status": @200,
        @"code_num": @1,
        @"msg": @"ok",
        @"message": @"ok",
        @"data": @{@"status": @1},
        @"check": @"bypass",
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

    [self.client URLProtocol:self didReceiveResponse:httpResponse cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:jsonData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

#pragma mark - 入口

__attribute__((constructor))
static void KamiBypassInit(void) {
    NSLog(@"[KamiBypass] 通用卡密验证绕过插件已加载");

    // 注册 URL 拦截器
    [NSURLProtocol registerClass:[KamiBypassProtocol class]];
}
