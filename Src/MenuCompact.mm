#import "Menu.h"
#import "Common.h"
#import "Logos.h"
#import "Settings.h"
#import <objc/runtime.h>

// RavenEngine compact menu.
// Presentation-only: controls write RavenSettings values already consumed by
// RavenAimbot / RavenESP. Controls without a live runtime consumer are omitted.

static UIColor* RVColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}
static UIColor* RVBg(void)      { return RVColor(0.022, 0.024, 0.030, 0.985); }
static UIColor* RVPanel(void)   { return RVColor(0.036, 0.039, 0.047, 0.995); }
static UIColor* RVCard(void)    { return RVColor(0.055, 0.059, 0.070, 1.0); }
static UIColor* RVBorder(void)  { return RVColor(0.13, 0.14, 0.16, 1.0); }
static UIColor* RVText(void)    { return RVColor(0.95, 0.96, 0.98, 1.0); }
static UIColor* RVMuted(void)   { return RVColor(0.53, 0.56, 0.63, 1.0); }
static UIColor* RVAccent(void) {
    switch (RavenSettings::uiAccentColor) {
        case 1: return RVColor(0.36, 0.40, 0.48, 1.0); // graphite
        case 2: return RVColor(0.90, 0.92, 0.96, 1.0); // mono
        default:return RVColor(0.86, 0.09, 0.14, 1.0); // Raven red
    }
}
static UIColor* RVAccentDim(void) {
    UIColor* c = RVAccent();
    CGFloat r=0,g=0,b=0,a=0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return RVColor(r * 0.32, g * 0.32, b * 0.32, 0.95);
}
static CGFloat RVStoredPercent(float raw, CGFloat fallback) {
    if (!isfinite(raw) || raw <= 0) return fallback;
    return raw <= 1.5f ? raw * 100.0f : raw;
}
static CGFloat RVMenuScale(void) {
    CGFloat raw = RavenSettings::menuScale;
    CGFloat scale = raw > 2.0 ? raw / 100.0 : raw;
    if (!isfinite(scale)) scale = 1.0;
    return MIN(1.0, MAX(0.68, scale));
}
static CGFloat RVMenuOpacity(void) {
    return MIN(1.0, MAX(0.35, RVStoredPercent(RavenSettings::miscMenuOpacity, 97.0) / 100.0));
}
static UIWindowScene* RVActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene*)s;
        for (UIScene* s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene*)s;
    }
    return nil;
}
static void RVLoadImage(const char* rawURL, void (^completion)(UIImage*)) {
    if (!rawURL || !*rawURL) { if (completion) completion(nil); return; }
    NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:rawURL]];
    if (!url) { if (completion) completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        (void)response;
        UIImage* image = (!error && data.length) ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(image); });
    }] resume];
}

typedef void (^RVBoolSetter)(BOOL);
typedef void (^RVFloatSetter)(float);
typedef void (^RVIntSetter)(NSInteger);
static const void* kSetter = &kSetter;
static const void* kValueLabel = &kValueLabel;
static const void* kFormat = &kFormat;

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
        CGPoint p = [panel convertPoint:point fromView:self];
        if ([panel pointInside:p withEvent:event]) return [panel hitTest:p withEvent:event];
    }
    if (ball && !ball.hidden && ball.alpha > 0.01) {
        CGPoint p = [ball convertPoint:point fromView:self];
        if ([ball pointInside:p withEvent:event]) return [ball hitTest:p withEvent:event];
    }
    return nil;
}
@end

@implementation RVToggle { UISwitch* _switch; }
- (instancetype)init { if ((self=[super initWithFrame:CGRectMake(0,0,48,28)])) { _switch=[UISwitch new]; _switch.transform=CGAffineTransformMakeScale(.76,.76); [_switch addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_switch]; } return self; }
- (void)layoutSubviews { [super layoutSubviews]; _switch.center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds)); }
- (void)changed:(UISwitch*)s { _on=s.on; if (_onChange) _onChange(_on); }
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)animated { _on=on; [_switch setOn:on animated:animated]; }
@end
@implementation RVSlider { UISlider* _slider; }
- (instancetype)init { if ((self=[super initWithFrame:CGRectMake(0,0,180,28)])) { _slider=[[UISlider alloc] initWithFrame:self.bounds]; [_slider addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_slider]; } return self; }
- (void)layoutSubviews { [super layoutSubviews]; _slider.frame=self.bounds; }
- (void)setMinValue:(float)v { _minValue=v; _slider.minimumValue=v; }
- (void)setMaxValue:(float)v { _maxValue=v; _slider.maximumValue=v; }
- (void)setValue:(float)v { _value=v; _slider.value=v; }
- (void)changed:(UISlider*)s { _value=s.value; if (_onChange) _onChange(_value); }
@end
@implementation RVSelector { UISegmentedControl* _seg; }
- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected { if ((self=[super initWithFrame:CGRectMake(0,0,220,28)])) { _items=[items copy]; _seg=[[UISegmentedControl alloc] initWithItems:_items]; _seg.selectedSegmentIndex=selected; [_seg addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_seg]; } return self; }
- (void)layoutSubviews { [super layoutSubviews]; _seg.frame=self.bounds; }
- (void)setSelectedIndex:(NSInteger)v { _selectedIndex=v; _seg.selectedSegmentIndex=v; }
- (void)changed:(UISegmentedControl*)s { _selectedIndex=s.selectedSegmentIndex; if (_onChange) _onChange(_selectedIndex); }
@end

