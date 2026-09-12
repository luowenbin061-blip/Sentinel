// Sentinel.m — 屏幕哨兵（TrollFools 注入用）
// ============================================================
// 干什么：圈一块屏幕区域，盯住它，OCR 认出关键字就报警（横幅 + 震动）。
//
// 设计要点（2026-09-13 定稿）：
//   ① 只截框选那一块、只对那一块跑 OCR —— 省一个数量级 CPU，且大幅降低误命中
//   ② 分级节奏：空闲 2s / 刚命中连验（500ms，连中 2 轮才算）
//   ③ 关键字匹配四件套：归一化 + 滑窗容错(编辑距离≤1) + 同义词组 + 置信度阈值
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

#pragma mark - 可调参数

static const NSTimeInterval kStartupDelay   = 0.6;
static const double kIdleInterval           = 2.0;   // 空闲扫描间隔(秒)
static const double kVerifyInterval         = 0.5;   // 命中后连验间隔(秒)
static const int    kVerifyNeed             = 2;     // 连续 N 轮命中才报警（防误报）
static const double kCooldownDefault        = 10.0;  // 同一关键字冷却(秒)
static const double kBusyInterval           = 6.0;   // 别人在忙时的降频间隔(秒)
static const double kBusyHold               = 8.0;   // 收到执行通知后降频保持(秒)
static const CGFloat kMinRegionSide         = 24.0;  // 框选最小边长(pt)
static const double kSelftestBandY          = 0.44;  // 自测假图里文字所在条带(归一化)
static const double kSelftestBandH          = 0.14;

static NSString *const kPeerBusyNote = @"com.changqing.fullTaskExecution";

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
static NSArray<NSArray<NSString *> *> *loadSynonyms(void) {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *grp in splitList([[NSUserDefaults standardUserDefaults] stringForKey:@"sentinel_synonyms"], @";")) {
        NSMutableArray *g = [NSMutableArray array];
        for (NSString *w in [grp componentsSeparatedByString:@"="]) {
            NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [g addObject:t];
        }
        if (g.count) [groups addObject:g];
    }
    return groups;
}

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

static int editDistance(NSString *a, NSString *b) {
    NSUInteger la = a.length, lb = b.length;
    if (la == 0) return (int)lb;
    if (lb == 0) return (int)la;
    if (la > 64 || lb > 64) return 99;
    int *p1 = (int *)malloc(sizeof(int) * (lb + 1));
    int *p2 = (int *)malloc(sizeof(int) * (lb + 1));
    if (!p1 || !p2) { free(p1); free(p2); return 99; }
    for (NSUInteger j = 0; j <= lb; j++) p1[j] = (int)j;
    for (NSUInteger i = 1; i <= la; i++) {
        p2[0] = (int)i;
        for (NSUInteger j = 1; j <= lb; j++) {
            int cost = ([a characterAtIndex:i - 1] == [b characterAtIndex:j - 1]) ? 0 : 1;
            int v = p1[j - 1] + cost;
            if (p1[j] + 1 < v) v = p1[j] + 1;
            if (p2[j - 1] + 1 < v) v = p2[j - 1] + 1;
            p2[j] = v;
        }
        int *t = p1; p1 = p2; p2 = t;
    }
    int r = p1[lb];
    free(p1); free(p2);
    return r;
}

static BOOL matchOne(NSString *normText, NSString *normKw) {
    if (!normText.length || !normKw.length) return NO;
    if ([normText containsString:normKw]) return YES;
    if (normKw.length < 2) return NO;
    if (normText.length < normKw.length) return NO;
    NSUInteger L = normKw.length;
    for (NSUInteger i = 0; i + L <= normText.length; i++) {
        NSString *sub = [normText substringWithRange:NSMakeRange(i, L)];
        if (editDistance(sub, normKw) <= 1) return YES;
    }
    return NO;
}

