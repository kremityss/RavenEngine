#import "Menu.h"
#import "Common.h"
#import "Logos.h"
#import "ESP.h"
#import "Aimbot.h"
#import "IL2CPP.h"
#import "Updater.h"
#import "Settings.h"
#import "LicenseClient.h"
#import <objc/runtime.h>

#define C_WIN      [UIColor colorWithRed:0.043 green:0.043 blue:0.055 alpha:0.97]
#define C_HEAD     [UIColor colorWithRed:0.051 green:0.051 blue:0.063 alpha:1.0]
#define C_SIDE     [UIColor colorWithRed:0.055 green:0.055 blue:0.071 alpha:1.0]
#define C_CARD     [UIColor colorWithRed:0.078 green:0.078 blue:0.090 alpha:1.0]
#define C_BORDER   [UIColor colorWithRed:0.157 green:0.157 blue:0.165 alpha:1.0]
#define C_RED      [UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:1.0]
#define C_CRIMSON  [UIColor colorWithRed:0.290 green:0.067 blue:0.086 alpha:1.0]
#define C_TEXT     [UIColor colorWithRed:0.949 green:0.949 blue:0.957 alpha:1.0]
#define C_SEC      [UIColor colorWithRed:0.573 green:0.573 blue:0.608 alpha:1.0]
#define C_MUTE     [UIColor colorWithRed:0.384 green:0.384 blue:0.420 alpha:1.0]

static const CGFloat kRefW       = 860;
static const CGFloat kRefH       = 500;
static const CGFloat kHeaderH    = 84;
static const CGFloat kFooterH    = 28;
static const CGFloat kSidebarW   = 168;
static const CGFloat kPad        = 18;
static const CGFloat kCardGap    = 12;
static const CGFloat kCardRad    = 8;
static const CGFloat kTabH       = 40;
static const CGFloat kRowH       = 28;
static const CGFloat kRowHBig    = 46;

static NSCache* g_imgCache = nil;
static NSString* ravenLicenseCountdown(void) {
    NSTimeInterval expiry = RavenLicense::expiryTimestamp();
    if (expiry <= 0.0) return @"Active • server-managed";
    NSTimeInterval remaining = expiry - NSDate.date.timeIntervalSince1970;
    if (remaining <= 0.0) return @"EXPIRED";
    NSInteger total = (NSInteger)remaining;
    NSInteger days = total / 86400;
    NSInteger hours = (total % 86400) / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger seconds = total % 60;
    if (days > 0) return [NSString stringWithFormat:@"%ldd %02ldh %02ldm", (long)days, (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld remaining", (long)hours, (long)minutes, (long)seconds];
}
typedef void(^ImgBlock)(UIImage*);

static NSString* diskPathFor(NSString* key) {
    NSString* dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString* hash = [NSString stringWithFormat:@"%lu", (unsigned long)key.hash];
    return [dir stringByAppendingPathComponent:[hash stringByAppendingString:@".img"]];
}

static UIImage* loadCachedImage(const char* url) {
    if (!url || !*url) return nil;
    if (!g_imgCache) g_imgCache = [[NSCache alloc] init];
    NSString* key = [NSString stringWithUTF8String:url];
    UIImage* c = [g_imgCache objectForKey:key];
    if (c) return c;
    NSData* d = [NSData dataWithContentsOfFile:diskPathFor(key)];
    if (!d) return nil;
    UIImage* img = [UIImage imageWithData:d];
    if (img) [g_imgCache setObject:img forKey:key];
    return img;
}

static void loadLogoURLAsync(const char* url, ImgBlock cb) {
    if (!url || !*url) { if (cb) cb(nil); return; }
    UIImage* cached = loadCachedImage(url);
    if (cached) { if (cb) cb(cached); return; }
    if (cb) cb(nil);

    NSString* key = [NSString stringWithUTF8String:url];
    NSURL* u = [NSURL URLWithString:key];
    if (!u) return;

    NSURLSessionDataTask* task =
        [[NSURLSession sharedSession] dataTaskWithURL:u
                                    completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
        if (!data) return;
        UIImage* img = [UIImage imageWithData:data];
        if (!img) return;
        if (!g_imgCache) g_imgCache = [[NSCache alloc] init];
        [g_imgCache setObject:img forKey:key];
        [data writeToFile:diskPathFor(key) atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cb) cb(img);
        });
    }];
    [task resume];
}

static UIImage* cropNormalized(UIImage* img, CGRect n) {
    if (!img || !img.CGImage) return img;
    size_t w = CGImageGetWidth(img.CGImage);
    size_t h = CGImageGetHeight(img.CGImage);
    CGRect px = CGRectMake(n.origin.x * w,
                           n.origin.y * h,
                           n.size.width * w,
                           n.size.height * h);
    px = CGRectIntersection(px, CGRectMake(0, 0, w, h));
    if (CGRectIsEmpty(px)) return img;
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, px);
    if (!cg) return img;
    UIImage* out = [UIImage imageWithCGImage:cg scale:img.scale orientation:img.imageOrientation];
    CGImageRelease(cg);
    return out;
}

static UILabel* lbl(NSString* t, CGFloat sz, UIColor* c, BOOL bold) {
    UILabel* l = [UILabel new];
    l.text = t;
    l.textColor = c;
    l.font = bold ? [UIFont systemFontOfSize:sz weight:UIFontWeightSemibold]
                  : [UIFont systemFontOfSize:sz weight:UIFontWeightRegular];
    l.numberOfLines = 1;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

static NSUInteger raven_landscape_mask(id self, SEL _cmd) {
    return UIInterfaceOrientationMaskLandscape;
}

static void forceLandscape(void) {
    Method m = class_getInstanceMethod([UIViewController class],
                                       @selector(supportedInterfaceOrientations));
    if (m) {
        method_setImplementation(m, (IMP)raven_landscape_mask);
    }
}

@implementation RavenWindow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    RavenMenu* m = [RavenMenu shared];
    if (!m) return nil;
    UIView* panel = [m valueForKey:@"panel"];
    UIView* ball  = [m valueForKey:@"ball"];
    if (panel && !panel.hidden && panel.alpha > 0.01) {
        CGPoint p = [panel convertPoint:point fromView:self];
        if ([panel pointInside:p withEvent:event]) {
            return [panel hitTest:p withEvent:event];
        }
    }
    if (ball && !ball.hidden && ball.alpha > 0.01) {
        CGPoint p = [ball convertPoint:point fromView:self];
        if ([ball pointInside:p withEvent:event]) {
            UIView* hit = [ball hitTest:p withEvent:event];
            if (hit) return hit;
        }
    }
    // Never consume gameplay touches outside the menu controls. Returning
    // nil here is required for the underlying game view to receive drag,
    // look, and touch/gyro input normally.
    return nil;
}
@end

@implementation RVToggle { UIView* _track; UIView* _knob; }
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 40, 22)])) {
        self.userInteractionEnabled = YES;
        _track = [[UIView alloc] initWithFrame:CGRectMake(0, 1, 40, 20)];
        _track.layer.cornerRadius = 10;
        _track.layer.borderWidth = 1;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.07].CGColor;
        _track.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1.0];
        [self addSubview:_track];
        _knob = [[UIView alloc] initWithFrame:CGRectMake(3, 3, 16, 16)];
        _knob.layer.cornerRadius = 8;
        _knob.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1.0];
        _knob.layer.shadowColor = [UIColor blackColor].CGColor;
        _knob.layer.shadowOpacity = 0.42;
        _knob.layer.shadowRadius = 3;
        _knob.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_knob];
        UITapGestureRecognizer* t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
        t.cancelsTouchesInView = YES;
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)toggle {
    UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
    self.on = !self.on;
    [self applyStateAnimated:RavenSettings::animations];
    if (self.onChange) self.onChange(self.on);
}
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)animated { _on = on; [self applyStateAnimated:animated]; }
- (void)applyStateAnimated:(BOOL)animated {
    UIColor* track = _on ? C_RED : [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1.0];
    CGRect knob = _on ? CGRectMake(21, 3, 16, 16) : CGRectMake(3, 3, 16, 16);
    void (^blk)(void) = ^{
        _track.backgroundColor = track;
        _track.layer.borderColor = (_on ? [C_RED colorWithAlphaComponent:0.85] : [UIColor colorWithWhite:1 alpha:0.07]).CGColor;
        _track.layer.shadowColor = C_RED.CGColor;
        _track.layer.shadowOpacity = _on ? 0.28 : 0.0;
        _track.layer.shadowRadius = _on ? 5.0 : 0.0;
        _track.layer.shadowOffset = CGSizeZero;
        _knob.frame = knob;
    };
    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.45
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:blk completion:nil];
    } else {
        blk();
    }
}
@end

