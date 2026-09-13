// Sentinel.m — 屏幕哨兵（TrollFools 注入用）
// ============================================================
// 干什么：圈一块屏幕区域，盯住它，OCR 认出关键字就报警（横幅 + 震动）。
//
// 设计要点（2026-09-13 定稿）：
//   ① 只截框选那一块、只对那一块跑 OCR —— 省一个数量级 CPU，且大幅降低误命中
//   ② 分级节奏：空闲 2s / 刚命中连验（500ms，连中 2 轮才算）
//   ③ 关键字匹配（v2.4）：归一化 + 精确包含 + 置信度阈值；容错与同义词已按用户要求删除（宁漏不误）
//   ④ 去重冷却：同一关键字 N 秒内只报一次
//   ⑤ 报警用非阻塞横幅，绝不用 UIAlertController（会抢焦点，影响正在操作的 App）
//   ⑥ 铃声只用 system sound，不建 AVAudioSession（同进程里可能还有别的插件在用）
//   ⑦ 自己的配置一律 sentinel_ 前缀，不和别人的键打架
//   ⑧ 收到"整体任务执行"通知时降频，避开同进程其他插件点击时的时序冲突
//
// 与同进程其他插件共存的约定：
//   - 悬浮球放【左边】（同类插件常放右边），可拖动，位置记 NSUserDefaults
//   - 横幅窗口 frame 只占横幅本身，不铺满屏幕（铺满会吞掉全屏触摸）
//   - 所有窗口不设 rootViewController、不 makeKeyAndVisible
//
// 排错：idevicesyslog 里 grep "Sentinel"；或看沙盒 Documents/Sentinel.log
// ============================================================

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdio.h>
#import <objc/runtime.h>

#pragma mark - 可调参数

static const NSTimeInterval kStartupDelay   = 0.6;
static const double kIdleInterval           = 2.0;   // 空闲扫描间隔(秒)
static const double kVerifyInterval         = 0.5;   // 命中后连验间隔(秒)
static const int    kVerifyNeed             = 2;     // 连续 N 轮命中才报警（防误报）
static const double kCooldownDefault        = 10.0;  // 同一关键字冷却(秒)
static const CGFloat kMinRegionSide         = 24.0;  // 框选最小边长(pt)
static const double kSelftestBandY          = 0.44;  // 自测假图里文字所在条带(归一化)
static const double kSelftestBandH          = 0.14;

// v2.3：删掉"与老贝贝共存"整套（入口挂载开关 + 收到对端通知降频）——用户确认不需要

// 面板配色（v2.2：上移到文件前部 —— 报警卡片在面板工厂之前定义，要用这几个宏）
#define PANEL_BG      [UIColor colorWithRed:0.173 green:0.173 blue:0.180 alpha:0.95]  // #2C2C2E
#define PANEL_FIELD   [UIColor colorWithRed:0.227 green:0.227 blue:0.235 alpha:1.0]   // #3A3A3C 输入框/按钮
#define PANEL_TROUGH  [UIColor colorWithRed:0.110 green:0.110 blue:0.118 alpha:1.0]   // #1C1C1E 分段控件底
#define PANEL_TEXT    [UIColor whiteColor]
#define PANEL_DIM     [UIColor colorWithWhite:1.0 alpha:0.62]   // 字段标题
#define PANEL_HAIR    [UIColor colorWithWhite:1.0 alpha:0.07]   // 极淡分隔

// 报警卡片要用到的控件工厂（实现在后面的面板区）
static UILabel *mkLabel(NSString *text, CGFloat size, UIColor *color, BOOL bold);
static UIButton *mkFootButton(NSString *title, BOOL primary, NSInteger tag);

#pragma mark - 配置（sentinel_ 前缀）

static NSArray<NSString *> *splitList(NSString *s, NSString *sep) {
    NSMutableArray *out = [NSMutableArray array];
    if (!s.length) return out;
    for (NSString *p in [s componentsSeparatedByString:sep]) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

static NSArray<NSString *> *loadKeywords(void) {
    NSArray *ks = splitList([[NSUserDefaults standardUserDefaults] stringForKey:@"sentinel_keywords"], @",");
    return ks.count ? ks : @[ @"体力不足", @"无法操作" ];
}

// "体力不足=体力不够=没体力;金币不足=金币不够" → @[ @[..], @[..] ]
// v2.4：loadSynonyms 已删除（同义词功能移除）

static double cfgDouble(NSString *key, double def) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return n ? n.doubleValue : def;
}

static BOOL loadRegion(CGRect *out) {
    NSArray *v = splitList([[NSUserDefaults standardUserDefaults] stringForKey:@"sentinel_region"], @",");
    if (v.count != 4) return NO;
    CGRect r = CGRectMake([v[0] doubleValue], [v[1] doubleValue], [v[2] doubleValue], [v[3] doubleValue]);
    if (r.size.width <= 0.01 || r.size.height <= 0.01) return NO;
    if (r.origin.x < 0 || r.origin.y < 0) return NO;
    if (out) *out = r;
    return YES;
}

static void saveRegion(CGRect r) {
    [[NSUserDefaults standardUserDefaults] setObject:
        [NSString stringWithFormat:@"%.5f,%.5f,%.5f,%.5f", r.origin.x, r.origin.y, r.size.width, r.size.height]
        forKey:@"sentinel_region"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 日志

static NSString *g_logPath = nil;
static NSMutableString *g_selftestLog = nil;

static void logToFile(NSString *msg) {
    @try {
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            g_logPath = [(doc ?: NSHomeDirectory()) stringByAppendingPathComponent:@"Sentinel.log"];
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss.SSS";
            FILE *f = fopen(g_logPath.fileSystemRepresentation, "a");
            if (f) { fputs("---- session ----\n", f); fclose(f); }
        });
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [df stringFromDate:[NSDate date]], msg];
        FILE *f = fopen(g_logPath.fileSystemRepresentation, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    } @catch (NSException *e) { }
}

#define SLog(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[Sentinel] %@", _m); \
    logToFile(_m); \
} while (0)

static void stWrite(NSString *line) {
    SLog(@"selftest: %@", line);
    if (!g_selftestLog) g_selftestLog = [NSMutableString string];
    [g_selftestLog appendFormat:@"%@\n", line];
}

#pragma mark - 字符串工具

static NSString *normalizeText(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    static NSCharacterSet *ws = nil, *punct = nil, *sym = nil;
    if (!ws) {
        ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        punct = [NSCharacterSet punctuationCharacterSet];
        sym = [NSCharacterSet symbolCharacterSet];
    }
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0xFF01 && c <= 0xFF5E) c = (unichar)(c - 0xFEE0);
        if (c == 0x3000) continue;
        if ([ws characterIsMember:c]) continue;
        if ([punct characterIsMember:c]) continue;
        if ([sym characterIsMember:c]) continue;
        [out appendString:[[NSString stringWithCharacters:&c length:1] lowercaseString]];
    }
    return out;
}

// v2.4：editDistance（编辑距离容错）已删除 —— 改精确匹配

// v2.4：宁漏不误 —— 只做精确包含，删掉编辑距离容错
// （用户定调：要精确识别，OCR 认错一个字就不认，避免误报）
static BOOL matchOne(NSString *normText, NSString *normKw) {
    if (!normText.length || !normKw.length) return NO;
    return [normText containsString:normKw];
}

// 一行文字是否命中；命中返回"报告用的关键词原文"，没命中返回 nil
// v2.4：删掉同义词组 —— 用户判断完全没用（要精确识别，同义词表要人维护、鸡肋）
static NSString *matchLine(NSString *normText, NSArray<NSString *> *keywords) {
    for (NSString *kw in keywords) {
        if (matchOne(normText, normalizeText(kw))) return kw;
    }
    return nil;
}

#pragma mark - 全局状态

static dispatch_queue_t g_queue;
static BOOL   g_armed = NO;
static BOOL   g_running = NO;
static BOOL   g_selecting = NO;
static BOOL   g_selftest = NO;
static NSArray<NSString *> *g_keywords = nil;
static NSMutableDictionary *g_lastAlert = nil;
static NSMutableDictionary *g_hitStreak = nil;
static NSString *g_lastReport = @"(还没有记录)";
static NSString *g_lastHitKeyword = nil;   // v2.2：最近命中的关键词（只用来精简显示状态行）
static NSArray<NSString *> *g_lastScanTexts = nil;
static UIWindow *g_ballWin = nil;
static UIWindow *g_bannerWin = nil;
static UILabel  *g_bannerLabel = nil;
static int g_seltestPass = 0, g_selftestFail = 0;
static BOOL g_guided = NO;   // 首次引导只做一次

// 前置声明
static void panelShow(void);
static void panelHide(void);
static void panelRefreshStatus(void);
static void showRegionSelector(void);
static void probeOnce(void);
static void startWatching(void);
static void stopWatching(void);
static void createFloatingBall(void);
static UIImage *renderFakeHUD(void);
static void runSelftest(void);

static void refreshConfig(void) {
    g_keywords = loadKeywords();
}

#pragma mark - 截屏 + 裁剪

static UIImage *captureScreen(void) {
    __block UIImage *img = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s; break;
                }
            }
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSArray<UIWindow *> *wins = scene.windows;
            if (wins.count == 0) wins = [[UIApplication sharedApplication] windows];
            #pragma clang diagnostic pop
            if (wins.count == 0) return;

            NSArray<UIWindow *> *sorted = [wins sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
                if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
                if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            UIScreen *scr = scene.screen ?: [UIScreen mainScreen];
            CGSize pts = scr.bounds.size;
            if (pts.width < 2 || pts.height < 2) return;
            UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
            fmt.scale = scr.scale;
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pts format:fmt];
            img = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
                for (UIWindow *w in sorted) {
                    if (w == g_ballWin || w == g_bannerWin) continue;   // 别把自己的球和横幅拍进去
                    if (w.hidden || w.alpha < 0.01 || w.frame.size.width < 1) continue;
                    [w drawViewHierarchyInRect:w.frame afterScreenUpdates:NO];
                }
            }];
        } @catch (NSException *e) {
            SLog(@"capture exception: %@", e);
        }
    });
    return img;
}

static UIImage *cropToRegion(UIImage *full, CGRect norm) {
    if (!full) return nil;
    CGImageRef cg = full.CGImage;
    if (!cg) return nil;
    size_t W = CGImageGetWidth(cg), H = CGImageGetHeight(cg);
    CGFloat x0 = norm.origin.x * W, y0 = norm.origin.y * H;
    CGFloat w  = norm.size.width * W, h = norm.size.height * H;
    if (x0 < 0) { w += x0; x0 = 0; }
    if (y0 < 0) { h += y0; y0 = 0; }
    if (x0 + w > W) w = W - x0;
    if (y0 + h > H) h = H - y0;
    if (w < 4 || h < 4) return nil;
    CGImageRef sub = CGImageCreateWithImageInRect(cg, CGRectMake(floor(x0), floor(y0), floor(w), floor(h)));
    if (!sub) return nil;
    UIImage *out = [UIImage imageWithCGImage:sub scale:full.scale orientation:full.imageOrientation];
    CGImageRelease(sub);
    return out;
}