@interface RavenMenu ()
@property(nonatomic,strong) RavenWindow* window;
@property(nonatomic,strong) UIViewController* rootController;
@property(nonatomic,strong) UIView* panel;
@property(nonatomic,strong) UIButton* ball;
@property(nonatomic,strong) UIView* header;
@property(nonatomic,strong) UIView* tabBar;
@property(nonatomic,strong) UIScrollView* content;
@property(nonatomic,strong) UILabel* pageTitle;
@property(nonatomic,strong) NSArray<UIButton*>* tabButtons;
@property(nonatomic,assign) NSInteger selectedTab;
@property(nonatomic,assign) CGPoint dragOrigin;
@property(nonatomic,assign) CGPoint ballDragOrigin;
@property(nonatomic,assign) BOOL started;
@end

@implementation RavenMenu
+ (instancetype)shared { static RavenMenu* s; static dispatch_once_t once; dispatch_once(&once, ^{ s=[RavenMenu new]; }); return s; }

- (UILabel*)label:(NSString*)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor*)color {
    UILabel* l=[UILabel new]; l.text=text; l.textColor=color; l.font=[UIFont systemFontOfSize:size weight:weight]; l.numberOfLines=1; return l;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.started) return;
        self.started=YES;
        self.window=[[RavenWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        if (@available(iOS 13.0,*)) self.window.windowScene=RVActiveScene();
        self.window.windowLevel=UIWindowLevelNormal+3.0;
        self.rootController=[UIViewController new];
        self.rootController.view.backgroundColor=UIColor.clearColor;
        self.window.rootViewController=self.rootController;
        self.window.hidden=NO;
        [self buildBall];
        [self buildPanel];
        [self layoutForCurrentScreen];
        [self selectTab:0];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    });
}

- (void)buildBall {
    self.ball=[UIButton buttonWithType:UIButtonTypeCustom];
    self.ball.backgroundColor=RVPanel();
    self.ball.layer.borderWidth=1.0;
    self.ball.layer.shadowColor=UIColor.blackColor.CGColor;
    self.ball.layer.shadowOpacity=.45;
    self.ball.layer.shadowRadius=8;
    self.ball.layer.shadowOffset=CGSizeMake(0,3);
    self.ball.imageView.contentMode=UIViewContentModeScaleAspectFit;
    [self.ball setTitle:@"R" forState:UIControlStateNormal];
    [self.ball setTitleColor:RVText() forState:UIControlStateNormal];
    self.ball.titleLabel.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBlack];
    [self.ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer* pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    [self.ball addGestureRecognizer:pan];
    [self.rootController.view addSubview:self.ball];
    RVLoadImage(kBallLogoURL, ^(UIImage* image){ if (image) { [self.ball setTitle:nil forState:UIControlStateNormal]; [self.ball setImage:image forState:UIControlStateNormal]; }});
}

- (void)buildPanel {
    self.panel=[[UIView alloc] initWithFrame:CGRectMake(0,0,610,330)];
    self.panel.backgroundColor=RVPanel();
    self.panel.layer.cornerRadius=13;
    self.panel.layer.borderWidth=1;
    self.panel.layer.shadowColor=UIColor.blackColor.CGColor;
    self.panel.layer.shadowOpacity=.55;
    self.panel.layer.shadowRadius=18;
    self.panel.layer.shadowOffset=CGSizeMake(0,8);
    [self.rootController.view addSubview:self.panel];

    self.header=[UIView new]; self.header.backgroundColor=RVBg(); [self.panel addSubview:self.header];
    UIPanGestureRecognizer* drag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)]; [self.header addGestureRecognizer:drag];

    UIView* accent=[UIView new]; accent.tag=9101; [self.header addSubview:accent];
    UILabel* brand=[self label:@"RAVENENGINE" size:15 weight:UIFontWeightBlack color:RVText()]; brand.tag=9102; [self.header addSubview:brand];
    UILabel* sub=[self label:@"COMBAT MASTER • iOS" size:8 weight:UIFontWeightSemibold color:RVMuted()]; sub.tag=9103; [self.header addSubview:sub];
    self.pageTitle=[self label:@"AIM" size:10 weight:UIFontWeightBold color:RVMuted()]; self.pageTitle.textAlignment=NSTextAlignmentRight; [self.header addSubview:self.pageTitle];
    UIButton* close=[UIButton buttonWithType:UIButtonTypeSystem]; close.tag=9105; [close setTitle:@"×" forState:UIControlStateNormal]; [close setTitleColor:RVMuted() forState:UIControlStateNormal]; close.titleLabel.font=[UIFont systemFontOfSize:20 weight:UIFontWeightRegular]; [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside]; [self.header addSubview:close];

    self.tabBar=[UIView new]; self.tabBar.backgroundColor=RVBg(); [self.panel addSubview:self.tabBar];
    NSArray* names=@[@"AIM",@"ESP",@"VISUAL",@"WEAPON",@"MOVE",@"SETTINGS"];
    NSMutableArray* buttons=[NSMutableArray array];
    for (NSInteger i=0;i<names.count;i++) {
        UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=100+i; [b setTitle:names[i] forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:9 weight:UIFontWeightBold]; b.layer.cornerRadius=7; [b addTarget:self action:@selector(tabPressed:) forControlEvents:UIControlEventTouchUpInside]; [self.tabBar addSubview:b]; [buttons addObject:b];
    }
    self.tabButtons=buttons;

    self.content=[UIScrollView new]; self.content.backgroundColor=RVBg(); self.content.alwaysBounceVertical=YES; self.content.showsVerticalScrollIndicator=YES; self.content.indicatorStyle=UIScrollViewIndicatorStyleWhite; [self.panel addSubview:self.content];
    [self applyTheme];
}

