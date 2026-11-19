/*
 * LingAutoSword — iOS dylib
 * Target: MLBB non-jailbreak (TrollStore / rootless inject)
 *
 * Flow: Ling presses ult (skill 3) → tap GO button in overlay
 *       → auto-collect 4 swords via ShowSelfPlayer::TryUseSkill (argc=9)
 *
 * IL2CPP names verified from MLBB-Dump/dump.cs:
 *   ShowSelfPlayer::TryUseSkill(skillId,dir,dirDefault,pos,bCommonAttack,bAlong,isInFirstDragRange,bIgnoreQueue,dragTime)  argc=9
 *   BattleManager::Instance  (static field)
 *   BattleManager::m_LocalPlayerShow  (instance field)
 */

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────────────────
// IL2CPP runtime function pointers
// ─────────────────────────────────────────────────────────

static const void *(*f_assembly_get_image)(const void *);
static void       *(*f_domain_get)(void);
static void      **(*f_domain_get_assemblies)(const void *, size_t *);
static const char *(*f_image_get_name)(void *);
static void       *(*f_class_from_name)(const void *, const char *, const char *);
static void       *(*f_class_get_field)(void *, const char *);
static void       *(*f_class_get_method)(void *, const char *, int);
static size_t      (*f_field_get_offset)(void *);
static void        (*f_field_static_get)(void *, void *);

static BOOL g_attached = NO;

// ─────────────────────────────────────────────────────────
// Attach il2cpp API via dlsym on GameAssembly
// ─────────────────────────────────────────────────────────

static void *find_gameassembly(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "GameAssembly")) {
            void *h = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
            if (h) return h;
        }
    }
    return NULL;
}

static BOOL il2cpp_attach(void) {
    if (g_attached) return YES;
    void *h = find_gameassembly();
    if (!h) return NO;

#define R(sym, field) *(void **)&field = dlsym(h, #sym)
    R(il2cpp_assembly_get_image,         f_assembly_get_image);
    R(il2cpp_domain_get,                 f_domain_get);
    R(il2cpp_domain_get_assemblies,      f_domain_get_assemblies);
    R(il2cpp_image_get_name,             f_image_get_name);
    R(il2cpp_class_from_name,            f_class_from_name);
    R(il2cpp_class_get_field_from_name,  f_class_get_field);
    R(il2cpp_class_get_method_from_name, f_class_get_method);
    R(il2cpp_field_get_offset,           f_field_get_offset);
    R(il2cpp_field_static_get_value,     f_field_static_get);
#undef R

    if (!f_domain_get || !f_domain_get_assemblies ||
        !f_class_from_name || !f_class_get_method || !f_field_get_offset) {
        NSLog(@"[Ling] attach failed — missing symbols");
        return NO;
    }
    g_attached = YES;
    NSLog(@"[Ling] il2cpp attached");
    return YES;
}

// ─────────────────────────────────────────────────────────
// IL2CPP helpers
// ─────────────────────────────────────────────────────────

static void *get_image(const char *img_name) {
    size_t sz = 0;
    void **asms = f_domain_get_assemblies(f_domain_get(), &sz);
    if (!asms) return NULL;
    for (size_t i = 0; i < sz; i++) {
        void *img = (void *)f_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *n = f_image_get_name(img);
        if (n && strcmp(n, img_name) == 0) return img;
    }
    return NULL;
}

static void *get_class(const char *img, const char *ns, const char *cls) {
    void *image = get_image(img);
    return image ? f_class_from_name(image, ns, cls) : NULL;
}

static void *get_method(const char *img, const char *ns, const char *cls,
                         const char *meth, int argc) {
    void *klass = get_class(img, ns, cls);
    if (!klass) { NSLog(@"[Ling] class not found: %s", cls); return NULL; }
    void **mi = (void **)f_class_get_method(klass, meth, argc);
    if (!mi) { NSLog(@"[Ling] method not found: %s::%s(%d)", cls, meth, argc); return NULL; }
    return *mi;
}

static size_t get_field_off(const char *img, const char *ns, const char *cls,
                             const char *field) {
    void *klass = get_class(img, ns, cls);
    if (!klass) return (size_t)-1;
    void *f = f_class_get_field(klass, field);
    if (!f) return (size_t)-1;
    return f_field_get_offset(f);
}

