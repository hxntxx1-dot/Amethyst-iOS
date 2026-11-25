#import "ControlJoystick.h"
#import "CustomControlsUtils.h"
#import "../input/ControllerInput.h"
#import "../UIKit+hook.h"
#import "../utils.h"
#include "../glfw_keycodes.h"

/*
 * On-screen joystick.
 *
 * Two modes:
 *  - Classic (default): a fixed stick, same behaviour as upstream Amethyst.
 *  - Floating ("floating": true): Roblox-style dynamic thumbstick. The control's
 *    frame becomes a touch *zone*; the stick appears where the finger lands and
 *    follows the finger when it is dragged past the edge of the ring.
 *
 * Extra optional JSON properties (all optional, upstream layouts keep working):
 *  floating        bool   Roblox-style dynamic stick (default false)
 *  stickSize       float  diameter of the ring in floating mode, dp (default 150)
 *  deadzone        float  0..1, ratio of the radius that does nothing
 *                         (default 0.35 classic / 0.2 floating)
 *  autoSprint      bool   hold the sprint key (Left Ctrl) when the stick is
 *                         pushed forward to the edge (default false)
 *  sprintThreshold float  0..1, how far forward for autoSprint (default 0.9)
 *  thumbColor      int    ARGB colour of the knob (default black classic /
 *                         translucent white floating)
 *  idleOpacity     float  0..1, opacity of the resting stick in floating mode
 *                         (default 0.4, 0 = invisible until touched)
 */

// Left thumbstick directions
#define DIRECTION_NONE -1
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
//#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
//#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7

extern BOOL leftShiftHeld;

extern CGFloat lastXValue; // lastHorizontalValue
extern CGFloat lastYValue; // lastVerticalValue

// From CustomControlsUtils
NSMutableDictionary* createButton(NSString* name, int* keycodes, NSString* dynamicX, NSString* dynamicY, CGFloat width, CGFloat height);

@interface ControlJoystick()
@property(nonatomic) UIView *background, *thumb;
@property(nonatomic) UIButton *fwdLockView;
@property(nonatomic) UILabel *zoneLabel;
@property(nonatomic) CGPoint mCenter;
@property(nonatomic, weak) UITouch *activeTouch;
@property(nonatomic) int lastDirection;
@property(nonatomic) BOOL sprintHeld;
@end

@implementation ControlJoystick

+ (id)buttonWithProperties:(NSMutableDictionary *)propArray {
    ControlJoystick *instance = [super buttonWithProperties:propArray];
    instance.clipsToBounds = NO;
    instance.multipleTouchEnabled = NO;
    instance.lastDirection = -2;
    instance.background = [UIView new];
    instance.background.userInteractionEnabled = NO;
    instance.thumb = [UIView new];
    instance.thumb.userInteractionEnabled = NO;
    instance.thumb.backgroundColor = UIColor.blackColor;
    [instance addSubview:instance.background];
    [instance addSubview:instance.thumb];

    instance.zoneLabel = [UILabel new];
    instance.zoneLabel.text = localize(@"custom_controls.joystick.floating_zone", nil);
    instance.zoneLabel.textColor = UIColor.whiteColor;
    instance.zoneLabel.font = [UIFont boldSystemFontOfSize:13];
    instance.zoneLabel.textAlignment = NSTextAlignmentCenter;
    instance.zoneLabel.adjustsFontSizeToFitWidth = YES;
    instance.zoneLabel.userInteractionEnabled = NO;
    instance.zoneLabel.hidden = YES;
    [instance addSubview:instance.zoneLabel];

    if (!isControlModifiable && [propArray[@"forwardLock"] boolValue] && ![propArray[@"floating"] boolValue]) {
        instance.fwdLockView = [UIButton buttonWithType:UIButtonTypeCustom];
        instance.fwdLockView.hidden = YES;
        instance.fwdLockView.imageEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
        instance.fwdLockView.tintColor = UIColor.whiteColor;
        instance.fwdLockView.userInteractionEnabled = NO;
        [instance addSubview:instance.fwdLockView];
    }

    return instance;
}