#pragma mark - OCR

static void runOCR(UIImage *img, void (^done)(NSArray<NSArray *> *items)) {
    NSMutableArray *items = [NSMutableArray array];
    if (!img || !img.CGImage) { done(items); return; }
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *request, NSError *reqErr) {
            if (reqErr) SLog(@"ocr error: %@", reqErr.localizedDescription);
            for (VNObservation *o in (request.results ?: @[])) {
                if (![o isKindOfClass:[VNRecognizedTextObservation class]]) continue;
                VNRecognizedText *t = [((VNRecognizedTextObservation *)o) topCandidates:1].firstObject;
                if (!t || !t.string.length) continue;
                if (t.confidence < 0.30f) continue;
                [items addObject:@[ normalizeText(t.string), t.string, @(t.confidence) ]];
            }
            done(items);
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;   // 认关键字，别让系统"纠"掉
    req.minimumTextHeight = 0.0f;      // 小字也要（HUD 文字通常很小）
    @try {
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
        NSError *err = nil;
        [h performRequests:@[req] error:&err];
        if (err) { SLog(@"ocr perform error: %@", err.localizedDescription); done(items); }
    } @catch (NSException *e) {
        SLog(@"ocr exception: %@", e);
        done(items);
    }
}

#pragma mark - 报警：非阻塞横幅 + 震动

static void showBanner(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s; break;
                }
            }
            if (!scene) return;
            CGSize scr = scene.screen.bounds.size;
            CGFloat h = 46.0;
            if (!g_bannerWin) {
                UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
                w.windowLevel = UIWindowLevelAlert + 97;
                w.backgroundColor = [UIColor colorWithRed:0.85 green:0.22 blue:0.20 alpha:0.94];
                w.clipsToBounds = YES;
                UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
                lb.textAlignment = NSTextAlignmentCenter;
                lb.font = [UIFont boldSystemFontOfSize:15];
                lb.textColor = [UIColor whiteColor];
                lb.numberOfLines = 1;
                lb.adjustsFontSizeToFitWidth = YES;
                lb.minimumScaleFactor = 0.7;
                g_bannerLabel = lb;
                [w addSubview:lb];
                g_bannerWin = w;
            }
            // 关键：窗口 frame 只占横幅，不铺满屏（铺满会吞掉全屏触摸）
            // v2.2：从安全区下方开始 —— 原来从 y=0 起步，整条被 iOS 系统状态栏压住，所以"看不到内容"
            CGFloat sbH = 44;
            if (@available(iOS 13.0, *)) sbH = scene.statusBarManager.statusBarFrame.size.height;
            if (sbH < 20) sbH = 44;
            CGFloat y = sbH + 6;
            g_bannerWin.frame = CGRectMake(0, y - h, scr.width, h);
            g_bannerLabel.frame = g_bannerWin.bounds;
            g_bannerLabel.text = text;
            g_bannerWin.hidden = NO;

            [UIView animateWithDuration:0.22 animations:^{
                g_bannerWin.frame = CGRectMake(0, y, scr.width, h);
            }];

            static int gen = 0;
            int my = ++gen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (my != gen || !g_bannerWin) return;
                [UIView animateWithDuration:0.25 animations:^{
                    g_bannerWin.frame = CGRectMake(0, y - h, scr.width, h);
                } completion:^(BOOL f) {
                    if (my == gen && g_bannerWin) g_bannerWin.hidden = YES;
                }];
            });
        } @catch (NSException *e) { SLog(@"banner exception: %@", e); }
    });
}

// ===== v2.2 新增：报警卡片 =====
// 顶部窄条只有 46pt 高、又被系统状态栏压住，真机上"内容完全看不到" →
// 报警时额外弹一张卡片，把命中的关键词 + 识别到的原文完整摊开。
// 卡片窗口只包住卡片本身（不铺满屏），所以不会挡住下面的操作；8 秒后自动收，也能点"知道了"提前收。
static UIWindow *g_alertCardWin = nil;
static int g_alertCardGen = 0;

static void dismissAlertCard(void) {
    if (!g_alertCardWin) return;
    UIWindow *w = g_alertCardWin;
    g_alertCardWin = nil;
    g_alertCardGen++;
    [UIView animateWithDuration:0.2 animations:^{ w.alpha = 0; }
                     completion:^(BOOL f) { w.hidden = YES; }];
}

@interface SELAlertActions : NSObject
@end
@implementation SELAlertActions
+ (void)onDismiss:(id)sender { dismissAlertCard(); }
@end

static void showAlertCard(NSString *keyword, NSString *rawText) {
    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        dismissAlertCard();   // 先收掉上一张
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) return;
        CGSize S = scene.screen.bounds.size;
        CGFloat top = 44;
        if (@available(iOS 13.0, *)) top = scene.statusBarManager.statusBarFrame.size.height;
        if (top < 20) top = 44;

        CGFloat cw = round(S.width * 0.84);
        CGFloat padX = 16;
        CGFloat innerW = cw - padX * 2;

        NSString *raw = rawText.length ? rawText : @"（这一轮没识别到可读文字）";
        UIFont *rawFont = [UIFont systemFontOfSize:14];
        CGRect rawRect = [raw boundingRectWithSize:CGSizeMake(innerW, 999)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{ NSFontAttributeName: rawFont } context:nil];
        CGFloat rawH = MIN(ceil(rawRect.size.height), ceil(rawFont.lineHeight * 4));   // 最多 4 行

        CGFloat h = 4 + 12 + 22 + 8 + 26 + 10 + 16 + rawH + 10 + 16 + 12 + 44 + 16;
        CGFloat x = (S.width - cw) / 2.0;
        CGFloat y = top + 52;
        if (y + h > S.height - 40) y = MAX(top + 16, S.height - 40 - h);

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(x - 6, y - 6, cw + 12, h + 12);   // 只包住卡片，不吞全屏触摸
        w.windowLevel = UIWindowLevelAlert + 98;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = YES;
        w.alpha = 0;
        g_alertCardWin = w;
        g_alertCardGen++;
        int my = g_alertCardGen;

        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(6, 6, cw, h)];
        card.backgroundColor = PANEL_BG;
        card.layer.cornerRadius = 16;
        card.clipsToBounds = YES;
        [w addSubview:card];

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 4)];
        bar.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
        [card addSubview:bar];

        CGFloat cy = 16;
        UILabel *t = mkLabel(@"🚨 哨兵报警", 16, PANEL_TEXT, YES);
        t.frame = CGRectMake(padX, cy, innerW, 22);
        [card addSubview:t];
        cy += 30;

        UILabel *k = mkLabel([NSString stringWithFormat:@"命中「%@」", keyword.length ? keyword : @"?"], 20,
                             [UIColor colorWithRed:1.0 green:0.38 blue:0.32 alpha:1.0], YES);
        k.frame = CGRectMake(padX, cy, innerW, 26);
        [card addSubview:k];
        cy += 36;

        UILabel *sub = mkLabel(@"识别到的文字", 12, PANEL_DIM, NO);
        sub.frame = CGRectMake(padX, cy, innerW, 16);
        [card addSubview:sub];
        cy += 18;

        UILabel *rawL = mkLabel(raw, 14, PANEL_TEXT, NO);
        rawL.font = rawFont;
        rawL.numberOfLines = 4;
        rawL.lineBreakMode = NSLineBreakByTruncatingTail;
        rawL.frame = CGRectMake(padX, cy, innerW, rawH);
        [card addSubview:rawL];
        cy += rawH + 10;

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        UILabel *ts = mkLabel([NSString stringWithFormat:@"%@ 报警", [df stringFromDate:[NSDate date]]],
                              11, PANEL_DIM, NO);
        ts.frame = CGRectMake(padX, cy, innerW, 16);
        [card addSubview:ts];

        UIButton *ok = mkFootButton(@"知道了", YES, 0);
        ok.frame = CGRectMake(padX, h - 16 - 44, innerW, 44);
        [ok removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
        [ok addTarget:[SELAlertActions class] action:@selector(onDismiss:)
     forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:ok];

        w.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ w.alpha = 1; }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (my == g_alertCardGen) dismissAlertCard();
        });
        SLog(@"alert card shown: keyword='%@' rawLen=%lu", keyword, (unsigned long)rawText.length);
      } @catch (NSException *e) { SLog(@"alert card exception: %@", e); }
    });
}

static void fireAlert(NSString *keyword, NSString *rawText) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL vibrate = [ud boolForKey:@"sentinel_vibrate"];
    BOOL sound   = [ud boolForKey:@"sentinel_sound"];
    if (vibrate) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    if (sound)   AudioServicesPlaySystemSound(1007);
    g_lastHitKeyword = keyword;   // 状态行只显示这个关键词，别把整段识别原文塞进去
    showBanner([NSString stringWithFormat:@"哨兵｜命中「%@」", keyword]);
    showAlertCard(keyword, rawText);   // 完整内容看卡片
    SLog(@"ALERT keyword='%@' raw='%@' vibrate=%d sound=%d", keyword, rawText, (int)vibrate, (int)sound);
}

#pragma mark - 一轮扫描

// 跑 OCR + 匹配；命中写入 outHits，识别到的原始文字写入 outTexts
static void evaluate(UIImage *crop, NSMutableArray *outHits, NSMutableArray *outTexts) {
    if (!crop) return;
    runOCR(crop, ^(NSArray<NSArray *> *items) {
        for (NSArray *it in items) {
            NSString *norm = it[0], *raw = it[1];
            [outTexts addObject:raw];
            NSString *k = matchLine(norm, g_keywords);
            if (k) [outHits addObject:k];
        }
    });
}

static NSString *joinShort(NSArray *a) {
    if (!a.count) return @"(无文字)";
    NSMutableArray *m = [NSMutableArray array];
    for (NSString *s in a) { [m addObject:s]; if (m.count >= 8) break; }
    return [m componentsJoinedByString:@" / "];
}