static void get_static(const char *img, const char *ns, const char *cls,
                        const char *field, void *out) {
    void *klass = get_class(img, ns, cls);
    if (!klass) return;
    void *f = f_class_get_field(klass, field);
    if (!f || !f_field_static_get) return;
    f_field_static_get(f, out);
}

// ─────────────────────────────────────────────────────────
// Cached game pointers
// ─────────────────────────────────────────────────────────

// TryUseSkill(skillId, dir, dirDefault, pos, bCommonAttack, bAlong,
//             isInFirstDragRange, bIgnoreQueue, dragTime)  → argc=9
// From dump.cs line 106275 — ShowSelfPlayer
typedef void (*TryUseSkill9_t)(void *self,
    int   skillId,
    void *dir,       // Vector2 or similar — pass NULL/zero struct
    void *dirDefault,
    void *pos,
    int   bCommonAttack,
    int   bAlong,
    int   isInFirstDragRange,
    int   bIgnoreQueue,
    float dragTime
);

static TryUseSkill9_t g_skill2  = NULL;
static size_t         g_lp_off  = (size_t)-1;
static BOOL           g_ready   = NO;
static int            g_tries   = 0;

static BOOL resolve(void) {
    if (g_ready) return YES;
    if (++g_tries > 120) return NO;
    if (!il2cpp_attach()) return NO;

    size_t sz = 0;
    void **asms = f_domain_get_assemblies(f_domain_get(), &sz);
    if (!asms || sz == 0) return NO;

    // argc=9 = TryUseSkill without state param (collect sword swipe)
    g_skill2  = (TryUseSkill9_t)get_method("Assembly-CSharp.dll", "", "ShowSelfPlayer", "TryUseSkill", 9);
    g_lp_off  = get_field_off("Assembly-CSharp.dll", "", "BattleManager", "m_LocalPlayerShow");

    if (!g_skill2 || g_lp_off == (size_t)-1) {
        NSLog(@"[Ling] partial: skill2=%p lp_off=%zu", (void*)g_skill2, g_lp_off);
        return NO;
    }
    g_ready = YES;
    NSLog(@"[Ling] ready skill2=%p lp_off=0x%zx", (void*)g_skill2, g_lp_off);
    return YES;
}

static void *get_bm(void) {
    void *bm = NULL;
    get_static("Assembly-CSharp.dll", "", "BattleManager", "Instance", &bm);
    return bm;
}

static void *get_player(void) {
    void *bm = get_bm();
    if (!bm || g_lp_off == (size_t)-1) return NULL;
    return *(void **)((uintptr_t)bm + g_lp_off);
}

// ─────────────────────────────────────────────────────────
// Sword collect state machine
// ─────────────────────────────────────────────────────────

typedef enum { sIdle=0, sWait, sCollect, sCooldown } State;
static State          g_state    = sIdle;
static int            g_swords   = 0;
static NSTimeInterval g_next     = 0;
static BOOL           g_trigger  = NO;
static BOOL           g_enabled  = YES;

// Vector2 dummy struct for dir params
typedef struct { float x; float y; } Vec2;
typedef struct { float x; float y; float z; } Vec3;

static void fire_skill2(void *player, int dir) {
    if (!g_skill2 || !player) return;
    static const Vec2 dirs[4] = {{0,200},{200,0},{0,-200},{-200,0}};
    Vec2 d = dirs[dir % 4];
    Vec3 pos = {d.x, 0, d.y};
    @try {
        g_skill2(player,
            1,          // skillId = 1 (0-based, skill 2)
            &d,         // dir
            &d,         // dirDefault
            &pos,       // pos
            0,          // bCommonAttack
            0,          // bAlong
            0,          // isInFirstDragRange
            1,          // bIgnoreQueue
            0.0f        // dragTime
        );
    } @catch(...) { NSLog(@"[Ling] skill2 crash dir=%d", dir); }
}