#pragma mark - Properties helpers

- (BOOL)isFloating {
    return [self.properties[@"floating"] boolValue];
}

- (CGFloat)floatProperty:(NSString *)key fallback:(CGFloat)fallback {
    id value = self.properties[key];
    if ([value isKindOfClass:NSNumber.class]) {
        return [value floatValue];
    }
    return fallback;
}

- (CGFloat)stickSize {
    CGFloat minSize = MIN(self.bounds.size.width, self.bounds.size.height);
    if (![self isFloating]) {
        return minSize;
    }
    CGFloat size = [self floatProperty:@"stickSize" fallback:150.0];
    return MAX(40.0, size);
}

- (CGFloat)thumbSize {
    return [self isFloating] ? [self stickSize] * 0.4 : [self stickSize] / 4.0;
}

- (CGFloat)maxRadius {
    if ([self isFloating]) {
        // Knob centre can travel up to the ring edge, like Roblox
        return [self stickSize] / 2.0;
    }
    return [self stickSize] / 2.0 - [self thumbSize] / 2.0;
}

- (CGFloat)deadzone {
    CGFloat value = [self floatProperty:@"deadzone" fallback:([self isFloating] ? 0.2 : 0.35)];
    return MIN(MAX(value, 0.0), 0.95);
}

- (CGPoint)restCenter {
    if (![self isFloating]) {
        return CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0);
    }
    CGFloat half = [self stickSize] / 2.0;
    CGFloat inset = 24.0;
    CGFloat x = MIN(half + inset, self.bounds.size.width / 2.0);
    CGFloat y = MAX(self.bounds.size.height - half - inset, self.bounds.size.height / 2.0);
    return CGPointMake(x, y);
}

- (void)setStickActive:(BOOL)active {
    if (![self isFloating]) {
        self.background.alpha = self.thumb.alpha = 1.0;
        return;
    }
    CGFloat idle = MIN(MAX([self floatProperty:@"idleOpacity" fallback:0.4], 0.0), 1.0);
    CGFloat alpha = (active || isControlModifiable) ? 1.0 : idle;
    self.background.alpha = self.thumb.alpha = alpha;
}

#pragma mark - Touch handling

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable) return;
    if (self.activeTouch != nil) return; // already driven by another finger

    UITouch *touch = touches.anyObject;
    if (touch.view != self) return;
    self.activeTouch = touch;

    CGPoint location = [touch locationInView:self];
    if ([self isFloating]) {
        // Spawn the stick under the finger
        self.mCenter = location;
        self.background.center = self.mCenter;
        self.thumb.center = self.mCenter;
        [self setStickActive:YES];
    } else {
        self.thumb.center = location;
        if (isGrabbing && self.fwdLockView) {
            self.fwdLockView.center = CGPointMake(self.mCenter.x, -self.mCenter.y);
        }
    }
    [self handleTouchAt:location];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable) return;
    if (self.activeTouch == nil || ![touches containsObject:self.activeTouch]) return;
    [self handleTouchAt:[self.activeTouch locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable) return;
    if (self.activeTouch == nil || ![touches containsObject:self.activeTouch]) return;
    CGPoint location = [self.activeTouch locationInView:self];
    self.activeTouch = nil;
    lastXValue = lastYValue = 0;

    if (isGrabbing && self.fwdLockView && !self.fwdLockView.hidden &&
        CGRectContainsPoint(self.fwdLockView.frame, location)) {
        // Forward lock: keep walking forward
        self.thumb.center = self.fwdLockView.center;
        return;
    }
    [self resetStick];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable) return;
    if (self.activeTouch == nil || ![touches containsObject:self.activeTouch]) return;
    self.activeTouch = nil;
    lastXValue = lastYValue = 0;
    [self resetStick];
}

- (void)resetStick {
    [self applyDirection:DIRECTION_NONE sprint:NO];
    self.mCenter = [self restCenter];
    self.background.center = self.mCenter;
    self.thumb.center = self.mCenter;
    [self setStickActive:NO];
}

