/**
 * douyin-class-dump.m v2 — 极简版，只导关键类名
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void init_dump(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[Dump] 扫描抖音类名...");

        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);

        // 只导出匹配关键词的类名（不导出方法，大幅减小体积）
        NSArray *kw = @[@"drama",@"short",@"episode",@"series",@"playlist",
                        @"reward",@"fullscreen",@"splash",@"feed",
                        @"message",@"chat",@"im",@"convers",
                        @"player",@"video",@"avplayer",@"stream",
                        @"download",@"watermark",@"share",
                        @"setting",@"prefer",@"account",@"profile",
                        @"comment",@"like",@"follow",
                        @"live",@"gift",@"room",
                        @"search",@"discover",@"hot",
                        @"webview",@"h5",@"jsbridge",
                        @"push",@"notify",@"alert"];

        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"=== 抖音关键类名 (%u total ===\n", count];

        int matched = 0;
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            NSString *lower = [name lowercaseString];

            // 只看抖音命名空间
            if (![lower hasPrefix:@"tt"] && ![lower hasPrefix:@"aw"] &&
                ![lower hasPrefix:@"ss"] && ![lower hasPrefix:@"ies"] &&
                ![lower hasPrefix:@"bu"] && ![lower hasPrefix:@"csj"]) continue;

            // 匹配关键词
            BOOL hit = NO;
            for (NSString *k in kw) {
                if ([lower containsString:k]) { hit = YES; break; }
            }
            if (!hit) continue;

            Class superCls = class_getSuperclass(cls);
            [out appendFormat:@"%@", name];
            if (superCls) [out appendFormat:@" : %@", NSStringFromClass(superCls)];
            [out appendString:@"\n"];
            matched++;
        }
        free(classes);

        [out appendFormat:@"\n匹配: %d 个类", matched];

        // 上传
        NSData *body = [out dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://log.lengye.top/"]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 60;
        [req setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = body;

        NSLog(@"[Dump] 上传 %lu 字节 (%d 个类)...", (unsigned long)body.length, matched);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSLog(@"[Dump] HTTP %ld %@", (long)[(NSHTTPURLResponse *)r statusCode],
                  e ? e.localizedDescription : @"✅");
        }] resume];
    });
}