static void tick(void) {
    if (!g_enabled) return;
    if (!resolve()) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    switch (g_state) {
        case sIdle:
            if (g_trigger) {
                g_trigger = NO; g_swords = 4; g_state = sWait;
                g_next = now + 0.35;
            }
            break;
        case sWait:
            if (now >= g_next) { g_state = sCollect; g_next = now; }
            break;
        case sCollect:
            if (g_swords <= 0) { g_state = sCooldown; g_next = now + 1.0; break; }
            if (now >= g_next) {
                void *p = get_player();
                if (p) fire_skill2(p, 4 - g_swords);
                else NSLog(@"[Ling] no player");
                g_swords--;
                g_next = now + 0.38;
            }
            break;
        case sCooldown:
            if (now >= g_next) g_state = sIdle;
            break;
    }
}

// ─────────────────────────────────────────────────────────
// Timer
// ─────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────
// Overlay UI
// ─────────────────────────────────────────────────────────

@class LingFloatingButton;
static LingFloatingButton *g_menu = nil;
static LingFloatingButton *g_goMenu = nil;

@interface LingFloatingButton : UIView
@property CGPoint drag;
@property BOOL goButton;
- (instancetype)initWithGoButton:(BOOL)isGo;
- (void)refresh;
@end

@implementation LingFloatingButton

- (instancetype)initWithGoButton:(BOOL)isGo {
    self = [super initWithFrame:CGRectMake(0, 0, 56, 44)];
    if (!self) return nil;
    _goButton = isGo;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    self.layer.cornerRadius = 11;
    self.layer.borderWidth = 1;
    self.clipsToBounds = YES;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = self.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:isGo ? 13 : 16];
    [button setTitle:(isGo ? @"GO" : @"L") forState:UIControlStateNormal];
    [button addTarget:self action:(isGo ? @selector(goTap) : @selector(toggle))
     forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];
    [self refresh];
    return self;
}

- (void)toggle {
    g_enabled = !g_enabled;
    g_state = sIdle;
    [g_menu refresh];
}

- (void)goTap {
    if (g_enabled && g_state == sIdle) g_trigger = YES;
}

- (void)refresh {
    UIColor *titleColor = _goButton
        ? [UIColor yellowColor]
        : (g_enabled ? [UIColor colorWithRed:.2 green:1 blue:.2 alpha:1] : [UIColor grayColor]);
    UIButton *button = (UIButton *)self.subviews.firstObject;
    [button setTitleColor:titleColor forState:UIControlStateNormal];
    self.layer.borderColor = (!_goButton && g_enabled)
        ? [UIColor colorWithRed:.2 green:.9 blue:.2 alpha:.8].CGColor
        : [UIColor colorWithWhite:.4 alpha:.65].CGColor;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *parent = self.superview;
    if (!parent) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        _drag = self.center;
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [g translationInView:parent];
        CGFloat halfW = CGRectGetWidth(self.bounds) * 0.5;
        CGFloat halfH = CGRectGetHeight(self.bounds) * 0.5;
        CGFloat maxX = CGRectGetWidth(parent.bounds) - halfW;
        CGFloat maxY = CGRectGetHeight(parent.bounds) - halfH;
        CGFloat x = MIN(MAX(_drag.x + translation.x, halfW), MAX(halfW, maxX));
        CGFloat y = MIN(MAX(_drag.y + translation.y, halfH), MAX(halfH, maxY));
        self.center = CGPointMake(x, y);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        _drag = self.center;
    }
}
@end

@interface LingWindow : UIWindow @end
@implementation LingWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];

    // Full-screen transparent window: only the floating menu consumes touches.
    // All touches outside the menu pass through to the game underneath.
    if (!v) return nil;
    if ((g_menu && (v == g_menu || [v isDescendantOfView:g_menu])) ||
        (g_goMenu && (v == g_goMenu || [v isDescendantOfView:g_goMenu]))) return v;
    return nil;
}
@end

// ─────────────────────────────────────────────────────────
// Timer (must be after LingMenu @implementation)
// ─────────────────────────────────────────────────────────

// Keep the overlay window and dispatch sources alive for the lifetime of the tweak.
static UIWindow *g_overlayWindow = nil;
static dispatch_source_t g_tickTimer = nil;
static dispatch_source_t g_overlayRetry = nil;