- (void)handleTouchAt:(CGPoint)location {
    CGFloat maxRadius = MAX([self maxRadius], 1.0);
    CGFloat dirX = location.x - self.mCenter.x;
    CGFloat dirY = location.y - self.mCenter.y;
    CGFloat radius = sqrt(dirX*dirX + dirY*dirY);

    if (radius > maxRadius) {
        if ([self isFloating]) {
            // Drag the whole stick along with the finger
            CGPoint center = self.mCenter;
            center.x = location.x - dirX * maxRadius / radius;
            center.y = location.y - dirY * maxRadius / radius;
            self.mCenter = center;
            self.background.center = center;
        }
        dirX = dirX * maxRadius / radius;
        dirY = dirY * maxRadius / radius;
        radius = maxRadius;
    }
    self.thumb.center = CGPointMake(self.mCenter.x + dirX, self.mCenter.y + dirY);

    // Normalised -1..1, Y up
    CGFloat xValue = dirX / maxRadius;
    CGFloat yValue = -dirY / maxRadius;
    CGFloat magnitude = radius / maxRadius;

    if (!isGrabbing) {
        // In menus the stick moves the virtual mouse
        [self applyDirection:DIRECTION_NONE sprint:NO];
        lastXValue = xValue;
        lastYValue = yValue;
        return;
    }

    if (magnitude < [self deadzone]) {
        // Back in the dead zone: release every key
        [self applyDirection:DIRECTION_NONE sprint:NO];
        return;
    }

    CGFloat degree = atan2(yValue, xValue) * (180.0 / M_PI);
    if (degree < 0) {
        degree += 360;
    }
    int direction = (int)((degree + 22.5) / 45.0) % 8;

    BOOL sprint = NO;
    if ([self.properties[@"autoSprint"] boolValue]) {
        CGFloat threshold = [self floatProperty:@"sprintThreshold" fallback:0.9];
        sprint = magnitude >= threshold &&
            direction >= DIRECTION_NORTH_EAST && direction <= DIRECTION_NORTH_WEST;
    }
    [self applyDirection:direction sprint:sprint];
}

- (void)applyDirection:(int)direction sprint:(BOOL)sprint {
    int mod = leftShiftHeld ? GLFW_MOD_SHIFT : 0;

    if (self.lastDirection != direction) {
        BOOL none = direction == DIRECTION_NONE;
        // Update WASD states
        CallbackBridge_nativeSendKey(GLFW_KEY_W, 0,
            !none &&
            direction >= DIRECTION_NORTH_EAST &&
            direction <= DIRECTION_NORTH_WEST,
            mod);
        CallbackBridge_nativeSendKey(GLFW_KEY_A, 0,
            !none &&
            direction >= DIRECTION_NORTH_WEST &&
            direction <= DIRECTION_SOUTH_WEST,
            mod);
        CallbackBridge_nativeSendKey(GLFW_KEY_S, 0,
            !none &&
            direction >= DIRECTION_SOUTH_WEST &&
            direction <= DIRECTION_SOUTH_EAST,
            mod);
        CallbackBridge_nativeSendKey(GLFW_KEY_D, 0,
            !none && (
            direction == DIRECTION_SOUTH_EAST ||
            direction == DIRECTION_EAST ||
            direction == DIRECTION_NORTH_EAST),
            mod);

        self.fwdLockView.hidden = direction != DIRECTION_NORTH;
        self.lastDirection = direction;
    }

    if (self.sprintHeld != sprint) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_CONTROL, 0, sprint, mod);
        self.sprintHeld = sprint;
    }
}

#pragma mark - Layout

- (void)setFrame:(CGRect)frame {
    if (![self isFloating]) {
        // Keep the frame square
        if (self.frame.size.width != frame.size.width) {
            frame.size.height = frame.size.width;
        } else if (self.frame.size.height != frame.size.height) {
            frame.size.width = frame.size.height;
        }
    }

    [super setFrame:frame];
    [self layoutStick];
}