// 一行文字是否命中；命中返回"报告用的关键词原文"，没命中返回 nil
static NSString *matchLine(NSString *normText, NSArray<NSString *> *keywords,
                           NSArray<NSArray<NSString *> *> *synonymGroups) {
    // ① 直接关键词
    for (NSString *kw in keywords) {
        if (matchOne(normText, normalizeText(kw))) return kw;
    }
    // ② 同义词组：组里只要有用户配的关键词，就看该组其它词是否命中
    for (NSArray<NSString *> *grp in synonymGroups) {
        BOOL groupWanted = NO;
        NSString *groupKey = nil;
        for (NSString *g in grp) {
            for (NSString *kw in keywords) {
                if ([normalizeText(kw) isEqualToString:normalizeText(g)]) { groupWanted = YES; groupKey = kw; break; }
            }
            if (groupWanted) break;
        }
        if (!groupWanted) continue;
        for (NSString *g in grp) {
            if (matchOne(normText, normalizeText(g))) return groupKey;
        }
    }
    return nil;
}

#pragma mark - 全局状态

static dispatch_queue_t g_queue;
static BOOL   g_armed = NO;
static BOOL   g_running = NO;
static BOOL   g_selecting = NO;
static BOOL   g_selftest = NO;
static double g_busyUntil = 0;
static NSArray<NSString *> *g_keywords = nil;
static NSArray<NSArray<NSString *> *> *g_synonyms = nil;
static NSMutableDictionary *g_lastAlert = nil;
static NSMutableDictionary *g_hitStreak = nil;
static NSString *g_lastReport = @"(还没有记录)";
static NSArray<NSString *> *g_lastScanTexts = nil;
static UIWindow *g_ballWin = nil;
static UIWindow *g_bannerWin = nil;
static UILabel  *g_bannerLabel = nil;
static int g_seltestPass = 0, g_selftestFail = 0;
static BOOL g_guided = NO;   // 首次引导只做一次

// 前置声明
static void showMenu(void);
static void showReport(NSString *msg);
static void showSettings(void);
static void showRegionSelector(void);
static void probeOnce(void);
static void startWatching(void);
static void stopWatching(void);
static void createFloatingBall(void);
static UIImage *renderFakeHUD(void);
static void runSelftest(void);

static void refreshConfig(void) {
    g_keywords = loadKeywords();
    g_synonyms = loadSynonyms();
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
            g_bannerWin.frame = CGRectMake(0, -h, scr.width, h);
            g_bannerLabel.frame = g_bannerWin.bounds;
            g_bannerLabel.text = text;
            g_bannerWin.hidden = NO;

            [UIView animateWithDuration:0.22 animations:^{
                g_bannerWin.frame = CGRectMake(0, 0, scr.width, h);
            }];

            static int gen = 0;
            int my = ++gen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (my != gen || !g_bannerWin) return;
                [UIView animateWithDuration:0.25 animations:^{
                    g_bannerWin.frame = CGRectMake(0, -h, scr.width, h);
                } completion:^(BOOL f) {
                    if (my == gen && g_bannerWin) g_bannerWin.hidden = YES;
                }];
            });
        } @catch (NSException *e) { SLog(@"banner exception: %@", e); }
    });
}

static void fireAlert(NSString *keyword, NSString *rawText) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL vibrate = [ud boolForKey:@"sentinel_vibrate"];
    BOOL sound   = [ud boolForKey:@"sentinel_sound"];
    if (vibrate) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    if (sound)   AudioServicesPlaySystemSound(1007);   // 系统音，不建 AVAudioSession
    showBanner([NSString stringWithFormat:@"哨兵｜命中「%@」%@", keyword,
                rawText.length ? [NSString stringWithFormat:@"  %@", rawText] : @""]);
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
            NSString *k = matchLine(norm, g_keywords, g_synonyms);
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

    UIImage *full = captureScreen();
    if (!full) { SLog(@"scan(%@) capture failed", reason); return; }
    UIImage *crop = cropToRegion(full, norm);
    if (!crop) { SLog(@"scan(%@) crop failed", reason); return; }

    NSMutableArray *hits = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];
    evaluate(crop, hits, texts);
    g_lastScanTexts = [texts copy];

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
    if (CACurrentMediaTime() < g_busyUntil && iv < kBusyInterval) iv = kBusyInterval;
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
            showReport([NSString stringWithFormat:@"试测结果\n\n%@\n\n识别到的文字：\n%@",
                        g_lastReport, joinShort(g_lastScanTexts ?: @[])]);
        });
    });
}

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
+ (void)onTap:(UITapGestureRecognizer *)t { SLog(@"ball tap → menu"); showMenu(); }
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