@implementation RVSlider { UIView* _track; UIView* _fill; UIView* _thumb; float _t; }
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 200, 20)])) {
        self.userInteractionEnabled = YES;
        _minValue = 0; _maxValue = 100; _value = 0; _t = 0;
        _track = [UIView new];
        _track.backgroundColor = [UIColor colorWithRed:0.19 green:0.19 blue:0.22 alpha:1.0];
        _track.layer.cornerRadius = 2.0;
        _track.layer.borderWidth = 0.5;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.035].CGColor;
        [self addSubview:_track];
        _fill = [UIView new];
        _fill.backgroundColor = C_RED;
        _fill.layer.cornerRadius = 2.0;
        _fill.layer.shadowColor = C_RED.CGColor;
        _fill.layer.shadowOpacity = 0.24;
        _fill.layer.shadowRadius = 4;
        _fill.layer.shadowOffset = CGSizeZero;
        [self addSubview:_fill];
        _thumb = [UIView new];
        _thumb.backgroundColor = [UIColor colorWithWhite:0.985 alpha:1.0];
        _thumb.layer.cornerRadius = 6;
        _thumb.layer.borderWidth = 1.5;
        _thumb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.72].CGColor;
        _thumb.layer.shadowColor = C_RED.CGColor;
        _thumb.layer.shadowOpacity = 0.36;
        _thumb.layer.shadowRadius = 4;
        _thumb.layer.shadowOffset = CGSizeZero;
        [self addSubview:_thumb];
        UIPanGestureRecognizer* p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
        p.cancelsTouchesInView = YES;
        [self addGestureRecognizer:p];
        UITapGestureRecognizer* t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        t.cancelsTouchesInView = YES;
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat th = 4.0;
    CGFloat ty = (h - th) / 2.0;
    CGFloat padL = 8.0;
    CGFloat padR = 8.0;
    CGFloat usable = w - padL - padR;
    _track.frame = CGRectMake(padL, ty, usable, th);
    _fill.frame  = CGRectMake(padL, ty, usable * _t, th);
    CGFloat thumbX = padL + usable * _t - 6.0;
    _thumb.frame = CGRectMake(thumbX, (h - 12.0) / 2.0, 12.0, 12.0);
}
- (void)setValue:(float)value {
    float v = MAX(_minValue, MIN(_maxValue, value));
    _value = v;
    _t = (_maxValue == _minValue) ? 0 : (v - _minValue) / (_maxValue - _minValue);
    [self setNeedsLayout];
}
- (void)onDrag:(UIPanGestureRecognizer*)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [h impactOccurred];
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.14 animations:^{ self->_thumb.transform = CGAffineTransformMakeScale(1.24, 1.24); }];
        }
    }
    CGPoint p = [g locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat padL = 8.0, padR = 8.0;
    CGFloat frac = MAX(0, MIN(1, (p.x - padL) / (w - padL - padR)));
    float v = _minValue + frac * (_maxValue - _minValue);
    self.value = v;
    if (self.onChange) self.onChange(v);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.18 animations:^{ self->_thumb.transform = CGAffineTransformIdentity; }];
        } else {
            _thumb.transform = CGAffineTransformIdentity;
        }
    }
}
- (void)onTap:(UITapGestureRecognizer*)g {
    CGPoint p = [g locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat padL = 8.0, padR = 8.0;
    CGFloat frac = MAX(0, MIN(1, (p.x - padL) / (w - padL - padR)));
    float v = _minValue + frac * (_maxValue - _minValue);
    self.value = v;
    UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
    [h selectionChanged];
    if (self.onChange) self.onChange(v);
    if (RavenSettings::animations) {
        _thumb.transform = CGAffineTransformMakeScale(1.18, 1.18);
        [UIView animateWithDuration:0.16 animations:^{ self->_thumb.transform = CGAffineTransformIdentity; }];
    }
}
@end

@implementation RVSelector { UIButton* _button; UILabel* _valueLabel; UIImageView* _chevron; }

- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 112, 24)])) {
        self.userInteractionEnabled = YES;
        self.layer.cornerRadius = 6;
        self.layer.borderWidth = 1;
        self.layer.borderColor = C_BORDER.CGColor;
        self.backgroundColor = [UIColor colorWithRed:0.092 green:0.092 blue:0.105 alpha:1.0];
        _valueLabel = lbl(@"", 11, C_TEXT, NO);
        _valueLabel.frame = CGRectMake(10, 0, 76, 24);
        [self addSubview:_valueLabel];
        UIImage* chevronImage = [UIImage systemImageNamed:@"chevron.down"];
        _chevron = [[UIImageView alloc] initWithImage:chevronImage];
        _chevron.tintColor = C_SEC;
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.frame = CGRectMake(92, 7, 10, 10);
        [self addSubview:_chevron];
        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        _button.frame = self.bounds;
        _button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_button addTarget:self action:@selector(cycleSelection) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_button];
        _items = [items copy] ?: @[];
        _selectedIndex = MAX(0, MIN((NSInteger)_items.count - 1, selected));
        [self rebuildMenu];
    }
    return self;
}
- (void)cycleSelection {
    if (_items.count == 0) return;
    NSInteger next = (_selectedIndex + 1) % (NSInteger)_items.count;
    self.selectedIndex = next;
    UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
    [h selectionChanged];
    if (self.onChange) self.onChange(next);
}
- (void)setItems:(NSArray<NSString*>*)items {
    _items = [items copy] ?: @[];
    if (_selectedIndex >= (NSInteger)_items.count) _selectedIndex = MAX(0, (NSInteger)_items.count - 1);
    [self rebuildMenu];
}
- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (_items.count == 0) {
        _selectedIndex = 0;
        _valueLabel.text = @"-";
        return;
    }
    _selectedIndex = MAX(0, MIN((NSInteger)_items.count - 1, selectedIndex));
    _valueLabel.text = _items[_selectedIndex];
    [self rebuildMenu];
}
- (void)rebuildMenu {
    if (!_button) return;
    if (_items.count == 0) {
        _valueLabel.text = @"-";
        _button.menu = nil;
        return;
    }
    NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];
    __weak RVSelector* weakSelf = self;
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        NSString* title = _items[i];
        UIAction* a = [UIAction actionWithTitle:title
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction* action) {
            (void)action;
            RVSelector* selfRef = weakSelf;
            if (!selfRef) return;
            selfRef->_selectedIndex = i;
            selfRef->_valueLabel.text = title;
            UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
            [h selectionChanged];
            if (RavenSettings::animations) {
                selfRef.transform = CGAffineTransformMakeScale(0.97, 0.97);
                [UIView animateWithDuration:0.18 animations:^{
                    selfRef.transform = CGAffineTransformIdentity;
                }];
            }
            if (selfRef.onChange) selfRef.onChange(i);
            [selfRef rebuildMenu];
        }];
        if (i == _selectedIndex) a.state = UIMenuElementStateOn;
        [actions addObject:a];
    }
    _button.menu = [UIMenu menuWithTitle:@"" children:actions];
    _valueLabel.text = _items[_selectedIndex];
}
@end

@interface RavenMenu ()
@property (nonatomic, strong) RavenWindow* window;
@property (nonatomic, strong, readwrite) UIView* panel;
@property (nonatomic, strong, readwrite) UIView* ball;
@property (nonatomic, strong) UIView*   panelInner;
@property (nonatomic, strong) UIView*   headerView;
@property (nonatomic, strong) UIScrollView* sidebarView;
@property (nonatomic, strong) UIView*   contentView;
@property (nonatomic, strong) UIView*   footerView;
@property (nonatomic, strong) NSMutableArray* tabButtons;
@property (nonatomic, strong) NSMutableDictionary* tabViews;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, strong) NSTimer* tickTimer;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL runtimeActive;
@property (nonatomic, assign) CGFloat uiScale;
@property (nonatomic, assign) CGSize  lastBounds;
@property (nonatomic, assign) CGRect  dragStartFrame;
@property (nonatomic, assign) BOOL    hasPanelPosition;
@property (nonatomic, strong) UIView* toastView;
@property (nonatomic, strong) NSTimer* toastTimer;
@end

@implementation RavenMenu

+ (instancetype)shared {
    static RavenMenu* s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RavenMenu new]; });
    return s;
}

- (BOOL)isPanelOpen { return self.panelOpen; }