static void scanOnce(NSString *reason) {
    if (g_selecting) return;

    if (g_selftest) { runSelftest(); return; }

    CGRect norm;
    if (!loadRegion(&norm)) {
        g_lastReport = @"还没圈定监视区域（点头 →「圈定监视区域」）";
        return;
    }

    // v2.4：耗时拆解日志 —— 用户要"毫秒级"，先拿真机数字说话，别拍脑袋调参
    NSTimeInterval t0 = CACurrentMediaTime();
    UIImage *full = captureScreen();
    NSTimeInterval t1 = CACurrentMediaTime();
    if (!full) { SLog(@"scan(%@) capture failed", reason); return; }
    UIImage *crop = cropToRegion(full, norm);
    NSTimeInterval t2 = CACurrentMediaTime();
    if (!crop) { SLog(@"scan(%@) crop failed", reason); return; }

    NSMutableArray *hits = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];
    evaluate(crop, hits, texts);
    NSTimeInterval t3 = CACurrentMediaTime();
    g_lastScanTexts = [texts copy];

    size_t pw = crop.CGImage ? CGImageGetWidth(crop.CGImage) : 0;
    size_t ph = crop.CGImage ? CGImageGetHeight(crop.CGImage) : 0;
    SLog(@"timing(%@): 截屏 %.0fms | 裁剪 %.0fms | OCR+匹配 %.0fms | 单轮合计 %.0fms | 送检图 %.0fx%.0f 像素(%.1f万) | 文字 %lu 条",
         reason, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t3 - t0) * 1000,
         (double)pw, (double)ph, pw * ph / 10000.0, (unsigned long)texts.count);

    SLog(@"scan(%@) crop=%.0fx%.0f texts=%lu hits=%@", reason,
         crop.size.width, crop.size.height, (unsigned long)texts.count,
         hits.count ? [hits componentsJoinedByString:@"|"] : @"-");

    if (!hits.count) {
        [g_hitStreak removeAllObjects];
        g_lastReport = [NSString stringWithFormat:@"待命 · 本轮识别 %@", joinShort(texts)];
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    double cooldown = cfgDouble(@"sentinel_cooldown", kCooldownDefault);
    for (NSString *kw in hits) {
        int n = [g_hitStreak[kw] intValue] + 1;
        g_hitStreak[kw] = @(n);
        if (n < kVerifyNeed) { SLog(@"hit '%@' streak %d/%d (待确认)", kw, n, kVerifyNeed); continue; }
        NSTimeInterval last = [g_lastAlert[kw] doubleValue];
        if (last > 0 && now - last < cooldown) {
            SLog(@"hit '%@' 冷却中（%.1fs 前报过）", kw, now - last);
            continue;
        }
        g_lastAlert[kw] = @(now);
        g_hitStreak[kw] = @0;
        fireAlert(kw, joinShort(texts));
        g_lastReport = [NSString stringWithFormat:@"已报警「%@」· 识别到 %@", kw, joinShort(texts)];
        return;
    }
    g_lastReport = [NSString stringWithFormat:@"命中待确认 · %@", joinShort(texts)];
}

static void scheduleNextScan(void) {
    if (!g_running) return;
    double iv = cfgDouble(@"sentinel_interval", kIdleInterval);
    BOOL verifying = NO;
    for (NSNumber *n in g_hitStreak.allValues) if (n.intValue > 0) { verifying = YES; break; }
    if (verifying && iv > kVerifyInterval) iv = kVerifyInterval;
    if (iv < 0.2) iv = 0.2;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)), g_queue, ^{
        if (!g_running) return;
        @autoreleasepool { scanOnce(@"tick"); }
        scheduleNextScan();
    });
}

static void startWatching(void) {
    if (g_running) return;
    g_running = YES;
    SLog(@"watch start (interval %.1fs, cooldown %.1fs, keywords=%@)",
         cfgDouble(@"sentinel_interval", kIdleInterval),
         cfgDouble(@"sentinel_cooldown", kCooldownDefault),
         [g_keywords componentsJoinedByString:@"|"]);
    scheduleNextScan();
}

static void stopWatching(void) { g_running = NO; SLog(@"watch stop"); }

static void probeOnce(void) {
    SLog(@"probe once");
    dispatch_async(g_queue, ^{
        @autoreleasepool { scanOnce(@"probe"); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_lastReport) g_lastReport = @"试测完成";
            panelShow();
            panelRefreshStatus();
        });
    });
}

#pragma mark - 面板（仿老贝贝「设置弹窗」结构，纯 frame 布局）
// 面板所有控件的动作都派发到这里（必须先声明，控件工厂里要用 [SELActions class]）
@interface SELActions : NSObject
// v2.3：自测里要直接调这几个做云端回归断言，先声明避免 -Wall 告警
+ (void)onKeywordsRow:(id)sender;
+ (void)onPromptOK;
+ (void)onPromptCancel;
@end
// 结构照它的 ivar 1:1 还原：
//   遮罩 → 面板(标题栏=标题标签+标题高光层CAGradientLayer+关闭按钮)
//                    (内容滚动区 = 纵向排布的分区)
//                    (底部视图 = 按钮栏)
//   分区 = 字段标题 + 控件行 + 分割线
// 它自己就是按 Y 坐标排的（方法名「添加XX设置区域起始Y:」），这里同样按 Y 排。

static const CGFloat kPanelRadius = 18.0;   // 截图量出来的圆角
static const CGFloat kPanelTitleH = 50.0;
static const CGFloat kPanelFootH  = 62.0;
static const CGFloat kPanelPadX   = 14.0;   // 内容左右内边距（截图偏窄）
static const CGFloat kRowH        = 44.0;
static const CGFloat kGapTitle    = 6.0;    // 字段标题 → 控件
static const CGFloat kGapSection  = 18.0;   // 上一控件 → 下个字段标题
static const CGFloat kSegH        = 36.0;
static const CGFloat kPanelWidthRatio = 0.66;  // 面板宽 = 屏宽 × 0.66（截图量出来的）

// 面板配色宏已上移到文件前部 —— 报警卡片先于面板工厂定义，要用它们

static UIWindow *g_panelWin = nil;
static UIView   *g_panelBox = nil;
static UIScrollView *g_panelScroll = nil;
static UILabel  *g_panelStatus = nil;
static UILabel  *g_regionValue = nil, *g_kwValue = nil;
static UILabel  *g_intervalVal = nil, *g_cooldownVal = nil;
static UISegmentedControl *g_vibSeg = nil, *g_sndSeg = nil;
static UIButton *g_runBtn = nil;
static NSInteger g_sectionCount = 0;
static CGFloat   g_panelW = 0;

// 输入卡片（不用 UIAlertController）
static UIWindow *g_promptWin = nil;
static UIView   *g_promptCard = nil;
static UITextField *g_promptField = nil;
static void (^g_promptOK)(NSString *text) = nil;

#pragma mark 控件工厂（规格全部照老贝贝截图；纯 frame 按 Y 排）

#define kValueTag 501   // 值行里那个"当前值"label 的 tag

static UILabel *mkLabel(NSString *text, CGFloat size, UIColor *color, BOOL bold) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = color;
    l.numberOfLines = 0;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

// 关闭按钮：白色实心圆 + 黑 X（截图里的样子）
static UIButton *mkCloseButton(CGFloat d) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, d, d);
    b.backgroundColor = [UIColor whiteColor];
    b.layer.cornerRadius = d / 2.0;
    UIImageView *x = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]];
    x.tintColor = [UIColor blackColor];
    x.contentMode = UIViewContentModeScaleAspectFit;
    x.frame = CGRectMake(d * 0.30, d * 0.30, d * 0.40, d * 0.40);
    x.userInteractionEnabled = NO;
    [b addSubview:x];
    return b;
}

// 字段标题：白 α0.62 / 13px / 左对齐 / 无分割线（截图里分区只靠间距）
static UILabel *mkSectionTitle(NSString *t, CGFloat w) {
    UILabel *l = mkLabel(t, 13, PANEL_DIM, NO);
    l.frame = CGRectMake(0, 0, w, 18);
    return l;
}

// 输入框样式的行（截图里"执行次数 → 1"那种深灰圆角框）
// v2.2：点击改由 UIButton 承载 —— 面板里 UITapGestureRecognizer 挂在这些行上真机不触发，
// 而同一面板里所有 UIButton（开始监视/整屏监视/试测一次）都正常，所以统一用 UIButton。
static UIButton *mkRowField(NSString *value, CGFloat w, SEL action) {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.frame = CGRectMake(0, 0, w, kRowH);
    row.backgroundColor = PANEL_FIELD;
    row.layer.cornerRadius = 10;
    row.exclusiveTouch = NO;
    [row addTarget:[SELActions class] action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *v = mkLabel(value, 15, PANEL_TEXT, NO);
    v.frame = CGRectMake(14, 0, w - 14 - 32, kRowH);
    v.lineBreakMode = NSLineBreakByTruncatingHead;
    v.tag = kValueTag;
    v.userInteractionEnabled = NO;   // 别让子视图吃掉点击
    [row addSubview:v];

    UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chev.tintColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    chev.contentMode = UIViewContentModeScaleAspectFit;
    chev.frame = CGRectMake(w - 22, (kRowH - 13) / 2.0, 8, 13);
    chev.userInteractionEnabled = NO;
    [row addSubview:chev];

    // 点一下给个视觉反馈，方便判断"到底点没点到"
    row.showsTouchWhenHighlighted = NO;
    return row;
}

// 分段控件：底 #1C1C1E，选中 = 白色药丸 + 黑字（截图里的样子）
static UISegmentedControl *mkSegmented(NSArray<NSString *> *items, NSInteger sel, CGFloat w, NSInteger tag) {
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.frame = CGRectMake(0, 0, w, kSegH);
    seg.selectedSegmentIndex = sel;
    seg.tag = tag;
    seg.selectedSegmentTintColor = [UIColor whiteColor];
    seg.backgroundColor = PANEL_TROUGH;
    if (@available(iOS 13.0, *)) seg.layer.cornerRadius = 8;
    [seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor whiteColor],
                                   NSFontAttributeName: [UIFont systemFontOfSize:14] }
                       forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: [UIColor blackColor],
                                   NSFontAttributeName: [UIFont boldSystemFontOfSize:14] }
                       forState:UIControlStateSelected];
    return seg;
}

// 整宽按钮（截图里"设置自定义悬浮图标"那种）
static UIView *mkRowButton(NSString *title, CGFloat w, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, kRowH);
    b.tag = tag;
    b.backgroundColor = PANEL_FIELD;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:PANEL_TEXT forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b addTarget:[SELActions class] action:@selector(onRegionBtn:)
        forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 底部按钮：主操作 = 白底黑字；次操作 = 深灰底白字（照截图）
