//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "DTResultsTextView.h"

#import "DTTermWindowController.h"

@interface TextStorageCacheEntry : NSObject
@property NSUInteger contentLength;
@property CGFloat computedHeight;
@property NSPoint scrollPosition;
@property NSArray<NSValue*> *selectedRanges;
@end
@implementation TextStorageCacheEntry
@end

@interface DTResultsTextView ()
{
    BOOL validResultsStorage;
    NSTimer* sizeToFitTimer;
    
    BOOL disableAntialiasing;
}

// TODO [?] should be cleared on font change
@property NSMapTable<NSTextStorage*, TextStorageCacheEntry*> *cache;

@end

@implementation DTResultsTextView

@synthesize disableAntialiasing;

+ (void)initialize {
	[DTResultsTextView exposeBinding:@"resultsStorage"];
	[DTResultsTextView exposeBinding:@"disableAntialiasing"];
}

- (void)awakeFromNib {
	[self.layoutManager replaceTextStorage:[[NSTextStorage alloc] init]];
	
	[self bind:@"disableAntialiasing"
	  toObject:[NSUserDefaultsController sharedUserDefaultsController]
   withKeyPath:@"values.DTDisableAntialiasing"
	   options:@{NSNullPlaceholderBindingOption: @NO}];
    
    self.cache = [NSMapTable weakToStrongObjectsMapTable];
}

- (void)setDisableAntialiasing:(BOOL)b {
	disableAntialiasing = b;
	[self setNeedsDisplay:YES];
}

extern void CGContextSetFontSmoothingStyle(CGContextRef, int);
- (void)drawRect:(NSRect)aRect {
    NSGraphicsContext *currentContext = [NSGraphicsContext currentContext];

    [currentContext saveGraphicsState];
    {
        BOOL useThinStrokes = YES;
        if(disableAntialiasing) {
            [currentContext setShouldAntialias:NO];
        } else if (useThinStrokes) {
            // iterm2 / iTermTextDrawingHelper.m
            // This seems to be available at least on 10.8 and later. The only reference to it is in
            // WebKit. This causes text to render just a little lighter, which looks nicer.
            CGContextSetFontSmoothingStyle([currentContext CGContext], 16);
        }

        [super drawRect:aRect];
    }
    [currentContext restoreGraphicsState];
}

- (NSTextStorage*)resultsStorage {
	if(validResultsStorage)
		return self.layoutManager.textStorage;
	else
		return nil;
}

- (void)setResultsStorage:(NSTextStorage*)newResults {
//	NSLog(@"setResultsStorage: %@", newResults);
	if(validResultsStorage)
		[[NSNotificationCenter defaultCenter] removeObserver:self name:NSTextStorageDidProcessEditingNotification object:[self resultsStorage]];
	
	
	validResultsStorage = (newResults != nil);
    [self cacheAndDropTextSelection];
	if(newResults) {
		[self.layoutManager replaceTextStorage:newResults];
        [self restoreTextSelection];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(dtTextChanged:)
													 name:NSTextStorageDidProcessEditingNotification
												   object:newResults];
	} else {
		[self.layoutManager replaceTextStorage:[[NSTextStorage alloc] init]];
	}
	
	[self dtSizeToFit];
}

- (void)dtTextChanged:(NSNotification*)ntf {
    UnusedParameter(ntf);
    
//	NSLog(@"dtTextChanged called: %@, %@", ntf, [self string]);

//	-- Commenting this stuff out because we don't have a good way to tell here if 
//	-- we were already scrolled at the bottom, and we don't want to force scroll
//	-- to the bottom otherwise
//	NSPoint newScrollOrigin;
//	
//	NSScrollView* scrollview = [self enclosingScrollView];
//	if ([[scrollview documentView] isFlipped]) {
//		newScrollOrigin=NSMakePoint(0.0,NSMaxY([[scrollview documentView] frame])
//									-NSHeight([[scrollview contentView] bounds]));
//	} else {
//		newScrollOrigin=NSMakePoint(0.0,0.0);
//	}
//	[[scrollview documentView] scrollPoint:newScrollOrigin];
	
	// There's a bunch of spurious empty string sets done by bindings :-/
	// We don't want to shrink-grow-shrink-grow during a continual grow
	// Smooth things out by only resizing when things have been unchanged for 1/10s
	
	if(!sizeToFitTimer.valid) {
		sizeToFitTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
														  target:self
														selector:@selector(dtSizeToFit)
														userInfo:nil
														 repeats:NO];
	}
}

- (TextStorageCacheEntry *)currentCacheEntryCreateOnAccess:(BOOL)createIfNotExists
{
    NSTextStorage* textStorage = self.layoutManager.textStorage;
    TextStorageCacheEntry *cached = [self.cache objectForKey:textStorage];

    if (!cached && createIfNotExists) {
        cached = [TextStorageCacheEntry new];
        [self.cache setObject:cached forKey:textStorage];
    }

    return cached;
}

// From http://www.cocoadev.com/index.pl?NSTextViewSizeToFit
- (NSSize)minSizeForContent {
	NSLayoutManager *layoutManager = self.layoutManager;
	NSTextContainer *textContainer = self.textContainer;
	
    [layoutManager ensureLayoutForTextContainer:textContainer];
	NSRect usedRect = [layoutManager usedRectForTextContainer:textContainer];
	NSSize inset = self.textContainerInset;
	
    NSSize minSize = NSInsetRect(usedRect, -inset.width * 2, -inset.height * 2).size;
    TextStorageCacheEntry *cached = [self currentCacheEntryCreateOnAccess:YES];
    cached.computedHeight = minSize.height;
    cached.contentLength = layoutManager.textStorage.length;
    
	return minSize;
}

- (CGFloat) targetHeightForContent
{
    NSTextStorage* textStorage = self.layoutManager.textStorage;
    TextStorageCacheEntry *cached = [self currentCacheEntryCreateOnAccess:NO];
    if (cached && (textStorage.length == cached.contentLength)) {
        return cached.computedHeight;
    }
    
    return [self minSizeForContent].height;
}

- (CGFloat)desiredHeightChange {
	NSSize currentSize = self.enclosingScrollView.contentSize;
	NSSize newSize = NSMakeSize(currentSize.width, [self targetHeightForContent]);
	
	return newSize.height - currentSize.height;
}

- (void)dtSizeToFit {
	CGFloat dHeight = [self desiredHeightChange];
	if(dHeight != 0.0)
		[(DTTermWindowController*)self.window.windowController requestWindowHeightChange:dHeight];
}

- (void)viewDidMoveToWindow {
	[self dtSizeToFit];
}

- (void) cacheAndDropTextSelection
{
    TextStorageCacheEntry *cached = [self currentCacheEntryCreateOnAccess:YES];

    cached.selectedRanges = self.selectedRanges;
    [self setSelectedRange:NSMakeRange(0, 0)];
}

- (void) restoreTextSelection
{
    NSArray *cachedSelectedRanges = [self currentCacheEntryCreateOnAccess:NO].selectedRanges;

    if (cachedSelectedRanges) {
        [self setSelectedRanges:cachedSelectedRanges];
    }
}

@end
