#import "Menu.h"
#import "Common.h"
#import "Logos.h"
#import "Settings.h"
#import <objc/runtime.h>

// RavenEngine UI refresh.
// Clean-room implementation inspired by the presentation/layout ideas in:
// - VenerableCode/iOS-Theos-ModMenuTemp-NoJB (architecture reference only; repo has no declared license)
// - silentninjabee/iOS-ImGui-ModMenu-Template (MIT; Metal/ImGui interaction reference)
//
// This file intentionally keeps Raven's existing settings/state boundary intact and does not
// include patching, hooking, ESP, aim or gameplay logic. The runtime continues to read the
// RavenSettings values exactly as before.

static UIColor* RVColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static UIColor* const RVPlaceholder = nil;
static UIColor* RVBg(void)        { return RVColor(0.025, 0.027, 0.033, 0.98); }
static UIColor* RVPanel(void)     { return RVColor(0.040, 0.043, 0.052, 0.99); }
static UIColor* RVSidebar(void)   { return RVColor(0.032, 0.034, 0.041, 1.00); }
static UIColor* RVCard(void)      { return RVColor(0.061, 0.064, 0.074, 1.00); }
static UIColor* RVCardHi(void)    { return RVColor(0.077, 0.080, 0.092, 1.00); }
static UIColor* RVBorder(void)    { return RVColor(0.135, 0.140, 0.158, 1.00); }
static UIColor* RVAccent(void)    { return RVColor(0.86, 0.09, 0.14, 1.00); }
static UIColor* RVAccentDim(void) { return RVColor(0.31, 0.045, 0.065, 1.00); }
static UIColor* RVText(void)      { return RVColor(0.95, 0.955, 0.97, 1.00); }
static UIColor* RVMuted(void)     { return RVColor(0.52, 0.54, 0.60, 1.00); }

static UIWindowScene* RVActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene*)scene;
            }
        }
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene*)scene;
        }
    }
    return nil;
}

static void RVLoadImage(const char* cURL, void (^completion)(UIImage*)) {
    if (!cURL || !*cURL) { if (completion) completion(nil); return; }
    NSString* s = [NSString stringWithUTF8String:cURL];
    NSURL* url = [NSURL URLWithString:s];
    if (!url) { if (completion) completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        (void)response;
        UIImage* image = (!error && data.length) ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(image); });
    }] resume];
}

typedef void (^RVBoolSetter)(BOOL value);
typedef void (^RVFloatSetter)(float value);
typedef void (^RVIntSetter)(NSInteger value);

static const void* kRVSetterKey = &kRVSetterKey;
static const void* kRVValueLabelKey = &kRVValueLabelKey;
static const void* kRVFormatKey = &kRVFormatKey;

@class RavenMenu;

@implementation RavenWindow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
    }
    return self;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    RavenMenu* menu = [RavenMenu shared];
    UIView* panel = [menu valueForKey:@"panel"];
    UIView* ball = [menu valueForKey:@"ball"];

    if (panel && !panel.hidden && panel.alpha > 0.01) {
        CGPoint local = [panel convertPoint:point fromView:self];
        if ([panel pointInside:local withEvent:event]) return [panel hitTest:local withEvent:event];
    }
    if (ball && !ball.hidden && ball.alpha > 0.01) {
        CGPoint local = [ball convertPoint:point fromView:self];
        if ([ball pointInside:local withEvent:event]) return [ball hitTest:local withEvent:event];
    }
    return nil;
}
@end

@implementation RVToggle {
    UISwitch* _switch;
}
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 52, 32)])) {
        _switch = [[UISwitch alloc] initWithFrame:CGRectZero];
        _switch.onTintColor = RVAccent();
        [_switch addTarget:self action:@selector(rvChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_switch];
    }
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _switch.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds)); }
- (void)rvChanged:(UISwitch*)sender { _on = sender.on; if (self.onChange) self.onChange(_on); }
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)animated { _on = on; [_switch setOn:on animated:animated]; }
@end

@implementation RVSlider {
    UISlider* _slider;
}
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 220, 32)])) {
        _minValue = 0; _maxValue = 100; _value = 0;
        _slider = [[UISlider alloc] initWithFrame:self.bounds];
        _slider.minimumTrackTintColor = RVAccent();
        _slider.maximumTrackTintColor = RVBorder();
        [_slider addTarget:self action:@selector(rvChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_slider];
    }
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _slider.frame = self.bounds; }
- (void)setMinValue:(float)v { _minValue = v; _slider.minimumValue = v; }
- (void)setMaxValue:(float)v { _maxValue = v; _slider.maximumValue = v; }
- (void)setValue:(float)v { _value = v; _slider.value = v; }
- (void)rvChanged:(UISlider*)sender { _value = sender.value; if (self.onChange) self.onChange(_value); }
@end