- (void)applyTheme {
    UIColor* accent=RVAccent(); UIColor* dim=RVAccentDim();
    self.panel.layer.borderColor=[accent colorWithAlphaComponent:.42].CGColor;
    UIView* stripe=[self.header viewWithTag:9101]; stripe.backgroundColor=accent;
    self.ball.layer.borderColor=[accent colorWithAlphaComponent:.75].CGColor;
    for (NSInteger i=0;i<self.tabButtons.count;i++) {
        UIButton* b=self.tabButtons[i]; BOOL active=(i==self.selectedTab);
        b.backgroundColor=active?dim:UIColor.clearColor;
        [b setTitleColor:active?RVText():RVMuted() forState:UIControlStateNormal];
        b.layer.borderWidth=active?1:0;
        b.layer.borderColor=active?[accent colorWithAlphaComponent:.38].CGColor:UIColor.clearColor.CGColor;
    }
    for (UIView* card in self.content.subviews) [self applyAccentRecursively:card accent:accent dim:dim];
}
- (void)applyAccentRecursively:(UIView*)view accent:(UIColor*)accent dim:(UIColor*)dim {
    if ([view isKindOfClass:UISwitch.class]) ((UISwitch*)view).onTintColor=accent;
    if ([view isKindOfClass:UISlider.class]) { ((UISlider*)view).minimumTrackTintColor=accent; ((UISlider*)view).maximumTrackTintColor=RVBorder(); }
    if ([view isKindOfClass:UISegmentedControl.class]) ((UISegmentedControl*)view).selectedSegmentTintColor=dim;
    for (UIView* child in view.subviews) [self applyAccentRecursively:child accent:accent dim:dim];
}

- (void)orientationChanged:(NSNotification*)note { (void)note; dispatch_async(dispatch_get_main_queue(), ^{ [self layoutForCurrentScreen]; [self renderSelectedTab]; }); }

- (void)layoutForCurrentScreen {
    if (!self.panel) return;
    CGRect bounds=self.rootController.view.bounds;
    self.window.frame=UIScreen.mainScreen.bounds;
    CGFloat scale=RVMenuScale();
    CGFloat maxW=MAX(360.0,bounds.size.width-40.0), maxH=MAX(210.0,bounds.size.height-30.0);
    CGFloat w=MIN(610.0*scale,maxW), h=MIN(330.0*scale,maxH);
    w=MAX(390.0,MIN(w,maxW)); h=MAX(220.0,MIN(h,maxH));

    CGFloat x=(bounds.size.width-w)*.5;
    if (RavenSettings::uiPosition==1) x=20.0;
    else if (RavenSettings::uiPosition==2) x=bounds.size.width-w-20.0;
    x=MAX(8.0,MIN(x,bounds.size.width-w-8.0));
    CGFloat y=MAX(8.0,(bounds.size.height-h)*.5);
    self.panel.frame=CGRectMake(x,y,w,h);
    self.panel.alpha=RVMenuOpacity();

    CGFloat headerH=46.0, tabsH=38.0;
    self.header.frame=CGRectMake(0,0,w,headerH);
    self.tabBar.frame=CGRectMake(0,headerH,w,tabsH);
    self.content.frame=CGRectMake(0,headerH+tabsH,w,h-headerH-tabsH);
    [self.header viewWithTag:9101].frame=CGRectMake(14,13,3,20);
    [self.header viewWithTag:9102].frame=CGRectMake(25,7,170,20);
    [self.header viewWithTag:9103].frame=CGRectMake(25,26,170,12);
    UIButton* close=(UIButton*)[self.header viewWithTag:9105]; close.frame=CGRectMake(w-38,9,28,28);
    self.pageTitle.frame=CGRectMake(MAX(190,w-160),13,110,18);

    CGFloat gap=5.0, side=10.0;
    CGFloat bw=(w-side*2-gap*5)/6.0;
    for (NSInteger i=0;i<self.tabButtons.count;i++) self.tabButtons[i].frame=CGRectMake(side+i*(bw+gap),5,bw,28);

    [self applyBallStyle];
}