#pragma mark - 报告 / 设置 / 菜单

static UIViewController *presentVC(void) {
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w == g_ballWin || w == g_bannerWin) continue;   // 跳过自己的窗口
            if (w.hidden || !w.rootViewController) continue;
            if (!win || w.windowLevel > win.windowLevel) win = w;
        }
    }
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void showReport(NSString *msg) {
    SLog(@"report: %@", msg);
    g_lastReport = msg;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *vc = presentVC();
            if (!vc) return;
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"哨兵"
                message:msg preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"确 定" style:UIAlertActionStyleCancel handler:nil]];
            [vc presentViewController:ac animated:YES completion:nil];
        } @catch (NSException *e) { SLog(@"report exception: %@", e); }
    });
}

static void showSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = presentVC();
        if (!vc) return;
        CGRect r;
        NSString *regionHint = loadRegion(&r)
            ? [NSString stringWithFormat:@"当前区域 %.0f%%,%.0f%%  %.0f%%×%.0f%%",
               r.origin.x*100, r.origin.y*100, r.size.width*100, r.size.height*100]
            : @"还没圈定区域（点头 →「圈定监视区域」）";

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"哨兵设置"
            message:[NSString stringWithFormat:
                @"关键词：逗号分隔\n同义词：同义词用 = 连，不同组用 ; 隔\n例：体力不足=体力不够;金币不足=金币不够\n\n%@", regionHint]
            preferredStyle:UIAlertControllerStyleAlert];

        NSArray *specs = @[
            @[@"sentinel_keywords", @"体力不足,无法操作",        @"关键词"],
            @[@"sentinel_synonyms", @"体力不足=体力不够;金币不足=金币不够", @"同义词"],
            @[@"sentinel_interval", @"2",                        @"扫描间隔(秒)"],
            @[@"sentinel_cooldown", @"10",                       @"报警冷却(秒)"],
        ];
        for (NSArray *sp in specs) {
            NSString *key = sp[0], *ph = sp[1], *title = sp[2];
            [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                id cur = [[NSUserDefaults standardUserDefaults] objectForKey:key];
                tf.text = cur ? [NSString stringWithFormat:@"%@", cur] : @"";
                tf.placeholder = [NSString stringWithFormat:@"%@：%@", title, ph];
                tf.clearButtonMode = UITextFieldViewModeAlways;
                BOOL isText = ([key isEqualToString:@"sentinel_keywords"] ||
                               [key isEqualToString:@"sentinel_synonyms"]);
                tf.keyboardType = isText ? UIKeyboardTypeDefault : UIKeyboardTypeDecimalPad;
            }];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"保存并试测" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            for (NSUInteger i = 0; i < specs.count; i++) {
                NSString *key = specs[i][0];
                NSString *val = ac.textFields[i].text ?: @"";
                if ([key isEqualToString:@"sentinel_interval"] || [key isEqualToString:@"sentinel_cooldown"]) {
                    double d = val.doubleValue;
                    if (d <= 0) d = [key isEqualToString:@"sentinel_interval"] ? kIdleInterval : kCooldownDefault;
                    [ud setObject:@(d) forKey:key];
                } else {
                    [ud setObject:val forKey:key];
                }
            }
            [ud synchronize];
            refreshConfig();
            SLog(@"settings saved: kw=%@ iv=%.1f cd=%.1f",
                 [g_keywords componentsJoinedByString:@"|"],
                 cfgDouble(@"sentinel_interval", kIdleInterval),
                 cfgDouble(@"sentinel_cooldown", kCooldownDefault));
            probeOnce();
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:ac animated:YES completion:nil];
    });
}