@implementation RVSelector {
    UISegmentedControl* _seg;
}
- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 260, 32)])) {
        _items = [items copy]; _selectedIndex = selected;
        _seg = [[UISegmentedControl alloc] initWithItems:_items];
        _seg.selectedSegmentIndex = selected;
        _seg.selectedSegmentTintColor = RVAccentDim();
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RVMuted()} forState:UIControlStateNormal];
        [_seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RVText()} forState:UIControlStateSelected];
        [_seg addTarget:self action:@selector(rvChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_seg];
    }
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _seg.frame = self.bounds; }
- (void)setSelectedIndex:(NSInteger)v { _selectedIndex = v; _seg.selectedSegmentIndex = v; }
- (void)rvChanged:(UISegmentedControl*)sender { _selectedIndex = sender.selectedSegmentIndex; if (self.onChange) self.onChange(_selectedIndex); }
@end

@interface RavenMenu ()
@property (nonatomic, strong) RavenWindow* window;
@property (nonatomic, strong) UIViewController* rootController;
@property (nonatomic, strong) UIView* panel;
@property (nonatomic, strong) UIButton* ball;
@property (nonatomic, strong) UIView* header;
@property (nonatomic, strong) UIView* sidebar;
@property (nonatomic, strong) UIScrollView* content;
@property (nonatomic, strong) UILabel* pageTitle;
@property (nonatomic, strong) NSArray<UIButton*>* tabButtons;
@property (nonatomic, assign) NSInteger selectedTab;
@property (nonatomic, assign) CGPoint dragOrigin;
@property (nonatomic, assign) BOOL started;
@end

@implementation RavenMenu

+ (instancetype)shared {
    static RavenMenu* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [RavenMenu new]; });
    return shared;
}

- (UILabel*)label:(NSString*)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor*)color {
    UILabel* label = [UILabel new];
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = 1;
    return label;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.started) return;
        self.started = YES;

        CGRect bounds = UIScreen.mainScreen.bounds;
        self.window = [[RavenWindow alloc] initWithFrame:bounds];
        if (@available(iOS 13.0, *)) self.window.windowScene = RVActiveScene();
        self.window.windowLevel = UIWindowLevelNormal + 3.0;
        self.window.backgroundColor = UIColor.clearColor;

        self.rootController = [UIViewController new];
        self.rootController.view.backgroundColor = UIColor.clearColor;
        self.window.rootViewController = self.rootController;
        self.window.hidden = NO;

        [self buildOpenButton];
        [self buildPanel];
        [self layoutForCurrentScreen];
        [self selectTab:0];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(rvOrientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    });
}

- (void)buildOpenButton {
    self.ball = [UIButton buttonWithType:UIButtonTypeCustom];
    self.ball.frame = CGRectMake(18, 110, 54, 54);
    self.ball.backgroundColor = RVPanel();
    self.ball.layer.cornerRadius = 27;
    self.ball.layer.borderWidth = 1.0;
    self.ball.layer.borderColor = [RVAccent() colorWithAlphaComponent:0.75].CGColor;
    self.ball.layer.shadowColor = UIColor.blackColor.CGColor;
    self.ball.layer.shadowOpacity = 0.45;
    self.ball.layer.shadowRadius = 10;
    self.ball.layer.shadowOffset = CGSizeMake(0, 4);
    self.ball.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.ball.contentEdgeInsets = UIEdgeInsetsMake(7, 7, 7, 7);
    [self.ball setTitle:@"R" forState:UIControlStateNormal];
    [self.ball setTitleColor:RVText() forState:UIControlStateNormal];
    self.ball.titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBlack];
    [self.ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.rootController.view addSubview:self.ball];

    RVLoadImage(kBallLogoURL, ^(UIImage* image) {
        if (!image) return;
        [self.ball setTitle:nil forState:UIControlStateNormal];
        [self.ball setImage:image forState:UIControlStateNormal];
    });
}