- (void)start {
    if (self.window) return;
    [[RavenESP shared] attach];

    self.tabButtons    = [NSMutableArray array];
    self.tabViews      = [NSMutableDictionary dictionary];
    self.activeTab     = 0;
    self.uiScale       = 1.0;
    self.lastBounds    = CGSizeZero;
    self.hasPanelPosition = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        loadCachedImage(kWordmarkURL);
        loadCachedImage(kBallLogoURL);
        loadCachedImage(kEmblemURL);
        loadLogoURLAsync(kWordmarkURL, ^(UIImage* i){ (void)i; });
        loadLogoURLAsync(kBallLogoURL,   ^(UIImage* i){ (void)i; });
        loadLogoURLAsync(kEmblemURL,     ^(UIImage* i){ (void)i; });
    });

    self.window = [[RavenWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowLevel = UIWindowLevelNormal + 1.0;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController.view.userInteractionEnabled = YES;
    [self attachToScene];
    self.window.hidden = NO;

    [self buildPanel];
    [self buildBall];
    [self relayout];

    self.panel.hidden = YES;
    self.ball.hidden  = (RavenSettings::uiOpenButton == 2);
    self.runtimeActive = true;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:@"UIWindowSceneDidUpdateCoordinateSpaceNotification"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:UISceneDidActivateNotification
                                               object:nil];

    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                      target:self
                                                    selector:@selector(onTick)
                                                    userInfo:nil
                                                     repeats:YES];
    RAVEN_LOG("menu started");
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)attachToScene {
    for (UIScene* s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            if (s.activationState == UISceneActivationStateForegroundActive ||
                s.activationState == UISceneActivationStateForegroundInactive) {
                self.window.windowScene = (UIWindowScene*)s;
                return;
            }
        }
    }
}

- (void)setVisible:(BOOL)v { self.window.hidden = !v; }

- (void)onGeometryChanged {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachToScene];
        self.window.hidden = NO;
        [self relayout];
        [self clampPanel];
    });
}

- (void)relayout {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    if (screen.size.width < 1 || screen.size.height < 1) return;

    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGFloat usableW = screen.size.width - safe.left - safe.right;
    CGFloat usableH = screen.size.height - safe.top - safe.bottom;

    CGFloat requestedScale = MAX(0.50, MIN(1.50, RavenSettings::menuScale / 100.0));
    CGFloat safeFit = MIN(usableW / kRefW, usableH / kRefH);
    CGFloat fit = MIN(requestedScale, safeFit);
    self.uiScale = fit;

    CGFloat panelW = kRefW * fit;
    CGFloat panelH = kRefH * fit;

    CGPoint oldCenter = self.panel ? self.panel.center
                                   : CGPointMake(safe.left + usableW / 2.0,
                                                 safe.top + usableH / 2.0);
    CGFloat panelX = safe.left + (usableW - panelW) / 2.0;
    CGFloat panelY = safe.top  + (usableH - panelH) / 2.0;
    if (self.hasPanelPosition && self.panel) {
        panelX = oldCenter.x - panelW / 2.0;
        panelY = oldCenter.y - panelH / 2.0;
    }

    self.panel.transform = CGAffineTransformIdentity;
    self.panel.frame = CGRectMake(panelX, panelY, panelW, panelH);

    CGFloat sx = panelW / kRefW;
    CGFloat sy = panelH / kRefH;
    self.panelInner.bounds = CGRectMake(0, 0, kRefW, kRefH);
    self.panelInner.transform = CGAffineTransformIdentity;
    self.panelInner.transform = CGAffineTransformMakeScale(sx, sy);
    self.panelInner.center = CGPointMake(panelW / 2.0, panelH / 2.0);

    CGFloat bsize = 46;
    self.panel.alpha = MAX(0.20, MIN(1.0, RavenSettings::miscMenuOpacity / 100.0));
    if (!self.ball.hidden && RavenSettings::uiOpenButton != 2) {
        CGFloat bx = screen.size.width - safe.right - bsize - 16;
        if (RavenSettings::uiPosition == 1) bx = safe.left + 16;
        if (RavenSettings::uiPosition == 2) bx = (screen.size.width - bsize) / 2.0;
        CGFloat by = safe.top + 24;
        bx = MAX(safe.left + 4, MIN(screen.size.width - safe.right - bsize - 4, bx));
        by = MAX(safe.top + 4,  MIN(screen.size.height - safe.bottom - bsize - 4, by));
        self.ball.frame = CGRectMake(bx, by, bsize, bsize);
    }
}

- (void)clampPanel {
    if (!self.window || self.panel.hidden) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGRect f = self.panel.frame;
    CGFloat maxW = screen.size.width - safe.left - safe.right;
    CGFloat maxH = screen.size.height - safe.top - safe.bottom;
    if (f.size.width  > maxW) f.size.width  = maxW;
    if (f.size.height > maxH) f.size.height = maxH;
    CGFloat minX = safe.left;
    CGFloat maxX = screen.size.width - safe.right - f.size.width;
    CGFloat minY = safe.top;
    CGFloat maxY = screen.size.height - safe.bottom - f.size.height;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    f.origin.x = MAX(minX, MIN(maxX, f.origin.x));
    f.origin.y = MAX(minY, MIN(maxY, f.origin.y));
    self.panel.frame = f;
}

- (void)centerPanel {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGFloat usableW = screen.size.width - safe.left - safe.right;
    CGFloat usableH = screen.size.height - safe.top - safe.bottom;
    CGRect f = self.panel.frame;
    f.origin.x = safe.left + (usableW - f.size.width) / 2;
    f.origin.y = safe.top  + (usableH - f.size.height) / 2;
    self.panel.frame = f;
}

- (void)buildBall {
    CGFloat size = 46;
    self.ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    self.ball.backgroundColor = C_WIN;
    self.ball.layer.cornerRadius = size / 2.0;
    self.ball.layer.borderWidth = 1.5;
    self.ball.layer.borderColor = C_RED.CGColor;
    self.ball.layer.shadowColor = C_RED.CGColor;
    self.ball.layer.shadowOpacity = 0.6;
    self.ball.layer.shadowRadius = 10;
    self.ball.layer.shadowOffset = CGSizeZero;
    self.ball.userInteractionEnabled = YES;
    self.ball.multipleTouchEnabled = NO;

    UILabel* placeholder = [[UILabel alloc] initWithFrame:self.ball.bounds];
    placeholder.text = @"R";
    placeholder.textAlignment = NSTextAlignmentCenter;
    placeholder.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    placeholder.textColor = C_RED;
    placeholder.tag = 700;
    [self.ball addSubview:placeholder];

    UIImageView* iv = [[UIImageView alloc] initWithFrame:CGRectInset(self.ball.bounds, 3, 3)];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.layer.cornerRadius = (size - 6) / 2.0;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    iv.hidden = YES;
    iv.tag = 701;
    [self.ball addSubview:iv];

    __weak UIImageView* weakIV = iv;
    __weak UILabel* weakPH = placeholder;
    loadLogoURLAsync(kBallLogoURL, ^(UIImage* img) {
        if (!img) return;
        weakIV.image = img;
        weakIV.hidden = NO;
        weakPH.hidden = YES;
    });

    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    tap.cancelsTouchesInView = YES;
    [self.ball addGestureRecognizer:tap];

    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    pan.cancelsTouchesInView = YES;
    pan.maximumNumberOfTouches = 1;
    [self.ball addGestureRecognizer:pan];

    [self.window addSubview:self.ball];
}

- (void)togglePanel {
    self.panelOpen = !self.panelOpen;
    if (self.panelOpen) {
        [self relayout];
        if (!self.hasPanelPosition) [self centerPanel];
        [self clampPanel];
        self.panel.hidden = NO;
        self.ball.hidden = YES;
        [self.window bringSubviewToFront:self.panel];
        if (RavenSettings::animations) {
            self.panel.alpha = 0.0;
            self.panel.transform = CGAffineTransformMakeScale(0.965, 0.965);
            [UIView animateWithDuration:0.24
                                  delay:0
                 usingSpringWithDamping:0.84
                  initialSpringVelocity:0.35
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                self.panel.alpha = 1.0;
                self.panel.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
        }
    } else {
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.16 animations:^{
                self.panel.alpha = 0.0;
                self.panel.transform = CGAffineTransformMakeScale(0.975, 0.975);
            } completion:^(BOOL finished) {
                self.panel.hidden = YES;
                self.panel.alpha = 1.0;
                self.panel.transform = CGAffineTransformIdentity;
                self.ball.hidden = NO;
                self.ball.alpha = 0.0;
                self.ball.transform = CGAffineTransformMakeScale(0.82, 0.82);
                [self.window bringSubviewToFront:self.ball];
                [UIView animateWithDuration:0.18 animations:^{
                    self.ball.alpha = 1.0;
                    self.ball.transform = CGAffineTransformIdentity;
                }];
            }];
        } else {
            self.panel.hidden = YES;
            self.ball.hidden = NO;
            [self.window bringSubviewToFront:self.ball];
        }
    }
}