static UIButton *mkFootButton(NSString *title, BOOL primary, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = primary ? [UIColor whiteColor] : PANEL_FIELD;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:(primary ? [UIColor blackColor] : PANEL_TEXT) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    [b addTarget:[SELActions class] action:@selector(onFootBtn:)
        forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark 面板内容

static NSString *regionText(void) {
    CGRect r;
    if (!loadRegion(&r)) return @"点击设置区域";
    return [NSString stringWithFormat:@"%.0f%%,%.0f%%  %.0f%%×%.0f%%",
            r.origin.x * 100, r.origin.y * 100, r.size.width * 100, r.size.height * 100];
}

static CGFloat g_cursorY = 0;

// 往滚动区里按 Y 追加一行（v 的高度已在工厂里定好）
static void panelAdd(CGFloat topGap, UIView *v, CGFloat w) {
    g_cursorY += topGap;
    v.frame = CGRectMake(0, g_cursorY, w, v.frame.size.height);
    [g_panelScroll addSubview:v];
    g_cursorY += v.frame.size.height;
}

static void panelAddSectionTitle(NSString *t, CGFloat w) {
    panelAdd(g_sectionCount ? kGapSection : 0, mkSectionTitle(t, w), w);
    g_cursorY += kGapTitle;
    g_sectionCount++;
}

static void panelBuild(void) {
    for (UIView *v in [g_panelScroll.subviews copy]) [v removeFromSuperview];
    g_cursorY = 14;
    g_sectionCount = 0;
    CGFloat w = g_panelW;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // ① 状态
    panelAddSectionTitle(@"状态", w);
    g_panelStatus = mkLabel(@"", 14, PANEL_TEXT, NO);
    g_panelStatus.frame = CGRectMake(0, 0, w, 38);
    panelAdd(0, g_panelStatus, w);

    // ② 监视区域（点这行 = 重新框选）
    panelAddSectionTitle(@"监视区域", w);
    UIButton *r1 = mkRowField(regionText(), w, @selector(onRegionRow:));
    g_regionValue = (UILabel *)[r1 viewWithTag:kValueTag];
    panelAdd(0, r1, w);
    UIView *r1b = mkRowButton(@"整屏监视", w, 201);
    panelAdd(8, r1b, w);

    // ③ 关键词
    panelAddSectionTitle(@"关键词", w);
    UIButton *r3 = mkRowField([g_keywords componentsJoinedByString:@","], w, @selector(onKeywordsRow:));
    g_kwValue = (UILabel *)[r3 viewWithTag:kValueTag];
    panelAdd(0, r3, w);

    // v2.4：删掉「同义词」区（用户判断没用，要精确识别）

    // ⑤ 节奏
    panelAddSectionTitle(@"扫描间隔（秒）", w);
    UIButton *r5 = mkRowField([NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_interval", kIdleInterval)],
                              w, @selector(onIntervalRow:));
    g_intervalVal = (UILabel *)[r5 viewWithTag:kValueTag];
    panelAdd(0, r5, w);
    panelAddSectionTitle(@"报警冷却（秒）", w);
    UIButton *r6 = mkRowField([NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_cooldown", kCooldownDefault)],
                              w, @selector(onCooldownRow:));
    g_cooldownVal = (UILabel *)[r6 viewWithTag:kValueTag];
    panelAdd(0, r6, w);

    // ⑥ 报警方式
    panelAddSectionTitle(@"震动报警", w);
    g_vibSeg = mkSegmented(@[ @"关闭", @"开启" ], [ud boolForKey:@"sentinel_vibrate"] ? 1 : 0, w, 400);
    [g_vibSeg addTarget:[SELActions class] action:@selector(onVibrateSeg:)
       forControlEvents:UIControlEventValueChanged];
    panelAdd(0, g_vibSeg, w);
    panelAddSectionTitle(@"声音报警（系统音）", w);
    g_sndSeg = mkSegmented(@[ @"关闭", @"开启" ], [ud boolForKey:@"sentinel_sound"] ? 1 : 0, w, 401);
    [g_sndSeg addTarget:[SELActions class] action:@selector(onSoundSeg:)
       forControlEvents:UIControlEventValueChanged];
    panelAdd(0, g_sndSeg, w);

    // v2.3：删掉「入口挂到老贝贝设置页」（原为占位开关，未实现任何功能，用户确认不需要）

    g_panelScroll.contentSize = CGSizeMake(w, g_cursorY + 14);
    panelRefreshStatus();
}

static void panelRefreshStatus(void) {
    if (!g_panelStatus) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    // v2.2：状态行只说"在不在监控"；命中了才把关键词缀在后面。
    // （原来把整段识别原文拼进来，真机上被截成一团，完全看不清）
    NSString *st = g_running ? @"监视中" : @"已暂停";
    if (g_lastHitKeyword.length) st = [st stringByAppendingFormat:@" · 「%@」", g_lastHitKeyword];
    g_panelStatus.text = st;
    if (g_regionValue) g_regionValue.text = regionText();
    if (g_kwValue)     g_kwValue.text = [g_keywords componentsJoinedByString:@","];
    if (g_intervalVal) g_intervalVal.text = [NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_interval", kIdleInterval)];
    if (g_cooldownVal) g_cooldownVal.text = [NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_cooldown", kCooldownDefault)];
    if (g_runBtn)      [g_runBtn setTitle:(g_running ? @"暂停监视" : @"开始监视") forState:UIControlStateNormal];
}

#pragma mark 面板显示 / 关闭

static void panelHide(void) {
    if (g_promptWin) { g_promptWin.hidden = YES; g_promptWin = nil; g_promptCard = nil; g_promptField = nil; g_promptOK = nil; }
    if (!g_panelWin) return;
    UIWindow *w = g_panelWin;
    g_panelWin = nil; g_panelBox = nil; g_panelScroll = nil; g_panelStatus = nil;
    g_regionValue = g_kwValue = g_intervalVal = g_cooldownVal = nil;
    g_vibSeg = g_sndSeg = nil; g_runBtn = nil;
    [UIView animateWithDuration:0.16 animations:^{ w.alpha = 0; }
                     completion:^(BOOL f) { w.hidden = YES; SLog(@"panel closed"); }];
}

static void panelShow(void) {
    if (g_panelWin) { panelRefreshStatus(); return; }
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) { SLog(@"panel: no scene"); return; }
        CGSize S = scene.screen.bounds.size;

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(0, 0, S.width, S.height);
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = YES;
        g_panelWin = w;

        // 遮罩：比截图略深一点，保证底下的内容看不清（截图里遮罩很淡）
        // v2.2：用 UIControl 承载点按（同面板按钮机制，避免手势在悬浮窗里不触发）
        UIControl *mask = [[UIControl alloc] initWithFrame:w.bounds];
        mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
        [mask addTarget:[SELActions class] action:@selector(onMaskTap:)
       forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:mask];

        // 面板宽 = 屏宽 × 0.66（截图量出来的），高度先给最大值，建完内容再收
        CGFloat pw = round(S.width * kPanelWidthRatio);
        CGFloat maxH = S.height * 0.72;
        g_panelW = pw - kPanelPadX * 2;

        UIView *box = [[UIView alloc] initWithFrame:
            CGRectMake((S.width - pw) / 2.0, (S.height - maxH) / 2.0, pw, maxH)];
        box.backgroundColor = PANEL_BG;
        box.layer.cornerRadius = kPanelRadius;
        box.clipsToBounds = YES;
        [w addSubview:box];
        g_panelBox = box;

        // 标题栏：标题左对齐 + 右上白色圆关闭按钮（照截图）
        UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, kPanelTitleH)];
        [box addSubview:titleBar];
        UILabel *title = mkLabel(@"屏幕哨兵 v2.5", 17, PANEL_TEXT, YES);   // 带版本号：用户一眼确认注入是否生效
        title.frame = CGRectMake(16, 0, pw - 16 - 52, kPanelTitleH);
        [titleBar addSubview:title];
        UIButton *close = mkCloseButton(32);
        close.frame = CGRectMake(pw - 32 - 12, (kPanelTitleH - 32) / 2.0, 32, 32);
        [close addTarget:[SELActions class] action:@selector(onCloseBtn)
        forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:close];
        UIView *tline = [[UIView alloc] initWithFrame:CGRectMake(0, kPanelTitleH - 0.5, pw, 0.5)];
        tline.backgroundColor = PANEL_HAIR;
        [titleBar addSubview:tline];

        // 内容滚动区
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(
            kPanelPadX, kPanelTitleH, g_panelW, maxH - kPanelTitleH - kPanelFootH)];
        sv.showsVerticalScrollIndicator = YES;
        sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
        [box addSubview:sv];
        g_panelScroll = sv;

        // 底部按钮栏：主操作白底黑字，次操作深灰底白字（照截图）
        UIView *foot = [[UIView alloc] initWithFrame:CGRectMake(0, maxH - kPanelFootH, pw, kPanelFootH)];
        [box addSubview:foot];
        UIView *fline = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 0.5)];
        fline.backgroundColor = PANEL_HAIR;
        [foot addSubview:fline];
        CGFloat fw = (pw - kPanelPadX * 2 - 10 * 2) / 3.0;
        NSArray *defs = @[ @[ (g_running ? @"暂停监视" : @"开始监视"), @301, @1 ],
                           @[ @"试测一次", @302, @0 ],
                           @[ @"复制日志", @303, @0 ] ];
        for (NSUInteger i = 0; i < defs.count; i++) {
            UIButton *b = mkFootButton(defs[i][0], [defs[i][2] boolValue], [defs[i][1] integerValue]);
            b.frame = CGRectMake(kPanelPadX + i * (fw + 10), (kPanelFootH - 44) / 2.0, fw, 44);
            [foot addSubview:b];
            if (i == 0) g_runBtn = b;
        }

        panelBuild();

        // 高度按内容收（截图里面板是"内容多高就多高"）
        CGFloat needH = kPanelTitleH + g_cursorY + kPanelFootH + 10;
        CGFloat ph = MIN(needH, maxH);
        box.frame = CGRectMake((S.width - pw) / 2.0, (S.height - ph) / 2.0, pw, ph);
        sv.frame = CGRectMake(kPanelPadX, kPanelTitleH, g_panelW, ph - kPanelTitleH - kPanelFootH);
        foot.frame = CGRectMake(0, ph - kPanelFootH, pw, kPanelFootH);

        w.alpha = 0;
        w.hidden = NO;   // 不 makeKeyAndVisible
        [UIView animateWithDuration:0.18 animations:^{ w.alpha = 1; }];
        SLog(@"panel shown: %.0fx%.0f（宽=屏宽%.0f%%）, %ld 个分区, 内容高 %.0f",
             pw, ph, kPanelWidthRatio * 100, (long)g_sectionCount, g_cursorY);
    } @catch (NSException *e) {
        SLog(@"panel exception: %@", e);
    }
}

#pragma mark 面板内输入卡片（不使用 UIAlertController）