- (void)buildPanel {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 820, 460)];
    self.panel.backgroundColor = RVPanel();
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = RVBorder().CGColor;
    self.panel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.panel.layer.shadowOpacity = 0.58;
    self.panel.layer.shadowRadius = 24;
    self.panel.layer.shadowOffset = CGSizeMake(0, 12);
    self.panel.clipsToBounds = NO;
    [self.rootController.view addSubview:self.panel];

    self.header = [[UIView alloc] initWithFrame:CGRectZero];
    self.header.backgroundColor = RVBg();
    self.header.layer.cornerRadius = 16;
    self.header.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self.panel addSubview:self.header];

    UIPanGestureRecognizer* drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    drag.maximumNumberOfTouches = 1;
    [self.header addGestureRecognizer:drag];

    UIView* accent = [[UIView alloc] initWithFrame:CGRectZero];
    accent.tag = 9101;
    accent.backgroundColor = RVAccent();
    accent.layer.cornerRadius = 1.5;
    [self.header addSubview:accent];

    UILabel* brand = [self label:@"RAVENENGINE" size:18 weight:UIFontWeightBlack color:RVText()];
    brand.tag = 9102;
    [self.header addSubview:brand];

    UILabel* sub = [self label:@"COMBAT MASTER  •  iOS" size:10 weight:UIFontWeightSemibold color:RVMuted()];
    sub.tag = 9103;
    [self.header addSubview:sub];

    self.pageTitle = [self label:@"AIM" size:12 weight:UIFontWeightBold color:RVMuted()];
    self.pageTitle.textAlignment = NSTextAlignmentRight;
    self.pageTitle.tag = 9104;
    [self.header addSubview:self.pageTitle];

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.tag = 9105;
    close.frame = CGRectZero;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:RVMuted() forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:25 weight:UIFontWeightRegular];
    close.backgroundColor = RVCard();
    close.layer.cornerRadius = 15;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:close];

    self.sidebar = [[UIView alloc] initWithFrame:CGRectZero];
    self.sidebar.backgroundColor = RVSidebar();
    [self.panel addSubview:self.sidebar];

    NSArray<NSString*>* names = @[@"AIM", @"ESP", @"VISUALS", @"WEAPON", @"MISC", @"SETTINGS"];
    NSMutableArray* buttons = [NSMutableArray arrayWithCapacity:names.count];
    for (NSInteger i = 0; i < names.count; i++) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = 100 + i;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 15, 0, 0);
        [b setTitle:names[i] forState:UIControlStateNormal];
        [b setTitleColor:RVMuted() forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        b.layer.cornerRadius = 8;
        [b addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.sidebar addSubview:b];
        [buttons addObject:b];
    }
    self.tabButtons = buttons;

    UILabel* footer = [self label:@"RAVEN  •  MOBILE" size:9 weight:UIFontWeightSemibold color:[RVMuted() colorWithAlphaComponent:0.65]];
    footer.tag = 9200;
    [self.sidebar addSubview:footer];

    self.content = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.content.backgroundColor = RVBg();
    self.content.alwaysBounceVertical = YES;
    self.content.showsVerticalScrollIndicator = YES;
    self.content.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.panel addSubview:self.content];
}

- (void)rvOrientationChanged:(NSNotification*)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self layoutForCurrentScreen]; });
}

- (void)layoutForCurrentScreen {
    if (!self.panel) return;
    CGRect bounds = self.rootController.view.bounds;
    self.window.frame = UIScreen.mainScreen.bounds;

    CGFloat maxW = MAX(420.0, bounds.size.width - 28.0);
    CGFloat maxH = MAX(300.0, bounds.size.height - 28.0);
    CGFloat w = MIN(820.0 * MAX(0.82, MIN(1.15, RavenSettings::menuScale)), maxW);
    CGFloat h = MIN(460.0 * MAX(0.82, MIN(1.15, RavenSettings::menuScale)), maxH);
    self.panel.frame = CGRectMake((bounds.size.width - w) * 0.5,
                                  (bounds.size.height - h) * 0.5,
                                  w, h);

    CGFloat headerH = 62;
    CGFloat sideW = MIN(162.0, w * 0.24);
    self.header.frame = CGRectMake(0, 0, w, headerH);
    self.sidebar.frame = CGRectMake(0, headerH, sideW, h - headerH);
    self.content.frame = CGRectMake(sideW, headerH, w - sideW, h - headerH);

    UIView* accent = [self.header viewWithTag:9101];
    accent.frame = CGRectMake(18, 20, 4, 22);
    UILabel* brand = (UILabel*)[self.header viewWithTag:9102];
    brand.frame = CGRectMake(32, 13, 220, 23);
    UILabel* sub = (UILabel*)[self.header viewWithTag:9103];
    sub.frame = CGRectMake(32, 36, 220, 14);
    UIButton* close = (UIButton*)[self.header viewWithTag:9105];
    close.frame = CGRectMake(w - 46, 16, 30, 30);
    self.pageTitle.frame = CGRectMake(w - 210, 21, 150, 20);

    CGFloat y = 18;
    CGFloat bw = sideW - 20;
    for (UIButton* button in self.tabButtons) {
        button.frame = CGRectMake(10, y, bw, 38);
        y += 44;
    }
    UILabel* footer = (UILabel*)[self.sidebar viewWithTag:9200];
    footer.frame = CGRectMake(18, self.sidebar.bounds.size.height - 28, sideW - 30, 16);

    if (self.ball.superview) {
        CGRect bf = self.ball.frame;
        bf.origin.x = MIN(MAX(10.0, bf.origin.x), MAX(10.0, bounds.size.width - bf.size.width - 10.0));
        bf.origin.y = MIN(MAX(10.0, bf.origin.y), MAX(10.0, bounds.size.height - bf.size.height - 10.0));
        self.ball.frame = bf;
    }
}

- (void)dragPanel:(UIPanGestureRecognizer*)pan {
    CGPoint translation = [pan translationInView:self.rootController.view];
    if (pan.state == UIGestureRecognizerStateBegan) self.dragOrigin = self.panel.center;
    CGPoint target = CGPointMake(self.dragOrigin.x + translation.x, self.dragOrigin.y + translation.y);
    CGRect bounds = self.rootController.view.bounds;
    CGFloat halfW = self.panel.bounds.size.width * 0.5;
    CGFloat halfH = self.panel.bounds.size.height * 0.5;
    target.x = MIN(MAX(target.x, halfW * 0.55), bounds.size.width - halfW * 0.55);
    target.y = MIN(MAX(target.y, halfH * 0.55), bounds.size.height - halfH * 0.55);
    self.panel.center = target;
}