- (void)dragBall:(UIPanGestureRecognizer*)g {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.ball.center;
    c.x += t.x; c.y += t.y;
    CGFloat hs = self.ball.bounds.size.width / 2.0;
    c.x = MAX(safe.left + hs, MIN(screen.size.width - safe.right - hs, c.x));
    c.y = MAX(safe.top + hs,  MIN(screen.size.height - safe.bottom - hs, c.y));
    self.ball.center = c;
    [g setTranslation:CGPointZero inView:self.window];
}

- (void)buildPanel {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kRefW, kRefH)];
    self.panel.backgroundColor = C_WIN;
    self.panel.layer.cornerRadius = 12;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = C_CRIMSON.CGColor;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.7;
    self.panel.layer.shadowRadius = 24;
    self.panel.layer.shadowOffset = CGSizeMake(0, 8);
    self.panel.clipsToBounds = YES;
    self.panel.userInteractionEnabled = YES;

    self.panelInner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kRefW, kRefH)];
    self.panelInner.backgroundColor = [UIColor clearColor];
    [self.panel addSubview:self.panelInner];

    [self buildHeader:CGRectMake(0, 0, kRefW, kHeaderH)];
    [self buildSidebar:CGRectMake(0, kHeaderH, kSidebarW, kRefH - kHeaderH - kFooterH)];
    [self buildContent:CGRectMake(kSidebarW, kHeaderH, kRefW - kSidebarW, kRefH - kHeaderH - kFooterH)];
    [self buildFooter:CGRectMake(0, kRefH - kFooterH, kRefW, kFooterH)];

    [self.window addSubview:self.panel];
    [self selectTab:0];
}

- (void)buildHeader:(CGRect)r {
    self.headerView = [[UIView alloc] initWithFrame:r];
    self.headerView.backgroundColor = C_HEAD;
    self.headerView.clipsToBounds = YES;
    self.headerView.userInteractionEnabled = YES;

    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(0, r.size.height - 1, r.size.width, 1)];
    line.backgroundColor = [C_RED colorWithAlphaComponent:0.35];
    [self.headerView addSubview:line];

    UIImageView* wm = [[UIImageView alloc] initWithFrame:self.headerView.bounds];
    wm.contentMode = UIViewContentModeScaleAspectFill;
    wm.clipsToBounds = YES;
    wm.userInteractionEnabled = NO;
    wm.hidden = YES;
    wm.tag = 801;
    [self.headerView addSubview:wm];

    UILabel* fallback = lbl(@"RAVEN", 22, C_TEXT, YES);
    fallback.frame = CGRectMake(20, 0, 200, r.size.height);
    fallback.tag = 800;
    [self.headerView addSubview:fallback];

    __weak UIImageView* weakWM = wm;
    __weak UILabel* weakFB = fallback;
    loadLogoURLAsync(kWordmarkURL, ^(UIImage* img) {
        if (!img) return;
        weakWM.image = cropNormalized(img, CGRectMake(0.0, 0.286, 1.0, 0.364));
        weakWM.hidden = NO;
        weakFB.hidden = YES;
    });

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(r.size.width - 44, (r.size.height - 30)/2, 30, 30);
    [close setTitle:@"X" forState:UIControlStateNormal];
    [close setTitleColor:C_RED forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:close];

    UIButton* min = [UIButton buttonWithType:UIButtonTypeSystem];
    min.frame = CGRectMake(r.size.width - 82, (r.size.height - 30)/2, 30, 30);
    [min setTitle:@"-" forState:UIControlStateNormal];
    [min setTitleColor:C_SEC forState:UIControlStateNormal];
    min.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [min addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:min];

    UIPanGestureRecognizer* pg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHeaderDrag:)];
    pg.cancelsTouchesInView = NO;
    pg.maximumNumberOfTouches = 1;
    [self.headerView addGestureRecognizer:pg];

    [self.panelInner addSubview:self.headerView];
}

- (void)onHeaderDrag:(UIPanGestureRecognizer*)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStartFrame = self.panel.frame;
        self.hasPanelPosition = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.window];
        CGRect f = self.dragStartFrame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        self.panel.frame = f;
        [self clampPanel];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        [self clampPanel];
    }
}

- (NSArray*)tabDefs {
    return @[
        @{@"title":@"AIMBOT",   @"key":@"aimbot"},
        @{@"title":@"GYRO AIM", @"key":@"gyro"},
        @{@"title":@"ESP",      @"key":@"esp"},
        @{@"title":@"VISUALS",  @"key":@"visuals"},
        @{@"title":@"WEAPON",   @"key":@"weapon"},
        @{@"title":@"MISC",     @"key":@"misc"},
        @{@"title":@"PLAYERS",  @"key":@"players"},
        @{@"title":@"INFO",     @"key":@"info"},
        @{@"title":@"SETTINGS", @"key":@"settings"},
    ];
}

- (void)buildSidebar:(CGRect)r {
    self.sidebarView = [[UIScrollView alloc] initWithFrame:r];
    self.sidebarView.backgroundColor = C_SIDE;
    self.sidebarView.clipsToBounds = YES;
    self.sidebarView.showsVerticalScrollIndicator = YES;
    self.sidebarView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.sidebarView.alwaysBounceVertical = YES;
    self.sidebarView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    UIImageView* bg = [[UIImageView alloc] initWithFrame:self.sidebarView.bounds];
    bg.contentMode = UIViewContentModeScaleAspectFill;
    bg.clipsToBounds = YES;
    bg.userInteractionEnabled = NO;
    bg.tag = 900;
    [self.sidebarView addSubview:bg];

    __weak UIImageView* weakBG = bg;
    loadLogoURLAsync(kEmblemURL, ^(UIImage* img) {
        if (img) weakBG.image = img;
    });

    UIView* tint = [[UIView alloc] initWithFrame:self.sidebarView.bounds];
    tint.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.04 alpha:0.14];
    tint.userInteractionEnabled = NO;
    [self.sidebarView addSubview:tint];

    UIView* sep = [[UIView alloc] initWithFrame:CGRectMake(r.size.width - 1, 0, 1, r.size.height)];
    sep.backgroundColor = C_BORDER;
    [self.sidebarView addSubview:sep];

    NSArray* defs = [self tabDefs];
    CGFloat y = 14;
    for (NSInteger i = 0; i < defs.count; i++) {
        NSDictionary* d = defs[i];
        std::string k = std::string([d[@"key"] UTF8String]);
        if (!Updater::feature(k, true)) continue;

        UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, y, r.size.width - 1, kTabH);
        btn.tag = i;
        btn.backgroundColor = [UIColor clearColor];
        [btn addTarget:self action:@selector(onTabTap:) forControlEvents:UIControlEventTouchUpInside];

        UIView* accent = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 2, kTabH - 16)];
        accent.backgroundColor = [UIColor clearColor];
        accent.layer.cornerRadius = 1;
        accent.tag = 990;
        [btn addSubview:accent];

        UILabel* label = lbl(d[@"title"], 13, C_SEC, NO);
        label.frame = CGRectMake(20, 0, btn.frame.size.width - 28, kTabH);
        label.tag = 991;
        [btn addSubview:label];

        [self.sidebarView addSubview:btn];
        [self.tabButtons addObject:btn];
        y += kTabH + 4;
    }
    self.sidebarView.contentSize = CGSizeMake(r.size.width, MAX(r.size.height, y + 12));

    [self.panelInner addSubview:self.sidebarView];
}

- (void)onTabTap:(UIButton*)b { [self selectTab:b.tag]; }

- (void)reloadActiveTab {
    [self.tabViews removeAllObjects];
    for (UIView* v in self.contentView.subviews) [v removeFromSuperview];
    NSArray* defs = [self tabDefs];
    if (self.activeTab < 0 || self.activeTab >= (NSInteger)defs.count) return;
    [self selectTab:self.activeTab];
}