static void panelPrompt(NSString *title, NSString *hint, NSString *current,
                        void (^onOK)(NSString *text)) {
    void (^blk)(void) = ^{
        @try {
            if (g_promptWin) { g_promptWin.hidden = YES; g_promptWin = nil; }
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s; break;
                }
            }
            if (!scene) return;
            CGSize S = scene.screen.bounds.size;

            UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
            w.frame = CGRectMake(0, 0, S.width, S.height);
            w.windowLevel = UIWindowLevelAlert + 101;
            w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
            w.userInteractionEnabled = YES;
            g_promptWin = w;

            // v2.3：点卡片外面 = 取消。改用 UIControl（手势在这套悬浮窗里不触发）
            UIControl *tap = [[UIControl alloc] initWithFrame:w.bounds];
            [tap addTarget:[SELActions class] action:@selector(onPromptCancel)
          forControlEvents:UIControlEventTouchUpInside];
            [w addSubview:tap];

            // 卡片规格照截图：圆角 18 / #2C2C2E / 标题左对齐 / 右上白色圆关闭
            CGFloat cw = round(S.width * (kPanelWidthRatio + 0.06));
            CGFloat ch = 196;
            UIView *card = [[UIView alloc] initWithFrame:
                CGRectMake((S.width - cw) / 2.0, S.height * 0.17, cw, ch)];
            card.backgroundColor = PANEL_BG;
            card.layer.cornerRadius = kPanelRadius;
            card.clipsToBounds = YES;
            [w addSubview:card];
            g_promptCard = card;

            UILabel *t = mkLabel(title, 17, PANEL_TEXT, YES);
            t.frame = CGRectMake(16, 14, cw - 16 - 52, 24);
            [card addSubview:t];
            UIButton *cl = mkCloseButton(32);
            cl.frame = CGRectMake(cw - 32 - 12, 10, 32, 32);
            [cl addTarget:[SELActions class] action:@selector(onPromptCancel)
             forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:cl];

            UILabel *h = mkLabel(hint, 12, PANEL_DIM, NO);
            h.frame = CGRectMake(16, 44, cw - 32, 16);
            [card addSubview:h];

            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(14, 68, cw - 28, 44)];
            tf.text = current ?: @"";
            tf.textColor = PANEL_TEXT;
            tf.font = [UIFont systemFontOfSize:15];
            tf.backgroundColor = PANEL_FIELD;
            tf.layer.cornerRadius = 10;
            tf.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:(hint ?: @"") attributes:@{ NSForegroundColorAttributeName: PANEL_DIM }];
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.clearButtonMode = UITextFieldViewModeAlways;
            UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
            tf.leftView = pad;
            tf.leftViewMode = UITextFieldViewModeAlways;
            [card addSubview:tf];
            g_promptField = tf;

            // 底部：取消（深灰白字） / 确定（白底黑字）—— 照截图
            CGFloat bw = (cw - 14 * 2 - 10) / 2.0;
            UIButton *cancel = mkFootButton(@"取消", NO, 0);
            cancel.frame = CGRectMake(14, 128, bw, 44);
            [cancel removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
            [cancel addTarget:[SELActions class] action:@selector(onPromptCancel)
             forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:cancel];

            UIButton *ok = mkFootButton(@"确定", YES, 0);
            ok.frame = CGRectMake(14 + bw + 10, 128, bw, 44);
            [ok removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
            [ok addTarget:[SELActions class] action:@selector(onPromptOK)
             forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:ok];

            g_promptOK = onOK;
            // ★ v2.3 关键修复（真机"点了没反应"的真凶）：
            //   ① UIWindow 创建后默认 hidden=YES —— 原来只建不显示，卡片根本看不见
            //   ② 不是 key window 时 becomeFirstResponder 会失败 —— 输入法自然也不弹
            [w makeKeyAndVisible];
            BOOL focused = [tf becomeFirstResponder];
            SLog(@"prompt shown: %@ (hidden=%d key=%d focus=%d)", title,
                 (int)w.hidden, (int)w.isKeyWindow, (int)focused);
        } @catch (NSException *e) { SLog(@"prompt exception: %@", e); }
    };
    // 已在主线程就直接执行（同步，方便云端自测断言），否则派发到主线程
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}
#pragma mark 面板动作（全部由面板控件派发到这里）

@implementation SELActions

+ (void)onRegionRow:(id)sender {
    SLog(@"tap: 监视区域 → 重新框选");
    panelHide();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showRegionSelector(); });
}

+ (void)onMaskTap:(id)sender { panelHide(); }
+ (void)onCloseBtn { panelHide(); }

+ (void)onRegionBtn:(UIButton *)b {
    BOOL full = (b.tag == 201);
    panelHide();
    if (full) {
        saveRegion(CGRectMake(0, 0, 1, 1));
        SLog(@"region set to full screen");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ probeOnce(); });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ showRegionSelector(); });
    }
}

+ (void)onKeywordsRow:(id)sender {
    SLog(@"tap: 关键词 → 输入卡片");
    panelPrompt(@"关键词", @"多个用逗号分隔，例如：体力不足,无法操作",
                [g_keywords componentsJoinedByString:@","], ^(NSString *text) {
        [[NSUserDefaults standardUserDefaults] setObject:(text ?: @"") forKey:@"sentinel_keywords"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        refreshConfig();
        SLog(@"keywords → %@", [g_keywords componentsJoinedByString:@"|"]);
        panelRefreshStatus();
    });
}

// v2.4：onSynonymsRow 已删除（同义词功能移除）

+ (void)onIntervalRow:(id)sender {
    SLog(@"tap: 扫描间隔 → 输入卡片");
    panelPrompt(@"扫描间隔", @"单位秒。越小越灵敏、越费电（建议 1~3）",
        [NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_interval", kIdleInterval)], ^(NSString *text) {
        double d = text.doubleValue;
        if (d < 0.3) d = kIdleInterval;
        [[NSUserDefaults standardUserDefaults] setObject:@(d) forKey:@"sentinel_interval"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        SLog(@"interval → %.1f", d);
        panelRefreshStatus();
    });
}

+ (void)onCooldownRow:(id)sender {
    SLog(@"tap: 报警冷却 → 输入卡片");
    panelPrompt(@"报警冷却", @"同一个关键词在这段时间内只报一次（单位秒）",
        [NSString stringWithFormat:@"%.1f", cfgDouble(@"sentinel_cooldown", kCooldownDefault)], ^(NSString *text) {
        double d = text.doubleValue;
        if (d < 1.0) d = kCooldownDefault;
        [[NSUserDefaults standardUserDefaults] setObject:@(d) forKey:@"sentinel_cooldown"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        SLog(@"cooldown → %.1f", d);
        panelRefreshStatus();
    });
}

+ (void)onVibrateSeg:(UISegmentedControl *)s {
    [[NSUserDefaults standardUserDefaults] setBool:(s.selectedSegmentIndex == 1) forKey:@"sentinel_vibrate"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    SLog(@"vibrate → %d", (int)(s.selectedSegmentIndex == 1));
}

+ (void)onSoundSeg:(UISegmentedControl *)s {
    [[NSUserDefaults standardUserDefaults] setBool:(s.selectedSegmentIndex == 1) forKey:@"sentinel_sound"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    SLog(@"sound → %d", (int)(s.selectedSegmentIndex == 1));
}

+ (void)onFootBtn:(UIButton *)b {
    if (b.tag == 301) {
        if (g_running) stopWatching(); else startWatching();
        panelRefreshStatus();
        return;
    }
    if (b.tag == 302) {
        panelHide();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ probeOnce(); });
        return;
    }
    if (b.tag == 303) {
        NSString *log = [NSString stringWithContentsOfFile:g_logPath encoding:NSUTF8StringEncoding error:nil];
        [UIPasteboard generalPasteboard].string = log ?: @"(日志为空)";
        showBanner(@"日志已复制到剪贴板");
    }
}

+ (void)onPromptCancel {
    if (g_promptWin) {
        g_promptWin.hidden = YES;
        g_promptWin = nil; g_promptCard = nil; g_promptField = nil; g_promptOK = nil;
        // v2.3：把 key 还给面板窗口（输入卡片是临时抢 key 的）
        if (g_panelWin) [g_panelWin makeKeyWindow];
    }
}

+ (void)onPromptOK {
    NSString *text = g_promptField.text ?: @"";
    void (^cb)(NSString *) = g_promptOK;
    [SELActions onPromptCancel];
    if (cb) cb(text);
}

@end
#pragma mark - 悬浮球（左侧，避让右侧同类插件）

@interface SELBallButton : UIButton
@end
@implementation SELBallButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    SLog(@"ball touch began");
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self restoreColor];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self restoreColor];
}
- (void)restoreColor { self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.5]; }
@end

@interface SELBallHelper : NSObject
+ (void)onTap:(UITapGestureRecognizer *)t;
+ (void)onDrag:(UIPanGestureRecognizer *)p;
@end
@implementation SELBallHelper
+ (void)onTap:(UITapGestureRecognizer *)t { SLog(@"ball tap → panel"); panelShow(); }
+ (void)onDrag:(UIPanGestureRecognizer *)p {
    UIWindow *w = g_ballWin;
    if (!w) return;
    CGPoint tr = [p translationInView:w];
    CGPoint c = w.center;
    c.x += tr.x; c.y += tr.y;
    CGSize scr = w.screen.bounds.size;
    c.x = MIN(MAX(c.x, 22), scr.width - 22);
    c.y = MIN(MAX(c.y, 22), scr.height - 22);
    w.center = c;
    [p setTranslation:CGPointZero inView:w];
    if (p.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setObject:
            [NSString stringWithFormat:@"%.1f,%.1f", c.x, c.y] forKey:@"sentinel_ball_pos"];
        SLog(@"ball moved to (%.0f, %.0f)", c.x, c.y);
    }
}
@end

static void createFloatingBall(void) {
    if (g_ballWin) return;
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) return;
        CGSize scr = scene.screen.bounds.size;
        CGFloat bs = 40.0;
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        CGPoint c = CGPointMake(bs / 2.0 + 6.0, scr.height * 0.22);   // 默认【左侧】
        NSArray *v = splitList([[NSUserDefaults standardUserDefaults] stringForKey:@"sentinel_ball_pos"], @",");
        if (v.count == 2) c = CGPointMake([v[0] doubleValue], [v[1] doubleValue]);
        w.frame = CGRectMake(c.x - bs / 2.0, c.y - bs / 2.0, bs, bs);
        w.windowLevel = UIWindowLevelAlert + 99;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = YES;   // 不设 rootViewController（延迟加载的 view 会盖住按钮）

        SELBallButton *b = [SELBallButton buttonWithType:UIButtonTypeCustom];
        b.frame = w.bounds;
        b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        b.layer.cornerRadius = bs / 2.0;
        b.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.5];
        b.layer.borderWidth = 1.0;
        b.layer.borderColor = [UIColor colorWithRed:0.35 green:0.85 blue:0.6 alpha:0.8].CGColor;
        b.clipsToBounds = YES;
        [b setTitle:@"哨" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithRed:0.6 green:1.0 blue:0.8 alpha:1.0] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        b.userInteractionEnabled = YES;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:[SELBallHelper class] action:@selector(onTap:)];
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[SELBallHelper class] action:@selector(onDrag:)];
        pan.cancelsTouchesInView = NO;
        [b addGestureRecognizer:tap];
        [b addGestureRecognizer:pan];

        [w addSubview:b];
        w.hidden = NO;
        g_ballWin = w;
        SLog(@"floating ball created at (%.0f, %.0f) [left side]", w.frame.origin.x, w.frame.origin.y);
    } @catch (NSException *e) { SLog(@"ball exception: %@", e); }
}

#pragma mark - 区域框选界面

static UIWindow *g_selWin = nil;
static UIView   *g_dimTop = nil, *g_dimBottom = nil, *g_dimLeft = nil, *g_dimRight = nil;
static UIView   *g_selBox = nil;
static UIView   *g_handles[4] = { nil, nil, nil, nil };
static CGRect    g_selRect = { {0, 0}, {0, 0} };
static CGPoint   g_drawAnchor = { 0, 0 };
static BOOL      g_drawing = NO;

