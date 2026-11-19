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

@interface LingMenu : UIView
@property CGPoint drag;
- (void)refresh;
@end

@implementation LingMenu

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, 64, 96)];
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    self.layer.cornerRadius = 10;
    self.layer.borderWidth = 1;
    self.clipsToBounds = YES;
    [self makeButtons];
    return self;
}

- (void)makeButtons {
    UIButton *tog = [UIButton buttonWithType:UIButtonTypeCustom];
    tog.frame = CGRectMake(0,0,64,44);
    tog.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [tog setTitle:@"L" forState:UIControlStateNormal];
    [tog setTitleColor:[UIColor colorWithRed:.2 green:1 blue:.2 alpha:1] forState:UIControlStateNormal];
    [tog addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:tog];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeCustom];
    go.frame = CGRectMake(0,44,64,44);
    go.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [go setTitle:@"GO" forState:UIControlStateNormal];
    [go setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
    [go addTarget:self action:@selector(goTap) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:go];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [self addGestureRecognizer:pan];
}

- (void)toggle { g_enabled = !g_enabled; g_state = sIdle; [self refresh]; }
- (void)goTap  { if (g_enabled && g_state == sIdle) g_trigger = YES; }

- (void)refresh {
    UIView *tog = self.subviews.firstObject;
    if ([tog isKindOfClass:[UIButton class]]) {
        UIColor *c = g_enabled ? [UIColor colorWithRed:.2 green:1 blue:.2 alpha:1]
                               : [UIColor grayColor];
        [(UIButton *)tog setTitleColor:c forState:UIControlStateNormal];
    }
    self.layer.borderColor = g_enabled
        ? [UIColor colorWithRed:.2 green:.9 blue:.2 alpha:.8].CGColor
        : [UIColor colorWithWhite:.4 alpha:.6].CGColor;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _drag = self.center;
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(_drag.x + t.x, _drag.y + t.y);
}

@end

@interface LingWindow : UIWindow @end
@implementation LingWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;
}
@end

// ─────────────────────────────────────────────────────────
// Timer (must be after LingMenu @implementation)
// ─────────────────────────────────────────────────────────

static LingMenu *g_menu = nil;

static void start_timer(void) {
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
    dispatch_resume(t);
}

static void setup_overlay(void) {
    if (g_menu) return; // already set up

    // Try UIWindowScene first (iOS 13+)
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            break; // take first available, don't require ForegroundActive
        }
    }

    if (scene) {
        LingWindow *win = [[LingWindow alloc] initWithWindowScene:scene];
        win.windowLevel = UIWindowLevelAlert + 100;
        win.backgroundColor = UIColor.clearColor;
        win.hidden = NO;

        CGFloat top  = win.safeAreaInsets.top  > 0 ? win.safeAreaInsets.top  : 44;
        CGFloat left = win.safeAreaInsets.left > 0 ? win.safeAreaInsets.left : 12;

        LingMenu *menu = [LingMenu new];
        menu.center = CGPointMake(left + 32, top + 48);
        [win addSubview:menu];
        g_menu = menu;
    } else {
        // Fallback: attach to existing key window (suppress deprecation — no scene available)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *kw = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
        if (!kw) return;
        CGFloat top  = kw.safeAreaInsets.top  > 0 ? kw.safeAreaInsets.top  : 44;
        CGFloat left = kw.safeAreaInsets.left > 0 ? kw.safeAreaInsets.left : 12;
        LingMenu *menu = [LingMenu new];
        menu.center = CGPointMake(left + 32, top + 48);
        [kw addSubview:menu];
        g_menu = menu;
    }
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

    // Retry overlay every 2s until it appears (max 15 tries = 30s)
    __block int tries = 0;
    dispatch_source_t retry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(retry,
        dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
        2*NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(retry, ^{
        if (g_menu || ++tries > 15) {
            dispatch_source_cancel(retry);
            return;
        }
        setup_overlay();
    });
    dispatch_resume(retry);
}