- (void)selectTab:(NSInteger)idx {
    self.activeTab = idx;
    for (UIButton* b in self.tabButtons) {
        BOOL active = (b.tag == idx);
        UIView*  accent = [b viewWithTag:990];
        UILabel* label  = [b viewWithTag:991];
        accent.backgroundColor = active ? C_RED : [UIColor clearColor];
        label.textColor = active ? C_TEXT : C_SEC;
        label.font = active
            ? [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]
            : [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        b.backgroundColor = active ? [C_CRIMSON colorWithAlphaComponent:0.55] : [UIColor clearColor];
    }
    for (UIView* v in self.contentView.subviews) [v removeFromSuperview];

    NSArray* defs = [self tabDefs];
    if (idx < 0 || idx >= (NSInteger)defs.count) return;
    NSString* key = defs[idx][@"title"];
    UIView* content = self.tabViews[key];
    if (!content) {
        content = [self buildTabContent:key];
        self.tabViews[key] = content;
    }
    content.frame = self.contentView.bounds;
    [self.contentView addSubview:content];

    if (RavenSettings::animations) {
        content.alpha = 0.0;
        content.transform = CGAffineTransformMakeTranslation(10.0, 0.0);
        [UIView animateWithDuration:0.18 animations:^{
            content.alpha = 1.0;
            content.transform = CGAffineTransformIdentity;
        }];
    } else {
        content.alpha = 1.0;
        content.transform = CGAffineTransformIdentity;
    }
}

- (void)buildContent:(CGRect)r {
    self.contentView = [[UIView alloc] initWithFrame:r];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.contentView.clipsToBounds = YES;
    [self.panelInner addSubview:self.contentView];
}

- (UIView*)buildTabContent:(NSString*)tab {
    UIScrollView* sv = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
    sv.backgroundColor = [UIColor clearColor];
    sv.showsVerticalScrollIndicator = NO;
    sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    CGFloat W = sv.bounds.size.width;

    UILabel* title = lbl(tab, 18, C_TEXT, YES);
    title.frame = CGRectMake(kPad, 14, W - kPad*2, 22);
    [sv addSubview:title];

    UILabel* sub = lbl([self subtitleForTab:tab], 11, C_SEC, NO);
    sub.frame = CGRectMake(kPad, 38, W - kPad*2, 15);
    [sv addSubview:sub];

    CGFloat startY = 68;
    CGFloat availW = W - kPad*2;
    BOOL twoCols = (availW >= 500);
    CGFloat colW = twoCols ? (availW - kCardGap) / 2.0 : availW;

    NSArray* cards = [self cardsForTab:tab width:colW];
    CGFloat leftY = startY;
    CGFloat rightY = startY;

    for (NSInteger i = 0; i < (NSInteger)cards.count; i++) {
        UIView* c = cards[i];
        CGFloat h = c.frame.size.height;
        if (twoCols && (i % 2) == 0) {
            c.frame = CGRectMake(kPad, leftY, colW, h);
            leftY += h + kCardGap;
        } else if (twoCols) {
            c.frame = CGRectMake(kPad + colW + kCardGap, rightY, colW, h);
            rightY += h + kCardGap;
        } else {
            c.frame = CGRectMake(kPad, leftY, colW, h);
            leftY += h + kCardGap;
        }
        [sv addSubview:c];
    }
    CGFloat contentH = MAX(leftY, rightY) + kPad;
    sv.contentSize = CGSizeMake(W, contentH);
    return sv;
}

- (NSString*)subtitleForTab:(NSString*)tab {
    if ([tab isEqualToString:@"AIMBOT"])   return @"Configure targeting and aim behavior";
    if ([tab isEqualToString:@"GYRO AIM"])  return @"Gyroscope-driven aim correction";
    if ([tab isEqualToString:@"ESP"])      return @"Player visibility and overlay options";
    if ([tab isEqualToString:@"VISUALS"])  return @"Screen and rendering adjustments";
    if ([tab isEqualToString:@"WEAPON"])   return @"Weapon behavior modifications";
    if ([tab isEqualToString:@"MISC"])     return @"Movement, utility and interface tweaks";
    if ([tab isEqualToString:@"PLAYERS"])  return @"Nearby player list";
    if ([tab isEqualToString:@"INFO"])     return @"Raven account, device and runtime information";
    if ([tab isEqualToString:@"SETTINGS"]) return @"Menu configuration and about";
    return @"";
}

- (UIView*)card:(NSString*)title width:(CGFloat)w rows:(NSArray*)rows {
    UIView* card = [UIView new];
    card.backgroundColor = C_CARD;
    card.layer.cornerRadius = kCardRad;
    card.layer.borderWidth = 1;
    card.layer.borderColor = C_BORDER.CGColor;

    UILabel* t = lbl(title, 11, C_RED, YES);
    t.frame = CGRectMake(14, 11, w - 28, 14);
    [card addSubview:t];

    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(14, 28, w - 28, 1)];
    line.backgroundColor = [C_RED colorWithAlphaComponent:0.12];
    [card addSubview:line];

    CGFloat y = 36;
    for (UIView* r in rows) {
        CGFloat rh = r.frame.size.height;
        r.frame = CGRectMake(0, y, w, rh);
        for (UIView* sub in r.subviews) {
            if ([sub isKindOfClass:[RVToggle class]]) {
                sub.frame = CGRectMake(w - 52, (kRowH - 20) / 2.0, 38, 20);
            } else if ([sub isKindOfClass:[RVSlider class]]) {
                sub.frame = CGRectMake(14, 26, MAX(40, w - 28), 18);
            } else if ([sub isKindOfClass:[RVSelector class]]) {
                sub.frame = CGRectMake(MAX(14, w - 126), 2, 112, 24);
            } else if ([sub isKindOfClass:[UIButton class]]) {
                sub.frame = CGRectMake(12, 2, MAX(40, w - 24), 32);
            } else if (sub.tag == 610) {
                sub.frame = CGRectMake(w - 68, 4, 54, 18);
            } else if (sub.tag == 611) {
                sub.frame = CGRectMake(w - 160, 0, 146, kRowH);
            }
        }
        [card addSubview:r];
        y += rh;
    }
    y += 8;
    card.frame = CGRectMake(0, 0, w, y);
    return card;
}

- (UIView*)rowToggle:(NSString*)title on:(BOOL)on cb:(void(^)(BOOL))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 160, kRowH);
    [row addSubview:l];
    RVToggle* t = [[RVToggle alloc] init];
    t.on = on;
    t.onChange = ^(BOOL value) {
        if (cb) cb(value);
        RavenSettings::save();
    };
    t.frame = CGRectMake(row.frame.size.width - 52, (kRowH - 20) / 2.0, 38, 20);
    t.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:t];
    return row;
}

- (UIView*)rowSlider:(NSString*)title min:(float)mn max:(float)mx val:(float)v cb:(void(^)(float))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowHBig)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 4, 170, 18);
    [row addSubview:l];

    UILabel* val = lbl([NSString stringWithFormat:@"%.0f", v], 12, C_RED, YES);
    val.tag = 610;
    val.textAlignment = NSTextAlignmentRight;
    val.frame = CGRectMake(row.frame.size.width - 68, 4, 54, 18);
    val.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:val];

    RVSlider* s = [[RVSlider alloc] init];
    s.minValue = mn; s.maxValue = mx; s.value = v;
    s.frame = CGRectMake(14, 26, row.frame.size.width - 28, 18);
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    s.onChange = ^(float nv) {
        val.text = [NSString stringWithFormat:@"%.0f", nv];
        if (cb) cb(nv);
        RavenSettings::save();
    };
    [row addSubview:s];
    return row;
}

- (UIView*)rowDropdown:(NSString*)title value:(NSString*)val {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    UIView* pill = [[UIView alloc] initWithFrame:CGRectMake(row.frame.size.width - 112, 2, 98, 24)];
    pill.backgroundColor = [UIColor colorWithRed:0.092 green:0.092 blue:0.105 alpha:1.0];
    pill.layer.cornerRadius = 6;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = C_BORDER.CGColor;
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:pill];
    UILabel* v = lbl(val, 11, C_TEXT, NO);
    v.frame = CGRectMake(10, 0, 70, 24);
    [pill addSubview:v];
    UIImageView* chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = C_MUTE;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.frame = CGRectMake(82, 7, 9, 9);
    [pill addSubview:chevron];
    return row;
}

- (UIView*)rowSelector:(NSString*)title
                 items:(NSArray<NSString*>*)items
              selected:(NSInteger)selected
                    cb:(void(^)(NSInteger))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    RVSelector* s = [[RVSelector alloc] initWithItems:items selected:selected];
    s.frame = CGRectMake(row.frame.size.width - 126, 2, 112, 24);
    s.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    s.onChange = ^(NSInteger value) {
        if (cb) cb(value);
        RavenSettings::save();
    };
    [row addSubview:s];
    return row;
}