static void selLayout(void) {
    if (!g_selWin) return;
    CGSize S = g_selWin.bounds.size;
    CGRect r = g_selRect;
    g_dimTop.frame    = CGRectMake(0, 0, S.width, MAX(0, r.origin.y));
    g_dimBottom.frame = CGRectMake(0, CGRectGetMaxY(r), S.width, MAX(0, S.height - CGRectGetMaxY(r)));
    g_dimLeft.frame   = CGRectMake(0, r.origin.y, MAX(0, r.origin.x), r.size.height);
    g_dimRight.frame  = CGRectMake(CGRectGetMaxX(r), r.origin.y,
                                   MAX(0, S.width - CGRectGetMaxX(r)), r.size.height);
    g_selBox.frame    = r;
    CGFloat hs = 34.0;
    CGFloat ins = hs / 2.0;   // v2.2：手柄整体收进框内 —— 原来中心钉在框角上，整屏时有一半悬在屏幕外＋贴着系统手势区，手指够不着
    CGPoint cs[4] = { {r.origin.x + ins, r.origin.y + ins},
                      {CGRectGetMaxX(r) - ins, r.origin.y + ins},
                      {r.origin.x + ins, CGRectGetMaxY(r) - ins},
                      {CGRectGetMaxX(r) - ins, CGRectGetMaxY(r) - ins} };
    for (int i = 0; i < 4; i++) {
        if (!g_handles[i]) continue;
        g_handles[i].bounds = CGRectMake(0, 0, hs, hs);
        g_handles[i].center = cs[i];
    }
}

static void selClamp(void) {
    if (!g_selWin) return;
    CGSize S = g_selWin.bounds.size;
    CGRect r = g_selRect;
    if (r.size.width  < kMinRegionSide) r.size.width  = kMinRegionSide;
    if (r.size.height < kMinRegionSide) r.size.height = kMinRegionSide;
    if (r.origin.x < 0) r.origin.x = 0;
    if (r.origin.y < 0) r.origin.y = 0;
    if (r.origin.x + r.size.width  > S.width)  r.origin.x = S.width  - r.size.width;
    if (r.origin.y + r.size.height > S.height) r.origin.y = S.height - r.size.height;
    if (r.origin.x < 0) r.origin.x = 0;
    if (r.origin.y < 0) r.origin.y = 0;
    g_selRect = r;
}

static void selDismiss(void) {
    g_selecting = NO;
    g_drawing = NO;
    if (g_selWin) { g_selWin.hidden = YES; g_selWin = nil; }
    g_selBox = nil;
    for (int i = 0; i < 4; i++) g_handles[i] = nil;
    g_dimTop = g_dimBottom = g_dimLeft = g_dimRight = nil;
    SLog(@"region selector closed");
}

@interface SELRegionActions : NSObject
@end
@implementation SELRegionActions

+ (void)onMove:(UIPanGestureRecognizer *)p {   // 拖框内 = 整体移动
    if (!g_selWin) return;
    CGPoint tr = [p translationInView:g_selWin];
    g_selRect.origin.x += tr.x;
    g_selRect.origin.y += tr.y;
    [p setTranslation:CGPointZero inView:g_selWin];
    selClamp();
    selLayout();
}

+ (void)onHandle:(UIPanGestureRecognizer *)p {  // 拖四角
    if (!g_selWin || !p.view) return;
    CGPoint c = [p locationInView:g_selWin];
    CGRect r = g_selRect;
    CGFloat x1 = r.origin.x, y1 = r.origin.y, x2 = CGRectGetMaxX(r), y2 = CGRectGetMaxY(r);
    int idx = (int)p.view.tag;
    if (idx == 0 || idx == 2) x1 = c.x; else x2 = c.x;
    if (idx == 0 || idx == 1) y1 = c.y; else y2 = c.y;
    g_selRect = CGRectMake(MIN(x1, x2), MIN(y1, y2), fabs(x2 - x1), fabs(y2 - y1));
    selClamp();
    selLayout();
}

+ (void)onBlank:(UIPanGestureRecognizer *)p {   // 拖空白 = 重新画
    if (!g_selWin) return;
    CGPoint c = [p locationInView:g_selWin];
    if (p.state == UIGestureRecognizerStateBegan) {
        g_drawAnchor = c;
        g_drawing = YES;
        g_selRect = CGRectMake(c.x, c.y, 1, 1);
    } else if (p.state == UIGestureRecognizerStateChanged && g_drawing) {
        g_selRect = CGRectMake(MIN(g_drawAnchor.x, c.x), MIN(g_drawAnchor.y, c.y),
                               fabs(c.x - g_drawAnchor.x), fabs(c.y - g_drawAnchor.y));
    } else if (p.state == UIGestureRecognizerStateEnded ||
               p.state == UIGestureRecognizerStateCancelled) {
        g_drawing = NO;
        selClamp();
    }
    selLayout();
}

+ (void)onButton:(UIButton *)b {
    if (!g_selWin) return;
    CGSize S = g_selWin.bounds.size;
    if (b.tag == 100) { selDismiss(); return; }                      // 取消
    if (b.tag == 101) { g_selRect = CGRectMake(0, 0, S.width, S.height); selLayout(); return; }  // 全屏
    if (b.tag == 102) {                                              // 确定
        CGRect n = CGRectMake(g_selRect.origin.x / S.width, g_selRect.origin.y / S.height,
                              g_selRect.size.width / S.width, g_selRect.size.height / S.height);
        saveRegion(n);
        SLog(@"region saved: %.4f,%.4f,%.4f,%.4f", n.origin.x, n.origin.y, n.size.width, n.size.height);
        selDismiss();
        // 等遮罩真的消失再试测，否则第一张图会拍到自己的遮罩层
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ probeOnce(); });
    }
}
@end

static void showRegionSelector(void) {
    if (g_selWin) return;
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (!scene) { SLog(@"no scene for selector"); return; }
        CGSize S = scene.screen.bounds.size;

        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(0, 0, S.width, S.height);
        w.windowLevel = UIWindowLevelAlert + 100;   // 比悬浮球(99)高，盖住它免得误触
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = YES;
        g_selWin = w;
        g_selecting = YES;

        UIColor *dim = [UIColor colorWithWhite:0 alpha:0.55];
        g_dimTop = [[UIView alloc] init];    g_dimTop.backgroundColor = dim;
        g_dimBottom = [[UIView alloc] init]; g_dimBottom.backgroundColor = dim;
        g_dimLeft = [[UIView alloc] init];   g_dimLeft.backgroundColor = dim;
        g_dimRight = [[UIView alloc] init];  g_dimRight.backgroundColor = dim;
        for (UIView *v in @[g_dimTop, g_dimBottom, g_dimLeft, g_dimRight]) [w addSubview:v];

        g_selBox = [[UIView alloc] init];
        g_selBox.backgroundColor = [UIColor clearColor];
        g_selBox.layer.borderWidth = 2.0;
        g_selBox.layer.borderColor = [UIColor colorWithRed:0.35 green:0.95 blue:0.7 alpha:1.0].CGColor;
        g_selBox.userInteractionEnabled = YES;
        [w addSubview:g_selBox];
        [g_selBox addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:[SELRegionActions class] action:@selector(onMove:)]];

        CGFloat hs = 34.0;
        for (int i = 0; i < 4; i++) {
            UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, hs, hs)];
            h.backgroundColor = [UIColor clearColor];
            h.tag = i;
            h.userInteractionEnabled = YES;
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(hs/2-9, hs/2-9, 18, 18)];
            dot.backgroundColor = [UIColor colorWithRed:0.35 green:0.95 blue:0.7 alpha:1.0];
            dot.layer.cornerRadius = 9;
            dot.userInteractionEnabled = NO;
            [h addSubview:dot];
            [h addGestureRecognizer:[[UIPanGestureRecognizer alloc]
                initWithTarget:[SELRegionActions class] action:@selector(onHandle:)]];
            [w addSubview:h];
            g_handles[i] = h;
        }

        UIPanGestureRecognizer *blank = [[UIPanGestureRecognizer alloc]
            initWithTarget:[SELRegionActions class] action:@selector(onBlank:)];
        [w addGestureRecognizer:blank];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 40, S.width, 34)];
        hint.text = @"拖空白重画 · 拖四角缩放 · 拖框内移动（整屏会自动内缩）";
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont systemFontOfSize:13];
        hint.textColor = [UIColor whiteColor];
        [w addSubview:hint];

        CGFloat bw = (S.width - 16 * 2 - 10 * 2) / 3.0;
        CGFloat by = S.height - 64;
        NSArray *titles = @[ @"取消", @"全屏", @"确定" ];
        for (int i = 0; i < 3; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(16 + i * (bw + 10), by, bw, 44);
            [b setTitle:titles[i] forState:UIControlStateNormal];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            b.backgroundColor = (i == 2) ? [UIColor colorWithRed:0.16 green:0.62 blue:0.42 alpha:0.95]
                                         : [UIColor colorWithWhite:0.25 alpha:0.92];
            b.layer.cornerRadius = 10;
            b.tag = 100 + i;
            [b addTarget:[SELRegionActions class] action:@selector(onButton:)
                forControlEvents:UIControlEventTouchUpInside];
            [w addSubview:b];
        }

        CGRect r0 = CGRectMake(S.width * 0.2, S.height * 0.3, S.width * 0.6, S.height * 0.25);
        CGRect saved;
        if (loadRegion(&saved)) {
            r0 = CGRectMake(saved.origin.x * S.width, saved.origin.y * S.height,
                            saved.size.width * S.width, saved.size.height * S.height);
            // v2.2：保存的是整屏（100%×100%）时，框铺满全屏 → 拖哪儿都是"移动框"且被边界卡死、
            // 四角手柄又贴在屏幕边缘够不着，用户就"缩不小"。这里自动内缩一圈，一进来就能拖着改小。
            if (saved.size.width > 0.97 && saved.size.height > 0.97) {
                CGFloat ix = S.width * 0.08, iy = S.height * 0.10;
                r0 = CGRectMake(ix, iy, S.width - ix * 2, S.height - iy * 2);
                SLog(@"saved region was full-screen → preview shrunk for adjustment");
            }
        }
        g_selRect = r0;
        selLayout();

        w.hidden = NO;   // 不 makeKeyAndVisible
        SLog(@"region selector opened (init %.0f,%.0f %.0fx%.0f)", r0.origin.x, r0.origin.y, r0.size.width, r0.size.height);
    } @catch (NSException *e) {
        SLog(@"selector exception: %@", e);
        g_selecting = NO;
    }
}

#pragma mark - 老贝贝识字命中探针（v2.5）

