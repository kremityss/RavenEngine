#ifndef RAVEN_MENU_H
#define RAVEN_MENU_H
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface RavenWindow : UIWindow
@end

@interface RavenMenu : NSObject
+ (instancetype)shared;
- (void)start;
- (void)setVisible:(BOOL)v;
- (BOOL)isPanelOpen;
@end

@interface RVToggle : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^onChange)(BOOL);
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface RVSlider : UIView
@property (nonatomic, assign) float value;
@property (nonatomic, assign) float minValue;
@property (nonatomic, assign) float maxValue;
@property (nonatomic, copy) void (^onChange)(float);
@end

@interface RVSelector : UIView
@property (nonatomic, copy) NSArray<NSString*>* items;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) void (^onChange)(NSInteger);
- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected;
@end

#endif