- (void)togglePanel {
    BOOL opening = self.panel.hidden;
    self.panel.hidden = NO;
    if (RavenSettings::animations) {
        if (opening) {
            self.panel.alpha = 0;
            self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
            [UIView animateWithDuration:0.18 animations:^{
                self.panel.alpha = 1;
                self.panel.transform = CGAffineTransformIdentity;
            }];
        } else {
            [UIView animateWithDuration:0.14 animations:^{
                self.panel.alpha = 0;
                self.panel.transform = CGAffineTransformMakeScale(0.97, 0.97);
            } completion:^(BOOL finished) {
                (void)finished;
                self.panel.hidden = YES;
                self.panel.alpha = 1;
                self.panel.transform = CGAffineTransformIdentity;
            }];
        }
    } else {
        self.panel.hidden = !opening;
    }
}

- (void)closePanel {
    if (!self.panel.hidden) [self togglePanel];
}

- (BOOL)isPanelOpen { return self.started && self.panel && !self.panel.hidden; }

- (void)setVisible:(BOOL)v {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.hidden = !v;
    });
}

- (void)tabPressed:(UIButton*)sender { [self selectTab:sender.tag - 100]; }

- (void)selectTab:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tabButtons.count) return;
    self.selectedTab = index;
    NSArray* titles = @[@"AIM", @"ESP", @"VISUALS", @"WEAPON", @"MISC", @"SETTINGS"];
    self.pageTitle.text = titles[index];

    for (NSInteger i = 0; i < self.tabButtons.count; i++) {
        UIButton* b = self.tabButtons[i];
        BOOL active = (i == index);
        b.backgroundColor = active ? RVAccentDim() : UIColor.clearColor;
        [b setTitleColor:active ? RVText() : RVMuted() forState:UIControlStateNormal];
        b.layer.borderWidth = active ? 1 : 0;
        b.layer.borderColor = active ? [RVAccent() colorWithAlphaComponent:0.42].CGColor : UIColor.clearColor.CGColor;
    }
    [self renderSelectedTab];
}

- (void)clearContent {
    for (UIView* v in self.content.subviews) [v removeFromSuperview];
}

- (CGFloat)addSection:(NSString*)title y:(CGFloat)y {
    UILabel* l = [self label:title size:10 weight:UIFontWeightBold color:RVMuted()];
    l.frame = CGRectMake(18, y + 4, self.content.bounds.size.width - 36, 20);
    [self.content addSubview:l];
    return y + 30;
}

- (UIView*)cardAtY:(CGFloat)y height:(CGFloat)height {
    CGFloat width = MAX(280, self.content.bounds.size.width - 36);
    UIView* card = [[UIView alloc] initWithFrame:CGRectMake(18, y, width, height)];
    card.backgroundColor = RVCard();
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [RVBorder() colorWithAlphaComponent:0.72].CGColor;
    [self.content addSubview:card];
    return card;
}