// 用户目标：老贝贝「识字」动作命中关键词时，触发哨兵报警（横幅+卡片+震动/声音）。
// 第一步是探针：识字命中那一刻老贝贝内部走哪个方法、参数里能不能拿到命中的词，
// 静态分析定不了，必须真机实测——本模块把候选方法全部挂上「透明日志陷阱」。
//
// 设计（零破坏原则）：
//   · 按候选 selector 遍历全部 ObjC 类（instance/class method 都查），老贝贝类不存在时自然 0 匹配，零影响；
//   · 只 hook「返回 void/id、参数全为对象且 ≤3 个」的方法 —— block 转发原参数调用原实现，行为不变；
//   · encoding 不支持的方法只记一条日志，不 hook；
//   · 识字命中时日志会打出各候选方法的调用时序与参数内容（含 识字命中项 对象的字段）。

static BOOL g_probeInstalled = NO;
static int  g_probeHooked = 0;
static int  g_probeSkipped = 0;

static NSString *lbbArgDesc(id o) {
    if (!o) return @"(nil)";
    NSString *d = [o description];
    if (d.length > 120) d = [[d substringToIndex:120] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([o class] ?: [NSObject class]), d];
}

// 解析 ObjC 类型编码。返回 1 = 探针支持（返回 v/@，参数全为 @ 且 ≤3 个）
static int lbbParseEncoding(const char *enc, char *retType, int *argCount) {
    if (!enc || !*enc) return 0;
    const char *p = enc;
    char c = *p++;
    while (*p >= '0' && *p <= '9') p++;
    *retType = c;
    if (c != 'v' && c != '@') return 0;
    int objs = 0;
    while (*p) {
        char t = *p++;
        while (*p >= '0' && *p <= '9') p++;
        if (t == ':') continue;              // _cmd
        if (t != '@') return 0;              // 含非对象参数 → 探针不支持
        objs++;                              // 第一个是 self
    }
    *argCount = objs - 1;
    return (*argCount >= 0 && *argCount <= 3);
}

static IMP lbbTrapV0(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^(id _self){
        SLog(@"[probe] %@ > %@ 调用", owner, NSStringFromSelector(sel));
        ((void(*)(id, SEL))orig)(_self, sel);
    });
}
static IMP lbbTrapV1(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^(id _self, id a1){
        SLog(@"[probe] %@ > %@ 参数1=%@", owner, NSStringFromSelector(sel), lbbArgDesc(a1));
        ((void(*)(id, SEL, id))orig)(_self, sel, a1);
    });
}
static IMP lbbTrapV2(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^(id _self, id a1, id a2){
        SLog(@"[probe] %@ > %@ 参数1=%@ 参数2=%@", owner, NSStringFromSelector(sel),
             lbbArgDesc(a1), lbbArgDesc(a2));
        ((void(*)(id, SEL, id, id))orig)(_self, sel, a1, a2);
    });
}
static IMP lbbTrapV3(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^(id _self, id a1, id a2, id a3){
        SLog(@"[probe] %@ > %@ 参数1=%@ 参数2=%@ 参数3=%@", owner, NSStringFromSelector(sel),
             lbbArgDesc(a1), lbbArgDesc(a2), lbbArgDesc(a3));
        ((void(*)(id, SEL, id, id, id))orig)(_self, sel, a1, a2, a3);
    });
}
static IMP lbbTrapR1(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^id(id _self, id a1){
        id r = ((id(*)(id, SEL, id))orig)(_self, sel, a1);
        SLog(@"[probe] %@ > %@ (返回id) 参数1=%@ 返回=%@", owner, NSStringFromSelector(sel),
             lbbArgDesc(a1), lbbArgDesc(r));
        return r;
    });
}
static IMP lbbTrapR2(NSString *owner, SEL sel, IMP orig) {
    return imp_implementationWithBlock(^id(id _self, id a1, id a2){
        id r = ((id(*)(id, SEL, id, id))orig)(_self, sel, a1, a2);
        SLog(@"[probe] %@ > %@ (返回id) 参数1=%@ 参数2=%@ 返回=%@", owner, NSStringFromSelector(sel),
             lbbArgDesc(a1), lbbArgDesc(a2), lbbArgDesc(r));
        return r;
    });
}

static IMP lbbMakeTrap(char retType, int argc, NSString *owner, SEL sel, IMP orig) {
    if (retType == 'v') {
        if (argc == 0) return lbbTrapV0(owner, sel, orig);
        if (argc == 1) return lbbTrapV1(owner, sel, orig);
        if (argc == 2) return lbbTrapV2(owner, sel, orig);
        if (argc == 3) return lbbTrapV3(owner, sel, orig);
    } else if (retType == '@') {
        if (argc == 1) return lbbTrapR1(owner, sel, orig);
        if (argc == 2) return lbbTrapR2(owner, sel, orig);
    }
    return NULL;
}

static void lbbHookOne(Class cls, SEL sel, BOOL isClassMethod, NSString *selName) {
    // 只匹配「类自身声明」的方法：class_getInstanceMethod 会沿继承链命中父类的同一实现，
    // 子类遍历时就会重复 hook（CI 实测每 selector 命中 2 次的根因）。
    unsigned int n = 0;
    Method *list = isClassMethod ? class_copyMethodList(object_getClass(cls), &n)
                                 : class_copyMethodList(cls, &n);
    if (!list) return;
    Method m = NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { m = list[i]; break; }   // SEL 指针唯一，可直接比
    }
    free(list);
    if (!m) return;
    char retType; int argc;
    const char *enc = method_getTypeEncoding(m);
    if (!lbbParseEncoding(enc, &retType, &argc)) {
        g_probeSkipped++;
        SLog(@"[probe] %@%@ 存在但 encoding 不支持(%s)，未 hook",
             isClassMethod ? @"+" : @"-", selName, enc ? enc : "?");
        return;
    }
    IMP orig = method_getImplementation(m);
    IMP trap = lbbMakeTrap(retType, argc, NSStringFromClass(cls), sel, orig);
    if (!trap) return;
    method_setImplementation(m, trap);
    g_probeHooked++;
    SLog(@"[probe] hook 成功：%@ [%@%@]（返回 %c，%d 个对象参数）",
         NSStringFromClass(cls), isClassMethod ? @"+" : @"-", selName, retType, argc);
}

static void lbbProbeInstall(void) {
    if (g_probeInstalled) return;
    g_probeInstalled = YES;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [ud objectForKey:@"sentinel_lbb_probe"] == nil ? YES : [ud boolForKey:@"sentinel_lbb_probe"];
    if (!enabled) { SLog(@"[probe] 探针已关闭（sentinel_lbb_probe=NO）"); return; }

    NSArray *cands = @[ @"执行识别成功后点击目标",
                        @"执行识别成功动作列表",
                        @"执行识别成功后点击坐标",
                        @"执行动作",
                        @"执行一次动作",
                        @"执行动作列表",
                        @"开始执行动作列表",
                        @"执行录制动作",
                        @"开始预览动作" ];

    int num = objc_getClassList(NULL, 0);
    if (num <= 0) { SLog(@"[probe] 无法枚举 ObjC 类"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    if (!classes) return;
    int real = objc_getClassList(classes, num);

    for (NSString *selName in cands) {
        SEL sel = NSSelectorFromString(selName);
        for (int i = 0; i < real; i++) {
            lbbHookOne(classes[i], sel, NO, selName);
            lbbHookOne(classes[i], sel, YES, selName);
        }
    }
    free(classes);
    SLog(@"[probe] 安装完成：hook %d 处，跳过 %d 处（老贝贝未同进程时自然为 0/0）",
         g_probeHooked, g_probeSkipped);
}

#pragma mark - 自测（云端模拟器 e2e 用）

// 现场渲染一张假游戏 HUD（不依赖外部图片资源）
static UIImage *renderFakeHUD(void) {
    CGSize S = CGSizeMake(390, 844);
    UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
    fmt.scale = 2.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:S format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.11 green:0.13 blue:0.18 alpha:1].CGColor);
        CGContextFillRect(c, CGRectMake(0, 0, S.width, S.height));
        CGContextSetFillColorWithColor(c, [UIColor colorWithRed:0.75 green:0.20 blue:0.20 alpha:1].CGColor);
        CGContextFillRect(c, CGRectMake(20, 40, 350, 14));           // 顶部血条
        NSDictionary *a1 = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:22],
                              NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:1] };
        [@"体力不足 无法继续" drawAtPoint:CGPointMake(80, 420) withAttributes:a1];
        NSDictionary *a2 = @{ NSFontAttributeName: [UIFont systemFontOfSize:16],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:0.78 alpha:1] };
        [@"恭喜获得金币 x100" drawAtPoint:CGPointMake(120, 520) withAttributes:a2];
    }];
}

#define ST_CHECK(cond, name) do { \
    if (cond) { g_seltestPass++; stWrite([NSString stringWithFormat:@"PASS %@", (name)]); } \
    else      { g_selftestFail++; stWrite([NSString stringWithFormat:@"FAIL %@", (name)]); } \
} while (0)