- (UIView*)rowInfo:(NSString*)title value:(NSString*)val {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    UILabel* v = lbl(val, 12, C_RED, YES);
    v.tag = 611;
    v.textAlignment = NSTextAlignmentRight;
    v.frame = CGRectMake(row.frame.size.width - 160, 0, 146, kRowH);
    v.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:v];
    return row;
}

- (UIView*)rowButton:(NSString*)title tap:(void(^)(void))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 36)];
    UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(12, 2, row.frame.size.width - 24, 32);
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 1;
    b.layer.borderColor = C_BORDER.CGColor;
    b.tag = (NSInteger)CFBridgingRetain([cb copy]);
    [b addTarget:self action:@selector(onGenericButton:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:b];
    return row;
}

- (void)onGenericButton:(UIButton*)b {
    void (^cb)(void) = (__bridge void (^)(void))(void*)b.tag;
    if (cb) cb();
    if (RavenSettings::animations) {
        b.transform = CGAffineTransformMakeScale(0.98, 0.98);
        [UIView animateWithDuration:0.14 animations:^{ b.transform = CGAffineTransformIdentity; }];
    }
}

- (void)showToast:(NSString*)title detail:(NSString*)detail {
    [self.toastTimer invalidate];
    [self.toastView removeFromSuperview];

    UIView* toast = [[UIView alloc] initWithFrame:CGRectMake(kRefW - 286, kHeaderH + 12, 266, 48)];
    toast.backgroundColor = [UIColor colorWithRed:0.055 green:0.055 blue:0.066 alpha:0.97];
    toast.layer.cornerRadius = 8;
    toast.layer.borderWidth = 1;
    toast.layer.borderColor = [C_RED colorWithAlphaComponent:0.42].CGColor;
    toast.layer.shadowColor = [UIColor blackColor].CGColor;
    toast.layer.shadowOpacity = 0.45;
    toast.layer.shadowRadius = 10;
    toast.layer.shadowOffset = CGSizeMake(0, 4);

    UIView* bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, 48)];
    bar.backgroundColor = C_RED;
    bar.layer.cornerRadius = 1.5;
    [toast addSubview:bar];

    UILabel* t = lbl(title ?: @"RAVEN", 12, C_TEXT, YES);
    t.frame = CGRectMake(14, 7, 238, 16);
    [toast addSubview:t];

    UILabel* d = lbl(detail ?: @"", 10, C_SEC, NO);
    d.frame = CGRectMake(14, 25, 238, 14);
    [toast addSubview:d];

    self.toastView = toast;
    [self.panelInner addSubview:toast];
    [self.panelInner bringSubviewToFront:toast];

    if (RavenSettings::animations) {
        toast.alpha = 0.0;
        toast.transform = CGAffineTransformMakeTranslation(14, -4);
        [UIView animateWithDuration:0.22 animations:^{
            toast.alpha = 1.0;
            toast.transform = CGAffineTransformIdentity;
        }];
    }

    __weak RavenMenu* weakSelf = self;
    self.toastTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer* timer) {
        RavenMenu* selfRef = weakSelf;
        if (!selfRef || selfRef.toastView != toast) return;
        void (^removeToast)(void) = ^{
            [toast removeFromSuperview];
            if (selfRef.toastView == toast) selfRef.toastView = nil;
        };
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.18 animations:^{
                toast.alpha = 0.0;
                toast.transform = CGAffineTransformMakeTranslation(10, -4);
            } completion:^(BOOL finished) { removeToast(); }];
        } else {
            removeToast();
        }
    }];
}