- (CGFloat)addToggle:(NSString*)title detail:(NSString*)detail value:(BOOL)value y:(CGFloat)y setter:(RVBoolSetter)setter {
    UIView* card = [self cardAtY:y height:58];
    UILabel* t = [self label:title size:13 weight:UIFontWeightSemibold color:RVText()];
    t.frame = CGRectMake(14, detail.length ? 9 : 18, MAX(120, card.bounds.size.width - 92), 20);
    [card addSubview:t];
    if (detail.length) {
        UILabel* d = [self label:detail size:9 weight:UIFontWeightRegular color:RVMuted()];
        d.frame = CGRectMake(14, 31, MAX(120, card.bounds.size.width - 92), 14);
        [card addSubview:d];
    }
    UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.on = value;
    sw.onTintColor = RVAccent();
    sw.transform = CGAffineTransformMakeScale(0.78, 0.78);
    sw.center = CGPointMake(card.bounds.size.width - 35, card.bounds.size.height * 0.5);
    objc_setAssociatedObject(sw, kRVSetterKey, [setter copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [sw addTarget:self action:@selector(rvSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];
    return y + 66;
}

- (CGFloat)addSlider:(NSString*)title value:(float)value min:(float)min max:(float)max format:(NSString*)format y:(CGFloat)y setter:(RVFloatSetter)setter {
    UIView* card = [self cardAtY:y height:70];
    UILabel* t = [self label:title size:12 weight:UIFontWeightSemibold color:RVText()];
    t.frame = CGRectMake(14, 8, card.bounds.size.width * 0.58, 18);
    [card addSubview:t];

    UILabel* val = [self label:[NSString stringWithFormat:format, value] size:11 weight:UIFontWeightBold color:RVAccent()];
    val.textAlignment = NSTextAlignmentRight;
    val.frame = CGRectMake(card.bounds.size.width - 112, 8, 98, 18);
    [card addSubview:val];

    UISlider* slider = [[UISlider alloc] initWithFrame:CGRectMake(14, 32, card.bounds.size.width - 28, 28)];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    slider.minimumTrackTintColor = RVAccent();
    slider.maximumTrackTintColor = RVBorder();
    objc_setAssociatedObject(slider, kRVSetterKey, [setter copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(slider, kRVValueLabelKey, val, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, kRVFormatKey, format, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [slider addTarget:self action:@selector(rvSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];
    return y + 78;
}

- (CGFloat)addSelector:(NSString*)title items:(NSArray<NSString*>*)items selected:(NSInteger)selected y:(CGFloat)y setter:(RVIntSetter)setter {
    UIView* card = [self cardAtY:y height:76];
    UILabel* t = [self label:title size:12 weight:UIFontWeightSemibold color:RVText()];
    t.frame = CGRectMake(14, 8, card.bounds.size.width - 28, 18);
    [card addSubview:t];

    UISegmentedControl* seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.frame = CGRectMake(12, 34, card.bounds.size.width - 24, 30);
    if (selected >= 0 && selected < (NSInteger)items.count) seg.selectedSegmentIndex = selected;
    seg.selectedSegmentTintColor = RVAccentDim();
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RVMuted(), NSFontAttributeName:[UIFont systemFontOfSize:9 weight:UIFontWeightSemibold]} forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: RVText(), NSFontAttributeName:[UIFont systemFontOfSize:9 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    objc_setAssociatedObject(seg, kRVSetterKey, [setter copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [seg addTarget:self action:@selector(rvSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:seg];
    return y + 84;
}

- (CGFloat)addAction:(NSString*)title destructive:(BOOL)destructive y:(CGFloat)y selector:(SEL)selector {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(18, y, MAX(280, self.content.bounds.size.width - 36), 46);
    button.backgroundColor = destructive ? [RVAccentDim() colorWithAlphaComponent:0.72] : RVCard();
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 1;
    button.layer.borderColor = (destructive ? [RVAccent() colorWithAlphaComponent:0.55] : RVBorder()).CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:(destructive ? RVText() : RVMuted()) forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [self.content addSubview:button];
    return y + 54;
}

- (void)rvSwitchChanged:(UISwitch*)sender {
    RVBoolSetter setter = objc_getAssociatedObject(sender, kRVSetterKey);
    if (setter) setter(sender.on);
    RavenSettings::save();
}

- (void)rvSliderChanged:(UISlider*)sender {
    RVFloatSetter setter = objc_getAssociatedObject(sender, kRVSetterKey);
    if (setter) setter(sender.value);
    UILabel* label = objc_getAssociatedObject(sender, kRVValueLabelKey);
    NSString* format = objc_getAssociatedObject(sender, kRVFormatKey) ?: @"%.1f";
    label.text = [NSString stringWithFormat:format, sender.value];
    RavenSettings::save();
}

- (void)rvSegmentChanged:(UISegmentedControl*)sender {
    RVIntSetter setter = objc_getAssociatedObject(sender, kRVSetterKey);
    if (setter) setter(sender.selectedSegmentIndex);
    RavenSettings::save();
}

- (void)resetPressed {
    RavenSettings::resetToDefaults();
    RavenSettings::save();
    [self layoutForCurrentScreen];
    [self renderSelectedTab];
}

- (void)hidePressed { [self closePanel]; }

- (void)renderSelectedTab {
    [self clearContent];
    CGFloat y = 16;

    switch (self.selectedTab) {
        case 0: {
            y = [self addSection:@"PRIMARY AIM" y:y];
            y = [self addToggle:@"Enable Aim" detail:@"Master aim-assist state" value:RavenSettings::aimEnabled y:y setter:^(BOOL v){ RavenSettings::aimEnabled = v; }];
            y = [self addSelector:@"Activation" items:@[@"Always", @"Fire", @"ADS", @"Fire+ADS"] selected:RavenSettings::aimActivation y:y setter:^(NSInteger v){ RavenSettings::aimActivation = (int)v; }];
            y = [self addSelector:@"Aim Bone" items:@[@"Head", @"Neck", @"Chest", @"Pelvis"] selected:RavenSettings::aimBone y:y setter:^(NSInteger v){ RavenSettings::aimBone = (int)v; }];
            y = [self addSlider:@"FOV" value:RavenSettings::aimFov min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::aimFov = v; }];
            y = [self addSlider:@"Smooth" value:RavenSettings::aimSmooth min:0 max:20 format:@"%.1f" y:y setter:^(float v){ RavenSettings::aimSmooth = v; }];
            y = [self addSlider:@"Strength" value:RavenSettings::aimStrength min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::aimStrength = v; }];
            y = [self addSlider:@"Max Distance" value:RavenSettings::aimMaxDist min:20 max:1000 format:@"%.0f m" y:y setter:^(float v){ RavenSettings::aimMaxDist = v; }];
            y = [self addToggle:@"Prediction" detail:@"Use target motion prediction" value:RavenSettings::aimPrediction y:y setter:^(BOOL v){ RavenSettings::aimPrediction = v; }];
            y = [self addToggle:@"Visibility Check" detail:@"Respect current visibility state" value:RavenSettings::aimVisCheck y:y setter:^(BOOL v){ RavenSettings::aimVisCheck = v; }];
            y = [self addToggle:@"Ignore Teammates" detail:@"Exclude same-team targets" value:RavenSettings::aimIgnoreTeammates y:y setter:^(BOOL v){ RavenSettings::aimIgnoreTeammates = v; }];
            y = [self addToggle:@"Dynamic FOV" detail:@"Scale aim region dynamically" value:RavenSettings::aimDynamicFov y:y setter:^(BOOL v){ RavenSettings::aimDynamicFov = v; }];

            y = [self addSection:@"GYRO" y:y];
            y = [self addToggle:@"Gyro Aim" detail:@"Enable gyro settings path" value:RavenSettings::gyroEnabled y:y setter:^(BOOL v){ RavenSettings::gyroEnabled = v; }];
            y = [self addSlider:@"Gyro Smooth" value:RavenSettings::gyroSmooth min:0 max:20 format:@"%.1f" y:y setter:^(float v){ RavenSettings::gyroSmooth = v; }];
            y = [self addSlider:@"Gyro FOV" value:RavenSettings::gyroFov min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::gyroFov = v; }];
            y = [self addSlider:@"Stabilizer" value:RavenSettings::gyroStabilizer min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::gyroStabilizer = v; }];
            y = [self addSlider:@"Micro Correction" value:RavenSettings::gyroMicroCorrection min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::gyroMicroCorrection = v; }];
            y = [self addToggle:@"Low Latency" detail:@"Prefer reduced UI/runtime delay" value:RavenSettings::gyroLowLatency y:y setter:^(BOOL v){ RavenSettings::gyroLowLatency = v; }];
            break;
        }

        case 1: {
            y = [self addSection:@"ESP" y:y];
            y = [self addToggle:@"Enable ESP" detail:@"Master ESP state" value:RavenSettings::espEnabled y:y setter:^(BOOL v){ RavenSettings::espEnabled = v; }];
            y = [self addToggle:@"Boxes" detail:@"Player boxes" value:RavenSettings::espBox y:y setter:^(BOOL v){ RavenSettings::espBox = v; }];
            y = [self addToggle:@"Corner Boxes" detail:@"Corner-style box mode" value:RavenSettings::espCorner y:y setter:^(BOOL v){ RavenSettings::espCorner = v; }];
            y = [self addToggle:@"Skeleton" detail:@"Player skeleton lines" value:RavenSettings::espSkeleton y:y setter:^(BOOL v){ RavenSettings::espSkeleton = v; }];
            y = [self addToggle:@"Snaplines" detail:@"Screen-to-player lines" value:RavenSettings::espSnaplines y:y setter:^(BOOL v){ RavenSettings::espSnaplines = v; }];
            y = [self addToggle:@"Names" detail:@"Display player names" value:RavenSettings::espName y:y setter:^(BOOL v){ RavenSettings::espName = v; }];
            y = [self addToggle:@"Distance" detail:@"Display target distance" value:RavenSettings::espDistance y:y setter:^(BOOL v){ RavenSettings::espDistance = v; }];
            y = [self addToggle:@"Health" detail:@"Display health" value:RavenSettings::espHealth y:y setter:^(BOOL v){ RavenSettings::espHealth = v; }];
            y = [self addToggle:@"Health Bar" detail:@"Draw health bar" value:RavenSettings::espHealthBar y:y setter:^(BOOL v){ RavenSettings::espHealthBar = v; }];
            y = [self addToggle:@"Armor Bar" detail:@"Draw armor bar" value:RavenSettings::espArmorBar y:y setter:^(BOOL v){ RavenSettings::espArmorBar = v; }];
            y = [self addToggle:@"Weapon" detail:@"Display equipped weapon" value:RavenSettings::espWeapon y:y setter:^(BOOL v){ RavenSettings::espWeapon = v; }];
            y = [self addToggle:@"Head Dot" detail:@"Draw head marker" value:RavenSettings::espHeadDot y:y setter:^(BOOL v){ RavenSettings::espHeadDot = v; }];
            y = [self addToggle:@"Visible Only" detail:@"Render only visible targets" value:RavenSettings::espVisibleOnly y:y setter:^(BOOL v){ RavenSettings::espVisibleOnly = v; }];
            y = [self addToggle:@"RGB" detail:@"Cycle ESP color" value:RavenSettings::espRgb y:y setter:^(BOOL v){ RavenSettings::espRgb = v; }];
            y = [self addToggle:@"Performance Mode" detail:@"Prefer lighter ESP rendering" value:RavenSettings::espPerformanceMode y:y setter:^(BOOL v){ RavenSettings::espPerformanceMode = v; }];
            y = [self addToggle:@"Auto Optimize" detail:@"Allow adaptive ESP load" value:RavenSettings::espAutoOptimize y:y setter:^(BOOL v){ RavenSettings::espAutoOptimize = v; }];
            y = [self addToggle:@"FPS Counter" detail:@"Show ESP performance counter" value:RavenSettings::espFpsCounter y:y setter:^(BOOL v){ RavenSettings::espFpsCounter = v; }];
            y = [self addSlider:@"Box Scale" value:RavenSettings::espBoxScale min:0.5 max:2.0 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::espBoxScale = v; }];
            y = [self addSelector:@"Snapline Origin" items:@[@"Top", @"Center", @"Bottom"] selected:RavenSettings::espSnaplinePosition y:y setter:^(NSInteger v){ RavenSettings::espSnaplinePosition = (int)v; }];
            y = [self addSelector:@"Box Style" items:@[@"Full", @"Corner", @"Rounded"] selected:RavenSettings::espBoxStyle y:y setter:^(NSInteger v){ RavenSettings::espBoxStyle = (int)v; }];
            break;
        }

        case 2: {
            y = [self addSection:@"HUD" y:y];
            y = [self addToggle:@"Crosshair" detail:@"Custom crosshair overlay" value:RavenSettings::visCrosshair y:y setter:^(BOOL v){ RavenSettings::visCrosshair = v; }];
            y = [self addSelector:@"Crosshair Style" items:@[@"Plus", @"Dot", @"Circle", @"T"] selected:RavenSettings::visCrosshairStyle y:y setter:^(NSInteger v){ RavenSettings::visCrosshairStyle = (int)v; }];
            y = [self addSlider:@"Crosshair Size" value:RavenSettings::visCrosshairSize min:2 max:60 format:@"%.0f" y:y setter:^(float v){ RavenSettings::visCrosshairSize = v; }];
            y = [self addSlider:@"Crosshair Thickness" value:RavenSettings::visCrosshairThickness min:0.5 max:8 format:@"%.1f" y:y setter:^(float v){ RavenSettings::visCrosshairThickness = v; }];
            y = [self addToggle:@"FOV Circle" detail:@"Draw configured FOV circle" value:RavenSettings::visFovCircle y:y setter:^(BOOL v){ RavenSettings::visFovCircle = v; }];
            y = [self addSlider:@"FOV Radius" value:RavenSettings::visFovRadius min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::visFovRadius = v; }];
            y = [self addSlider:@"FOV Thickness" value:RavenSettings::visFovThickness min:0.5 max:8 format:@"%.1f" y:y setter:^(float v){ RavenSettings::visFovThickness = v; }];

            y = [self addSection:@"SCENE" y:y];
            y = [self addToggle:@"Remove Fog" detail:@"Use existing Raven visual setting" value:RavenSettings::visRemoveFog y:y setter:^(BOOL v){ RavenSettings::visRemoveFog = v; }];
            y = [self addToggle:@"Night Mode" detail:@"Use existing Raven visual setting" value:RavenSettings::visNightMode y:y setter:^(BOOL v){ RavenSettings::visNightMode = v; }];
            y = [self addToggle:@"Brightness Boost" detail:@"Enable brightness adjustment" value:RavenSettings::visBrightnessBoost y:y setter:^(BOOL v){ RavenSettings::visBrightnessBoost = v; }];
            y = [self addSlider:@"Brightness" value:RavenSettings::visBrightness min:0 max:3 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::visBrightness = v; }];
            y = [self addToggle:@"No Flash" detail:@"Use existing Raven visual setting" value:RavenSettings::visNoFlash y:y setter:^(BOOL v){ RavenSettings::visNoFlash = v; }];
            y = [self addToggle:@"No Smoke" detail:@"Use existing Raven visual setting" value:RavenSettings::visNoSmoke y:y setter:^(BOOL v){ RavenSettings::visNoSmoke = v; }];
            y = [self addToggle:@"Better Textures" detail:@"Use existing Raven visual setting" value:RavenSettings::visBetterTextures y:y setter:^(BOOL v){ RavenSettings::visBetterTextures = v; }];
            y = [self addSlider:@"Camera FOV" value:RavenSettings::visCameraFov min:50 max:140 format:@"%.0f°" y:y setter:^(float v){ RavenSettings::visCameraFov = v; }];
            y = [self addToggle:@"Third Person" detail:@"Use existing Raven camera setting" value:RavenSettings::visThirdPerson y:y setter:^(BOOL v){ RavenSettings::visThirdPerson = v; }];
            break;
        }

        case 3: {
            y = [self addSection:@"WEAPON" y:y];
            y = [self addToggle:@"No Recoil" detail:@"Existing Raven weapon state" value:RavenSettings::wpnNoRecoil y:y setter:^(BOOL v){ RavenSettings::wpnNoRecoil = v; }];
            y = [self addToggle:@"No Spread" detail:@"Existing Raven weapon state" value:RavenSettings::wpnNoSpread y:y setter:^(BOOL v){ RavenSettings::wpnNoSpread = v; }];
            y = [self addSlider:@"Recoil Strength" value:RavenSettings::wpnRecoilStrength min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::wpnRecoilStrength = v; }];
            y = [self addToggle:@"Fast Reload" detail:@"Existing Raven weapon state" value:RavenSettings::wpnFastReload y:y setter:^(BOOL v){ RavenSettings::wpnFastReload = v; }];
            y = [self addToggle:@"Rapid Fire" detail:@"Existing Raven weapon state" value:RavenSettings::wpnRapidFire y:y setter:^(BOOL v){ RavenSettings::wpnRapidFire = v; }];
            y = [self addSlider:@"Fire Rate" value:RavenSettings::wpnFireRate min:0.25 max:4.0 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::wpnFireRate = v; }];
            y = [self addToggle:@"No Muzzle Flash" detail:@"Existing Raven weapon state" value:RavenSettings::wpnNoFlash y:y setter:^(BOOL v){ RavenSettings::wpnNoFlash = v; }];
            y = [self addToggle:@"No Weapon Smoke" detail:@"Existing Raven weapon state" value:RavenSettings::wpnNoSmoke y:y setter:^(BOOL v){ RavenSettings::wpnNoSmoke = v; }];
            y = [self addToggle:@"No Shells" detail:@"Existing Raven weapon state" value:RavenSettings::wpnNoShells y:y setter:^(BOOL v){ RavenSettings::wpnNoShells = v; }];
            break;
        }

        case 4: {
            y = [self addSection:@"MOVEMENT" y:y];
            y = [self addToggle:@"Bunny Hop" detail:@"Existing Raven movement state" value:RavenSettings::miscBunnyHop y:y setter:^(BOOL v){ RavenSettings::miscBunnyHop = v; }];
            y = [self addToggle:@"Auto Strafe" detail:@"Existing Raven movement state" value:RavenSettings::miscAutoStrafe y:y setter:^(BOOL v){ RavenSettings::miscAutoStrafe = v; }];
            y = [self addToggle:@"Long Slide" detail:@"Existing Raven movement state" value:RavenSettings::miscLongSlide y:y setter:^(BOOL v){ RavenSettings::miscLongSlide = v; }];
            y = [self addSlider:@"Slide Strength" value:RavenSettings::miscLongSlideStrength min:0 max:5 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::miscLongSlideStrength = v; }];
            y = [self addSlider:@"Player Speed" value:RavenSettings::miscPlayerSpeed min:0.5 max:3 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::miscPlayerSpeed = v; }];
            y = [self addToggle:@"No Fall Damage" detail:@"Existing Raven misc state" value:RavenSettings::miscNoFallDamage y:y setter:^(BOOL v){ RavenSettings::miscNoFallDamage = v; }];

            y = [self addSection:@"UTILITY" y:y];
            y = [self addToggle:@"Unlock All" detail:@"Existing Raven misc state" value:RavenSettings::miscUnlockAll y:y setter:^(BOOL v){ RavenSettings::miscUnlockAll = v; }];
            y = [self addToggle:@"No Ads" detail:@"Existing Raven misc state" value:RavenSettings::miscNoAds y:y setter:^(BOOL v){ RavenSettings::miscNoAds = v; }];
            y = [self addToggle:@"Panic Key" detail:@"Existing Raven panic state" value:RavenSettings::miscPanicKey y:y setter:^(BOOL v){ RavenSettings::miscPanicKey = v; }];
            y = [self addToggle:@"Hide When Closed" detail:@"Keep only Raven open button visible" value:RavenSettings::miscHideWhenClosed y:y setter:^(BOOL v){ RavenSettings::miscHideWhenClosed = v; }];
            y = [self addSlider:@"Menu Opacity" value:RavenSettings::miscMenuOpacity min:0.35 max:1.0 format:@"%.2f" y:y setter:^(float v){ RavenSettings::miscMenuOpacity = v; self.panel.alpha = v; }];
            break;
        }

        case 5: {
            y = [self addSection:@"INTERFACE" y:y];
            y = [self addSlider:@"Menu Scale" value:RavenSettings::menuScale min:0.82 max:1.15 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::menuScale = v; [self layoutForCurrentScreen]; }];
            y = [self addToggle:@"Animations" detail:@"Panel and control transitions" value:RavenSettings::animations y:y setter:^(BOOL v){ RavenSettings::animations = v; }];
            y = [self addSelector:@"Accent" items:@[@"Raven", @"Dark", @"Mono"] selected:MIN(MAX(RavenSettings::uiAccentColor, 0), 2) y:y setter:^(NSInteger v){ RavenSettings::uiAccentColor = (int)v; }];
            y = [self addSelector:@"Open Button" items:@[@"Ball", @"Compact", @"Hidden"] selected:MIN(MAX(RavenSettings::uiOpenButton, 0), 2) y:y setter:^(NSInteger v){ RavenSettings::uiOpenButton = (int)v; self.ball.hidden = (v == 2); }];
            y = [self addSelector:@"Position" items:@[@"Left", @"Center", @"Right"] selected:MIN(MAX(RavenSettings::uiPosition, 0), 2) y:y setter:^(NSInteger v){ RavenSettings::uiPosition = (int)v; }];
            y = [self addSection:@"MAINTENANCE" y:y];
            y = [self addAction:@"RESET RAVEN SETTINGS" destructive:YES y:y selector:@selector(resetPressed)];
            y = [self addAction:@"HIDE MENU" destructive:NO y:y selector:@selector(hidePressed)];
            break;
        }
    }

    self.content.contentSize = CGSizeMake(self.content.bounds.size.width, y + 20);
}

@end