static void showMenu(void) {
    UIViewController *vc = presentVC();
    if (!vc) { SLog(@"showMenu FAILED: no app window/rootVC"); return; }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL vibrate = [ud boolForKey:@"sentinel_vibrate"];
    BOOL sound   = [ud boolForKey:@"sentinel_sound"];
    CGRect r; BOOL hasRegion = loadRegion(&r);

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"哨兵"
        message:[NSString stringWithFormat:@"%@\n区域：%@\n关键词：%@\n%@",
                 g_running ? @"监视中" : @"已暂停",
                 hasRegion ? [NSString stringWithFormat:@"%.0f%%,%.0f%%  %.0f%%×%.0f%%",
                              r.origin.x*100, r.origin.y*100, r.size.width*100, r.size.height*100] : @"未圈定",
                 [g_keywords componentsJoinedByString:@" / "],
                 g_lastReport]
        preferredStyle:UIAlertControllerStyleActionSheet];
    ac.popoverPresentationController.sourceView = vc.view;

    [ac addAction:[UIAlertAction actionWithTitle:@"▭ 圈定监视区域" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { showRegionSelector(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:(g_running ? @"⏸ 暂停监视" : @"▶ 开始监视")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (g_running) stopWatching(); else startWatching();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔍 试测一次（看识别到什么）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { probeOnce(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"⚙ 设置（关键词/同义词/间隔）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { showSettings(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"📳 震动报警：%@", vibrate ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [ud setBool:!vibrate forKey:@"sentinel_vibrate"]; [ud synchronize];
        SLog(@"vibrate → %d", (int)!vibrate);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"🔊 声音报警：%@", sound ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [ud setBool:!sound forKey:@"sentinel_sound"]; [ud synchronize];
        SLog(@"sound → %d", (int)!sound);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"📋 复制日志" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
        NSString *log = [NSString stringWithContentsOfFile:g_logPath encoding:NSUTF8StringEncoding error:nil];
        [UIPasteboard generalPasteboard].string = log ?: @"(日志为空)";
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
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
    CGPoint cs[4] = { {r.origin.x, r.origin.y}, {CGRectGetMaxX(r), r.origin.y},
                      {r.origin.x, CGRectGetMaxY(r)}, {CGRectGetMaxX(r), CGRectGetMaxY(r)} };
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
        hint.text = @"拖空白处重画 · 拖四角微调 · 拖框内移动";
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

    // ③ 容错（OCR 错认一个字）
    ST_CHECK(matchOne(@"体力木足无法继续", @"体力不足"), @"match 容错(编辑距离1)");
    ST_CHECK(!matchOne(@"体力没有问题", @"体力不足"), @"match 容错不过度放宽");

    // ④ 同义词组（用"没劲了"这种和关键词差很多的词，才能单独验证同义词这条路）
    NSArray *grpSyn = @[ @[@"体力不足", @"没劲了"] ];
    ST_CHECK([matchLine(@"没劲了", @[@"体力不足"], grpSyn) isEqualToString:@"体力不足"],
              @"synonym 组内其它词命中并回报组键");
    ST_CHECK(matchLine(@"金币不足", @[@"体力不足"], grpSyn) == nil, @"synonym 组外不命中");
    ST_CHECK([matchLine(@"体力木足", @[@"体力不足"], @[]) isEqualToString:@"体力不足"],
              @"match 容错命中并回报关键词");

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
        g_synonyms = @[ @[@"体力不足", @"体力不够"] ];
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
    g_synonyms = loadSynonyms();
    ST_CHECK(g_keywords.count >= 1, @"config 关键词加载非空");

    stWrite([NSString stringWithFormat:@"RESULT pass=%d fail=%d", g_seltestPass, g_selftestFail]);
    SLog(@"SELFTEST RESULT pass=%d fail=%d", g_seltestPass, g_selftestFail);

    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (doc) {
        [g_selftestLog writeToFile:[doc stringByAppendingPathComponent:@"Sentinel_selftest.txt"]
                        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    showReport([NSString stringWithFormat:@"哨兵自测\n通过 %d · 失败 %d\n\n%@",
                g_seltestPass, g_selftestFail, g_selftestLog]);
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
        // 同进程别的插件执行任务时降频，避开点击时序冲突
        [[NSNotificationCenter defaultCenter] addObserverForName:kPeerBusyNote
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                g_busyUntil = CACurrentMediaTime() + kBusyHold;
                SLog(@"peer busy note → throttle %.0fs", kBusyHold);
        }];

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
        SLog(@"armed (sentinel v1.0)");
    });
}
