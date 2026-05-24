/**
 * haode-kami-bridge.m
 *
 * 桥接插件：把"巨魔好的"(haode-extension)的卡密验证系统替换为你的 kami.lengye.top
 *
 * 使用方式：
 *   1. 越狱设备安装 haode-extension.deb（Cydia/Sileo）
 *   2. 本文件用 GitHub Actions 编译成 dylib
 *   3. TrollFools 注入到"滴滴司机端"App
 *   4. 打开滴滴 → 弹出激活框 → 输入你的卡密 → 验证通过 → 功能正常
 *
 * 编译命令（macOS GitHub Actions）：
 *   clang -arch arm64 -arch arm64e \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -target arm64-apple-ios14.0 \
 *     -shared -dynamiclib \
 *     -framework Foundation -framework UIKit -framework Security \
 *     -fobjc-arc \
 *     -o HaodeKamiBridge.dylib haode-kami-bridge.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

#pragma mark - 配置：改成你自己的

// 你的卡密验证 API
static NSString * const kKamiAPIURL  = @"https://kami.lengye.top/api/card/check";
static NSString * const kKamiAppKey  = @"9VRZ0ATE1YKM";   // 你的 APPKEY

// haode-extension 的 Keychain 标识符（从逆向分析确认）
static NSString * const kHaoDeKeychainID = @"kGuanHaoDeAuthCode";

// Token 在 Keychain 里的 service 名（需要与 haode-extension 的 KeychainItemWrapper 匹配）
// haode 用 initWithUid:domain: 创建 KeychainItem，uid 可能是设备 UUID
static NSString * const kHaoDeService    = @"com.gt.haode-extension10";

#pragma mark - 设备码生成

static NSString *GetDeviceCode(void) {
    // 取设备 UUID 的 SHA256 前 16 位 hex（跟你卡密系统一致）
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"00000000-0000-0000-0000-000000000000";
    const char *cstr = [uuid UTF8String];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(cstr, (CC_LONG)strlen(cstr), hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return [hex uppercaseString];
}

#pragma mark - 你的卡密验证 API

static void VerifyKami(NSString *code, void (^completion)(BOOL success, NSString *msg)) {
    NSString *device = GetDeviceCode();

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kKamiAPIURL]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"appkey": kKamiAppKey,
        @"code":   code ?: @"",
        @"device": device
    };

    NSError *err = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) {
        NSLog(@"[HK-Bridge] JSON序列化失败: %@", err);
        completion(NO, @"内部错误");
        return;
    }

    NSLog(@"[HK-Bridge] 验证卡密: device=%@ code=%@", device, code);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) {
            NSLog(@"[HK-Bridge] 网络错误: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"网络连接失败"); });
            return;
        }

        NSError *parseErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!json) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[binary]";
            NSLog(@"[HK-Bridge] 响应解析失败: %@ raw=%@", parseErr, raw);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"服务器响应异常"); });
            return;
        }

        NSLog(@"[HK-Bridge] 服务器响应: %@", json);

        // 兼容多种返回格式
        NSInteger status = [json[@"code"] integerValue];
        if (status == 0) status = [json[@"status"] integerValue];
        if (status == 0) status = [json[@"code_num"] integerValue];

        BOOL ok = (status == 200 || status == 1 || json[@"ok"] != nil);
        NSString *msg = json[@"msg"] ?: json[@"message"] ?: (ok ? @"验证成功" : @"卡密无效");

        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, msg); });
    }] resume];
}

#pragma mark - Keychain 操作（模拟 haode-extension 的 KeychainItemWrapper）

static BOOL WriteTokenToKeychain(NSString *token) {
    // haode-extension 用 initWithUid:domain: 初始化 KeychainItemWrapper
    // 对应的 Keychain 查询字典：
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kHaoDeService,
        (__bridge id)kSecAttrAccount: kHaoDeKeychainID,
    };

    // 先删旧的
    SecItemDelete((__bridge CFDictionaryRef)query);

    // 写入新值
    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecSuccess) {
        NSLog(@"[HK-Bridge] Keychain 写入成功: %@ (%@)", kHaoDeKeychainID, token);
        return YES;
    }

    NSLog(@"[HK-Bridge] Keychain 写入失败: %d (可能需要 entitlements)", (int)status);
    return NO;
}

static BOOL WriteByPassFlag(NSString *code) {
    // 写两个地方：
    // 1. Keychain → haode-extension 启动时 guan_checkAuthCode: 能读到
    // 2. NSUserDefaults → 我们自己下次启动能检测到

    // 时间戳作为 token 值
    NSString *token = [NSString stringWithFormat:@"kami_bypass_%lld", (long long)[[NSDate date] timeIntervalSince1970]];
    BOOL keychainOK = WriteTokenToKeychain(token);

    // NSUserDefaults 备份
    [[NSUserDefaults standardUserDefaults] setObject:code forKey:@"HK_LastKamiCode"];
    [[NSUserDefaults standardUserDefaults] setObject:@(YES) forKey:@"HK_Activated"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    return keychainOK;
}

#pragma mark - UIAlert 拦截：劫持 haode 的激活弹窗

static BOOL gAlertHooked = NO;
static BOOL gProcessingActivation = NO;

static void ShowTip(NSString *title, NSString *msg) {
    // 找到当前最顶层的 VC
    UIViewController *topVC = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            topVC = ws.windows.firstObject.rootViewController;
            if (topVC) break;
        }
    }
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;

    UIAlertController *tip = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [tip addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [topVC presentViewController:tip animated:YES completion:nil];
}

static void HandleActivationCode(UIAlertController *alert, NSString *inputCode) {
    if (gProcessingActivation) return;
    gProcessingActivation = YES;

    NSLog(@"[HK-Bridge] 用户输入验证码: %@", inputCode);

    if (inputCode.length == 0) {
        gProcessingActivation = NO;
        ShowTip(@"提示", @"请输入验证码");
        return;
    }

    VerifyKami(inputCode, ^(BOOL success, NSString *msg) {
        if (success) {
            WriteByPassFlag(inputCode);

            // 关掉 haode 的弹窗
            [alert dismissViewControllerAnimated:YES completion:^{
                ShowTip(@"🎉 激活成功", @"卡密验证通过，功能已激活！");
            }];
        } else {
            ShowTip(@"激活失败", msg);
        }
        gProcessingActivation = NO;
    });
}

// Swizzle UIAlertController 的 addAction: 来拦截激活按钮
static void (*Orig_addAction)(id, SEL, id) = NULL;

static void Hooked_addAction(id self, SEL _cmd, UIAlertAction *action) {
    UIAlertController *alert = (UIAlertController *)self;

    // 检测是否是 haode 的激活弹窗
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    BOOL isKamiAlert = [title containsString:@"验证码"] || [title containsString:@"激活"] ||
                       [message containsString:@"验证码"] || [message containsString:@"激活"] ||
                       [title containsString:@"荣耀"];

    if (isKamiAlert) {
        NSString *btnTitle = [action valueForKey:@"title"] ?: @"";
        BOOL isActivateBtn = [btnTitle containsString:@"激活"] || [btnTitle containsString:@"确认"] ||
                             [btnTitle isEqualToString:@"OK"] || [btnTitle isEqualToString:@"确定"];

        if (isActivateBtn && action.style != UIAlertActionStyleDestructive) {
            NSLog(@"[HK-Bridge] 拦截激活按钮: %@ → 替换为 kami 验证", btnTitle);

            // 不添加原始 action，换成我们自己的
            UIAlertAction *ourAction = [UIAlertAction actionWithTitle:btnTitle
                style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *_action) {
                    NSString *code = @"";
                    if (alert.textFields.count > 0) {
                        code = [alert.textFields[0] text] ?: @"";
                    }
                    HandleActivationCode(alert, code);
                }];
            Orig_addAction(self, _cmd, ourAction);
            return;
        }
    }

    // 非目标，走原始
    Orig_addAction(self, _cmd, action);
}

#pragma mark - UIAlertController swizzle

static void InstallAlertHook(void) {
    if (gAlertHooked) return;
    gAlertHooked = YES;

    // Swizzle UIAlertController 的 addAction:
    Method m = class_getInstanceMethod([UIAlertController class], @selector(addAction:));
    if (!m) {
        NSLog(@"[HK-Bridge] 找不到 addAction: 方法");
        return;
    }
    Orig_addAction = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)Hooked_addAction);

    NSLog(@"[HK-Bridge] UIAlert 拦截已安装");
}

#pragma mark - 入口

__attribute__((constructor))
static void HaodeKamiBridgeInit(void) {
    NSLog(@"[HK-Bridge] ====== 卡密桥接插件已加载 ======");

    // 检查是否已激活过（从 NSUserDefaults）
    BOOL activated = [[NSUserDefaults standardUserDefaults] boolForKey:@"HK_Activated"];
    NSString *lastCode = [[NSUserDefaults standardUserDefaults] stringForKey:@"HK_LastKamiCode"];

    if (activated && lastCode.length > 0) {
        NSLog(@"[HK-Bridge] 检测到已激活记录，写入 Keychain");
        // 每次启动都写一次 Keychain，确保 haode 能读到
        NSString *token = [NSString stringWithFormat:@"kami_bypass_%lld", (long long)[[NSDate date] timeIntervalSince1970]];
        WriteTokenToKeychain(token);
    } else {
        NSLog(@"[HK-Bridge] 未激活，安装 UIAlert 拦截");
        // 注册 UIAlert 拦截 → 等 haode 弹出激活框时劫持
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                InstallAlertHook();
            });
    }

    // 额外保险：写 NSUserDefaults 备用
    // 某些情况下 haode 可能用别的路径读激活状态

    NSLog(@"[HK-Bridge] 初始化完成，账号: %@", activated ? lastCode : @"未激活");
}