static void runSelftest(void) {
    if (g_selftestLog) return;   // 只跑一次
    g_selftestLog = [NSMutableString string];
    g_seltestPass = 0; g_selftestFail = 0;
    SLog(@"selftest begin");

    // ① 归一化
    ST_CHECK([normalizeText(@"体力 不足！") isEqualToString:@"体力不足"], @"normalize 去空格与标点");
    ST_CHECK([normalizeText(@"ＡＢC") isEqualToString:@"abc"], @"normalize 全角转半角+小写");

    // ② 精确包含
    ST_CHECK(matchOne(@"体力不足无法继续", @"体力不足"), @"match 子串命中");
    ST_CHECK(!matchOne(@"金币不足", @"体力不足"), @"match 不误命中");

    // ③ v2.4：宁漏不误 —— 容错已删除，OCR 认错一个字就不该命中
    ST_CHECK(!matchOne(@"体力木足无法继续", @"体力不足"), @"v2.4 精确匹配：错字不再命中");
    ST_CHECK(!matchOne(@"体力没有问题", @"体力不足"), @"v2.4 精确匹配：不相干的词不命中");

    // ④ v2.4：同义词功能已删除 —— 别的说法不再命中（要报就自己加进关键词）
    ST_CHECK([matchLine(@"体力不足", @[@"体力不足"]) isEqualToString:@"体力不足"],
              @"v2.4 精确匹配：正常命中并回报关键词");
    ST_CHECK(matchLine(@"没劲了", @[@"体力不足"]) == nil, @"v2.4 已删同义词：别的说法不命中");
    ST_CHECK(matchLine(@"金币不足", @[@"体力不足"]) == nil, @"v2.4 无关词不命中");

    // ⑤ v2.4：耗时测量链（真机靠这条日志定"毫秒级"能到什么程度）
    {
        NSTimeInterval q0 = CACurrentMediaTime();
        UIImage *hud0 = renderFakeHUD();
        UIImage *band0 = cropToRegion(hud0, CGRectMake(0, kSelftestBandY, 1, kSelftestBandH));
        NSTimeInterval q1 = CACurrentMediaTime();
        __block NSUInteger n0 = 0;
        runOCR(band0, ^(NSArray *items) { n0 = items.count; });
        NSTimeInterval q2 = CACurrentMediaTime();
        size_t w0 = band0.CGImage ? CGImageGetWidth(band0.CGImage) : 0;
        size_t h0 = band0.CGImage ? CGImageGetHeight(band0.CGImage) : 0;
        SLog(@"timing(selftest): 造图+裁剪 %.0fms | OCR %.0fms | 合计 %.0fms | 送检图 %.0fx%.0f 像素(%.1f万) | 文字 %lu 条",
             (q1 - q0) * 1000, (q2 - q1) * 1000, (q2 - q0) * 1000,
             (double)w0, (double)h0, w0 * h0 / 10000.0, (unsigned long)n0);
        ST_CHECK(q2 > q0 && n0 >= 1, @"v2.4 耗时测量链可用（日志里能看到 timing）");
    }

    // ⑤ 区域裁剪（不依赖 OCR）
    UIImage *hud = renderFakeHUD();
    ST_CHECK(hud != nil, @"render 假HUD图成功");
    if (hud) {
        UIImage *c1 = cropToRegion(hud, CGRectMake(0, 0, 1, 1));
        ST_CHECK(c1 != nil && fabs(c1.size.width - 390) < 3, @"crop 全屏区域尺寸");
        UIImage *c2 = cropToRegion(hud, CGRectMake(0.5, 0.5, 0.5, 0.5));
        ST_CHECK(c2 != nil && fabs(c2.size.width - 195) < 5, @"crop 半屏区域尺寸");

        // ⑥ OCR 端到端（依赖模拟器能渲染中文）
        __block NSUInteger upN = 9999, bandN = 0;
        runOCR(cropToRegion(hud, CGRectMake(0, 0, 1, 0.30)), ^(NSArray *items) { upN = items.count; });
        runOCR(cropToRegion(hud, CGRectMake(0, kSelftestBandY, 1, kSelftestBandH)), ^(NSArray *items) { bandN = items.count; });
        stWrite([NSString stringWithFormat:@"ocr 无文字区 %lu 条 / 文字条带 %lu 条",
                 (unsigned long)upN, (unsigned long)bandN]);
        ST_CHECK(upN == 0, @"e2e 无文字区域识别 0 条");
        ST_CHECK(bandN >= 1, @"e2e 文字条带能识别出来");

        // ⑦ 关键字真的能命中（完整链：裁区域 → OCR → 归一化 → 匹配）
        g_keywords = @[@"体力不足"];
        __block int hits = 0;
        __block NSString *seen = @"(空)";
        NSMutableArray *hh = [NSMutableArray array], *tt = [NSMutableArray array];
        evaluate(cropToRegion(hud, CGRectMake(0, kSelftestBandY, 1, kSelftestBandH)), hh, tt);
        hits = (int)hh.count;
        seen = joinShort(tt);
        stWrite([NSString stringWithFormat:@"e2e 识别到: %@ → 命中 %d", seen, hits]);
        ST_CHECK(hits >= 1, @"e2e 关键字「体力不足」命中");

        // ⑧ 冷却
        g_lastAlert = [NSMutableDictionary dictionary];
        g_lastAlert[@"体力不足"] = @(CACurrentMediaTime());
        double cd = cfgDouble(@"sentinel_cooldown", kCooldownDefault);
        ST_CHECK(CACurrentMediaTime() - [g_lastAlert[@"体力不足"] doubleValue] < cd, @"cooldown 冷却期内不重复报");
        ST_CHECK([g_lastAlert objectForKey:@"金币不足"] == nil, @"cooldown 没报过的关键字放行");
    }

    // ⑨ 配置
    g_keywords = loadKeywords();
    ST_CHECK(g_keywords.count >= 1, @"config 关键词加载非空");
    saveRegion(CGRectMake(0.1, 0.2, 0.3, 0.4));
    CGRect rr;
    ST_CHECK(loadRegion(&rr) && fabs(rr.origin.x - 0.1) < 0.001 && fabs(rr.size.height - 0.4) < 0.001,
             @"config 区域存取往返正确");
    ST_CHECK([regionText() rangeOfString:@"%"].location != NSNotFound, @"面板 区域摘要可生成");

    // ⑩ v2.2 修复项回归（这三处都是真机报上来的 bug，逻辑层必须自动验一遍）
    // ① 面板可点行必须是 UIButton —— 原来挂 UITapGestureRecognizer，真机上点了完全没反应
    panelShow();   // 幂等：确保面板已构建
    __block int rowBtnN = 0;
    for (UIView *v in g_panelScroll.subviews) if ([v isKindOfClass:[UIButton class]]) rowBtnN++;
    ST_CHECK(rowBtnN >= 4, @"v2.2 面板可点行是 UIButton（不是手势）");

    // ② 保存整屏后打开框选，初始框必须自动内缩 —— 否则整屏框铺满屏拖哪儿都卡死、四角手柄又贴屏幕边够不着
    saveRegion(CGRectMake(0, 0, 1, 1));
    selDismiss();
    showRegionSelector();
    BOOL selOK = (g_selWin != nil);
    CGRect initRect = g_selRect;
    CGFloat SW = g_selWin ? g_selWin.bounds.size.width : 390;
    CGFloat SH = g_selWin ? g_selWin.bounds.size.height : 844;
    ST_CHECK(selOK, @"v2.2 整屏后仍能重新打开框选界面");
    ST_CHECK(selOK && initRect.size.width < SW * 0.95 && initRect.size.height < SH * 0.95,
             @"v2.2 整屏区域打开框选时自动内缩（能拖小）");
    selDismiss();

    // ③ 状态行精简：只说在不在监控；命中才把关键词缀上
    g_running = YES;
    g_lastHitKeyword = nil;
    panelRefreshStatus();
    BOOL stIdle = [g_panelStatus.text isEqualToString:@"监视中"];
    g_lastHitKeyword = @"福利";
    panelRefreshStatus();
    BOOL stHit = [g_panelStatus.text isEqualToString:@"监视中 · 「福利」"];
    ST_CHECK(stIdle, @"v2.2 状态行只显示「监视中」");
    ST_CHECK(stHit, @"v2.2 命中后状态行追加关键词");
    g_running = NO;
    g_lastHitKeyword = nil;

    // ④ 报警卡片：异步建窗，靠日志断言（simtest Verdict 里 grep "alert card shown"）
    fireAlert(@"福利", @"福利 点击领取");

    // ⑪ v2.3 回归：输入卡片必须"真的显示出来 + 拿到键盘焦点"
    //    真机"点四行没反应"的真凶：窗口建了但没显示（UIWindow 默认 hidden=YES），
    //    且非 key window 时 becomeFirstResponder 失败 → 卡片看不见、键盘也不弹
    [SELActions onKeywordsRow:nil];
    BOOL cardShown  = (g_promptWin != nil && !g_promptWin.hidden);
    BOOL cardIsKey  = (g_promptWin != nil && g_promptWin.isKeyWindow);
    BOOL fieldFocus = (g_promptField != nil && [g_promptField isFirstResponder]);
    ST_CHECK(cardShown,  @"v2.3 输入卡片真的显示出来了（不是 hidden）");
    ST_CHECK(cardIsKey,  @"v2.3 输入卡片窗口成为 key（键盘能弹）");
    ST_CHECK(fieldFocus, @"v2.3 输入框自动获得焦点");
    // 确定按钮回填也验一次，顺带确认关闭把 key 还给了面板
    if (g_promptField) g_promptField.text = @"福利,测试词";
    [SELActions onPromptOK];
    BOOL wroteKw = [[[NSUserDefaults standardUserDefaults] stringForKey:@"sentinel_keywords"]
                    rangeOfString:@"测试词"].location != NSNotFound;
    ST_CHECK(wroteKw, @"v2.3 输入卡片「确定」能把参数写进配置");
    ST_CHECK(g_promptWin == nil, @"v2.3 确定后输入卡片已关闭");

    // ⑬ v2.5：探针模块自检（CI/无老贝贝环境 → 应为「已安装但 hook 0 处」，证明跳过逻辑安全）
    ST_CHECK(g_probeInstalled, @"v2.5 探针模块已安装");

    SLog(@"SELFTEST RESULT pass=%d fail=%d", g_seltestPass, g_selftestFail);

    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (doc) {
        [g_selftestLog writeToFile:[doc stringByAppendingPathComponent:@"Sentinel_selftest.txt"]
                        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    g_lastReport = [NSString stringWithFormat:@"自测 通过 %d · 失败 %d", g_seltestPass, g_selftestFail];
    panelShow();
    ST_CHECK(g_sectionCount >= 5, @"面板 分区数 >= 5（确认界面真的建起来了）");
    stWrite([NSString stringWithFormat:@"RESULT pass=%d fail=%d", g_seltestPass, g_selftestFail]);
}

#pragma mark - 入口

__attribute__((constructor))
static void sentinel_init(void) {
    if (g_armed) return;
    g_armed = YES;
    g_queue = dispatch_queue_create("wb.sentinel.scan", DISPATCH_QUEUE_SERIAL);
    g_lastAlert = [NSMutableDictionary dictionary];
    g_hitStreak = [NSMutableDictionary dictionary];
    refreshConfig();
    lbbProbeInstall();   // v2.5：识字命中探针（老贝贝类不存在时自动跳过）

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    g_selftest = [ud boolForKey:@"sentinel_selftest"];
    if ([ud objectForKey:@"sentinel_vibrate"]  == nil) [ud setBool:YES forKey:@"sentinel_vibrate"];
    if ([ud objectForKey:@"sentinel_sound"]    == nil) [ud setBool:NO  forKey:@"sentinel_sound"];
    if ([ud objectForKey:@"sentinel_interval"] == nil) [ud setObject:@(kIdleInterval)   forKey:@"sentinel_interval"];
    if ([ud objectForKey:@"sentinel_cooldown"] == nil) [ud setObject:@(kCooldownDefault) forKey:@"sentinel_cooldown"];
    [ud synchronize];

    SLog(@"constructor (selftest=%d, keywords=%@)", (int)g_selftest,
         [g_keywords componentsJoinedByString:@"|"]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartupDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        void (^onActive)(void) = ^{
            @try {
                createFloatingBall();
                if (g_selftest) { runSelftest(); return; }
                startWatching();
                // 第一次用：还没圈过区域 → 先给提示，再自动把框选界面打开
                if (!g_guided) {
                    g_guided = YES;
                    if (!loadRegion(NULL)) {
                        SLog(@"first run: no region yet → opening selector");
                        showBanner(@"哨兵已就绪：先圈定要盯住的区域");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ showRegionSelector(); });
                    }
                }
            } @catch (NSException *e) { SLog(@"onActive exception: %@", e); }
        };

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UISceneDidActivateNotification object:nil
                         queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { onActive(); }];
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                         queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { onActive(); }];
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (s.activationState == UISceneActivationStateForegroundActive) { onActive(); break; }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ createFloatingBall(); });
        SLog(@"armed (sentinel v2.5)");
    });
}