- (void)layoutStick {
    CGFloat stickSize = [self stickSize];
    CGFloat thumbSize = [self thumbSize];

    if (self.fwdLockView) {
        self.fwdLockView.frame = CGRectMake(0, 0, stickSize/4, stickSize/4);
        [self.fwdLockView setImage:[UIImage systemImageNamed:@"lock"] forState:UIControlStateNormal];
        self.fwdLockView.layer.cornerRadius = self.fwdLockView.frame.size.width/2;
    }

    self.thumb.frame = CGRectMake(0, 0, thumbSize, thumbSize);
    self.thumb.layer.cornerRadius = thumbSize/2;

    CGFloat bgSize = [self isFloating] ? stickSize :
        stickSize - thumbSize + self.background.layer.borderWidth/2;
    self.background.frame = CGRectMake(0, 0, bgSize, bgSize);
    self.background.layer.cornerRadius = bgSize/2;

    if (self.activeTouch == nil) {
        self.mCenter = [self restCenter];
    }
    self.background.center = self.mCenter;
    self.thumb.center = self.mCenter;

    self.zoneLabel.frame = CGRectMake(8, 8, MAX(self.bounds.size.width - 16, 0), 20);
}

- (void)update {
    NSAssert(self.superview != nil, @"should not be nil");

    self.displayInGame = [self.properties[@"displayInGame"] boolValue];
    self.displayInMenu = [self.properties[@"displayInMenu"] boolValue];

    // net/kdt/pojavlaunch/customcontrols/ControlData.update()
    [self preProcessProperties];

    BOOL floating = [self isFloating];
    NSString *propDynamicX = (NSString *) self.properties[@"dynamicX"];
    NSString *propDynamicY = (NSString *) self.properties[@"dynamicY"];

    CGFloat propW = [self.properties[@"width"] floatValue];
    CGFloat propH = [self.properties[@"height"] floatValue];
    float propStrokeWidth = [self.properties[@"strokeWidth"] floatValue];
    int propBackgroundColor = [self.properties[@"bgColor"] intValue];
    int propStrokeColor = [self.properties[@"strokeColor"] intValue];

    self.background.backgroundColor = self.fwdLockView.backgroundColor = convertARGB2UIColor(propBackgroundColor);
    self.background.layer.borderColor = [convertARGB2UIColor(propStrokeColor) CGColor];
    self.background.layer.borderWidth = propStrokeWidth + (floating ? 2 : 1);

    if (self.properties[@"thumbColor"]) {
        self.thumb.backgroundColor = convertARGB2UIColor([self.properties[@"thumbColor"] intValue]);
    } else {
        self.thumb.backgroundColor = floating ?
            [UIColor colorWithWhite:1.0 alpha:0.85] : UIColor.blackColor;
    }

    // Calculate dynamic position
    CGFloat propX = [self calculateDynamicPos:propDynamicX];
    CGFloat propY = [self calculateDynamicPos:propDynamicY];

    // Update other properties
    self.frame = CGRectMake(propX, propY, propW, propH);
    self.alpha = [self.properties[@"opacity"] floatValue];
    self.alpha = MAX(self.alpha, isControlModifiable ? 0.1 : 0.01);

    if (floating) {
        // The zone itself is invisible while playing, outlined while editing
        self.backgroundColor = isControlModifiable ?
            [UIColor colorWithWhite:1.0 alpha:0.12] : UIColor.clearColor;
        self.layer.borderWidth = isControlModifiable ? 1.5 : 0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
        self.layer.cornerRadius = 12.0;
        self.zoneLabel.hidden = !isControlModifiable;
        // The zone is large: keep it behind every button so that buttons
        // overlapping it (e.g. an opened drawer) still receive their taps
        if (self.superview.subviews.firstObject != self) {
            [self.superview sendSubviewToBack:self];
        }
    } else {
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderWidth = 0;
        self.layer.cornerRadius = MIN(self.frame.size.width, self.frame.size.height) / 2.0;
        self.zoneLabel.hidden = YES;
    }
    [self setStickActive:self.activeTouch != nil];
}

@end
