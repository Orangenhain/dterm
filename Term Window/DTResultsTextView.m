//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "DTResultsTextView.h"

#import "DTTermWindowController.h"

@interface TextStorageCacheEntry : NSObject
@property NSUInteger contentLength;
@property CGFloat computedHeight;
@property NSPoint scrollPosition;
@property BOOL wasScrolledToBottom;
@property NSArray<NSValue*> *selectedRanges;
@end
@implementation TextStorageCacheEntry
@end

@interface NSScrollView (DTScrollingFun)
@property (readonly) BOOL isAtBottom;
@end

@interface DTResultsTextView ()
{
    BOOL validResultsStorage;
    NSTimer* sizeToFitTimer;
    
    BOOL disableAntialiasing;
}

// TODO [?] should be cleared on font change
@property NSMapTable<NSTextStorage*, TextStorageCacheEntry*> *cache;

@property BOOL isResizingWindow;

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
    
    [self startObservingScrolling];
    
    self.cache = [[NSMapTable alloc] initWithKeyOptions:NSMapTableWeakMemory | NSMapTableObjectPointerPersonality  // NSTextStorage changes hash & isEqual when the content string changes
                                           valueOptions:NSMapTableStrongMemory
                                               capacity:0];
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
    [self cacheScrollPosition:NO];
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
//        NSLog(@"creating for text storage: %p", textStorage);
        cached = [TextStorageCacheEntry new];
        cached.wasScrolledToBottom = YES;
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
    if(dHeight != 0.0) {
        self.isResizingWindow = YES;
        self.enclosingScrollView.hasVerticalScroller = NO;
        [(DTTermWindowController*)self.window.windowController requestWindowHeightChange:dHeight onCompletion:^{
            self.enclosingScrollView.hasVerticalScroller = YES;
            self.isResizingWindow = NO;
        }];
//        NSLog(@"Sizing to height: %f", dHeight);

        [self restoreScrollPosition];
    }
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

// MARK: - Scrolling

- (void) startObservingScrolling
{
    NSScrollView *sv = self.enclosingScrollView;
    sv.postsFrameChangedNotifications = YES;
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(scrollViewDidChangedFrame:) name:NSViewFrameDidChangeNotification object:sv];
    [nc addObserver:self selector:@selector(scrollViewDidLiveScroll:) name:NSScrollViewDidLiveScrollNotification object:sv];
}

- (void)scrollViewDidChangedFrame:(NSNotification * __unused)notification
{
    if (self.window.inLiveResize && !self.isResizingWindow) {
        [self cacheScrollPosition:NO];
    }
}

- (void)scrollViewDidLiveScroll:(NSNotification * __unused)notification
{
    [self cacheScrollPosition:YES];
}

- (void) cacheScrollPosition:(BOOL)updateIsAtBottom
{
    TextStorageCacheEntry *cached = [self currentCacheEntryCreateOnAccess:YES];
    
    cached.scrollPosition = self.enclosingScrollView.contentView.documentVisibleRect.origin;
    if (updateIsAtBottom) {
        cached.wasScrolledToBottom = self.enclosingScrollView.isAtBottom;
    }
//    NSLog(@"caching scroll position: %@ - bottom: %@ for %@", NSStringFromPoint(cached.scrollPosition), cached.wasScrolledToBottom ? @"YES" : @"NO", cached);
}

- (void) restoreScrollPosition
{
    TextStorageCacheEntry *cached = [self currentCacheEntryCreateOnAccess:NO];
    if (!cached) {
        return;
    }

    if (cached.wasScrolledToBottom) {
//        NSLog(@"scroll to bottom for %@", cached);
        [self scrollToEndOfDocument:nil];
    } else {
//        NSLog(@"restoring scroll position: %@ from %@", NSStringFromPoint(cached.scrollPosition), cached);
        [self.enclosingScrollView.contentView scrollToPoint:cached.scrollPosition];
    }
}

@end

@implementation NSScrollView (DTScrollingFun)
@dynamic isAtBottom;
- (BOOL)isAtBottom
{
    CGFloat fuzzyFactor = 5. + DBL_EPSILON; // so the user doesn't have to scroll *all* the way down
    
    NSRect visibleRect = self.contentView.documentVisibleRect;
    CGFloat visibleHeight = CGRectGetHeight(visibleRect);
    CGFloat scrollMaxY = CGRectGetMaxY(visibleRect);
    CGFloat documentHeight = CGRectGetHeight(self.documentView.frame);
    
    //    NSLog(@"visibleHeight = %f - documentHeight: %f - scrollMaxY: %f", visibleHeight, documentHeight, scrollMaxY);
    
    // important when the scroll view is larger than the actual content & user is scrolling down - that makes scrollMaxY smaller than the document/visible height, even though everything fits on screen
    BOOL allContentFitsOnScreen = fabs(visibleHeight - documentHeight) < DBL_EPSILON;
    
    return allContentFitsOnScreen || (scrollMaxY >= (documentHeight - fuzzyFactor));
}

@end