- (void)applyBallStyle {
    CGRect bounds=self.rootController.view.bounds;
    CGFloat size=RavenSettings::uiOpenButton==1?38.0:48.0;
    if (RavenSettings::uiOpenButton==2) { self.ball.hidden=YES; return; }
    self.ball.hidden=NO;
    CGPoint c=self.ball.center;
    if (CGPointEqualToPoint(c,CGPointZero)) c=CGPointMake(38,105);
    self.ball.bounds=CGRectMake(0,0,size,size); self.ball.layer.cornerRadius=size*.5; self.ball.contentEdgeInsets=UIEdgeInsetsMake(6,6,6,6);
    c.x=MIN(MAX(size*.5+8,c.x),bounds.size.width-size*.5-8); c.y=MIN(MAX(size*.5+8,c.y),bounds.size.height-size*.5-8); self.ball.center=c;
}

- (void)dragPanel:(UIPanGestureRecognizer*)pan {
    CGPoint t=[pan translationInView:self.rootController.view]; if (pan.state==UIGestureRecognizerStateBegan) self.dragOrigin=self.panel.center;
    CGPoint c=CGPointMake(self.dragOrigin.x+t.x,self.dragOrigin.y+t.y); CGRect b=self.rootController.view.bounds; CGFloat hw=self.panel.bounds.size.width*.5, hh=self.panel.bounds.size.height*.5;
    c.x=MIN(MAX(hw*.65,c.x),b.size.width-hw*.65); c.y=MIN(MAX(hh*.65,c.y),b.size.height-hh*.65); self.panel.center=c;
}
- (void)dragBall:(UIPanGestureRecognizer*)pan {
    CGPoint t=[pan translationInView:self.rootController.view]; if (pan.state==UIGestureRecognizerStateBegan) self.ballDragOrigin=self.ball.center;
    if (pan.state==UIGestureRecognizerStateChanged || pan.state==UIGestureRecognizerStateEnded) { self.ball.center=CGPointMake(self.ballDragOrigin.x+t.x,self.ballDragOrigin.y+t.y); [self applyBallStyle]; }
}

- (void)togglePanel {
    BOOL opening=self.panel.hidden; self.panel.hidden=NO; CGFloat target=RVMenuOpacity();
    if (!RavenSettings::animations) { self.panel.alpha=opening?target:0; self.panel.hidden=!opening; if (!opening) self.panel.alpha=target; return; }
    if (opening) { self.panel.alpha=0; self.panel.transform=CGAffineTransformMakeScale(.97,.97); [UIView animateWithDuration:.16 animations:^{ self.panel.alpha=target; self.panel.transform=CGAffineTransformIdentity; }]; }
    else { [UIView animateWithDuration:.13 animations:^{ self.panel.alpha=0; self.panel.transform=CGAffineTransformMakeScale(.98,.98); } completion:^(BOOL done){ (void)done; self.panel.hidden=YES; self.panel.alpha=target; self.panel.transform=CGAffineTransformIdentity; }]; }
}
- (void)closePanel { if (!self.panel.hidden) [self togglePanel]; }
- (BOOL)isPanelOpen { return self.started && self.panel && !self.panel.hidden; }
- (void)setVisible:(BOOL)v { dispatch_async(dispatch_get_main_queue(), ^{ self.window.hidden=!v; }); }
- (void)tabPressed:(UIButton*)sender { [self selectTab:sender.tag-100]; }
- (void)selectTab:(NSInteger)index {
    if (index<0 || index>=self.tabButtons.count) return; self.selectedTab=index;
    NSArray* titles=@[@"AIM",@"ESP",@"VISUAL",@"WEAPON",@"MOVEMENT",@"SETTINGS"]; self.pageTitle.text=titles[index];
    [self renderSelectedTab]; [self applyTheme];
}
- (void)clearContent { for (UIView* v in self.content.subviews) [v removeFromSuperview]; }

