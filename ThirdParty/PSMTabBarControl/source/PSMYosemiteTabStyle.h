//
//  PSMYosemiteTabStyle.h
//  PSMTabBarControl
//
//  Created by John Pannell on 2/17/06.
//  Copyright 2006 Positive Spin Media. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PSMTabStyle.h"
#import "PSMTabBarControl.h"

@interface NSColor (HSP)
@property (nonatomic, readonly) CGFloat it_hspBrightness;
@end

@interface PSMYosemiteTabStyle : NSObject<NSCoding, PSMTabStyle>

@property(nonatomic, readonly) NSColor *tabBarColor;

#pragma mark - For subclasses

- (NSColor *)topLineColorSelected:(BOOL)selected;
- (BOOL)anyTabHasColor;
- (CGFloat)tabColorBrightness:(PSMTabBarCell *)cell;

@end
