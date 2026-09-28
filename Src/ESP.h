#ifndef RAVEN_ESP_H
#define RAVEN_ESP_H
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "Common.h"

@interface RavenESP : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CAShapeLayer *boxes;
@property (nonatomic, strong) CAShapeLayer *lines;
@property (nonatomic, strong) CAShapeLayer *guides;
@property (nonatomic, strong) CATextLayer  *labels;

+ (instancetype)shared;
- (void)attach;
- (void)attachToScene;
- (void)begin;
- (void)end;
- (void)render;
- (NSArray<NSString*>*)snapshotPlayerRows;

- (void)drawBox:(CGRect)r color:(UIColor*)c;
- (void)drawCornerBox:(CGRect)r color:(UIColor*)c;
- (void)drawRoundBox:(CGRect)r color:(UIColor*)c;
- (void)drawHexBox:(CGRect)r color:(UIColor*)c;
- (void)drawGradientBox:(CGRect)r color:(UIColor*)c;
- (void)drawEliteBox:(CGRect)r color:(UIColor*)c;
- (void)drawLine:(CGPoint)a to:(CGPoint)b color:(UIColor*)c;
- (void)drawGuideCircle:(CGPoint)center radius:(CGFloat)radius color:(UIColor*)c;
@end
#endif