static void start_timer(void) {
    if (g_tickTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0),
                              50*NSEC_PER_MSEC, 10*NSEC_PER_MSEC);
    __block int c = 0;
    dispatch_source_set_event_handler(t, ^{
        @try { tick(); } @catch(...) {}
        if (++c % 20 == 0 && g_menu)
            [g_menu refresh];
    });
    g_tickTimer = t;
    dispatch_resume(t);
}

static void setup_overlay(void) {
    if (g_menu && g_overlayWindow) return;

    UIApplication *app = UIApplication.sharedApplication;
    UIWindowScene *scene = nil;

    // Only attach to a foreground scene; selecting a background scene can
    // create a window that exists but is never presented.
    for (UIScene *candidate in app.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
        if (candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
        if (!scene && candidate.activationState == UISceneActivationStateForegroundInactive) {
            scene = (UIWindowScene *)candidate;
        }
    }

    if (scene) {
        LingWindow *win = [[LingWindow alloc] initWithWindowScene:scene];
        win.frame = scene.coordinateSpace.bounds;
        win.windowLevel = UIWindowLevelAlert + 1;
        win.backgroundColor = UIColor.clearColor;
        win.opaque = NO;
        win.rootViewController = [UIViewController new];
        win.rootViewController.view.backgroundColor = UIColor.clearColor;
        win.rootViewController.view.userInteractionEnabled = YES;

        // Retain the UIWindow explicitly. A local UIWindow can disappear after
        // setup returns, taking the overlay with it.
        g_overlayWindow = win;
        CGFloat top = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 44;
        CGFloat left = win.safeAreaInsets.left > 0 ? win.safeAreaInsets.left : 12;
        UIView *host = win.rootViewController.view;
        LingFloatingButton *menu = [[LingFloatingButton alloc] initWithGoButton:NO];
        LingFloatingButton *go = [[LingFloatingButton alloc] initWithGoButton:YES];
        menu.center = CGPointMake(left + 28, top + 48);
        go.center = CGPointMake(left + 28, top + 104);
        [host addSubview:menu];
        [host addSubview:go];
        g_menu = menu;
        g_goMenu = go;
        win.hidden = NO;
        [win setNeedsLayout];
        [win layoutIfNeeded];
        NSLog(@"[Ling] overlay attached to foreground UIWindowScene");
        return;
    }

    // Scene may not be ready immediately after injection. Attach to the
    // current app window when available, and let the retry timer try again.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = app.keyWindow;
#pragma clang diagnostic pop
    if (!keyWindow) {
        for (UIScene *candidate in app.connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidateWindow in ((UIWindowScene *)candidate).windows) {
                if (!candidateWindow.hidden) { keyWindow = candidateWindow; break; }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        NSLog(@"[Ling] overlay waiting: no active app window yet");
        return;
    }

    CGFloat top = keyWindow.safeAreaInsets.top > 0 ? keyWindow.safeAreaInsets.top : 44;
    CGFloat left = keyWindow.safeAreaInsets.left > 0 ? keyWindow.safeAreaInsets.left : 12;
    LingFloatingButton *menu = [[LingFloatingButton alloc] initWithGoButton:NO];
    LingFloatingButton *go = [[LingFloatingButton alloc] initWithGoButton:YES];
    menu.center = CGPointMake(left + 28, top + 48);
    go.center = CGPointMake(left + 28, top + 104);
    [keyWindow addSubview:menu];
    [keyWindow addSubview:go];
    [keyWindow bringSubviewToFront:menu];
    [keyWindow bringSubviewToFront:go];
    g_overlayWindow = keyWindow;
    g_menu = menu;
    g_goMenu = go;
    NSLog(@"[Ling] overlay attached to existing app window");
}

// ─────────────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────────────

__attribute__((constructor))
static void ling_init(void) {
    NSLog(@"[LingAutoSword] loaded");

    // Start game tick after 3s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        il2cpp_attach();
        start_timer();
    });

    // Retry until UIKit has a foreground window. Keep the source alive.
    g_overlayRetry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             dispatch_get_main_queue());
    dispatch_source_set_timer(g_overlayRetry,
        dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC),
        2*NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_overlayRetry, ^{
        if (g_menu) {
            dispatch_source_cancel(g_overlayRetry);
            g_overlayRetry = nil;
            return;
        }
        setup_overlay();
    });
    dispatch_resume(g_overlayRetry);
}
