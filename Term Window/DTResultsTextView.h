//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

@import Cocoa;

@interface DTResultsTextView : NSTextView 

@property (nonatomic) BOOL disableAntialiasing;

- (NSSize)minSizeForContent;
- (CGFloat)desiredHeightChange;
- (void)dtSizeToFit;

@end