- (NSArray*)cardsForTab:(NSString*)tab width:(CGFloat)w {
    if ([tab isEqualToString:@"AIMBOT"]) {
        UIView* general = [self card:@"GENERAL" width:w rows:@[
            [self rowToggle:@"Enable Aimbot" on:RavenSettings::aimEnabled cb:^(BOOL v){
                RavenAimbot::setEnabled(v);
                RAVEN_LOG("aim-toggle: enabled=%d esp=%d",
                          RavenSettings::aimEnabled, RavenSettings::espEnabled);
                RavenSettings::save();
            }],
            [self rowSelector:@"Aim Activation" items:@[@"Always", @"ADS only"] selected:RavenSettings::aimActivation cb:^(NSInteger v){ RavenSettings::aimActivation = (int)v; RavenSettings::save(); }],
            [self rowSlider:@"Aim FOV" min:60 max:240 val:RavenSettings::aimFov cb:^(float v){ RavenSettings::aimFov = v; }],
            [self rowSlider:@"Smoothness" min:1 max:30 val:RavenSettings::aimSmooth cb:^(float v){ RavenSettings::aimSmooth = v; }],
            [self rowSlider:@"Aim Strength" min:0 max:100 val:RavenSettings::aimStrength cb:^(float v){ RavenSettings::aimStrength = v; }],
            [self rowSlider:@"Acceleration" min:0 max:100 val:RavenSettings::aimAcceleration cb:^(float v){ RavenSettings::aimAcceleration = v; }],
            [self rowToggle:@"Prediction" on:RavenSettings::aimPrediction cb:^(BOOL v){ RavenSettings::aimPrediction = v; }],
            [self rowSlider:@"Prediction Strength" min:0 max:100 val:RavenSettings::aimPredictionStrength cb:^(float v){ RavenSettings::aimPredictionStrength = v; }],
            [self rowSlider:@"Prediction Velocity" min:0 max:100 val:RavenSettings::aimPredictionVelocity cb:^(float v){ RavenSettings::aimPredictionVelocity = v; }],
            [self rowToggle:@"Visibility Check" on:RavenSettings::aimVisCheck cb:^(BOOL v){ RavenSettings::aimVisCheck = v; }],
            [self rowToggle:@"Ignore Teammates" on:RavenSettings::aimIgnoreTeammates cb:^(BOOL v){ RavenSettings::aimIgnoreTeammates = v; }],
        ]];
        UIView* advanced = [self card:@"ADVANCED" width:w rows:@[
            [self rowSlider:@"Target Switch Delay" min:0 max:500 val:RavenSettings::aimSwitchDelay cb:^(float v){ RavenSettings::aimSwitchDelay = v; }],
        ]];
        UIView* targeting = [self card:@"TARGETING" width:w rows:@[
            [self rowSelector:@"Target Bone"
                         items:@[@"Head", @"Neck", @"Chest", @"Pelvis"]
                      selected:RavenSettings::aimBone
                            cb:^(NSInteger v){ RavenSettings::aimBone = (int)v; RavenSettings::save(); }],
            [self rowSlider:@"Max Distance" min:50 max:500 val:RavenSettings::aimMaxDist cb:^(float v){ RavenSettings::aimMaxDist = v; }],
        ]];
        UIView* fovCard = [self card:@"FOV" width:w rows:@[
            [self rowToggle:@"Show FOV Circle" on:RavenSettings::aimShowCircle cb:^(BOOL v){ RavenSettings::aimShowCircle = v; }],
            [self rowToggle:@"Dynamic FOV" on:RavenSettings::aimDynamicFov cb:^(BOOL v){ RavenSettings::aimDynamicFov = v; }],
            [self rowSlider:@"FOV Radius" min:20 max:400 val:RavenSettings::aimCircleRadius cb:^(float v){ RavenSettings::aimCircleRadius = v; }],
            [self rowSlider:@"Circle Thickness" min:1 max:6 val:RavenSettings::aimCircleThickness cb:^(float v){ RavenSettings::aimCircleThickness = v; }],
        ]];
        return @[general, targeting, advanced, fovCard];
    }

    if ([tab isEqualToString:@"GYRO AIM"]) {
        UIView* gyro = [self card:@"GYRO AIM" width:w rows:@[
            [self rowToggle:@"Enable Gyro Aimbot" on:RavenSettings::gyroEnabled cb:^(BOOL v){ RavenSettings::gyroEnabled = v; RavenSettings::save(); }],
            [self rowSlider:@"Gyro Strength" min:0 max:100 val:RavenSettings::aimStrength cb:^(float v){ RavenSettings::aimStrength = v; }],
            [self rowSlider:@"Gyro Smoothness" min:1 max:30 val:RavenSettings::gyroSmooth cb:^(float v){ RavenSettings::gyroSmooth = v; }],
            [self rowSlider:@"Gyro FOV" min:60 max:240 val:RavenSettings::gyroFov cb:^(float v){ RavenSettings::gyroFov = v; }],
            [self rowToggle:@"Dynamic Gyro FOV" on:RavenSettings::aimDynamicFov cb:^(BOOL v){ RavenSettings::aimDynamicFov = v; }],
            [self rowSelector:@"Response Curve" items:@[@"Linear", @"Smooth", @"Aggressive"] selected:RavenSettings::gyroCurve cb:^(NSInteger v){ RavenSettings::gyroCurve = (int)v; }],
            [self rowSlider:@"Stabilizer" min:0 max:100 val:RavenSettings::gyroStabilizer cb:^(float v){ RavenSettings::gyroStabilizer = v; }],
            [self rowSlider:@"Micro Correction" min:0 max:100 val:RavenSettings::gyroMicroCorrection cb:^(float v){ RavenSettings::gyroMicroCorrection = v; }],
            [self rowToggle:@"Low Latency Gyro" on:RavenSettings::gyroLowLatency cb:^(BOOL v){ RavenSettings::gyroLowLatency = v; }],
        ]];
        return @[gyro];
    }

    if ([tab isEqualToString:@"ESP"]) {
        UIView* player = [self card:@"PLAYER ESP" width:w rows:@[
            [self rowToggle:@"Enable ESP" on:RavenSettings::espEnabled cb:^(BOOL v){ RavenSettings::espEnabled = v; RavenSettings::save(); }],
            [self rowToggle:@"Box" on:RavenSettings::espBox cb:^(BOOL v){ RavenSettings::espBox = v; }],
            [self rowToggle:@"Corner Box" on:RavenSettings::espCorner cb:^(BOOL v){ RavenSettings::espCorner = v; }],
            [self rowSelector:@"Box Style"
                         items:@[@"Raven Pro", @"Raven Hex", @"Raven Round", @"Raven Gradient", @"Raven Elite"]
                      selected:RavenSettings::espBoxStyle
                            cb:^(NSInteger v){ RavenSettings::espBoxStyle = (int)v; RavenSettings::save(); }],
            [self rowToggle:@"Skeleton" on:RavenSettings::espSkeleton cb:^(BOOL v){ RavenSettings::espSkeleton = v; }],
            [self rowToggle:@"Snaplines" on:RavenSettings::espSnaplines cb:^(BOOL v){ RavenSettings::espSnaplines = v; }],
            [self rowToggle:@"Head Dot" on:RavenSettings::espHeadDot cb:^(BOOL v){ RavenSettings::espHeadDot = v; }],
            [self rowToggle:@"RGB ESP" on:RavenSettings::espRgb cb:^(BOOL v){ RavenSettings::espRgb = v; }],
            [self rowToggle:@"Team ESP" on:RavenSettings::espTeam cb:^(BOOL v){ RavenSettings::espTeam = v; }],
            [self rowToggle:@"Visible Only" on:RavenSettings::espVisibleOnly cb:^(BOOL v){ RavenSettings::espVisibleOnly = v; }],
            [self rowSelector:@"Snapline Origin" items:@[@"Top", @"Center", @"Bottom"] selected:RavenSettings::espSnaplinePosition cb:^(NSInteger v){ RavenSettings::espSnaplinePosition = (int)v; }],
            [self rowToggle:@"Health Bar" on:RavenSettings::espHealthBar cb:^(BOOL v){ RavenSettings::espHealthBar = v; }],
            [self rowToggle:@"Armor Bar" on:RavenSettings::espArmorBar cb:^(BOOL v){ RavenSettings::espArmorBar = v; }],
            [self rowSlider:@"Box Size" min:0 max:100 val:(RavenSettings::espBoxScale - 0.7f) / 0.011f cb:^(float v){ RavenSettings::espBoxScale = 0.7f + v * 0.011f; }],
        ]];
        UIView* info = [self card:@"INFORMATION" width:w rows:@[
            [self rowToggle:@"Name" on:RavenSettings::espName cb:^(BOOL v){ RavenSettings::espName = v; }],
            [self rowToggle:@"Distance" on:RavenSettings::espDistance cb:^(BOOL v){ RavenSettings::espDistance = v; }],
            [self rowToggle:@"Health" on:RavenSettings::espHealth cb:^(BOOL v){ RavenSettings::espHealth = v; }],
        ]];
        UIView* colors = [self card:@"COLORS" width:w rows:@[
            [self rowSelector:@"Enemy Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espEnemyColor
                            cb:^(NSInteger v){ RavenSettings::espEnemyColor = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Visible Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espVisibleColor
                            cb:^(NSInteger v){ RavenSettings::espVisibleColor = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Skeleton Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espSkeletonColor
                            cb:^(NSInteger v){ RavenSettings::espSkeletonColor = (int)v; RavenSettings::save(); }],
        ]];
        return @[player, info, colors];
    }

    if ([tab isEqualToString:@"VISUALS"]) {
        UIView* cross = [self card:@"CROSSHAIR" width:w rows:@[
            [self rowToggle:@"Enable Crosshair" on:RavenSettings::visCrosshair cb:^(BOOL v){ RavenSettings::visCrosshair = v; }],
            [self rowSelector:@"Style"
                         items:@[@"Dot", @"Cross", @"Circle", @"T-Shape"]
                      selected:RavenSettings::visCrosshairStyle
                            cb:^(NSInteger v){ RavenSettings::visCrosshairStyle = (int)v; RavenSettings::save(); }],
            [self rowSlider:@"Size" min:1 max:30 val:RavenSettings::visCrosshairSize cb:^(float v){ RavenSettings::visCrosshairSize = v; }],
            [self rowSlider:@"Thickness" min:1 max:6 val:RavenSettings::visCrosshairThickness cb:^(float v){ RavenSettings::visCrosshairThickness = v; }],
        ]];
        UIView* camera = [self card:@"CAMERA" width:w rows:@[
            [self rowSlider:@"Camera FOV" min:60 max:240 val:RavenSettings::visCameraFov cb:^(float v){ RavenSettings::visCameraFov = v; RavenSettings::save(); }],
            [self rowToggle:@"Third Person" on:RavenSettings::visThirdPerson cb:^(BOOL v){ RavenSettings::visThirdPerson = v; RavenSettings::save(); }],
        ]];
        return @[cross, camera];
    }

    if ([tab isEqualToString:@"WEAPON"]) {
        UIView* weapon = [self card:@"WEAPON CONTROL" width:w rows:@[
            [self rowToggle:@"No Recoil" on:RavenSettings::wpnNoRecoil cb:^(BOOL v){ RavenSettings::wpnNoRecoil = v; }],
            [self rowSlider:@"Recoil Strength" min:0 max:1 val:RavenSettings::wpnRecoilStrength cb:^(float v){ RavenSettings::wpnRecoilStrength = v; }],
            [self rowToggle:@"Fast Reload" on:RavenSettings::wpnFastReload cb:^(BOOL v){ RavenSettings::wpnFastReload = v; }],
        ]];
        return @[weapon];
    }

    if ([tab isEqualToString:@"MISC"]) {
        UIView* utility = [self card:@"UTILITY" width:w rows:@[
            [self rowToggle:@"Long Slide" on:RavenSettings::miscLongSlide cb:^(BOOL v){ RavenSettings::miscLongSlide = v; }],
            [self rowSlider:@"Long Slide Strength" min:0 max:100 val:RavenSettings::miscLongSlideStrength cb:^(float v){ RavenSettings::miscLongSlideStrength = v; }],
            [self rowSlider:@"Player Speed" min:0 max:100 val:RavenSettings::miscPlayerSpeed cb:^(float v){ RavenSettings::miscPlayerSpeed = v; }],
            [self rowToggle:@"Panic Key" on:RavenSettings::miscPanicKey cb:^(BOOL v){ RavenSettings::miscPanicKey = v; }]
        ]];
        UIView* iface = [self card:@"INTERFACE" width:w rows:@[
            [self rowToggle:@"Hide Menu When Closed" on:RavenSettings::miscHideWhenClosed cb:^(BOOL v){ RavenSettings::miscHideWhenClosed = v; }],
            [self rowSlider:@"Menu Opacity" min:20 max:100 val:RavenSettings::miscMenuOpacity cb:^(float v){ RavenSettings::miscMenuOpacity = v; }],
        ]];
        return @[utility, iface];
    }

    if ([tab isEqualToString:@"PLAYERS"]) {
        NSArray<NSString*>* playerRows = [[RavenESP shared] snapshotPlayerRows];
        NSMutableArray* rows = [NSMutableArray array];
        if (playerRows.count == 0) {
            UILabel* empty = lbl(@"No live enemy players detected", 12, C_SEC, NO);
            empty.textAlignment = NSTextAlignmentCenter;
            empty.frame = CGRectMake(0, 0, w - 28, 34);
            UIView* emptyRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];
            [emptyRow addSubview:empty];
            [rows addObject:emptyRow];
        } else {
            for (NSInteger i = 0; i < (NSInteger)playerRows.count; i++)
                [rows addObject:[self rowInfo:[NSString stringWithFormat:@"PLAYER %ld", (long)i + 1]
                                      value:playerRows[i]]];
        }
        UIView* list = [self card:@"PLAYER LIST" width:w rows:rows];
        return @[list];
    }

    if ([tab isEqualToString:@"INFO"]) {
        UIDevice* device = [UIDevice currentDevice];
        NSString* key = [[NSUserDefaults standardUserDefaults] stringForKey:@"raven.license.maskedKey"];
        if (!key.length) key = @"Not linked";
        NSString* hwid = RavenLicense::deviceFingerprint();
        NSString* maskedHwid = hwid.length > 12 ? [NSString stringWithFormat:@"%@…%@", [hwid substringToIndex:6], [hwid substringFromIndex:hwid.length - 6]] : hwid;
        UIView* account = [self card:@"ACCOUNT & KEY" width:w rows:@[
            [self rowInfo:@"Account" value:@"Raven user"],
            [self rowInfo:@"License" value:key],
            [self rowInfo:@"Duration" value:ravenLicenseCountdown()],
            [self rowInfo:@"HWID" value:maskedHwid.length ? maskedHwid : @"Unavailable"],
        ]];
        UIView* deviceCard = [self card:@"DEVICE" width:w rows:@[
            [self rowInfo:@"Model" value:device.model ?: @"Unknown"],
            [self rowInfo:@"System" value:device.systemVersion ?: @"Unknown"],
            [self rowInfo:@"Screen" value:[NSString stringWithFormat:@"%.0f × %.0f", UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height]],
        ]];
        const char* il2cppStatus = IL2CPP::status();
        NSString* runtimeStatus = il2cppStatus ? [NSString stringWithUTF8String:il2cppStatus] : @"Unavailable";
        NSString* aimStatus = RavenSettings::aimEnabled || RavenSettings::gyroEnabled ? @"Enabled" : @"Standby";
        NSString* espStatus = RavenSettings::espEnabled ? @"Enabled" : @"Disabled";
        UIView* runtime = [self card:@"RUNTIME" width:w rows:@[
            [self rowInfo:@"IL2CPP" value:runtimeStatus],
            [self rowInfo:@"Aim Runtime" value:aimStatus],
            [self rowInfo:@"ESP Runtime" value:espStatus],
            [self rowInfo:@"Game Build" value:@"0.30.2"],
            [self rowInfo:@"Key Cache" value:@"Device-bound offline cache"],
            [self rowInfo:@"Release" value:@"RavenEngine V1.0"],
        ]];
        return @[account, deviceCard, runtime];
    }

    if ([tab isEqualToString:@"SETTINGS"]) {
        std::string rv = Updater::remoteVersion();
        NSString* rvStr = [NSString stringWithUTF8String:rv.c_str()];

        UIView* iface = [self card:@"INTERFACE" width:w rows:@[
            [self rowSlider:@"Menu Scale" min:50 max:150 val:RavenSettings::menuScale cb:^(float v){
                RavenSettings::menuScale = v;
                [self relayout];
                [self clampPanel];
            }],
            [self rowSelector:@"Accent Color"
                         items:@[@"Crimson", @"Red", @"Blue", @"Green", @"Purple"]
                      selected:RavenSettings::uiAccentColor
                            cb:^(NSInteger v){ RavenSettings::uiAccentColor = (int)v; RavenSettings::save(); }],
            [self rowToggle:@"Animations" on:RavenSettings::animations cb:^(BOOL v){
                RavenSettings::animations = v;
                RavenSettings::save();
                [self showToast:@"Animations" detail:(v ? @"Smooth UI motion enabled" : @"UI motion disabled")];
            }],
        ]];
        UIView* config = [self card:@"CONFIG" width:w rows:@[
            [self rowButton:@"Save Config" tap:^{
                RavenSettings::save();
                [self showToast:@"Config Saved" detail:@"RAVEN settings stored"];
            }],
            [self rowButton:@"Load Config" tap:^{
                RavenSettings::load();
                [self reloadActiveTab];
                [self relayout];
                [self showToast:@"Config Loaded" detail:@"Saved settings restored"];
            }],
            [self rowButton:@"Reset to Defaults" tap:^{
                RavenSettings::resetToDefaults();
                [self reloadActiveTab];
                [self relayout];
                [self showToast:@"Reset Complete" detail:@"All settings restored"];
            }],
        ]];
        UIView* menu = [self card:@"MENU" width:w rows:@[
            [self rowSelector:@"Open/Close Button"
                         items:@[@"Floating", @"Corner", @"Hidden"]
                      selected:RavenSettings::uiOpenButton
                            cb:^(NSInteger v){
                                RavenSettings::uiOpenButton = (int)v;
                                self.ball.hidden = (v == 2);
                                [self relayout];
                            }],
            [self rowSelector:@"Position"
                         items:@[@"Right", @"Left", @"Center"]
                      selected:RavenSettings::uiPosition
                            cb:^(NSInteger v){
                                RavenSettings::uiPosition = (int)v;
                                [self relayout];
                            }],
            [self rowSlider:@"Opacity" min:20 max:100 val:RavenSettings::miscMenuOpacity cb:^(float v){ RavenSettings::miscMenuOpacity = v; }],
        ]];
        UIView* about = [self card:@"ABOUT" width:w rows:@[
            [self rowInfo:@"Version" value:rvStr],
            [self rowInfo:@"Brand" value:@"RavenEngine"],
            [self rowInfo:@"Developer" value:@"Raven Team"],
            [self rowInfo:@"Status" value:[NSString stringWithUTF8String:Updater::status()]],
        ]];
        return @[iface, config, menu, about];
    }

    return @[];
}

- (void)buildFooter:(CGRect)r {
    self.footerView = [[UIView alloc] initWithFrame:r];
    self.footerView.backgroundColor = C_HEAD;

    UIView* top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, r.size.width, 1)];
    top.backgroundColor = C_BORDER;
    [self.footerView addSubview:top];

    UIView* dot = [[UIView alloc] initWithFrame:CGRectMake(14, (r.size.height - 7)/2, 7, 7)];
    dot.backgroundColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0];
    dot.layer.cornerRadius = 3.5;
    [self.footerView addSubview:dot];

    UILabel* l = lbl(@"Connected", 10, C_SEC, NO);
    l.frame = CGRectMake(26, 0, 140, r.size.height);
    [self.footerView addSubview:l];

    UILabel* r2 = lbl(@"RAVENENGINE  •  V1.0", 10, C_RED, YES);
    r2.textAlignment = NSTextAlignmentRight;
    r2.frame = CGRectMake(r.size.width - 230, 0, 216, r.size.height);
    [self.footerView addSubview:r2];

    [self.panelInner addSubview:self.footerView];
}