- (CGFloat)addSection:(NSString*)title y:(CGFloat)y {
    UILabel* l=[self label:title size:9 weight:UIFontWeightBold color:RVMuted()]; l.frame=CGRectMake(12,y,self.content.bounds.size.width-24,16); [self.content addSubview:l]; return y+21;
}
- (UIView*)cardAtY:(CGFloat)y h:(CGFloat)h {
    UIView* c=[[UIView alloc] initWithFrame:CGRectMake(12,y,MAX(250,self.content.bounds.size.width-24),h)]; c.backgroundColor=RVCard(); c.layer.cornerRadius=9; c.layer.borderWidth=1; c.layer.borderColor=[RVBorder() colorWithAlphaComponent:.75].CGColor; [self.content addSubview:c]; return c;
}
- (CGFloat)addToggle:(NSString*)title detail:(NSString*)detail value:(BOOL)value y:(CGFloat)y setter:(RVBoolSetter)setter {
    UIView* c=[self cardAtY:y h:48]; UILabel* t=[self label:title size:11 weight:UIFontWeightSemibold color:RVText()]; t.frame=CGRectMake(12,detail.length?7:14,c.bounds.size.width-72,17); [c addSubview:t];
    if (detail.length) { UILabel* d=[self label:detail size:8 weight:UIFontWeightRegular color:RVMuted()]; d.frame=CGRectMake(12,25,c.bounds.size.width-72,12); [c addSubview:d]; }
    UISwitch* s=[UISwitch new]; s.on=value; s.transform=CGAffineTransformMakeScale(.70,.70); s.center=CGPointMake(c.bounds.size.width-29,24); objc_setAssociatedObject(s,kSetter,[setter copy],OBJC_ASSOCIATION_COPY_NONATOMIC); [s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged]; [c addSubview:s]; return y+54;
}
- (CGFloat)addSlider:(NSString*)title value:(float)value min:(float)min max:(float)max format:(NSString*)format y:(CGFloat)y setter:(RVFloatSetter)setter {
    UIView* c=[self cardAtY:y h:58]; UILabel* t=[self label:title size:10.5 weight:UIFontWeightSemibold color:RVText()]; t.frame=CGRectMake(12,6,c.bounds.size.width*.60,16); [c addSubview:t]; UILabel* v=[self label:[NSString stringWithFormat:format,value] size:10 weight:UIFontWeightBold color:RVAccent()]; v.textAlignment=NSTextAlignmentRight; v.frame=CGRectMake(c.bounds.size.width-100,6,88,16); [c addSubview:v];
    UISlider* s=[[UISlider alloc] initWithFrame:CGRectMake(12,27,c.bounds.size.width-24,24)]; s.minimumValue=min; s.maximumValue=max; s.value=MIN(max,MAX(min,value)); objc_setAssociatedObject(s,kSetter,[setter copy],OBJC_ASSOCIATION_COPY_NONATOMIC); objc_setAssociatedObject(s,kValueLabel,v,OBJC_ASSOCIATION_ASSIGN); objc_setAssociatedObject(s,kFormat,format,OBJC_ASSOCIATION_COPY_NONATOMIC); [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [c addSubview:s]; return y+64;
}
- (CGFloat)addSelector:(NSString*)title items:(NSArray<NSString*>*)items selected:(NSInteger)selected y:(CGFloat)y setter:(RVIntSetter)setter {
    UIView* c=[self cardAtY:y h:66]; UILabel* t=[self label:title size:10.5 weight:UIFontWeightSemibold color:RVText()]; t.frame=CGRectMake(12,6,c.bounds.size.width-24,16); [c addSubview:t]; UISegmentedControl* s=[[UISegmentedControl alloc] initWithItems:items]; s.frame=CGRectMake(10,28,c.bounds.size.width-20,27); if (selected>=0 && selected<items.count) s.selectedSegmentIndex=selected; [s setTitleTextAttributes:@{NSForegroundColorAttributeName:RVMuted(),NSFontAttributeName:[UIFont systemFontOfSize:8 weight:UIFontWeightSemibold]} forState:UIControlStateNormal]; [s setTitleTextAttributes:@{NSForegroundColorAttributeName:RVText(),NSFontAttributeName:[UIFont systemFontOfSize:8 weight:UIFontWeightBold]} forState:UIControlStateSelected]; objc_setAssociatedObject(s,kSetter,[setter copy],OBJC_ASSOCIATION_COPY_NONATOMIC); [s addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged]; [c addSubview:s]; return y+72;
}
- (CGFloat)addAction:(NSString*)title destructive:(BOOL)destructive y:(CGFloat)y selector:(SEL)selector {
    UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; b.frame=CGRectMake(12,y,MAX(250,self.content.bounds.size.width-24),38); b.backgroundColor=destructive?[RVAccentDim() colorWithAlphaComponent:.7]:RVCard(); b.layer.cornerRadius=9; b.layer.borderWidth=1; b.layer.borderColor=(destructive?[RVAccent() colorWithAlphaComponent:.5]:RVBorder()).CGColor; [b setTitle:title forState:UIControlStateNormal]; [b setTitleColor:destructive?RVText():RVMuted() forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightBold]; [b addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside]; [self.content addSubview:b]; return y+44;
}
- (void)switchChanged:(UISwitch*)s { RVBoolSetter setter=objc_getAssociatedObject(s,kSetter); if (setter) setter(s.on); RavenSettings::save(); }
- (void)sliderChanged:(UISlider*)s { RVFloatSetter setter=objc_getAssociatedObject(s,kSetter); if (setter) setter(s.value); UILabel* l=objc_getAssociatedObject(s,kValueLabel); NSString* f=objc_getAssociatedObject(s,kFormat)?:@"%.1f"; l.text=[NSString stringWithFormat:f,s.value]; l.textColor=RVAccent(); RavenSettings::save(); }
- (void)segmentChanged:(UISegmentedControl*)s { RVIntSetter setter=objc_getAssociatedObject(s,kSetter); if (setter) setter(s.selectedSegmentIndex); RavenSettings::save(); }
- (void)resetPressed { RavenSettings::resetToDefaults(); RavenSettings::save(); [self layoutForCurrentScreen]; [self renderSelectedTab]; [self applyTheme]; }
- (void)hidePressed { [self closePanel]; }

- (void)renderSelectedTab {
    [self clearContent]; CGFloat y=10; __weak RavenMenu* weakSelf=self;
    switch (self.selectedTab) {
        case 0: {
            y=[self addSection:@"AIM ASSIST" y:y];
            y=[self addToggle:@"Enable Aim" detail:@"Master target-assist state" value:RavenSettings::aimEnabled y:y setter:^(BOOL v){ RavenSettings::aimEnabled=v; }];
            y=[self addSelector:@"Activation" items:@[@"Always",@"ADS"] selected:(RavenSettings::aimActivation==1?1:0) y:y setter:^(NSInteger v){ RavenSettings::aimActivation=(int)v; }];
            y=[self addSelector:@"Aim Bone" items:@[@"Head",@"Chest"] selected:(RavenSettings::aimBone==0?0:1) y:y setter:^(NSInteger v){ RavenSettings::aimBone=(int)v; }];
            y=[self addSlider:@"FOV" value:RavenSettings::aimFov min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::aimFov=v; }];
            y=[self addSlider:@"Smooth" value:RavenSettings::aimSmooth min:1 max:20 format:@"%.1f" y:y setter:^(float v){ RavenSettings::aimSmooth=v; }];
            y=[self addSlider:@"Strength" value:RavenSettings::aimStrength min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::aimStrength=v; }];
            y=[self addSlider:@"Max Distance" value:RavenSettings::aimMaxDist min:20 max:1000 format:@"%.0fm" y:y setter:^(float v){ RavenSettings::aimMaxDist=v; }];
            y=[self addToggle:@"Prediction" detail:@"Lead targets using movement velocity" value:RavenSettings::aimPrediction y:y setter:^(BOOL v){ RavenSettings::aimPrediction=v; }];
            if (RavenSettings::aimPrediction) {
                y=[self addSlider:@"Prediction Strength" value:RavenSettings::aimPredictionStrength min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::aimPredictionStrength=v; }];
                y=[self addSlider:@"Prediction Velocity" value:RavenSettings::aimPredictionVelocity min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::aimPredictionVelocity=v; }];
            }
            y=[self addSlider:@"Acceleration" value:RavenSettings::aimAcceleration min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::aimAcceleration=v; }];
            y=[self addSlider:@"Switch Delay" value:RavenSettings::aimSwitchDelay min:0 max:500 format:@"%.0fms" y:y setter:^(float v){ RavenSettings::aimSwitchDelay=v; }];
            y=[self addToggle:@"Visibility Check" detail:@"Ignore non-visible targets" value:RavenSettings::aimVisCheck y:y setter:^(BOOL v){ RavenSettings::aimVisCheck=v; }];
            y=[self addToggle:@"Ignore Teammates" detail:@"Never select same-team players" value:RavenSettings::aimIgnoreTeammates y:y setter:^(BOOL v){ RavenSettings::aimIgnoreTeammates=v; }];
            y=[self addToggle:@"Dynamic FOV" detail:@"Adapt target region with distance" value:RavenSettings::aimDynamicFov y:y setter:^(BOOL v){ RavenSettings::aimDynamicFov=v; }];
            y=[self addSection:@"GYRO PATH" y:y];
            y=[self addToggle:@"Gyro Aim" detail:@"Use gyro-specific tuning path" value:RavenSettings::gyroEnabled y:y setter:^(BOOL v){ RavenSettings::gyroEnabled=v; }];
            y=[self addSlider:@"Gyro FOV" value:RavenSettings::gyroFov min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::gyroFov=v; }];
            y=[self addSlider:@"Gyro Smooth" value:RavenSettings::gyroSmooth min:1 max:20 format:@"%.1f" y:y setter:^(float v){ RavenSettings::gyroSmooth=v; }];
            y=[self addSelector:@"Gyro Curve" items:@[@"Linear",@"Precision",@"Aggressive"] selected:MIN(MAX(RavenSettings::gyroCurve,0),2) y:y setter:^(NSInteger v){ RavenSettings::gyroCurve=(int)v; }];
            y=[self addSlider:@"Stabilizer" value:RavenSettings::gyroStabilizer min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::gyroStabilizer=v; }];
            y=[self addSlider:@"Micro Correction" value:RavenSettings::gyroMicroCorrection min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::gyroMicroCorrection=v; }];
            y=[self addToggle:@"Low Latency" detail:@"Prefer immediate gyro correction" value:RavenSettings::gyroLowLatency y:y setter:^(BOOL v){ RavenSettings::gyroLowLatency=v; }];
            break;
        }
        case 1: {
            y=[self addSection:@"PLAYER ESP" y:y];
            y=[self addToggle:@"Enable ESP" detail:@"Master overlay state" value:RavenSettings::espEnabled y:y setter:^(BOOL v){ RavenSettings::espEnabled=v; }];
            y=[self addToggle:@"Boxes" detail:@"Draw player boxes" value:RavenSettings::espBox y:y setter:^(BOOL v){ RavenSettings::espBox=v; }];
            y=[self addSelector:@"Box Style" items:@[@"Full",@"Hex",@"Round",@"Gradient",@"Elite"] selected:MIN(MAX(RavenSettings::espBoxStyle,0),4) y:y setter:^(NSInteger v){ RavenSettings::espBoxStyle=(int)v; }];
            y=[self addToggle:@"Corner Mode" detail:@"Used by Full box style" value:RavenSettings::espCorner y:y setter:^(BOOL v){ RavenSettings::espCorner=v; }];
            y=[self addSlider:@"Box Scale" value:RavenSettings::espBoxScale min:.7 max:1.8 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::espBoxScale=v; }];
            y=[self addToggle:@"Skeleton" detail:@"Draw resolved bone chain" value:RavenSettings::espSkeleton y:y setter:^(BOOL v){ RavenSettings::espSkeleton=v; }];
            y=[self addToggle:@"Head Dot" detail:@"Mark projected head position" value:RavenSettings::espHeadDot y:y setter:^(BOOL v){ RavenSettings::espHeadDot=v; }];
            y=[self addToggle:@"Snaplines" detail:@"Draw screen-to-player lines" value:RavenSettings::espSnaplines y:y setter:^(BOOL v){ RavenSettings::espSnaplines=v; }];
            y=[self addSelector:@"Snapline Origin" items:@[@"Top",@"Center",@"Bottom"] selected:MIN(MAX(RavenSettings::espSnaplinePosition,0),2) y:y setter:^(NSInteger v){ RavenSettings::espSnaplinePosition=(int)v; }];
            y=[self addToggle:@"Names" detail:@"Display resolved player names" value:RavenSettings::espName y:y setter:^(BOOL v){ RavenSettings::espName=v; }];
            y=[self addToggle:@"Distance" detail:@"Display world distance" value:RavenSettings::espDistance y:y setter:^(BOOL v){ RavenSettings::espDistance=v; }];
            y=[self addToggle:@"Health Text" detail:@"Display HP / armor text" value:RavenSettings::espHealth y:y setter:^(BOOL v){ RavenSettings::espHealth=v; }];
            y=[self addToggle:@"Health Bar" detail:@"Draw health bar" value:RavenSettings::espHealthBar y:y setter:^(BOOL v){ RavenSettings::espHealthBar=v; }];
            y=[self addToggle:@"Armor Bar" detail:@"Draw armor bar" value:RavenSettings::espArmorBar y:y setter:^(BOOL v){ RavenSettings::espArmorBar=v; }];
            y=[self addToggle:@"Visible Only" detail:@"Filter hidden targets" value:RavenSettings::espVisibleOnly y:y setter:^(BOOL v){ RavenSettings::espVisibleOnly=v; }];
            y=[self addToggle:@"Show Teammates" detail:@"Include same-team players" value:RavenSettings::espTeam y:y setter:^(BOOL v){ RavenSettings::espTeam=v; }];
            y=[self addToggle:@"RGB" detail:@"Cycle ESP palette" value:RavenSettings::espRgb y:y setter:^(BOOL v){ RavenSettings::espRgb=v; }];
            break;
        }
        case 2: {
            y=[self addSection:@"GUIDES" y:y];
            y=[self addToggle:@"Crosshair" detail:@"Custom center reticle" value:RavenSettings::visCrosshair y:y setter:^(BOOL v){ RavenSettings::visCrosshair=v; }];
            y=[self addSelector:@"Crosshair Style" items:@[@"Dot",@"Plus",@"Circle",@"T"] selected:MIN(MAX(RavenSettings::visCrosshairStyle,0),3) y:y setter:^(NSInteger v){ RavenSettings::visCrosshairStyle=(int)v; }];
            y=[self addSlider:@"Crosshair Size" value:RavenSettings::visCrosshairSize min:2 max:60 format:@"%.0f" y:y setter:^(float v){ RavenSettings::visCrosshairSize=v; }];
            y=[self addSlider:@"Crosshair Thickness" value:RavenSettings::visCrosshairThickness min:.5 max:8 format:@"%.1f" y:y setter:^(float v){ RavenSettings::visCrosshairThickness=v; }];
            y=[self addToggle:@"Visual FOV Circle" detail:@"Independent visual guide" value:RavenSettings::visFovCircle y:y setter:^(BOOL v){ RavenSettings::visFovCircle=v; }];
            y=[self addSlider:@"Visual FOV Radius" value:RavenSettings::visFovRadius min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::visFovRadius=v; }];
            y=[self addSlider:@"Visual FOV Thickness" value:RavenSettings::visFovThickness min:.5 max:8 format:@"%.1f" y:y setter:^(float v){ RavenSettings::visFovThickness=v; }];
            y=[self addToggle:@"Aim FOV Guide" detail:@"Show aim-region guide" value:RavenSettings::aimShowCircle y:y setter:^(BOOL v){ RavenSettings::aimShowCircle=v; }];
            y=[self addSlider:@"Aim Guide Radius" value:RavenSettings::aimCircleRadius min:10 max:500 format:@"%.0f" y:y setter:^(float v){ RavenSettings::aimCircleRadius=v; }];
            y=[self addSlider:@"Aim Guide Thickness" value:RavenSettings::aimCircleThickness min:.5 max:8 format:@"%.1f" y:y setter:^(float v){ RavenSettings::aimCircleThickness=v; }];
            y=[self addSection:@"CAMERA" y:y];
            y=[self addSlider:@"Camera FOV" value:RavenSettings::visCameraFov min:60 max:140 format:@"%.0f°" y:y setter:^(float v){ RavenSettings::visCameraFov=v; }];
            y=[self addToggle:@"Third Person" detail:@"Switch camera mode through resolved controller" value:RavenSettings::visThirdPerson y:y setter:^(BOOL v){ RavenSettings::visThirdPerson=v; }];
            break;
        }
        case 3: {
            y=[self addSection:@"WEAPON RUNTIME" y:y];
            y=[self addToggle:@"No Recoil" detail:@"Apply resolved recoil control" value:RavenSettings::wpnNoRecoil y:y setter:^(BOOL v){ RavenSettings::wpnNoRecoil=v; }];
            y=[self addSlider:@"Recoil Amount" value:MIN(100.0f,MAX(0.0f,RavenSettings::wpnRecoilStrength*100.0f)) min:0 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::wpnRecoilStrength=v/100.0f; }];
            y=[self addToggle:@"Fast Reload" detail:@"Use resolved reload multiplier" value:RavenSettings::wpnFastReload y:y setter:^(BOOL v){ RavenSettings::wpnFastReload=v; }];
            break;
        }
        case 4: {
            y=[self addSection:@"MOVEMENT RUNTIME" y:y];
            y=[self addToggle:@"Long Slide" detail:@"Keep slide state while grounded/crouched" value:RavenSettings::miscLongSlide y:y setter:^(BOOL v){ RavenSettings::miscLongSlide=v; }];
            float speed=0.5f+MIN(100.0f,MAX(0.0f,RavenSettings::miscPlayerSpeed))*.015f;
            y=[self addSlider:@"Player Speed" value:speed min:.5 max:2.0 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::miscPlayerSpeed=MIN(100.0f,MAX(0.0f,(v-.5f)/.015f)); }];
            break;
        }
        case 5: {
            y=[self addSection:@"COMPACT INTERFACE" y:y];
            y=[self addSlider:@"Menu Size" value:RVMenuScale() min:.68 max:1.0 format:@"%.2fx" y:y setter:^(float v){ RavenSettings::menuScale=v*100.0f; dispatch_async(dispatch_get_main_queue(), ^{ RavenMenu* m=weakSelf; if (m) { [m layoutForCurrentScreen]; [m renderSelectedTab]; [m applyTheme]; }}); }];
            y=[self addSlider:@"Menu Opacity" value:RVStoredPercent(RavenSettings::miscMenuOpacity,97.0) min:35 max:100 format:@"%.0f%%" y:y setter:^(float v){ RavenSettings::miscMenuOpacity=v; RavenMenu* m=weakSelf; if (m) m.panel.alpha=v/100.0f; }];
            y=[self addToggle:@"Animations" detail:@"Compact open / close transitions" value:RavenSettings::animations y:y setter:^(BOOL v){ RavenSettings::animations=v; }];
            y=[self addSelector:@"Accent" items:@[@"Raven",@"Graphite",@"Mono"] selected:MIN(MAX(RavenSettings::uiAccentColor,0),2) y:y setter:^(NSInteger v){ RavenSettings::uiAccentColor=(int)v; dispatch_async(dispatch_get_main_queue(), ^{ RavenMenu* m=weakSelf; if (m) { [m renderSelectedTab]; [m applyTheme]; }}); }];
            y=[self addSelector:@"Open Button" items:@[@"Ball",@"Compact",@"Hidden"] selected:MIN(MAX(RavenSettings::uiOpenButton,0),2) y:y setter:^(NSInteger v){ RavenSettings::uiOpenButton=(int)v; dispatch_async(dispatch_get_main_queue(), ^{ RavenMenu* m=weakSelf; if (m) [m applyBallStyle]; }); }];
            y=[self addSelector:@"Panel Position" items:@[@"Center",@"Left",@"Right"] selected:MIN(MAX(RavenSettings::uiPosition,0),2) y:y setter:^(NSInteger v){ RavenSettings::uiPosition=(int)v; dispatch_async(dispatch_get_main_queue(), ^{ RavenMenu* m=weakSelf; if (m) [m layoutForCurrentScreen]; }); }];
            y=[self addSection:@"MAINTENANCE" y:y];
            y=[self addAction:@"RESET RAVEN SETTINGS" destructive:YES y:y selector:@selector(resetPressed)];
            y=[self addAction:@"HIDE MENU" destructive:NO y:y selector:@selector(hidePressed)];
            break;
        }
    }
    self.content.contentSize=CGSizeMake(self.content.bounds.size.width,y+12); [self applyTheme];
}
@end
