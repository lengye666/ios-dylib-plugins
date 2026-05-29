/**
 * douyin-class-dump.m
 * 抖音类名导出 — 极简版，只做一件事
 *
 * 注入后打开抖音 → 自动导出所有类名到文件
 * 文件路径: /var/mobile/Documents/douyin_classes.txt
 * 然后用 Filza 取出来发给我
 *
 * 编译: clang -arch arm64 -arch arm64e -shared -dynamiclib
 *       -framework Foundation -fobjc-arc -o DouyinDump.dylib
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void init_dump(void) {
    NSLog(@"[Dump] 抖音类名导出插件已加载");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC),
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[Dump] 开始扫描所有类...");

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);

        NSMutableString *output = [NSMutableString string];
        [output appendFormat:@"=== 抖音类名列表 (%u 个非系统类) ===\n", count];
        [output appendFormat:@"时间: %@\n\n", [NSDate date]];

        // 关键字过滤
        NSArray *keywords = @[@"drama",@"short",@"episode",@"ad",@"reward",
                              @"message",@"chat",@"im",@"conv",
                              @"player",@"video",@"play",@"download",
                              @"setting",@"prefer",@"account",
                              @"watermark",@"comment",@"follow",@"like",
                              @"live",@"stream",@"feed",@"home",
                              @"webview",@"jsbridge",@"h5"];

        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            NSString *name = NSStringFromClass(cls);
            NSString *lower = [name lowercaseString];

            // 只看抖音命名空间的类
            if (![lower hasPrefix:@"tt"] &&
                ![lower hasPrefix:@"aw"] &&
                ![lower hasPrefix:@"ss"] &&
                ![lower hasPrefix:@"ies"] &&
                ![lower hasPrefix:@"bu"] &&
                ![lower hasPrefix:@"csj"] &&
                ![lower hasPrefix:@"douyin"] &&
                ![lower hasPrefix:@"tiktok"]) {
                // 但也要包含广告 SDK 的类
                BOOL isAdSDK = [lower containsString:@"pangle"] ||
                               [lower containsString:@"buad"] ||
                               [lower containsString:@"reward"];
                if (!isAdSDK) continue;
            }

            Class superCls = class_getSuperclass(cls);

            // 列出方法和协议
            unsigned int mCount = 0;
            Method *methods = class_copyMethodList(cls, &mCount);
            NSMutableArray *methodNames = [NSMutableArray array];
            for (unsigned int m = 0; m < mCount && m < 20; m++) {
                [methodNames addObject:NSStringFromSelector(method_getName(methods[m]))];
            }
            free(methods);

            unsigned int pCount = 0;
            Protocol * __unsafe_unretained *protocols = class_copyProtocolList(cls, &pCount);
            NSMutableArray *protoNames = [NSMutableArray array];
            for (unsigned int p = 0; p < pCount; p++) {
                [protoNames addObject:NSStringFromProtocol(protocols[p])];
            }
            free(protocols);

            [output appendFormat:@"● %@", name];
            if (superCls) [output appendFormat:@" : %@", NSStringFromClass(superCls)];
            if (protoNames.count > 0) [output appendFormat:@" <%@>", [protoNames componentsJoinedByString:@", "]];
            [output appendString:@"\n"];
            for (NSString *m in methodNames) {
                [output appendFormat:@"    -%@\n", m];
            }
            if (mCount > 20) [output appendFormat:@"    ... +%u more\n", mCount - 20];
            [output appendString:@"\n"];
        }
        free(classes);

        // 直接上传到 log.lengye.top
        NSString *boundary = @"BoundaryDouyinDump";
        NSURL *url = [NSURL URLWithString:@"https://log.lengye.top/api/log/upload"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 60;
        [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
            forHTTPHeaderField:@"Content-Type"];

        NSMutableData *body = [NSMutableData data];
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"Content-Disposition: form-data; name=\"file\"; filename=\"douyin_classes.txt\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"Content-Type: text/plain; charset=utf-8\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[output dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        req.HTTPBody = body;

        NSLog(@"[Dump] 正在上传 %lu 字节到 log.lengye.top...", (unsigned long)body.length);

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
            if (e) {
                NSLog(@"[Dump] ❌ 上传失败: %@", e.localizedDescription);
                // 兜底写本地
                NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString *path = [docs stringByAppendingPathComponent:@"douyin_classes.txt"];
                [output writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSLog(@"[Dump] 已保存到本地: %@", path);
            } else {
                NSLog(@"[Dump] ✅ 上传成功 HTTP %ld", (long)http.statusCode);
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    });
}