- (void)onTick {
    if (!self.window) return;
    CGSize b = self.window.bounds.size;
    if (!CGSizeEqualToSize(b, self.lastBounds)) {
        self.lastBounds = b;
        [self relayout];
        [self clampPanel];
    }
    if (!self.runtimeActive) return;
    static double playerRefreshAt = 0.0;
    double tickNow = CACurrentMediaTime();
    if (self.panelOpen && ((self.activeTab == 6 && tickNow - playerRefreshAt >= 0.50) ||
                           (self.activeTab == 7 && tickNow - playerRefreshAt >= 1.0))) {
        playerRefreshAt = tickNow;
        [self reloadActiveTab];
    }
    // Apply camera assistance before doing any overlay work. ESP performs
    // multiple IL2CPP calls and rebuilds several Core Animation paths; it
    // must never delay the input correction or make aim appear inactive.
    RavenAimbot::tick();
    // Keep aim at the menu tick rate, but cap ESP geometry work to 15 Hz.
    // Re-render immediately when a guide/ESP state changes so switches still
    // take effect without making the overlay compete with camera input.
    BOOL overlayEnabled = RavenSettings::espEnabled || RavenSettings::aimShowCircle ||
                          RavenSettings::visFovCircle || RavenSettings::visCrosshair;
    static double espRenderAt = 0.0;
    static BOOL lastOverlayEnabled = NO;
    double espNow = CACurrentMediaTime();
    BOOL stateChanged = (overlayEnabled != lastOverlayEnabled);
    if (stateChanged || (espNow - espRenderAt) >= (1.0 / 15.0)) {
        espRenderAt = espNow;
        lastOverlayEnabled = overlayEnabled;
        [[RavenESP shared] render];
    }
}

@end
