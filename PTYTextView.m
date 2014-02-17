#import "AsyncHostLookupController.h"
#import "CharacterRun.h"
#import "CharacterRunInline.h"
#import "CommandHistory.h"
#import "FileTransferManager.h"
#import "FindCursorView.h"
#import "FontSizeEstimator.h"
#import "FutureMethods.h"
#import "FutureMethods.h"
#import "iTermSelection.h"
#import "ITAddressBookMgr.h"
#import "MovePaneController.h"
#import "MovingAverage.h"
#import "NSMutableAttributedString+iTerm.h"
#import "NSStringITerm.h"
#import "PTYNoteView.h"
#import "PTYNoteViewController.h"
#import "PTYScrollView.h"
#import "PTYTab.h"
#import "PTYTask.h"
#import "PTYTextView.h"
#import "PasteboardHistory.h"
#import "PointerController.h"
#import "PointerPrefsController.h"
#import "PreferencePanel.h"
#import "RegexKitLite/RegexKitLite.h"
#import "SCPPath.h"
#import "SmartMatch.h"
#import "SearchResult.h"
#import "SmartSelectionController.h"
#import "SolidColorView.h"
#import "ThreeFingerTapGestureRecognizer.h"
#import "URLAction.h"
#import "VT100ScreenMark.h"
#import "VT100RemoteHost.h"
#import "charmaps.h"
#import "iTerm.h"
#import "iTermApplicationDelegate.h"
#import "iTermController.h"
#import "iTermExpose.h"
#import "iTermNSKeyBindingEmulator.h"
#include <math.h>
#include <sys/time.h>

static const int kMaxSelectedTextLengthForCustomActions = 8192;

// This defines the fraction of a character's width on its right side that is used to
// select the NEXT character.
//        |   A rightward drag beginning left of the bar selects G.
//        <-> kCharWidthFractionOffset * charWidth
//  <-------> Character width
//   .-----.  .      :
//  ;         :      :
//  :         :      :
//  :    ---- :------:
//  '       : :      :
//   `-----'  :      :
static const double kCharWidthFractionOffset = 0.35;

//#define DEBUG_DRAWING

// Constants for converting RGB to luma.
#define RED_COEFFICIENT    0.30
#define GREEN_COEFFICIENT  0.59
#define BLUE_COEFFICIENT   0.11

#define SWAPINT(a, b) { int temp; temp = a; a = b; b = temp; }

// Drag-drop operation flags for different possible dropping operations.
const unsigned int kUploadDragOperation = NSDragOperationCopy;
const unsigned int kPasteDragOperation = NSDragOperationGeneric;

const int kDragPaneModifiers = (NSAlternateKeyMask | NSCommandKeyMask | NSShiftKeyMask);

// If the cursor's background color is too close to nearby background colors,
// force it to the "most different" color. This is the difference threshold
// that triggers that change. 0 means always trigger, 1 means never trigger.
static double gSmartCursorBgThreshold = 0.5;

// The cursor's text is forced to black or white if it is too similar to the
// background. If the brightness difference is below a threshold then the
// B/W text mode is triggered. 0 means always trigger, 1 means never trigger.
static double gSmartCursorFgThreshold = 0.75;

// Notifications posted when hostname lookups finish. Notifications are used to
// avoid dangling references.
static NSString *const kHostnameLookupFailed = @"kHostnameLookupFailed";
static NSString *const kHostnameLookupSucceeded = @"kHostnameLookupSucceeded";
static PTYTextView *gCurrentKeyEventTextView;  // See comment in -keyDown:

// Minimum distance that the mouse must move before a cmd+drag will be
// recognized as a drag.
static const int kDragThreshold = 3;
static const double kBackgroundConsideredDarkThreshold = 0.5;
static const int kBroadcastMargin = 4;
static const int kCoprocessMargin = 4;
static const int kAlertMargin = 4;

static NSCursor* textViewCursor;
static NSCursor* xmrCursor;
static NSImage* bellImage;
static NSImage* wrapToTopImage;
static NSImage* wrapToBottomImage;
static NSImage* broadcastInputImage;
static NSImage* coprocessImage;
static NSImage* alertImage;

static CGFloat PerceivedBrightness(CGFloat r, CGFloat g, CGFloat b) {
    return (RED_COEFFICIENT * r) + (GREEN_COEFFICIENT * g) + (BLUE_COEFFICIENT * b);
}

@interface PTYTextView () <iTermSelectionDelegate>
// Set the hostname this view is currently waiting for AsyncHostLookupController to finish looking
// up.
@property(nonatomic, copy) NSString *currentUnderlineHostname;
@property(nonatomic, retain) iTermSelection *selection;

- (NSRect)cursorRect;
- (URLAction *)urlActionForClickAtX:(int)x
                                  y:(int)y
             respectingHardNewlines:(BOOL)respectHardNewlines;
@end


@implementation PTYTextView {
    // This is a flag to let us know whether we are handling this
    // particular drag and drop operation. We are using it because
    // the prepareDragOperation and performDragOperation of the
    // parent NSTextView class return "YES" even if the parent
    // cannot handle the drag type. To make matters worse, the
    // concludeDragOperation does not have any return value.
    // This all results in the inability to test whether the
    // parent could handle the drag type properly. Is this a Cocoa
    // implementation bug?
    // Fortunately, the draggingEntered and draggingUpdated methods
    // seem to return a real status, based on which we can set this flag.
    BOOL extendedDragNDrop;
    
    // anti-alias flags
    BOOL asciiAntiAlias;
    BOOL nonasciiAntiAlias;  // Only used if useNonAsciiFont_ is set.
    BOOL useNonAsciiFont_;
    
    // option to not render in bold
    BOOL useBoldFont;
    
    // Option to draw bold text as brighter colors.
    BOOL useBrightBold;
    
    // option to not render in italic
    BOOL useItalicFont;
    
    // NSTextInput support
    BOOL IM_INPUT_INSERT;
    NSRange IM_INPUT_SELRANGE;
    NSRange IM_INPUT_MARKEDRANGE;
    NSDictionary *markedTextAttributes;
    NSAttributedString *markedText;
    
    BOOL CURSOR;
    BOOL colorInvertedCursor;
    
    // geometry
    double lineHeight;
    double lineWidth;
    double charWidth;
    double charWidthWithoutSpacing, charHeightWithoutSpacing;
    double horizontalSpacing_;
    double  verticalSpacing_;
    
    PTYFontInfo *primaryFont;
    PTYFontInfo *secondaryFont;  // non-ascii font, only used if useNonAsciiFont_ is set.
    
    NSColor* colorTable[256];
    NSColor* defaultFGColor;
    NSColor* defaultBGColor;
    NSColor* defaultBoldColor;
    NSColor* defaultCursorColor;
    NSColor* selectionColor;
    NSColor* unfocusedSelectionColor;
    NSColor* selectedTextColor;
    NSColor* cursorTextColor;
    
    // transparency
    double transparency;
    double blend;
    
    // data source
    id<PTYTextViewDataSource> dataSource;
    id<PTYTextViewDelegate> _delegate;
    
    // Underlined selection range (inclusive of all values), indicating clickable url.
    int _underlineStartX, _underlineStartY, _underlineEndX, _underlineEndY;
    BOOL mouseDown;
    BOOL mouseDragged;
    BOOL mouseDownOnSelection;
    BOOL mouseDownOnImage;
    ImageInfo *theImage;
    NSEvent *mouseDownEvent;
    int lastReportedX_, lastReportedY_;

    // Find cursor. Only the start coordinate is used. Is nil if there is no cursor.
    SearchResult *_lastFindCoord;
    
    BOOL reportingMouseDown;
    
    // blinking cursor
    BOOL blinkingCursor;
    BOOL showCursor;
    BOOL blinkShow;
    struct timeval lastBlink;
    int oldCursorX, oldCursorY;
    
    BOOL blinkAllowed_;
    
    // trackingRect tab
    NSTrackingArea *trackingArea;
    
    BOOL keyIsARepeat;
    
    // Is a find currently executing?
    BOOL _findInProgress;
    
    // Previous tracking rect to avoid expensive calls to addTrackingRect.
    NSRect _trackingRect;
    
    // Maps a NSNumber int consisting of color index, alternate fg semantics
    // flag, bold flag, and background flag to NSColor*s.
    NSMutableDictionary* dimmedColorCache_;
    
    // Dimmed background color with alpha.
    NSColor *cachedBackgroundColor_;
    double cachedBackgroundColorAlpha_;  // cached alpha value (comparable to another double)
    
    // Previuos contrasting color returned
    NSColor *memoizedContrastingColor_;
    double memoizedMainRGB_[4];  // rgba for "main" color memoized.
    double memoizedOtherRGB_[3];  // rgb for "other" color memoized.
    
    // Indicates if a selection that scrolls the window is in progress.
    // Negative value: scroll up.
    // Positive value: scroll down.
    // Zero: don't scroll.
    int selectionScrollDirection;
    NSTimeInterval lastSelectionScroll;
    
    // Scrolls view when you drag a selection to top or bottom of view.
    NSTimer* selectionScrollTimer;
    double prevScrollDelay;
    int scrollingX;
    int scrollingY;
    NSPoint scrollingLocation;
    
    // This gives the number of lines added to the bottom of the frame that do
    // not correspond to a line in the dataSource. They are used solely for
    // IME text.
    int imeOffset;
    
    // Last position that accessibility was read up to.
    int accX;
    int accY;
    
    double minimumContrast_;
    
    BOOL changedSinceLastExpose_;
    
    double dimmingAmount_;
    
    // The string last searched for.
    NSString* findString_;
    
    // The set of SearchResult objects for which matches have been found.
    NSMutableArray* findResults_;
    
    // The next offset into findResults_ where values from findResults_ should
    // be added to the map.
    int nextOffset_;
    
    // True if a result has been highlighted & scrolled to.
    BOOL foundResult_;
    
    // Maps an absolute line number (NSNumber longlong) to an NSData bit array
    // with one bit per cell indicating whether that cell is a match.
    NSMutableDictionary* resultMap_;
    
    // True if the last search was forward, flase if backward.
    BOOL searchingForward_;
    
    // Offset value for last search.
    int findOffset_;
    
    // True if trying to find a result before/after current selection to
    // highlight.
    BOOL searchingForNextResult_;
    
    // True if the last search was case insensitive.
    BOOL findIgnoreCase_;
    
    // True if the last search was for a regex.
    BOOL findRegex_;
    
    // Time that the flashing bell's alpha value was last adjusted.
    NSDate* lastFlashUpdate_;
    
    // Alpha value of flashing bell graphic.
    double flashing_;
    
    // Image currently flashing.
    FlashImage flashImage_;
    
    ITermCursorType cursorType_;
    
    // Works around an apparent OS bug where we get drag events without a mousedown.
    BOOL dragOk_;
    
    // Semantic history controller
    Trouter* trouter;
    
    // Flag to make sure a Trouter drag check is only one once per drag
    BOOL trouterDragged;
    
    // Saves the monotonically increasing event number of a first-mouse click, which disallows
    // selection.
    int firstMouseEventNumber_;
    
    // For accessibility. This is a giant string with the entire scrollback buffer plus screen concatenated with newlines for hard eol's.
    NSMutableString* allText_;
    // For accessibility. This is the indices at which soft newlines occur in allText_, ignoring multi-char compositing characters.
    NSMutableArray* lineBreakIndexOffsets_;
    // For accessibility. This is the actual indices at which soft newlines occcur in allText_.
    NSMutableArray* lineBreakCharOffsets_;
    
    // Brightness of background color
    double backgroundBrightness_;
    
    // Dim everything but the default background color.
    BOOL dimOnlyText_;
    
    // For find-cursor animation
    NSWindow *findCursorWindow_;
    FindCursorView *findCursorView_;
    NSTimer *findCursorTeardownTimer_;
    NSTimer *findCursorBlinkTimer_;
    BOOL autoHideFindCursor_;
    NSPoint imeCursorLastPos_;
    
    // Number of fingers currently down (only valid if three finger click
    // emulates middle button)
    int numTouches_;
    
    // If true, ignore the next mouse up because it's due to a three finger
    // mouseDown.
    BOOL mouseDownIsThreeFingerClick_;
    
    // Is the mouse inside our view?
    BOOL mouseInRect_;
    
    // Time the selection last changed at or 0 if there's no selection.
    NSTimeInterval selectionTime_;
    
    // Dictionaries with a regex and a priority.
    NSArray *smartSelectionRules_;
    
    // Show a background indicator when in broadcast input mode
    BOOL useBackgroundIndicator_;
    
    // Find context just after initialization.
    FindContext *initialFindContext_;
    
    PointerController *pointer_;
        NSCursor *cursor_;
    
    // True while the context menu is being opened.
    BOOL openingContextMenu_;
    
        // Experimental feature gated by ThreeFingerTapEmulatesThreeFingerClick bool pref.
    ThreeFingerTapGestureRecognizer *threeFingerTapGestureRecognizer_;
    
    // Position of cursor last time we looked. Since the cursor might move around a lot between
    // calls to -updateDirtyRects without making any changes, we only redraw the old and new cursor
    // positions.
    int prevCursorX, prevCursorY;
    
    MovingAverage *drawRectDuration_, *drawRectInterval_;
        // Current font. Only valid for the duration of a single drawing context.
    NSFont *selectedFont_;
    
    // Used by _drawCursorTo: to remember the last time the cursor moved to avoid drawing a blinked-out
    // cursor while it's moving.
    NSTimeInterval lastTimeCursorMoved_;

    // If set, the last-modified time of each line on the screen is shown on the right side of the display.
    BOOL showTimestamps_;
    float _antiAliasedShift;  // Amount to shift anti-aliased text by horizontally to simulate bold
    NSImage *markImage_;
    NSImage *markErrImage_;

    // Point clicked, valid only during -validateMenuItem and calls made from
    // the context menu and if x and y are nonnegative.
    VT100GridCoord validationClickPoint_;
    
    iTermSelection *_oldSelection;
}


+ (void)initialize
{
    NSPoint hotspot = NSMakePoint(4, 5);
    NSBundle* bundle = [NSBundle bundleForClass:[self class]];
    NSImage* image = [NSImage imageNamed:@"IBarCursor"];

    textViewCursor = [[NSCursor alloc] initWithImage:image hotSpot:hotspot];

    NSImage* xmrImage = [NSImage imageNamed:@"IBarCursorXMR"];
    xmrCursor = [[NSCursor alloc] initWithImage:xmrImage hotSpot:hotspot];

    NSString* bellFile = [bundle
                          pathForResource:@"bell"
                          ofType:@"png"];
    bellImage = [[NSImage alloc] initWithContentsOfFile:bellFile];
    [bellImage setFlipped:YES];

    NSString* wrapToTopFile = [bundle
                               pathForResource:@"wrap_to_top"
                               ofType:@"png"];
    wrapToTopImage = [[NSImage alloc] initWithContentsOfFile:wrapToTopFile];
    [wrapToTopImage setFlipped:YES];

    NSString* wrapToBottomFile = [bundle
                                  pathForResource:@"wrap_to_bottom"
                                  ofType:@"png"];
    wrapToBottomImage = [[NSImage alloc] initWithContentsOfFile:wrapToBottomFile];
    [wrapToBottomImage setFlipped:YES];

    NSString* broadcastInputFile = [bundle pathForResource:@"BroadcastInput"
                                                    ofType:@"png"];
    broadcastInputImage = [[NSImage alloc] initWithContentsOfFile:broadcastInputFile];
    [broadcastInputImage setFlipped:YES];

    NSString* coprocessFile = [bundle pathForResource:@"Coprocess"
                                                    ofType:@"png"];
    coprocessImage = [[NSImage alloc] initWithContentsOfFile:coprocessFile];
    [coprocessImage setFlipped:YES];

    alertImage = [NSImage imageNamed:@"Alert"];
    [alertImage setFlipped:YES];

    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"SmartCursorColorBgThreshold"]) {
        // Override the default.
        double d = [[NSUserDefaults standardUserDefaults] doubleForKey:@"SmartCursorColorBgThreshold"];
        if (d > 0) {
            gSmartCursorBgThreshold = d;
        }
    }
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"SmartCursorColorFgThreshold"]) {
        // Override the default.
        double d = [[NSUserDefaults standardUserDefaults] doubleForKey:@"SmartCursorColorFgThreshold"];
        if (d > 0) {
            gSmartCursorFgThreshold = d;
        }
    }
    
    [iTermNSKeyBindingEmulator sharedInstance];  // Load and parse DefaultKeyBindings.dict if needed.
}

+ (NSCursor *)textViewCursor
{
    return textViewCursor;
}

- (id)initWithFrame:(NSRect)aRect
{
    self = [super initWithFrame: aRect];
    if (self) {
        firstMouseEventNumber_ = -1;

        dimmedColorCache_ = [[NSMutableDictionary alloc] init];
        [self updateMarkedTextAttributes];
        CURSOR=YES;
        _selection = [[iTermSelection alloc] init];
        _selection.delegate = self;
        _oldSelection = [_selection copy];
        _underlineStartX = _underlineStartY = _underlineEndX = _underlineEndY = -1;
        markedText = nil;
        gettimeofday(&lastBlink, NULL);
        [[self window] useOptimizedDrawing:YES];

        // register for drag and drop
        [self registerForDraggedTypes: [NSArray arrayWithObjects:
            NSFilenamesPboardType,
            NSStringPboardType,
            nil]];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_useBackgroundIndicatorChanged:)
                                                     name:kUseBackgroundPatternIndicatorChangedNotification
                                                   object:nil];
        [self _useBackgroundIndicatorChanged:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_settingsChanged:)
                                                     name:@"iTermRefreshTerminal"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_pointerSettingsChanged:)
                                                     name:kPointerPrefsChangedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(flagsChangedNotification:)
                                                     name:@"iTermFlagsChanged"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(hostnameLookupFailed:)
                                                     name:kHostnameLookupFailed
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(hostnameLookupSucceeded:)
                                                     name:kHostnameLookupSucceeded
                                                   object:nil];
        
        imeOffset = 0;
        resultMap_ = [[NSMutableDictionary alloc] init];

        trouter = [[Trouter alloc] init];
        trouter.delegate = self;
        trouterDragged = NO;

        pointer_ = [[PointerController alloc] init];
        pointer_.delegate = self;
        primaryFont = [[PTYFontInfo alloc] init];
        secondaryFont = [[PTYFontInfo alloc] init];

        initialFindContext_ = [[FindContext alloc] init];
        if ([pointer_ viewShouldTrackTouches]) {
            DLog(@"Begin tracking touches in view %@", self);
            [self setAcceptsTouchEvents:YES];
            [self setWantsRestingTouches:YES];
            if ([self useThreeFingerTapGestureRecognizer]) {
                threeFingerTapGestureRecognizer_ =
                    [[ThreeFingerTapGestureRecognizer alloc] initWithTarget:self
                                                                   selector:@selector(threeFingerTap:)];
            }
        }
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"LogDrawingPerformance"]) {
            NSLog(@"** Drawing performance timing enabled **");
            drawRectDuration_ = [[MovingAverage alloc] init];
            drawRectInterval_ = [[MovingAverage alloc] init];
        }
        [self viewDidChangeBackingProperties];
        markImage_ = [NSImage imageNamed:@"mark"];
        markErrImage_ = [NSImage imageNamed:@"mark_err"];
    }
    return self;
}

- (void)dealloc
{
    [_selection release];
    [drawRectDuration_ release];
    [drawRectInterval_ release];
    [_lastFindCoord release];
    [smartSelectionRules_ release];
    int i;
    
    if (mouseDownEvent != nil) {
        [mouseDownEvent release];
        mouseDownEvent = nil;
    }
    
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }
    if ([self isFindingCursor]) {
        [findCursorWindow_ close];
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [dimmedColorCache_ release];
    [memoizedContrastingColor_ release];
    for (i = 0; i < 256; i++) {
        [colorTable[i] release];
    }
    [lastFlashUpdate_ release];
    [cachedBackgroundColor_ release];
    [resultMap_ release];
    [findResults_ release];
    [findString_ release];
    [defaultFGColor release];
    [defaultBGColor release];
    [defaultBoldColor release];
    [selectionColor release];
    [unfocusedSelectionColor release];
    [defaultCursorColor release];
    
    [primaryFont release];
    [secondaryFont release];
    
    [markedTextAttributes release];
    [markedText release];
    
    [selectionScrollTimer release];
    
    [trouter release];
    
    [pointer_ release];
    [cursor_ release];
    [threeFingerTapGestureRecognizer_ disconnectTarget];
    [threeFingerTapGestureRecognizer_ release];
    
    [initialFindContext_ release];
    if (self.currentUnderlineHostname) {
        [[AsyncHostLookupController sharedInstance] cancelRequestForHostname:self.currentUnderlineHostname];
    }
    [_currentUnderlineHostname release];
    
    [super dealloc];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<PTYTextView: %p frame=%@ visibleRect=%@ SCREEN=%@>",
            self,
            [NSValue valueWithRect:self.frame],
            [NSValue valueWithRect:[self visibleRect]],
            dataSource];
}

- (BOOL)useThreeFingerTapGestureRecognizer {
    // This used to be guarded by [[NSUserDefaults standardUserDefaults] boolForKey:@"ThreeFingerTapEmulatesThreeFingerClick"];
    // but I'm going to turn it on by default and see if anyone complains. 12/16/13
    return YES;
}

- (void)viewDidChangeBackingProperties {
    _antiAliasedShift = [[[self window] screen] backingScaleFactor] > 1 ? 0.5 : 0;
}

- (void)updateMarkedTextAttributes {
    [self setMarkedTextAttributes:
     [NSDictionary dictionaryWithObjectsAndKeys:
      defaultBGColor, NSBackgroundColorAttributeName,
      defaultFGColor, NSForegroundColorAttributeName,
      [self nafont], NSFontAttributeName,
      [NSNumber numberWithInt:(NSUnderlineStyleSingle|NSUnderlineByWordMask)],
      NSUnderlineStyleAttributeName,
      NULL]];
}

- (void)sendFakeThreeFingerClickDown:(BOOL)isDown basedOnEvent:(NSEvent *)event {
    CGEventRef cgEvent = [event CGEvent];
    CGEventRef fakeCgEvent = CGEventCreateMouseEvent(NULL,
                                                     isDown ? kCGEventLeftMouseDown : kCGEventLeftMouseUp,
                                                     CGEventGetLocation(cgEvent),
                                                     2);
    CGEventSetIntegerValueField(fakeCgEvent, kCGMouseEventClickState, 1);  // always a single click
    CGEventSetFlags(fakeCgEvent, CGEventGetFlags(cgEvent));
    NSEvent *fakeEvent = [NSEvent eventWithCGEvent:fakeCgEvent];
    int saved = numTouches_;
    numTouches_ = 3;
    if (isDown) {
        DLog(@"Emulate three finger click down");
        [self mouseDown:fakeEvent];
        DLog(@"Returned from mouseDown");
    } else {
        DLog(@"Emulate three finger click up");
        [self mouseUp:fakeEvent];
        DLog(@"Returned from mouseDown");
    }
    DLog(@"Restore numTouches to saved value of %d", saved);
    numTouches_ = saved;
    CFRelease(fakeCgEvent);
}

- (void)threeFingerTap:(NSEvent *)ev {
    [self sendFakeThreeFingerClickDown:YES basedOnEvent:ev];
    [self sendFakeThreeFingerClickDown:NO basedOnEvent:ev];
}

- (void)touchesBeganWithEvent:(NSEvent *)ev
{
    numTouches_ = [[ev touchesMatchingPhase:NSTouchPhaseBegan | NSTouchPhaseStationary
                                           inView:self] count];
    [threeFingerTapGestureRecognizer_ touchesBeganWithEvent:ev];
    DLog(@"%@ Begin touch. numTouches_ -> %d", self, numTouches_);
}

- (void)touchesEndedWithEvent:(NSEvent *)ev
{
    numTouches_ = [[ev touchesMatchingPhase:NSTouchPhaseStationary
                                     inView:self] count];
    [threeFingerTapGestureRecognizer_ touchesEndedWithEvent:ev];
    DLog(@"%@ End touch. numTouches_ -> %d", self, numTouches_);
}

- (void)touchesCancelledWithEvent:(NSEvent *)event
{
    numTouches_ = 0;
    [threeFingerTapGestureRecognizer_ touchesCancelledWithEvent:event];
    DLog(@"%@ Cancel touch. numTouches_ -> %d", self, numTouches_);
}

- (BOOL)resignFirstResponder
{
    [self removeUnderline];
    return YES;
}

- (BOOL)becomeFirstResponder
{
    [_delegate textViewDidBecomeFirstResponder];
    return YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)win
{
    if (!win && [self window] && trackingArea) {
        [self removeTrackingArea:trackingArea];
        trackingArea = nil;
    }
    [super viewWillMoveToWindow:win];
}

- (void)viewDidMoveToWindow
{
    [self updateTrackingAreas];
}

- (void)updateTrackingAreas
{
    int trackingOptions;

    if ([self window]) {
        trackingOptions = NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingActiveAlways | NSTrackingEnabledDuringMouseDrag;
        if (trackingArea) {
            [self removeTrackingArea:trackingArea];
        }
        if ([[dataSource terminal] mouseMode] == MOUSE_REPORTING_ALL_MOTION ||
            ([NSEvent modifierFlags] & NSCommandKeyMask)) {
            trackingOptions |= NSTrackingMouseMoved;
        }
        trackingArea = [[[NSTrackingArea alloc] initWithRect:[self visibleRect]
                                                     options:trackingOptions
                                                       owner:self
                                                    userInfo:nil] autorelease];
        [self addTrackingArea:trackingArea];
    }
}

// TODO: Not sure if this is used.
- (BOOL)shouldDrawInsertionPoint
{
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)setUseNonAsciiFont:(BOOL)useNonAsciiFont {
    useNonAsciiFont_ = useNonAsciiFont;
    [self setNeedsDisplay:YES];
    [self updateMarkedTextAttributes];
}

- (void)setAntiAlias:(BOOL)asciiAA nonAscii:(BOOL)nonAsciiAA
{
    asciiAntiAlias = asciiAA;
    nonasciiAntiAlias = nonAsciiAA;
    [self setNeedsDisplay:YES];
}

- (BOOL)useBoldFont
{
    return useBoldFont;
}

- (void)setUseBoldFont:(BOOL)boldFlag
{
    useBoldFont = boldFlag;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (BOOL)useItalicFont
{
    return useItalicFont;
}

- (void)setUseItalicFont:(BOOL)italicFlag
{
    useItalicFont = italicFlag;
    [self setNeedsDisplay:YES];
}


- (void)setUseBrightBold:(BOOL)flag
{
    useBrightBold = flag;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (BOOL)blinkingCursor
{
    return blinkingCursor;
}

- (void)setBlinkingCursor:(BOOL)bFlag
{
    blinkingCursor = bFlag;
}

- (void)setBlinkAllowed:(BOOL)value
{
    blinkAllowed_ = value;
    [self setNeedsDisplay:YES];
}

- (void)setCursorNeedsDisplay {
    int lineStart = [dataSource numberOfLines] - [dataSource height];
    int cursorX = [dataSource cursorX] - 1;
    int cursorY = [dataSource cursorY] - 1;
    NSRect dirtyRect = NSMakeRect(MARGIN + cursorX * charWidth,
                                  (lineStart + cursorY) * lineHeight,
                                  charWidth,
                                  lineHeight);
    [self setNeedsDisplayInRect:dirtyRect];
}

- (void)setCursorType:(ITermCursorType)value
{
    cursorType_ = value;
    [self setCursorNeedsDisplay];
    [self refresh];
}

- (void)setDimOnlyText:(BOOL)value
{
    dimOnlyText_ = value;
    [dimmedColorCache_ removeAllObjects];
    [[self superview] setNeedsDisplay:YES];
}

- (NSDictionary*)markedTextAttributes
{
    return markedTextAttributes;
}

- (void)setMarkedTextAttributes:(NSDictionary *)attr
{
    [markedTextAttributes autorelease];
    [attr retain];
    markedTextAttributes = attr;
}

- (void)setFGColor:(NSColor*)color
{
    [defaultFGColor release];
    [color retain];
    defaultFGColor = color;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)updateScrollerForBackgroundColor
{
    PTYScroller *scroller = [_delegate textViewVerticalScroller];
    BOOL isDark = ([self perceivedBrightness:defaultBGColor] < kBackgroundConsideredDarkThreshold);
    [scroller setHasDarkBackground:isDark];
}

- (void)setBGColor:(NSColor*)color
{
    [defaultBGColor release];
    [color retain];
    defaultBGColor = color;
    backgroundBrightness_ = PerceivedBrightness([color redComponent], [color greenComponent], [color blueComponent]);
    [self updateScrollerForBackgroundColor];
    [dimmedColorCache_ removeAllObjects];
    [cachedBackgroundColor_ release];
    cachedBackgroundColor_ = nil;
    [self setNeedsDisplay:YES];
}

- (void)setBoldColor:(NSColor*)color
{
    [defaultBoldColor release];
    [color retain];
    defaultBoldColor = color;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setCursorColor:(NSColor*)color
{
    [defaultCursorColor release];
    [color retain];
    defaultCursorColor = color;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setSelectedTextColor:(NSColor *)aColor
{
    [selectedTextColor release];
    [aColor retain];
    selectedTextColor = aColor;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setCursorTextColor:(NSColor*)aColor
{
    [cursorTextColor release];
    [aColor retain];
    cursorTextColor = aColor;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (NSColor*)cursorTextColor
{
    return cursorTextColor;
}

- (NSColor*)selectedTextColor
{
    return selectedTextColor;
}

- (NSColor*)defaultFGColor
{
    return defaultFGColor;
}

- (NSColor *) defaultBGColor
{
    return defaultBGColor;
}

- (NSColor *) defaultBoldColor
{
    return defaultBoldColor;
}

- (NSColor *) defaultCursorColor
{
    return defaultCursorColor;
}

- (void)setColorTable:(int)theIndex color:(NSColor*)origColor
{
    NSColor* theColor = [origColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    [colorTable[theIndex] release];
    [theColor retain];
    colorTable[theIndex] = theColor;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (NSColor*)_colorForCode:(int)theIndex
                    green:(int)green
                     blue:(int)blue
                colorMode:(ColorMode)theMode
                     bold:(BOOL)isBold
{
    NSColor* color;
    BOOL ok = NO;
    switch (theMode) {
        case ColorModeAlternate:
            ok = YES;
            switch (theIndex) {
                case ALTSEM_SELECTED:
                    color = selectedTextColor;
                    break;
                case ALTSEM_CURSOR:
                    color = cursorTextColor;
                    break;
                case ALTSEM_BG_DEFAULT:
                    color = defaultBGColor;
                    break;
                case ALTSEM_FG_DEFAULT:
                    if (isBold && useBrightBold) {
                        color = [self defaultBoldColor];
                    } else {
                        color = defaultFGColor;
                    }
                    break;
                default:
                    // This should never happen, but if it does we should
                    // get some bug reports by returning red.
                    NSLog(@"Unexpected alternate-semantics color %d", theIndex);
                    return [NSColor colorWithCalibratedRed:1 green:0 blue:0 alpha:1];
            }
            break;
        case ColorMode24bit:
            ok = YES;
            color = [self colorFromRed:theIndex
                                 green:green
                                  blue:blue];
            break;
        case ColorModeNormal:
            ok = YES;
            // Render bold text as bright. The spec (ECMA-48) describes the intense
            // display setting (esc[1m) as "bold or bright". We make it a
            // preference.
            if (isBold &&
                useBrightBold &&
                (theIndex < 8)) { // Only colors 0-7 can be made "bright".
                theIndex |= 8;  // set "bright" bit.
            }
            color = colorTable[theIndex];
            break;

        case ColorModeInvalid:
            assert(false);
    }
    NSAssert(ok, @"Bogus color mode %d", (int)theMode);
    if (!ok) {
        color = [NSColor redColor];
    }

    return color;
}

- (NSColor*)_dimmedColorFrom:(NSColor*)orig
{
    if (dimmingAmount_ == 0) {
        return orig;
    }
    double r = [orig redComponent];
    double g = [orig greenComponent];
    double b = [orig blueComponent];
    double alpha = [orig alphaComponent];
    // This algorithm limits the dynamic range of colors as well as brightening
    // them. Both attributes change in proportion to the dimmingAmount_.

    // Find a linear interpolation between kCenter and the requested color component
    // in proportion to 1- dimmingAmount_.
    if (!dimOnlyText_) {
        const double kCenter = 0.5;

        return [NSColor colorWithCalibratedRed:(1 - dimmingAmount_) * r + dimmingAmount_ * kCenter
                                         green:(1 - dimmingAmount_) * g + dimmingAmount_ * kCenter
                                          blue:(1 - dimmingAmount_) * b + dimmingAmount_ * kCenter
                                         alpha:alpha];
    } else {
        return [NSColor colorWithCalibratedRed:(1 - dimmingAmount_) * r + dimmingAmount_ * backgroundBrightness_
                                         green:(1 - dimmingAmount_) * g + dimmingAmount_ * backgroundBrightness_
                                          blue:(1 - dimmingAmount_) * b + dimmingAmount_ * backgroundBrightness_
                                         alpha:alpha];
    }
}

// Provide a dimmed version of a color. It includes a caching optimization that
// really helps when dimming is on.
- (NSColor *)_dimmedColorForCode:(int)theIndex
                           green:(int)green
                            blue:(int)blue
                       colorMode:(ColorMode)theMode
                            bold:(BOOL)isBold
                      background:(BOOL)isBackground
{
    if (dimmingAmount_ == 0) {
        // No dimming: return plain-vanilla color.
        NSColor *theColor = [self _colorForCode:theIndex
                                          green:green
                                           blue:blue
                                      colorMode:theMode
                                           bold:isBold];
        return theColor;
    }

    // 24-bit colors are not cached, as they could increase cache size
    // nontrivially up to to 2^27
    if (theMode == ColorMode24bit) {
        NSColor *theColor = [self _colorForCode:theIndex
                                          green:green
                                           blue:blue
                                      colorMode:theMode
                                           bold:isBold];
        return [self _dimmedColorFrom:theColor];
    }

    // Dimming is on. See if the dimmed version of the color is cached.
    // The max number of keys is 2^11 so this won't take too much memory.
    // This cache provides a 20%ish performance gain when dimming is on.
    int key = (((theIndex & 0xff) << 3) |
               ((theMode == ColorModeAlternate ? 1 : 0) << 2) |
               ((isBold ? 1 : 0) << 1) |
               ((isBackground ? 1 : 0) << 0));
    NSNumber *numKey = [NSNumber numberWithInt:key];
    NSColor *cacheEntry = [dimmedColorCache_ objectForKey:numKey];
    if (cacheEntry) {
        return cacheEntry;
    } else {
        NSColor *theColor = [self _colorForCode:theIndex
                                          green:green
                                           blue:blue
                                      colorMode:theMode
                                           bold:isBold];
        NSColor *dimmedColor = [self _dimmedColorFrom:theColor];
        [dimmedColorCache_ setObject:dimmedColor forKey:numKey];
        return dimmedColor;
    }
}

- (NSColor*)colorForCode:(int)theIndex
                   green:(int)green
                    blue:(int)blue
               colorMode:(ColorMode)theMode
                    bold:(BOOL)isBold
            isBackground:(BOOL)isBackground
{
    if (isBackground && dimOnlyText_) {
        NSColor *theColor = [self _colorForCode:theIndex
                                          green:green
                                           blue:blue
                                      colorMode:theMode
                                           bold:isBold];
        return theColor;
    } else {
        return [self _dimmedColorForCode:theIndex
                                   green:green
                                    blue:blue
                               colorMode:theMode
                                    bold:isBold
                              background:isBackground];
    }
}

- (NSColor *)colorFromRed:(int)red
                    green:(int)green
                     blue:(int)blue
{
    return [NSColor colorWithCalibratedRed:red/255.0
                                     green:green/255.0
                                      blue:blue/255.0
                                     alpha:1];
}

- (NSColor *)selectionColor
{
    return selectionColor;
}

- (NSColor *)selectionColorForCurrentFocus
{
    PTYTextView* frontTextView = [[iTermController sharedInstance] frontTextView];
    if (self == frontTextView) {
        return selectionColor;
    } else {
        return unfocusedSelectionColor;
    }
}

- (void)setSelectionColor:(NSColor *)aColor
{
    [selectionColor release];
    [aColor retain];
    selectionColor = aColor;

    [unfocusedSelectionColor autorelease];
    CGFloat r,g,b;
    r = [aColor redComponent];
    g = [aColor greenComponent];
    b = [aColor blueComponent];
    unfocusedSelectionColor = [[NSColor colorWithCalibratedRed:(r + 1) / 3
                                                         green:(g + 1) / 3
                                                          blue:(b + 1) / 3
                                                         alpha:1] retain];

    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (NSFont *)font
{
    return primaryFont.font;
}

- (NSFont *)nafont
{
    return useNonAsciiFont_ ? secondaryFont.font : primaryFont.font;
}

+ (NSSize)charSizeForFont:(NSFont*)aFont horizontalSpacing:(double)hspace verticalSpacing:(double)vspace baseline:(double*)baseline
{
    FontSizeEstimator* fse = [FontSizeEstimator fontSizeEstimatorForFont:aFont];
    NSSize size = [fse size];
    size.width = ceil(size.width * hspace);
    size.height = ceil(vspace * ceil(size.height + [aFont leading]));
    if (baseline) {
        *baseline = [fse baseline];
    }
    return size;
}

+ (NSSize)charSizeForFont:(NSFont*)aFont horizontalSpacing:(double)hspace verticalSpacing:(double)vspace
{
    return [PTYTextView charSizeForFont:aFont horizontalSpacing:hspace verticalSpacing:vspace baseline:nil];
}

- (double)horizontalSpacing
{
    return horizontalSpacing_;
}

- (double)verticalSpacing
{
    return verticalSpacing_;
}

- (void)setFont:(NSFont*)aFont
         nafont:(NSFont *)naFont
    horizontalSpacing:(double)horizontalSpacing
    verticalSpacing:(double)verticalSpacing
{
    double baseline;
    NSSize sz = [PTYTextView charSizeForFont:aFont
                           horizontalSpacing:1.0
                             verticalSpacing:1.0
                                    baseline:&baseline];

    charWidthWithoutSpacing = sz.width;
    charHeightWithoutSpacing = sz.height;
    horizontalSpacing_ = horizontalSpacing;
    verticalSpacing_ = verticalSpacing;
    charWidth = ceil(charWidthWithoutSpacing * horizontalSpacing);
    lineHeight = ceil(charHeightWithoutSpacing * verticalSpacing);

    primaryFont.font = aFont;
    primaryFont.baselineOffset = baseline;
    primaryFont.boldVersion = [primaryFont computedBoldVersion];
    primaryFont.italicVersion = [primaryFont computedItalicVersion];
    primaryFont.boldItalicVersion = [primaryFont computedBoldItalicVersion];
    
    secondaryFont.font = naFont;
    secondaryFont.baselineOffset = baseline;
    secondaryFont.boldVersion = [secondaryFont computedBoldVersion];
    secondaryFont.italicVersion = [secondaryFont computedItalicVersion];
    secondaryFont.boldItalicVersion = [secondaryFont computedBoldItalicVersion];

    // Force the secondary font to use the same baseline as the primary font.
    secondaryFont.baselineOffset = primaryFont.baselineOffset;
    if (secondaryFont.boldVersion) {
        if (primaryFont.boldVersion) {
            secondaryFont.boldVersion.baselineOffset = primaryFont.boldVersion.baselineOffset;
        } else {
            secondaryFont.boldVersion.baselineOffset = secondaryFont.baselineOffset;
        }
    }
    if (secondaryFont.italicVersion) {
        if (primaryFont.italicVersion) {
            secondaryFont.italicVersion.baselineOffset = primaryFont.italicVersion.baselineOffset;
        } else {
            secondaryFont.italicVersion.baselineOffset = secondaryFont.baselineOffset;
        }
    }

    [self updateMarkedTextAttributes];
    [self setNeedsDisplay:YES];

    NSScrollView* scrollview = [self enclosingScrollView];
    [scrollview setLineScroll:[self lineHeight]];
    [scrollview setPageScroll:2 * [self lineHeight]];
    [self updateNoteViewFrames];
    [_delegate textViewFontDidChange];
}

- (void)changeFont:(id)fontManager
{
    if ([[PreferencePanel sharedInstance] onScreen]) {
        [[PreferencePanel sharedInstance] changeFont:fontManager];
    } else if ([[PreferencePanel sessionsInstance] onScreen]) {
        [[PreferencePanel sessionsInstance] changeFont:fontManager];
    }
}

- (id)dataSource
{
    return dataSource;
}

- (void)setDataSource:(id)aDataSource
{
    dataSource = aDataSource;
}

- (id)delegate
{
    return _delegate;
}

- (void)setDelegate:(id)aDelegate
{
    _delegate = aDelegate;
}

- (double)lineHeight
{
    return ceil(lineHeight);
}

- (void)setLineHeight:(double)aLineHeight
{
    lineHeight = aLineHeight;
}

- (double)charWidth
{
    return ceil(charWidth);
}

- (void)setCharWidth:(double)width
{
    charWidth = width;
}

- (void)toggleShowTimestamps
{
    showTimestamps_ = !showTimestamps_;
    [self setNeedsDisplay:YES];
}

#ifdef DEBUG_DRAWING
NSMutableArray* screens=0;
- (void)appendDebug:(NSString*)str
{
    if (!screens) {
        screens = [[NSMutableArray alloc] init];
    }
    [screens addObject:str];
    if ([screens count] > 100) {
        [screens removeObjectAtIndex:0];
    }
}
#endif

- (NSRect)scrollViewContentSize
{
    NSRect r = NSMakeRect(0, 0, 0, 0);
    r.size = [[self enclosingScrollView] contentSize];
    return r;
}

- (double)excess
{
    NSRect visible = [self scrollViewContentSize];
    visible.size.height -= VMARGIN * 2;  // Height without top and bottom margins.
    int rows = visible.size.height / lineHeight;
    double usablePixels = rows * lineHeight;
    return MAX(visible.size.height - usablePixels + VMARGIN, VMARGIN);  // Never have less than VMARGIN excess, but it can be more (if another tab has a bigger font)
}

// We override this method since both refresh and window resize can conflict
// resulting in this happening twice So we do not allow the size to be set
// larger than what the data source can fill
- (void)setFrameSize:(NSSize)frameSize
{
    // Force the height to always be correct
    frameSize.height = [dataSource numberOfLines] * lineHeight + [self excess] + imeOffset * lineHeight;
    [super setFrameSize:frameSize];

    frameSize.height += VMARGIN;  // This causes a margin to be left at the top
    [[self superview] setFrameSize:frameSize];
    
    [_delegate textViewSizeDidChange];
}

- (void)scheduleSelectionScroll
{
    if (selectionScrollTimer) {
        [selectionScrollTimer release];
        if (prevScrollDelay > 0.001) {
            // Maximum speed hasn't been reached so accelerate scrolling speed by 5%.
            prevScrollDelay *= 0.95;
        }
    } else {
        // Set a slow initial scrolling speed.
        prevScrollDelay = 0.1;
    }

    lastSelectionScroll = [[NSDate date] timeIntervalSince1970];
    selectionScrollTimer = [[NSTimer scheduledTimerWithTimeInterval:prevScrollDelay
                                                             target:self
                                                           selector:@selector(updateSelectionScroll)
                                                           userInfo:nil
                                                            repeats:NO] retain];
}

// Scroll the screen up or down a line for a selection drag scroll.
- (void)updateSelectionScroll
{
    double actualDelay = [[NSDate date] timeIntervalSince1970] - lastSelectionScroll;
    const int kMaxLines = 100;
    int numLines = MIN(kMaxLines, MAX(1, actualDelay / prevScrollDelay));
    NSRect visibleRect = [self visibleRect];

    int y = 0;
    if (!selectionScrollDirection) {
        [selectionScrollTimer release];
        selectionScrollTimer = nil;
        return;
    } else if (selectionScrollDirection < 0) {
        visibleRect.origin.y -= [self lineHeight] * numLines;
        // Allow the origin to go as far as y=-VMARGIN so the top border is shown when the first line is
        // on screen.
        if (visibleRect.origin.y >= -VMARGIN) {
            [self scrollRectToVisible:visibleRect];
        }
        y = visibleRect.origin.y / lineHeight;
    } else if (selectionScrollDirection > 0) {
        visibleRect.origin.y += lineHeight * numLines;
        if (visibleRect.origin.y + visibleRect.size.height > [self frame].size.height) {
            visibleRect.origin.y = [self frame].size.height - visibleRect.size.height;
        }
        [self scrollRectToVisible:visibleRect];
        y = (visibleRect.origin.y + visibleRect.size.height - [self excess]) / lineHeight;
    }

    [self moveSelectionEndpointToX:scrollingX
                                 Y:y
                locationInTextView:scrollingLocation];

    [self scheduleSelectionScroll];
}

- (BOOL)accessibilityIsIgnored
{
    return NO;
}

- (NSArray*)accessibilityAttributeNames
{
    return [NSArray arrayWithObjects:
            NSAccessibilityRoleAttribute,
            NSAccessibilityRoleDescriptionAttribute,
            NSAccessibilityHelpAttribute,
            NSAccessibilityFocusedAttribute,
            NSAccessibilityParentAttribute,
            NSAccessibilityChildrenAttribute,
            NSAccessibilityWindowAttribute,
            NSAccessibilityTopLevelUIElementAttribute,
            NSAccessibilityPositionAttribute,
            NSAccessibilitySizeAttribute,
            NSAccessibilityDescriptionAttribute,
            NSAccessibilityValueAttribute,
            NSAccessibilityNumberOfCharactersAttribute,
            NSAccessibilitySelectedTextAttribute,
            NSAccessibilitySelectedTextRangeAttribute,
            NSAccessibilitySelectedTextRangesAttribute,
            NSAccessibilityInsertionPointLineNumberAttribute,
            NSAccessibilityVisibleCharacterRangeAttribute,
            nil];
}

- (NSArray *)accessibilityParameterizedAttributeNames
{
    return [NSArray arrayWithObjects:
            NSAccessibilityLineForIndexParameterizedAttribute,
            NSAccessibilityRangeForLineParameterizedAttribute,
            NSAccessibilityStringForRangeParameterizedAttribute,
            NSAccessibilityRangeForPositionParameterizedAttribute,
            NSAccessibilityRangeForIndexParameterizedAttribute,
            NSAccessibilityBoundsForRangeParameterizedAttribute,
            nil];
}

// Range in allText_ of the given line.
- (NSRange)_rangeOfLine:(NSUInteger)lineNumber
{
    NSRange range;
    [self _allText];  // Refresh lineBreakCharOffsets_
    if (lineNumber == 0) {
        range.location = 0;
    } else {
        range.location = [[lineBreakCharOffsets_ objectAtIndex:lineNumber-1] unsignedLongValue];
    }
    if (lineNumber >= [lineBreakCharOffsets_ count]) {
        range.length = [allText_ length] - range.location;
    } else {
        range.length = [[lineBreakCharOffsets_ objectAtIndex:lineNumber] unsignedLongValue] - range.location;
    }
    return range;
}

// Range in allText_ of the given index.
- (NSUInteger)_lineNumberOfIndex:(NSUInteger)theIndex
{
    NSUInteger lineNum = 0;
    for (NSNumber* n in lineBreakIndexOffsets_) {
        NSUInteger offset = [n unsignedLongValue];
        if (offset > theIndex) {
            break;
        }
        lineNum++;
    }
    return lineNum;
}

// Line number of a location (respecting compositing chars) in allText_.
- (NSUInteger)_lineNumberOfChar:(NSUInteger)location
{
    NSUInteger lineNum = 0;
    for (NSNumber* n in lineBreakCharOffsets_) {
        NSUInteger offset = [n unsignedLongValue];
        if (offset > location) {
            break;
        }
        lineNum++;
    }
    return lineNum;
}

// Number of unichar a character uses (normally 1 in English).
- (int)_lengthOfChar:(screen_char_t)sct
{
    return [ScreenCharToStr(&sct) length];
}

// Position, respecting compositing chars, in allText_ of a line.
- (NSUInteger)_offsetOfLine:(NSUInteger)lineNum
{
    if (lineNum == 0) {
        return 0;
    }
    assert(lineNum < [lineBreakCharOffsets_ count] + 1);
    return [[lineBreakCharOffsets_ objectAtIndex:lineNum - 1] unsignedLongValue];
}

// Onscreen X-position of a location (respecting compositing chars) in allText_.
- (NSUInteger)_columnOfChar:(NSUInteger)location inLine:(NSUInteger)lineNum
{
    NSUInteger lineStart = [self _offsetOfLine:lineNum];
    screen_char_t* theLine = [dataSource getLineAtIndex:lineNum];
    assert(location >= lineStart);
    int remaining = location - lineStart;
    int i = 0;
    while (remaining > 0 && i < [dataSource width]) {
        remaining -= [self _lengthOfChar:theLine[i++]];
    }
    return i;
}

// Index (ignoring compositing chars) of a line in allText_.
- (NSUInteger)_startingIndexOfLineNumber:(NSUInteger)lineNumber
{
    if (lineNumber < [lineBreakIndexOffsets_ count]) {
        return [[lineBreakCharOffsets_ objectAtIndex:lineNumber] unsignedLongValue];
    } else if ([lineBreakIndexOffsets_ count] > 0) {
        return [[lineBreakIndexOffsets_ lastObject] unsignedLongValue];
    } else {
        return 0;
    }
}

// Range in allText_ of an index (ignoring compositing chars).
- (NSRange)_rangeOfIndex:(NSUInteger)theIndex
{
    NSUInteger lineNumber = [self _lineNumberOfIndex:theIndex];
    screen_char_t* theLine = [dataSource getLineAtIndex:lineNumber];
    NSUInteger startingIndexOfLine = [self _startingIndexOfLineNumber:lineNumber];
    if (theIndex < startingIndexOfLine) {
        return NSMakeRange(NSNotFound, 0);
    }
    int x = theIndex - startingIndexOfLine;
    NSRange rangeOfLine = [self _rangeOfLine:lineNumber];
    NSRange range;
    range.location = rangeOfLine.location;
    for (int i = 0; i < x; i++) {
        range.location += [self _lengthOfChar:theLine[i]];
    }
    range.length = [self _lengthOfChar:theLine[x]];
    return range;
}

// Range, respecting compositing chars, of a character at an x,y position where 0,0 is the
// first char of the first line in the scrollback buffer.
- (NSRange)_rangeOfCharAtX:(int)x y:(int)y
{
    screen_char_t* theLine = [dataSource getLineAtIndex:y];
    NSRange lineRange = [self _rangeOfLine:y];
    NSRange result = lineRange;
    for (int i = 0; i < x; i++) {
        result.location += [self _lengthOfChar:theLine[i]];
    }
    result.length = [self _lengthOfChar:theLine[x]];
    return result;
}

/*
 * The concepts used here are not defined, so I'm going to give it my best guess.
 *
 * Suppose we have a terminal window like this:
 *
 * Line  On-Screen Contents
 * 0     [x]
 * 1     [ba'r]  (the ' is a combining accent)
 * 2     [y]
 *
 * Index  Location (as in a range)  Character
 * 0      0                         f
 * 1      1                         b
 * 2      2-3                       b + [']
 * 3      4                         r
 * 4      5                         y
 *
 * Index                   012 34
 * Char                    012345
 * allText_              = xba´ry
 * lineBreakCharOffests_ = [1, 4]
 * lineBreakInexOffsets_ = [1, 3]
 */
- (id)_accessibilityAttributeValue:(NSString *)attribute forParameter:(id)parameter
{
    if ([attribute isEqualToString:NSAccessibilityLineForIndexParameterizedAttribute]) {
        //(NSNumber *) - line# for char index; param:(NSNumber *)
        NSUInteger theIndex = [(NSNumber*)parameter unsignedLongValue];
        return [NSNumber numberWithUnsignedLong:[self _lineNumberOfIndex:theIndex]];
    } else if ([attribute isEqualToString:NSAccessibilityRangeForLineParameterizedAttribute]) {
        //(NSValue *)  - (rangeValue) range of line; param:(NSNumber *)
        NSUInteger lineNumber = [(NSNumber*)parameter unsignedLongValue];
        if (lineNumber >= [lineBreakIndexOffsets_ count]) {
            return [NSValue valueWithRange:NSMakeRange(NSNotFound, 0)];
        } else {
            return [NSValue valueWithRange:[self _rangeOfLine:lineNumber]];
        }
    } else if ([attribute isEqualToString:NSAccessibilityStringForRangeParameterizedAttribute]) {
        //(NSString *) - substring; param:(NSValue * - rangeValue)
        NSRange range = [(NSValue*)parameter rangeValue];
        return [allText_ substringWithRange:range];
    } else if ([attribute isEqualToString:NSAccessibilityRangeForPositionParameterizedAttribute]) {
        //(NSValue *)  - (rangeValue) composed char range; param:(NSValue * - pointValue)
        NSPoint screenPosition = [(NSValue*)parameter pointValue];
        NSRect screenRect = NSMakeRect(screenPosition.x,
                                       screenPosition.y,
                                       0,
                                       0);
        NSRect windowRect = [self.window convertRectFromScreen:screenRect];
        NSPoint locationInTextView = [self convertPoint:windowRect.origin fromView:nil];
        NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
        int x = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        int y = locationInTextView.y / lineHeight;

        if (y < 0) {
            return [NSValue valueWithRange:NSMakeRange(0, 0)];
        } else {
            return [NSValue valueWithRange:[self _rangeOfCharAtX:x y:y]];
        }
    } else if ([attribute isEqualToString:NSAccessibilityRangeForIndexParameterizedAttribute]) {
        //(NSValue *)  - (rangeValue) composed char range; param:(NSNumber *)
        NSUInteger theIndex = [(NSNumber*)parameter unsignedLongValue];
        return [NSValue valueWithRange:[self _rangeOfIndex:theIndex]];
    } else if ([attribute isEqualToString:NSAccessibilityBoundsForRangeParameterizedAttribute]) {
        //(NSValue *)  - (rectValue) bounds of text; param:(NSValue * - rangeValue)
        NSRange range = [(NSValue*)parameter rangeValue];
        int yStart = [self _lineNumberOfChar:range.location];
        int y2 = [self _lineNumberOfChar:range.location + range.length - 1];
        int xStart = [self _columnOfChar:range.location inLine:yStart];
        int x2 = [self _columnOfChar:range.location + range.length - 1 inLine:y2];
        ++x2;
        if (x2 == [dataSource width]) {
            x2 = 0;
            ++y2;
        }
        int yMin = MIN(yStart, y2);
        int yMax = MAX(yStart, y2);
        int xMin = MIN(xStart, x2);
        int xMax = MAX(xStart, x2);
        NSRect result = NSMakeRect(MAX(0, floor(xMin * charWidth + MARGIN)),
                                   MAX(0, yMin * lineHeight),
                                   MAX(0, (xMax - xMin) * charWidth),
                                   MAX(0, (yMax - yMin + 1) * lineHeight));
        result = [self convertRect:result toView:nil];
        result = [self.window convertRectToScreen:result];
        return [NSValue valueWithRect:result];
    } else if ([attribute isEqualToString:NSAccessibilityAttributedStringForRangeParameterizedAttribute]) {
        //(NSAttributedString *) - substring; param:(NSValue * - rangeValue)
        NSRange range = [(NSValue*)parameter rangeValue];
        if (range.location == NSNotFound) {
            return nil;
        } else {
            NSString *theString = [allText_ substringWithRange:range];
            NSAttributedString *attributedString = [[[NSAttributedString alloc] initWithString:theString] autorelease];
            return attributedString;
        }
    } else {
        return [super accessibilityAttributeValue:attribute forParameter:parameter];
    }
}

- (id)accessibilityAttributeValue:(NSString *)attribute forParameter:(id)parameter
{
    // NSLog(@"accessibilityAttributeValue:%@ forParameter:%@", attribute, parameter);
    id result = [self _accessibilityAttributeValue:attribute forParameter:parameter];
    // NSLog(@"  returns %@", result);
    // NSLog(@"%@(%@) = %@", attribute, parameter, result);
    return result;
}

// TODO(georgen): Speed this up! This code is dreadfully slow but it's only used
// when accessibility is on, and it might be faster than voiceover for reasonable
// amounts of text.
- (NSString*)_allText
{
    [allText_ release];
    [lineBreakCharOffsets_ release];
    [lineBreakIndexOffsets_ release];

    allText_ = [[NSMutableString alloc] init];
    lineBreakCharOffsets_ = [[NSMutableArray alloc] init];
    lineBreakIndexOffsets_ = [[NSMutableArray alloc] init];

    int width = [dataSource width];
    unichar chars[width * kMaxParts];
    int offset = 0;
    for (int i = 0; i < [dataSource numberOfLines]; i++) {
        screen_char_t* line = [dataSource getLineAtIndex:i];
        int k;
        // Get line width, store it in k
        for (k = width - 1; k >= 0; k--) {
            if (line[k].code) {
                break;
            }
        }
        int o = 0;
        // Add first width-k chars to the 'chars' array, expanding complex chars.
        for (int j = 0; j <= k; j++) {
            if (line[j].complexChar) {
                NSString* cs = ComplexCharToStr(line[j].code);
                for (int l = 0; l < [cs length]; ++l) {
                    chars[o++] = [cs characterAtIndex:l];
                }
            } else {
                if (line[j].code >= 0xf000) {
                    // Don't output private range chars to accessibility.
                    chars[o++] = 0;
                } else {
                    chars[o++] = line[j].code;
                }
            }
        }
        // Append this line to allText_.
        offset += o;
        if (k >= 0) {
            [allText_ appendString:[NSString stringWithCharacters:chars length:o]];
        }
        if (line[width].code == EOL_HARD) {
            // Add a newline and update offsets arrays that track line break locations.
            [allText_ appendString:@"\n"];
            ++offset;
        }
        [lineBreakCharOffsets_ addObject:[NSNumber numberWithUnsignedLong:[allText_ length]]];
        [lineBreakIndexOffsets_ addObject:[NSNumber numberWithUnsignedLong:offset]];
    }

    return allText_;
}

- (id)_accessibilityAttributeValue:(NSString *)attribute
{
    if ([attribute isEqualToString:NSAccessibilityRoleAttribute]) {
        return NSAccessibilityTextAreaRole;
    } else if ([attribute isEqualToString:NSAccessibilityRoleDescriptionAttribute]) {
        return NSAccessibilityRoleDescriptionForUIElement(self);
    } else if ([attribute isEqualToString:NSAccessibilityHelpAttribute]) {
        return nil;
    } else if ([attribute isEqualToString:NSAccessibilityFocusedAttribute]) {
        return [NSNumber numberWithBool:YES];
    } else if ([attribute isEqualToString:NSAccessibilityDescriptionAttribute]) {
        return @"shell";
    } else if ([attribute isEqualToString:NSAccessibilityValueAttribute]) {
        return [self _allText];
    } else if ([attribute isEqualToString:NSAccessibilityNumberOfCharactersAttribute]) {
        return [NSNumber numberWithInt:[[self _allText] length]];
    } else if ([attribute isEqualToString:NSAccessibilitySelectedTextAttribute]) {
        return [self selectedText];
    } else if ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute]) {
        int x = [dataSource cursorX] - 1;
        int y = [dataSource numberOfLines] - [dataSource height] + [dataSource cursorY] - 1;
        // quick fix for ZoomText for Mac - it does not query AXValue or other
        // attributes that (re)generate allText_ and especially lineBreak{Char,Index}Offsets_
        // which are needed for _rangeOfCharAtX:y:
        [self _allText];
        NSRange range = [self _rangeOfCharAtX:x y:y];
        range.length--;
        return [NSValue valueWithRange:range];
    } else if ([attribute isEqualToString:NSAccessibilitySelectedTextRangesAttribute]) {
        return [NSArray arrayWithObject:
                [self _accessibilityAttributeValue:NSAccessibilitySelectedTextRangeAttribute]];
    } else if ([attribute isEqualToString:NSAccessibilityInsertionPointLineNumberAttribute]) {
        return [NSNumber numberWithInt:[dataSource cursorY]-1 + [dataSource numberOfScrollbackLines]];
    } else if ([attribute isEqualToString:NSAccessibilityVisibleCharacterRangeAttribute]) {
        return [NSValue valueWithRange:NSMakeRange(0, [[self _allText] length])];
    } else {
        return [super accessibilityAttributeValue:attribute];
    }
}

- (id)accessibilityAttributeValue:(NSString *)attribute {
    // NSLog(@"accessibilityAttributeValue:%@", attribute);
    id result = [self _accessibilityAttributeValue:attribute];
    // NSLog(@"  returns %@", result);
    // NSLog(@"%@ = %@", attribute, result);
    return result;
}

// This exists to work around an apparent OS bug described in issue 2690. Under some circumstances
// (which I cannot reproduce) the key window will be an NSToolbarFullScreenWindow and the PTYWindow
// will be one of the main windows. NSToolbarFullScreenWindow doesn't appear to handle keystrokes,
// so they fall through to the main window. We'd like the cursor to blink and have other key-
// window behaviors in this case.
- (BOOL)isInKeyWindow
{
    if ([[self window] isKeyWindow]) {
        DLog(@"%@ is key window", self);
        return YES;
    }
    NSWindow *theKeyWindow = [[NSApplication sharedApplication] keyWindow];
    if (!theKeyWindow) {
        DLog(@"There is no key window");
        return NO;
    }
    if (!strcmp("NSToolbarFullScreenWindow", object_getClassName(theKeyWindow))) {
        DLog(@"key window is a NSToolbarFullScreenWindow, using my main window status of %d as key status",
             (int)self.window.isMainWindow);
        return [[self window] isMainWindow];
    }
    return NO;
}

- (BOOL)_isCursorBlinking
{
    if ([self blinkingCursor] &&
        [self isInKeyWindow] &&
        [_delegate textViewIsActiveSession]) {
        return YES;
    } else {
        return NO;
    }
}

- (BOOL)_charBlinks:(screen_char_t)sct
{
    return blinkAllowed_ && sct.blink;
}

- (BOOL)_isTextBlinking
{
    int width = [dataSource width];
    int lineStart = ([self visibleRect].origin.y + VMARGIN) / lineHeight;  // add VMARGIN because stuff under top margin isn't visible.
    int lineEnd = ceil(([self visibleRect].origin.y + [self visibleRect].size.height - [self excess]) / lineHeight);
    if (lineStart < 0) {
        lineStart = 0;
    }
    if (lineEnd > [dataSource numberOfLines]) {
        lineEnd = [dataSource numberOfLines];
    }
    for (int y = lineStart; y < lineEnd; y++) {
        screen_char_t* theLine = [dataSource getLineAtIndex:y];
        for (int x = 0; x < width; x++) {
            if (theLine[x].blink) {
                return YES;
            }
        }
    }

    return NO;
}

- (BOOL)_isAnythingBlinking
{
    return [self _isCursorBlinking] || (blinkAllowed_ && [self _isTextBlinking]);
}

- (BOOL)refresh
{
    DebugLog(@"PTYTextView refresh called");
    if (dataSource == nil) {
        return YES;
    }

    // number of lines that have disappeared if scrollback buffer is full
    int scrollbackOverflow = [dataSource scrollbackOverflow];
    [dataSource resetScrollbackOverflow];

    // frame size changed?
    int height = [dataSource numberOfLines] * lineHeight;
    NSRect frame = [self frame];

    double excess = [self excess];

    if ((int)(height + excess + imeOffset * lineHeight) != (int)frame.size.height) {
        // Grow the frame
        // Add VMARGIN to include top margin.
        frame.size.height = height + excess + imeOffset * lineHeight + VMARGIN;
        [[self superview] setFrame:frame];
        frame.size.height -= VMARGIN;
        NSAccessibilityPostNotification(self, NSAccessibilityRowCountChangedNotification);
    } else if (scrollbackOverflow > 0) {
        // Some number of lines were lost from the head of the buffer.

        NSScrollView* scrollView = [self enclosingScrollView];
        double amount = [scrollView verticalLineScroll] * scrollbackOverflow;
        BOOL userScroll = [(PTYScroller*)([scrollView verticalScroller]) userScroll];

        // Keep correct selection highlighted
        [_selection moveUpByLines:scrollbackOverflow];
        [_oldSelection moveUpByLines:scrollbackOverflow];

        // Keep the user's current scroll position, nothing to redraw.
        if (userScroll) {
            BOOL redrawAll = NO;
            NSRect scrollRect = [self visibleRect];
            scrollRect.origin.y -= amount;
            if (scrollRect.origin.y < 0) {
                scrollRect.origin.y = 0;
                redrawAll = YES;
                [self setNeedsDisplay:YES];
            }
            [self scrollRectToVisible:scrollRect];
            if (!redrawAll) {
                return [self _isAnythingBlinking];
            }
        }

        // Shift the old content upwards
        if (scrollbackOverflow < [dataSource height] && !userScroll) {
            [self scrollRect:[self visibleRect] by:NSMakeSize(0, -amount)];
            NSRect topMargin = [self visibleRect];
            topMargin.size.height = VMARGIN;
            [self setNeedsDisplayInRect:topMargin];

#ifdef DEBUG_DRAWING
            [self appendDebug:[NSString stringWithFormat:@"refresh: Scroll by %d", (int)amount]];
#endif
            if ([self needsDisplay]) {
                // If any part of the view needed to be drawn prior to
                // scrolling, mark the whole thing as needing to be redrawn.
                // This avoids some race conditions between scrolling and
                // drawing.  For example, if there was a region that needed to
                // be displayed because the underlying data changed, but before
                // drawRect is called we scroll with [self scrollRect], then
                // the wrong region will be drawn. This could be optimized by
                // storing the regions that need to be drawn and re-invaliding
                // them in their new positions, but it should be somewhat rare
                // that this branch of the if statement is taken.
                [self setNeedsDisplay:YES];
            } else {
                // Invalidate the bottom of the screen that was revealed by
                // scrolling.
                NSRect dr = NSMakeRect(0, frame.size.height - amount, frame.size.width, amount);
#ifdef DEBUG_DRAWING
                [self appendDebug:[NSString stringWithFormat:@"refresh: setNeedsDisplayInRect:%d,%d %dx%d", (int)dr.origin.x, (int)dr.origin.y, (int)dr.size.width, (int)dr.size.height]];
#endif
                [self setNeedsDisplayInRect:dr];
            }
        }

        // Move subviews up
        [self updateNoteViewFrames];

        NSAccessibilityPostNotification(self, NSAccessibilityRowCountChangedNotification);
    }

    // Scroll to the bottom if needed.
    BOOL userScroll = [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) userScroll];
    if (!userScroll) {
        [self scrollEnd];
    }
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    long long absCursorY = [dataSource cursorY] + [dataSource numberOfLines] + [dataSource totalScrollbackOverflow] - [dataSource height];
    if ([dataSource cursorX] != accX ||
        absCursorY != accY) {
        NSAccessibilityPostNotification(self, NSAccessibilitySelectedTextChangedNotification);
        NSAccessibilityPostNotification(self, NSAccessibilitySelectedRowsChangedNotification);
        NSAccessibilityPostNotification(self, NSAccessibilitySelectedColumnsChangedNotification);
        accX = [dataSource cursorX];
        accY = absCursorY;
        if (UAZoomEnabled()) {
            CGRect viewRect = NSRectToCGRect([self.window convertRectToScreen:[self convertRect:[self visibleRect] toView:nil]]);
            CGRect selectedRect = NSRectToCGRect([self.window convertRectToScreen:[self convertRect:[self cursorRect] toView:nil]]);
            viewRect.origin.y = [[NSScreen mainScreen] frame].size.height - (viewRect.origin.y + viewRect.size.height);
            selectedRect.origin.y = [[NSScreen mainScreen] frame].size.height - (selectedRect.origin.y + selectedRect.size.height);
            UAZoomChangeFocus(&viewRect, &selectedRect, kUAZoomFocusTypeInsertionPoint);
        }
    }

    if ([[self subviews] count]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PTYNoteViewControllerShouldUpdatePosition
                                                            object:nil];
        // Not sure why this is needed, but for some reason this view draws over its subviews.
        for (NSView *subview in [self subviews]) {
            [subview setNeedsDisplay:YES];
        }
    }

    return [self updateDirtyRects] || [self _isCursorBlinking];
}

- (void)setNeedsDisplayOnLine:(int)line
{
    [self setNeedsDisplayOnLine:line inRange:VT100GridRangeMake(0, dataSource.width)];
}

// Overrides an NSView method.
- (NSRect)adjustScroll:(NSRect)proposedVisibleRect
{
    proposedVisibleRect.origin.y = (int)(proposedVisibleRect.origin.y / lineHeight + 0.5) * lineHeight;
    return proposedVisibleRect;
}

- (void)scrollLineUp:(id)sender
{
    NSRect scrollRect;

    scrollRect= [self visibleRect];
    scrollRect.origin.y-=[[self enclosingScrollView] verticalLineScroll];
    if (scrollRect.origin.y<0) scrollRect.origin.y=0;
    [self scrollRectToVisible: scrollRect];
}

- (void)scrollLineDown:(id)sender
{
    NSRect scrollRect;

    scrollRect= [self visibleRect];
    scrollRect.origin.y+=[[self enclosingScrollView] verticalLineScroll];
    [self scrollRectToVisible: scrollRect];
}

- (void)scrollPageUp:(id)sender
{
    NSRect scrollRect;

    scrollRect = [self visibleRect];
    scrollRect.origin.y -= scrollRect.size.height - [[self enclosingScrollView] verticalPageScroll];
    [self scrollRectToVisible:scrollRect];
}

- (void)scrollPageDown:(id)sender
{
    NSRect scrollRect;

    scrollRect = [self visibleRect];
    scrollRect.origin.y+= scrollRect.size.height - [[self enclosingScrollView] verticalPageScroll];
    [self scrollRectToVisible: scrollRect];
}

- (void)scrollHome
{
    NSRect scrollRect;

    scrollRect = [self visibleRect];
    scrollRect.origin.y = 0;
    [self scrollRectToVisible: scrollRect];
}

- (void)scrollEnd
{
    if ([dataSource numberOfLines] <= 0) {
      return;
    }
    NSRect lastLine = [self visibleRect];
    lastLine.origin.y = ([dataSource numberOfLines] - 1) * lineHeight + [self excess] + imeOffset * lineHeight;
    lastLine.size.height = lineHeight;
    if (!NSContainsRect(self.visibleRect, lastLine)) {
        [self scrollRectToVisible:lastLine];
    }
}

- (long long)absoluteScrollPosition
{
    NSRect visibleRect = [self visibleRect];
    long long localOffset = (visibleRect.origin.y + VMARGIN) / [self lineHeight];
    return localOffset + [dataSource totalScrollbackOverflow];
}

- (void)scrollToAbsoluteOffset:(long long)absOff height:(int)height
{
    NSRect aFrame;
    aFrame.origin.x = 0;
    aFrame.origin.y = (absOff - [dataSource totalScrollbackOverflow]) * lineHeight - VMARGIN;
    aFrame.size.width = [self frame].size.width;
    aFrame.size.height = lineHeight * height;
    [self scrollRectToVisible: aFrame];
    [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
}

- (void)scrollToSelection
{
    if ([_selection hasSelection]) {
        NSRect aFrame;
        VT100GridCoordRange range = [_selection spanningRange];
        aFrame.origin.x = 0;
        aFrame.origin.y = range.start.y * lineHeight - VMARGIN;  // allow for top margin
        aFrame.size.width = [self frame].size.width;
        aFrame.size.height = (range.end.y - range.start.y + 1) *lineHeight;
        [self scrollRectToVisible: aFrame];
        [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
    }
}

- (void)markCursorDirty
{
  int currentCursorX = [dataSource cursorX] - 1;
  int currentCursorY = [dataSource cursorY] - 1;
  DLog(@"Mark cursor position %d,%d dirty", prevCursorX, prevCursorY);
  [dataSource setCharDirtyAtCursorX:currentCursorX Y:currentCursorY];
}

- (void)hideCursor
{
    DLog(@"hideCursor");
    [self markCursorDirty];
    CURSOR = NO;
}

- (void)showCursor
{
    DLog(@"showCursor");
    [self markCursorDirty];
    CURSOR = YES;
}

- (BOOL)cursorIsVisible
{
    return CURSOR;
}

- (void)drawRect:(NSRect)rect
{
    DLog(@"drawRect:%@ in view %@", [NSValue valueWithRect:rect], self);
    // If there are two or more rects that need display, the OS will pass in |rect| as the smallest
    // bounding rect that contains them all. Luckily, we can get the list of the "real" dirty rects
    // and they're guaranteed to be disjoint. So draw each of them individually.
    const NSRect *rectArray;
    NSInteger rectCount;
    if (drawRectDuration_) {
        [drawRectDuration_ startTimer];
        NSTimeInterval interval = [drawRectInterval_ timeSinceTimerStarted];
        if ([drawRectInterval_ haveStartedTimer]) {
            [drawRectInterval_ addValue:interval];
        }
        [drawRectInterval_ startTimer];
    }
    [self getRectsBeingDrawn:&rectArray count:&rectCount];
    for (int i = 0; i < rectCount; i++) {
        DLog(@"drawRect - draw sub rectangle %@", [NSValue valueWithRect:rectArray[i]]);
        [self drawRect:rectArray[i] to:nil];
    }
    if (drawRectDuration_) {
        [drawRectDuration_ addValue:[drawRectDuration_ timeSinceTimerStarted]];
        NSLog(@"%p Moving average time draw rect is %04f, time between calls to drawRect is %04f",
              self, drawRectDuration_.value, drawRectInterval_.value);
    }
    const NSRect frame = [self visibleRect];
    double x = frame.origin.x + frame.size.width;
    if ([_delegate textViewSessionIsBroadcastingInput]) {
        NSSize size = [broadcastInputImage size];
        x -= size.width + kBroadcastMargin;
        [broadcastInputImage drawAtPoint:NSMakePoint(x,
                                                     frame.origin.y + kBroadcastMargin)
                                fromRect:NSMakeRect(0, 0, size.width, size.height)
                               operation:NSCompositeSourceOver
                                fraction:0.5];
    }

    if ([_delegate textViewHasCoprocess]) {
        NSSize size = [coprocessImage size];
        x -= size.width + kCoprocessMargin;
        [coprocessImage drawAtPoint:NSMakePoint(x,
                                                     frame.origin.y + kCoprocessMargin)
                                fromRect:NSMakeRect(0, 0, size.width, size.height)
                               operation:NSCompositeSourceOver
                                fraction:0.5];
    }
    if ([_delegate alertOnNextMark]) {
        NSSize size = [alertImage size];
        x -= size.width + kAlertMargin;
        [alertImage drawAtPoint:NSMakePoint(x, frame.origin.y + kAlertMargin)
                           fromRect:NSMakeRect(0, 0, size.width, size.height)
                          operation:NSCompositeSourceOver
                           fraction:0.5];
    }

    if (flashing_ > 0) {
        NSImage* image = nil;
        switch (flashImage_) {
            case FlashBell:
                if ([[PreferencePanel sharedInstance] traditionalVisualBell]) {
                    image = [[[NSImage alloc] initWithSize: frame.size] autorelease];
                    [image lockFocus];
                    [defaultFGColor drawSwatchInRect:NSMakeRect(0, 0, frame.size.width, frame.size.width)];
                    [image unlockFocus];
                } else {
                    image = bellImage;
                }
                break;

            case FlashWrapToTop:
                image = wrapToTopImage;
                break;

            case FlashWrapToBottom:
                image = wrapToBottomImage;
                break;
        }

        NSSize size = [image size];
        [image drawAtPoint:NSMakePoint(frame.origin.x + frame.size.width/2 - size.width/2,
                                       frame.origin.y + frame.size.height/2 - size.height/2)
                  fromRect:NSMakeRect(0, 0, size.width, size.height)
                 operation:NSCompositeSourceOver
                  fraction:flashing_];
    }

    [self drawOutlineInRect:rect topOnly:NO];

    if (showTimestamps_) {
        [self drawTimestamps];
    }

    // Not sure why this is needed, but for some reason this view draws over its subviews.
    for (NSView *subview in [self subviews]) {
        [subview setNeedsDisplay:YES];
    }
}

- (void)drawTimestamps
{
    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];

    for (int y = visibleRect.origin.y / lineHeight;
         y < (visibleRect.origin.y + visibleRect.size.height) / lineHeight && y < [dataSource numberOfLines];
         y++) {
        [self drawTimestampForLine:y];
    }
}

- (void)drawTimestampForLine:(int)line
{
    NSDate *timestamp = [dataSource timestampForLine:line];
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    const NSTimeInterval day = -86400;
    const NSTimeInterval timeDelta = [timestamp timeIntervalSinceNow];
    if (timeDelta < day * 365) {
        // More than a year ago: include year
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"yyyyMMMd hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    } else if (timeDelta < day * 7) {
        // 1 week to 1 year ago: include date without year
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"MMMd hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    } else if (timeDelta < day) {
        // 1 day to 1 week ago: include day of week
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"EEE hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
        
    } else {
        // In last 24 hours, just show time
        [fmt setDateFormat:[NSDateFormatter dateFormatFromTemplate:@"hh:mm:ss"
                                                           options:0
                                                            locale:[NSLocale currentLocale]]];
    }
        
    NSString *s = [fmt stringFromDate:timestamp];

    NSSize size = [s sizeWithAttributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:10] }];
    int w = size.width + MARGIN;
    int x = MAX(0, self.frame.size.width - w);
    CGFloat y = line * lineHeight;
    NSColor *bgColor = defaultBGColor;
    NSColor *fgColor = defaultFGColor;
    BOOL isDark = ([self perceivedBrightness:defaultFGColor] < kBackgroundConsideredDarkThreshold);
    NSColor *shadowColor;
    if (isDark) {
        shadowColor = [NSColor whiteColor];
    } else {
        shadowColor = [NSColor blackColor];
    }

    const CGFloat alpha = 0.75;
    NSGradient *gradient =
        [[[NSGradient alloc] initWithStartingColor:[bgColor colorWithAlphaComponent:0]
                                       endingColor:[bgColor colorWithAlphaComponent:alpha]] autorelease];
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
    [gradient drawInRect:NSMakeRect(x - 20, y, 20, lineHeight) angle:0];

    [[bgColor colorWithAlphaComponent:alpha] set];
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
    NSRectFillUsingOperation(NSMakeRect(x, y, w, lineHeight), NSCompositeSourceOver);

    NSShadow *shadow = [[[NSShadow alloc] init] autorelease];
    shadow.shadowColor = shadowColor;
    shadow.shadowBlurRadius = 0.2f;
    shadow.shadowOffset = CGSizeMake(0.5, -0.5);

    NSDictionary *attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:10],
                                  NSForegroundColorAttributeName: fgColor,
                                  NSShadowAttributeName: shadow };
    CGFloat offset = (lineHeight - size.height) / 2;
    [s drawAtPoint:NSMakePoint(x, y + offset) withAttributes:attributes];
}

- (void)drawOutlineInRect:(NSRect)rect topOnly:(BOOL)topOnly
{
    if ([_delegate textViewTabHasMaximizedPanel]) {
        NSColor *color = [self defaultBGColor];
        double r = [color redComponent];
        double g = [color greenComponent];
        double b = [color blueComponent];
        double pb = PerceivedBrightness(r, g, b);
        double k;
        if (pb <= 0.5) {
            k = 1;
        } else {
            k = 0;
        }
        const double alpha = 0.2;
        r = alpha * k + (1 - alpha) * r;
        g = alpha * k + (1 - alpha) * g;
        b = alpha * k + (1 - alpha) * b;
        color = [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1];

        NSRect frame = [self visibleRect];
        if (!topOnly) {
            if (frame.origin.y < VMARGIN) {
                frame.size.height += (VMARGIN - frame.origin.y);
                frame.origin.y -= (VMARGIN - frame.origin.y);
            }
        }
        NSBezierPath *path = [[[NSBezierPath alloc] init] autorelease];
        CGFloat left = frame.origin.x + 0.5;
        CGFloat right = frame.origin.x + frame.size.width - 0.5;
        CGFloat top = frame.origin.y + 0.5;
        CGFloat bottom = frame.origin.y + frame.size.height - 0.5;

        if (topOnly) {
            [path moveToPoint:NSMakePoint(left, top + VMARGIN)];
            [path lineToPoint:NSMakePoint(left, top)];
            [path lineToPoint:NSMakePoint(right, top)];
            [path lineToPoint:NSMakePoint(right, top + VMARGIN)];
        } else {
            [path moveToPoint:NSMakePoint(left, top + VMARGIN)];
            [path lineToPoint:NSMakePoint(left, top)];
            [path lineToPoint:NSMakePoint(right, top)];
            [path lineToPoint:NSMakePoint(right, bottom)];
            [path lineToPoint:NSMakePoint(left, bottom)];
            [path lineToPoint:NSMakePoint(left, top + VMARGIN)];
        }

        CGFloat dashPattern[2] = { 5, 5 };
        [path setLineDash:dashPattern count:2 phase:0];
        [color set];
        [path stroke];
    }
}

- (void)drawRect:(NSRect)rect to:(NSPoint*)toOrigin
{
    // The range of chars in the line that need to be drawn.
    NSRange charRange = NSMakeRange(MAX(0, (rect.origin.x - MARGIN) / charWidth),
                                    (rect.origin.x + rect.size.width - MARGIN) / charWidth);
    charRange.length -= charRange.location;
    if (charRange.location + charRange.length > [dataSource width]) {
        charRange.length = [dataSource width] - charRange.location;
    }
#ifdef DEBUG_DRAWING
    static int iteration=0;
    static BOOL prevBad=NO;
    ++iteration;
    if (prevBad) {
        NSLog(@"Last was bad.");
        prevBad = NO;
    }
    DebugLog([NSString stringWithFormat:@"%s(%p): rect=(%f,%f,%f,%f) frameRect=(%f,%f,%f,%f)]",
          __PRETTY_FUNCTION__, self,
          rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
          [self frame].origin.x, [self frame].origin.y, [self frame].size.width, [self frame].size.height]);
#endif
    double curLineWidth = [dataSource width] * charWidth;
    if (lineHeight <= 0 || curLineWidth <= 0) {
        DebugLog(@"height or width too small");
        return;
    }

    // Configure graphics
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeCopy];

    // Where to start drawing?
    int lineStart = rect.origin.y / lineHeight;
    int lineEnd = ceil((rect.origin.y + rect.size.height) / lineHeight);

    // Ensure valid line ranges
    if (lineStart < 0) {
        lineStart = 0;
    }
    if (lineEnd > [dataSource numberOfLines]) {
        lineEnd = [dataSource numberOfLines];
    }
    NSRect visible = [self scrollViewContentSize];
    int vh = visible.size.height;
    int lh = lineHeight;
    int visibleRows = vh / lh;
    NSRect docVisibleRect = [[self enclosingScrollView] documentVisibleRect];
    double hiddenAbove = docVisibleRect.origin.y + [self frame].origin.y;
    int firstVisibleRow = hiddenAbove / lh;
    if (lineEnd > firstVisibleRow + visibleRows) {
        lineEnd = firstVisibleRow + visibleRows;
    }

#ifdef DEBUG_DRAWING
    DebugLog([NSString stringWithFormat:@"drawRect: Draw lines in range [%d, %d)", lineStart, lineEnd]);
    // Draw each line
    NSDictionary* dct =
        [NSDictionary dictionaryWithObjectsAndKeys:
            [NSColor textBackgroundColor], NSBackgroundColorAttributeName,
            [NSColor textColor], NSForegroundColorAttributeName,
            [NSFont userFixedPitchFontOfSize: 0], NSFontAttributeName, NULL];
#endif
    int overflow = [dataSource scrollbackOverflow];
#ifdef DEBUG_DRAWING
    NSMutableString* lineDebug = [NSMutableString stringWithFormat:@"drawRect:%d,%d %dx%d drawing these lines with scrollback overflow of %d, iteration=%d:\n", (int)rect.origin.x, (int)rect.origin.y, (int)rect.size.width, (int)rect.size.height, (int)[dataSource scrollbackOverflow], iteration];
#endif
    double y = lineStart * lineHeight;
    const double initialY = y;
    BOOL anyBlinking = NO;

    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];

    for (int line = lineStart; line < lineEnd; line++) {
        NSRect lineRect = [self visibleRect];
        lineRect.origin.y = line*lineHeight;
        lineRect.size.height = lineHeight;
        if ([self needsToDrawRect:lineRect]) {
            if (overflow <= line) {
                // If overflow > 0 then the lines in the dataSource are not
                // lined up in the normal way with the view. This happens when
                // the datasource has scrolled its contents up but -[refresh]
                // has not been called yet, so the view's contents haven't been
                // scrolled up yet. When that's the case, the first line of the
                // view is what the first line of the datasource was before
                // it overflowed. Continue to draw text in this out-of-alignment
                // manner until refresh is called and gets things in sync again.
                NSPoint temp;
                if (toOrigin) {
                    const CGFloat offsetFromTopOfScreen = y - initialY;
                    temp = NSMakePoint(toOrigin->x, toOrigin->y + offsetFromTopOfScreen);
                }
                anyBlinking |= [self _drawLine:line-overflow
                                           AtY:y
                                       toPoint:toOrigin ? &temp : nil
                                     charRange:charRange
                                       context:ctx];
            }
#ifdef DEBUG_DRAWING
            // if overflow > line then the requested line cannot be drawn
            // because it has been lost to the sands of time.
            if (gDebugLogging) {
                screen_char_t* theLine = [dataSource getLineAtIndex:line-overflow];
                int w = [dataSource width];
                char dl[w+1];
                for (int i = 0; i < [dataSource width]; ++i) {
                    if (theLine[i].complexChar) {
                        dl[i] = '#';
                    } else {
                        dl[i] = theLine[i].code;
                    }
                }
                DebugLog([NSString stringWithUTF8String:dl]);
            }

            screen_char_t* theLine = [dataSource getLineAtIndex:line-overflow];
            for (int i = 0; i < [dataSource width]; ++i) {
                [lineDebug appendFormat:@"%@", ScreenCharToStr(&theLine[i])];
            }
            [lineDebug appendString:@"\n"];
            [[NSString stringWithFormat:@"Iter %d, line %d, y=%d", iteration, line, (int)(y)]
                 drawInRect:NSMakeRect(rect.size.width-200,
                                       y,
                                       200,
                                       lineHeight)
                 withAttributes:dct];
#endif
        }
        y += lineHeight;
    }
#ifdef DEBUG_DRAWING
    [self appendDebug:lineDebug];
#endif
    NSRect excessRect;
    if (imeOffset) {
        // Draw a default-color rectangle from below the last line of text to
        // the bottom of the frame to make sure that IME offset lines are
        // cleared when the screen is scrolled up.
        excessRect.origin.x = 0;
        excessRect.origin.y = lineEnd * lineHeight;
        excessRect.size.width = [[self enclosingScrollView] contentSize].width;
        excessRect.size.height = [self frame].size.height - excessRect.origin.y;
    } else  {
        // Draw the excess bar at the bottom of the visible rect the in case
        // that some other tab has a larger font and these lines don't fit
        // evenly in the available space.
        NSRect visibleRect = [self visibleRect];
        excessRect.origin.x = 0;
        excessRect.origin.y = visibleRect.origin.y + visibleRect.size.height - [self excess];
        excessRect.size.width = [[self enclosingScrollView] contentSize].width;
        excessRect.size.height = [self excess];
    }
#ifdef DEBUG_DRAWING
    // Draws the excess bar in a different color each time
    static int i;
    i++;
    double rc = ((double)((i + 0) % 100)) / 100;
    double gc = ((double)((i + 33) % 100)) / 100;
    double bc = ((double)((i + 66) % 100)) / 100;
    [[NSColor colorWithCalibratedRed:rc green:gc blue:bc alpha:1] set];
    NSRectFill(excessRect);
#else
    if (toOrigin) {
        [self drawBackground:excessRect toPoint:*toOrigin];
    } else {
        [self drawBackground:excessRect];
    }
#endif

    // Draw a margin at the top of the visible area.
    NSRect topMarginRect = [self visibleRect];
    if (topMarginRect.origin.y > 0) {
        topMarginRect.size.height = VMARGIN;
        if (toOrigin) {
            [self drawBackground:topMarginRect toPoint:*toOrigin];
        } else {
            [self drawBackground:topMarginRect];
        }
    }

#ifdef DEBUG_DRAWING
    // Draws a different-colored rectangle around each drawn area. Useful for
    // seeing which groups of lines were drawn in a batch.
    static double it;
    it += 3.14/4;
    double red = sin(it);
    double green = sin(it + 1*2*3.14/3);
    double blue = sin(it + 2*2*3.14/3);
    NSColor* c = [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1];
    [c set];
    NSRect r = rect;
    r.origin.y++;
    r.size.height -= 2;
    NSFrameRect(rect);
    if (overflow != 0) {
        // Draw a diagonal line through blocks that were drawn when there
        // [dataSource scrollbackOverflow] > 0.
        [NSBezierPath strokeLineFromPoint:NSMakePoint(r.origin.x, r.origin.y)
                                  toPoint:NSMakePoint(r.origin.x + r.size.width, r.origin.y + r.size.height)];
    }
    NSString* debug;
    if (overflow == 0) {
        debug = [NSString stringWithFormat:@"origin=%d", (int)rect.origin.y];
    } else {
        debug = [NSString stringWithFormat:@"origin=%d, overflow=%d", (int)rect.origin.y, (int)overflow];
    }
    [debug drawInRect:rect withAttributes:dct];
#endif
    // If the IME is in use, draw its contents over top of the "real" screen
    // contents.
    [self drawInputMethodEditorTextAt:[dataSource cursorX] - 1
                                    y:[dataSource cursorY] - 1
                                width:[dataSource width]
                               height:[dataSource height]
                         cursorHeight:[self cursorHeight]
                                  ctx:ctx];
    [self _drawCursorTo:toOrigin];
    anyBlinking |= [self _isCursorBlinking];

#ifdef DEBUG_DRAWING
    if (overflow) {
        // It's useful to put a breakpoint at the top of this function
        // when prevBad == YES because then you can see the results of this
        // draw function.
        prevBad=YES;
    }
#endif
    if (anyBlinking) {
        // The user might have used the scroll wheel to cause blinking text to become
        // visible. Make sure the timer is running if anything onscreen is
        // blinking.
        [_delegate textViewWillNeedUpdateForBlink];
    }
    [selectedFont_ release];
    selectedFont_ = nil;
}

- (NSString*)_getTextInWindowAroundX:(int)x
                                   y:(int)y
                            numLines:(int)numLines
                        targetOffset:(int*)targetOffset
                              coords:(NSMutableArray*)coords
                    ignoringNewlines:(BOOL)ignoringNewlines
{
    const int width = [dataSource width];
    NSMutableString* joinedLines = [NSMutableString stringWithCapacity:numLines * width];

    *targetOffset = -1;

    // If rejectAtHardEol is true, then stop when you hit a hard EOL.
    // If false, stop when you hit a hard EOL that has an unused cell before it,
    // otherwise keep going.
    BOOL rejectAtHardEol = !ignoringNewlines;
    int xMin, xMax;
    xMin = 0;
    xMax = width;

    // Any text preceding a hard line break on a line before |y| should not be considered.
    int j = 0;
    int firstLine = y - numLines;
    for (int i = y - numLines; i < y; i++) {
        if (i < 0 || i >= [dataSource numberOfLines]) {
            continue;
        }
        screen_char_t* theLine = [dataSource getLineAtIndex:i];
        if (i < y && theLine[width].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[width - 1].code == 0) {
                firstLine = i + 1;
            }
        }
    }

    for (int i = firstLine; i <= y + numLines; i++) {
        if (i < 0 || i >= [dataSource numberOfLines]) {
            continue;
        }
        screen_char_t* theLine = [dataSource getLineAtIndex:i];
        if (i < y && theLine[width].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[width - 1].code == 0) {
                continue;
            }
        }
        unichar* backingStore;
        int* deltas;
        NSString* string = ScreenCharArrayToString(theLine,
                                                   xMin,
                                                   MIN(EffectiveLineLength(theLine, width), xMax),
                                                   &backingStore,
                                                   &deltas);
        int o = 0;
        for (int k = 0; k < [string length]; k++) {
            o = k + deltas[k];
            if (*targetOffset == -1 && i == y && o >= x) {
                *targetOffset = k + [joinedLines length];
            }
            [coords addObject:[NSValue valueWithGridCoord:VT100GridCoordMake(o, i)]];
        }
        [joinedLines appendString:string];
        free(deltas);
        free(backingStore);

        j++;
        o++;
        if (i >= y && theLine[width].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[width - 1].code == 0) {
                [coords addObject:[NSValue valueWithGridCoord:VT100GridCoordMake(o, i)]];
                break;
            }
        }
    }
    // TODO: What if it's multiple lines ending in a soft eol and the selection goes to the end?
    return joinedLines;
}

- (NSDictionary *)smartSelectAtX:(int)x
                               y:(int)y
                              to:(VT100GridCoordRange *)rangePtr
                ignoringNewlines:(BOOL)ignoringNewlines
                  actionRequired:(BOOL)actionRequred
{
    NSString* textWindow;
    int targetOffset;
    const int numLines = 2;
    const int width = [dataSource width];
    NSMutableArray* coords = [NSMutableArray arrayWithCapacity:numLines * width];
    textWindow = [self _getTextInWindowAroundX:x
                                             y:y
                                      numLines:2
                                  targetOffset:&targetOffset
                                        coords:coords
                              ignoringNewlines:ignoringNewlines];

    NSArray* rulesArray = smartSelectionRules_ ? smartSelectionRules_ : [SmartSelectionController defaultRules];
    const int numRules = [rulesArray count];

    NSMutableDictionary* matches = [NSMutableDictionary dictionaryWithCapacity:13];
    int numCoords = [coords count];

    BOOL debug = [SmartSelectionController logDebugInfo];
    if (debug) {
        NSLog(@"Perform smart selection on text: %@", textWindow);
    }
    for (int j = 0; j < numRules; j++) {
        NSDictionary *rule = [rulesArray objectAtIndex:j];
        if (actionRequred && [[SmartSelectionController actionsInRule:rule] count] == 0) {
            DLog(@"Ignore smart selection rule because it has no action: %@", rule);
            continue;
        }
        NSString *regex = [SmartSelectionController regexInRule:rule];
        double precision = [SmartSelectionController precisionInRule:rule];
        if (debug) {
            NSLog(@"Try regex %@", regex);
        }
        for (int i = 0; i <= targetOffset; i++) {
            NSString* substring = [textWindow substringWithRange:NSMakeRange(i, [textWindow length] - i)];
            NSError* regexError = nil;
            NSRange temp = [substring rangeOfRegex:regex
                                           options:0
                                           inRange:NSMakeRange(0, [substring length])
                                           capture:0
                                             error:&regexError];
            if (temp.location != NSNotFound) {
                if (i + temp.location <= targetOffset && i + temp.location + temp.length > targetOffset) {
                    NSString* result = [substring substringWithRange:temp];
                    double score = precision * (double) temp.length;
                    SmartMatch* oldMatch = [matches objectForKey:result];
                    if (!oldMatch || score > oldMatch.score) {
                        SmartMatch* match = [[[SmartMatch alloc] init] autorelease];
                        match.score = score;
                        VT100GridCoord startCoord = [[coords objectAtIndex:i + temp.location] gridCoordValue];
                        VT100GridCoord endCoord = [[coords objectAtIndex:MIN(numCoords - 1, i + temp.location + temp.length)] gridCoordValue];
                        match.startX = startCoord.x;
                        match.absStartY = startCoord.y + [dataSource totalScrollbackOverflow];
                        match.endX = endCoord.x;
                        match.absEndY = endCoord.y + [dataSource totalScrollbackOverflow];
                        match.rule = rule;
                        [matches setObject:match forKey:result];

                        if (debug) {
                            NSLog(@"Add result %@ at %d,%lld -> %d,%lld with score %lf", result, match.startX, match.absStartY, match.endX, match.absEndY, match.score);
                        }
                    }
                    i += temp.location + temp.length - 1;
                } else {
                    i += temp.location;
                }
            } else {
                break;
            }
        }
    }

    if ([matches count]) {
        NSArray* sortedMatches = [[matches allValues] sortedArrayUsingSelector:@selector(compare:)];
        SmartMatch* bestMatch = [sortedMatches lastObject];
        if (debug) {
            NSLog(@"Select match with score %lf", bestMatch.score);
        }
        *rangePtr = VT100GridCoordRangeMake(bestMatch.startX,
                                            bestMatch.absStartY - [dataSource totalScrollbackOverflow],
                                            bestMatch.endX,
                                            bestMatch.absEndY - [dataSource totalScrollbackOverflow]);
        return bestMatch.rule;
    } else {
        if (debug) {
            NSLog(@"No matches. Fall back on word selection.");
        }
        // Fall back on word selection
        [self getWordForX:x
                        y:y
                    range:rangePtr];
        return nil;
    }
}

- (BOOL)smartSelectAtX:(int)x y:(int)y ignoringNewlines:(BOOL)ignoringNewlines
{
    VT100GridCoordRange range;
    NSDictionary *rule = [self smartSelectAtX:x
                                            y:y
                                           to:&range
                             ignoringNewlines:ignoringNewlines
                               actionRequired:NO];

    [_selection beginSelectionAt:VT100GridCoordMake(x, y)
                            mode:kiTermSelectionModeSmart
                          resume:NO
                          append:NO];
    [_selection endLiveSelection];
    return rule != nil;
}

// Control-pgup and control-pgdown are handled at this level by NSWindow if no
// view handles it. It's necessary to setUserScroll in the PTYScroller, or else
// it scrolls back to the bottom right away. This code handles those two
// keypresses and scrolls correctly.
- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
    NSString* unmodkeystr = [theEvent charactersIgnoringModifiers];
    if ([unmodkeystr length] == 0) {
        return [super performKeyEquivalent:theEvent];
    }
    unichar unmodunicode = [unmodkeystr length] > 0 ? [unmodkeystr characterAtIndex:0] : 0;

    NSUInteger modifiers = [theEvent modifierFlags];
    if ((modifiers & NSControlKeyMask) &&
        (modifiers & NSFunctionKeyMask)) {
        switch (unmodunicode) {
            case NSPageUpFunctionKey:
                [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
                [self scrollPageUp:self];
                return YES;

            case NSPageDownFunctionKey:
                [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
                [self scrollPageDown:self];
                return YES;

            default:
                break;
        }
    }
    return [super performKeyEquivalent:theEvent];
}

- (void)keyDown:(NSEvent*)event
{
    static BOOL isFirstInteraction = YES;
    if (isFirstInteraction) {
        iTermApplicationDelegate *appDelegate = (iTermApplicationDelegate *)[[NSApplication sharedApplication] delegate];
        [appDelegate userDidInteractWithASession];
        isFirstInteraction = NO;
    }

    BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];

    if (debugKeyDown) {
        NSLog(@"PTYTextView keyDown BEGIN %@", event);
    }
    DebugLog(@"PTYTextView keyDown");
    id delegate = [self delegate];
    if ([delegate isPasting]) {
        [delegate queueKeyDown:event];
        return;
    }
    if ([_delegate textViewDelegateHandlesAllKeystrokes]) {
        if (debugKeyDown) {
            NSLog(@"PTYTextView keyDown: in instant replay, send to delegate");
        }
        // Delegate has special handling for this case.
        [delegate keyDown:event];
        return;
    }
    unsigned int modflag = [event modifierFlags];
    unsigned short keyCode = [event keyCode];
    BOOL prev = [self hasMarkedText];

    keyIsARepeat = [event isARepeat];
    if (debugKeyDown) {
        NSLog(@"PTYTextView keyDown modflag=%d keycode=%d", modflag, (int)keyCode);
        NSLog(@"prev=%d", (int)prev);
        NSLog(@"hasActionableKeyMappingForEvent=%d", (int)[delegate hasActionableKeyMappingForEvent:event]);
        NSLog(@"modFlag & (NSNumericPadKeyMask | NSFUnctionKeyMask)=%d", (modflag & (NSNumericPadKeyMask | NSFunctionKeyMask)));
        NSLog(@"charactersIgnoringModififiers length=%d", (int)[[event charactersIgnoringModifiers] length]);
        NSLog(@"delegate optionkey=%d, delegate rightOptionKey=%d", (int)[delegate optionKey], (int)[delegate rightOptionKey]);
        NSLog(@"modflag & leftAlt == leftAlt && optionKey != NORMAL = %d", (int)((modflag & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask && [delegate optionKey] != OPT_NORMAL));
        NSLog(@"modflag == alt && optionKey != NORMAL = %d", (int)(modflag == NSAlternateKeyMask && [delegate optionKey] != OPT_NORMAL));
        NSLog(@"modflag & rightAlt == rightAlt && rightOptionKey != NORMAL = %d", (int)((modflag & NSRightAlternateKeyMask) == NSRightAlternateKeyMask && [delegate rightOptionKey] != OPT_NORMAL));
        NSLog(@"isControl=%d", (int)(modflag & NSControlKeyMask));
        NSLog(@"keycode is slash=%d, is backslash=%d", (keyCode == 0x2c), (keyCode == 0x2a));
        NSLog(@"event is repeated=%d", keyIsARepeat);
    }

    // discard repeated key events if auto repeat mode (DECARM) is disabled
    if (keyIsARepeat && ![[dataSource terminal] autorepeatMode]) {
        return;
    }
    
    // Hide the cursor
    [NSCursor setHiddenUntilMouseMoves:YES];
    
    if ([[iTermNSKeyBindingEmulator sharedInstance] handlesEvent:event]) {
        DLog(@"iTermNSKeyBindingEmulator reports that event is handled, sending to interpretKeyEvents.");
        [self interpretKeyEvents:@[ event ]];
        return;
    }

    // Should we process the event immediately in the delegate?
    if ((!prev) &&
        ([delegate hasActionableKeyMappingForEvent:event] ||       // delegate will do something useful
         (modflag & (NSNumericPadKeyMask | NSFunctionKeyMask)) ||  // is an arrow key, f key, etc.
         ([[event charactersIgnoringModifiers] length] > 0 &&      // Will send Meta/Esc+ (length is 0 if it's a dedicated dead key)
          (((modflag & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask && [delegate optionKey] != OPT_NORMAL) ||
           (modflag == NSAlternateKeyMask && [delegate optionKey] != OPT_NORMAL) ||  // Synergy sends an Alt key that's neither left nor right!
           ((modflag & NSRightAlternateKeyMask) == NSRightAlternateKeyMask && [delegate rightOptionKey] != OPT_NORMAL))) ||
         ((modflag & NSControlKeyMask) &&                          // a few special cases
          (keyCode == 0x2c /* slash */ || keyCode == 0x2a /* backslash */)))) {
        if (debugKeyDown) {
            NSLog(@"PTYTextView keyDown: process in delegate");
        }
        [delegate keyDown:event];
        return;
    }

    if (debugKeyDown) {
        NSLog(@"Test for command key");
    }
    if (modflag & NSCommandKeyMask) {
        // You pressed cmd+something but it's not handled by the delegate. Going further would
        // send the unmodified key to the terminal which doesn't make sense.
        if (debugKeyDown) {
            NSLog(@"PTYTextView keyDown You pressed cmd+something");
        }
        return;
    }

    // Control+Key doesn't work right with custom keyboard layouts. Handle ctrl+key here for the
    // standard combinations.
    BOOL workAroundControlBug = NO;
    if (!prev &&
        (modflag & (NSControlKeyMask | NSCommandKeyMask | NSAlternateKeyMask)) == NSControlKeyMask) {
        if (debugKeyDown) {
            NSLog(@"Special ctrl+key handler running");
        }
        NSString *unmodkeystr = [event charactersIgnoringModifiers];
        if ([unmodkeystr length] != 0) {
            unichar unmodunicode = [unmodkeystr length] > 0 ? [unmodkeystr characterAtIndex:0] : 0;
            unichar cc = 0xffff;
            if (unmodunicode >= 'a' && unmodunicode <= 'z') {
                cc = unmodunicode - 'a' + 1;
            } else if (unmodunicode == ' ' || unmodunicode == '2' || unmodunicode == '@') {
                cc = 0;
            } else if (unmodunicode == '[') {  // esc
                cc = 27;
            } else if (unmodunicode == '\\') {
                cc = 28;
            } else if (unmodunicode == ']') {
                cc = 29;
            } else if (unmodunicode == '^' || unmodunicode == '6') {
                cc = 30;
            } else if (unmodunicode == '-' || unmodunicode == '_') {
                cc = 31;
            }
            if (cc != 0xffff) {
                [self insertText:[NSString stringWithCharacters:&cc length:1]];
                if (debugKeyDown) {
                    NSLog(@"PTYTextView keyDown work around control bug. cc=%d", (int)cc);
                }
                workAroundControlBug = YES;
            }
        }
    }

    if (!workAroundControlBug) {
        // Let the IME process key events
        IM_INPUT_INSERT = NO;
        if (debugKeyDown) {
            NSLog(@"PTYTextView keyDown send to IME");
        }
        
        // In issue 2743, it is revealed that in OS 10.9 this sometimes calls -insertText on the
        // wrong instnace of PTYTextView. We work around the issue by using a global variable to
        // track the instance of PTYTextView that is currently handling a key event and rerouting
        // calls as needed in -insertText and -doCommandBySelector.
        gCurrentKeyEventTextView = [[self retain] autorelease];
        [self interpretKeyEvents:[NSArray arrayWithObject:event]];
        gCurrentKeyEventTextView = nil;

        // If the IME didn't want it, pass it on to the delegate
        if (!prev &&
            !IM_INPUT_INSERT &&
            ![self hasMarkedText]) {
            if (debugKeyDown) {
                NSLog(@"PTYTextView keyDown IME no, send to delegate");
            }
            [delegate keyDown:event];
        }
    }
    if (debugKeyDown) {
        NSLog(@"PTYTextView keyDown END");
    }
}

- (BOOL)keyIsARepeat
{
    return (keyIsARepeat);
}

- (BOOL)xtermMouseReporting
{
    NSEvent *event = [NSApp currentEvent];
    return (([[self delegate] xtermMouseReporting]) &&        // Xterm mouse reporting is on
            !([event modifierFlags] & NSAlternateKeyMask));   // Not holding Opt to disable mouse reporting
}

// TODO: disable other, right mouse for inactive panes
- (void)otherMouseDown: (NSEvent *) event
{
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if ([self xtermMouseReporting] &&
        locationInTextView.y > visibleRect.origin.y) {
        // Mouse reporting is on
        int rx, ry;
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        int buttonNumber = [event buttonNumber];
        if (buttonNumber == 2) {
            // convert NSEvent's "middle button" to X11's one
            buttonNumber = MOUSE_BUTTON_MIDDLE;
        }

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                reportingMouseDown = YES;
                [_delegate writeTask:[terminal mousePress:buttonNumber
                                            withModifiers:[event modifierFlags]
                                                      atX:rx
                                                        Y:ry]];
                return;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }

    [pointer_ mouseDown:event withTouches:numTouches_];
}

- (void)otherMouseUp:(NSEvent *)event
{
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) && reportingMouseDown) {
        reportingMouseDown = NO;
        int rx, ry;
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        int buttonNumber = [event buttonNumber];
        if (buttonNumber == 2) {
            // convert NSEvent's "middle button" to X11's one
            buttonNumber = MOUSE_BUTTON_MIDDLE;
        }

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                [_delegate writeTask:[terminal mouseRelease:buttonNumber
                                             withModifiers:[event modifierFlags]
                                                       atX:rx
                                                         Y:ry]];
                return;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }
    if (!mouseDownIsThreeFingerClick_) {
        DLog(@"Sending third button press up to super");
        [super otherMouseUp:event];
    }
    DLog(@"Sending third button press up to pointer controller");
    [pointer_ mouseUp:event withTouches:numTouches_];
}

- (void)otherMouseDragged:(NSEvent *)event
{
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) &&
        (locationInTextView.y > visibleRect.origin.y) &&
        reportingMouseDown) {
        // Mouse reporting is on.
        int rx, ry;
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        int buttonNumber = [event buttonNumber];
        if (buttonNumber == 2) {
            // convert NSEvent's "middle button" to X11's one
            buttonNumber = MOUSE_BUTTON_MIDDLE;
        }

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                [_delegate writeTask:[terminal mouseMotion:buttonNumber
                                            withModifiers:[event modifierFlags]
                                                      atX:rx
                                                        Y:ry]];
                return;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }
    [super otherMouseDragged:event];
}

- (void)rightMouseDown:(NSEvent*)event
{
    if ([threeFingerTapGestureRecognizer_ rightMouseDown:event]) {
        DLog(@"Cancel right mouse down");
        return;
    }
    if ([pointer_ mouseDown:event withTouches:numTouches_]) {
        return;
    }
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) &&
        (locationInTextView.y > visibleRect.origin.y)) {
        int rx, ry;
        rx = (locationInTextView.x-MARGIN - visibleRect.origin.x)/charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y)/lineHeight;
        if (rx < 0) rx = -1;
        if (ry < 0) ry = -1;
        VT100Terminal *terminal = [dataSource terminal];

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                reportingMouseDown = YES;
                [_delegate writeTask:[terminal mousePress:MOUSE_BUTTON_RIGHT
                                           withModifiers:[event modifierFlags]
                                                     atX:rx
                                                       Y:ry]];
                return;
                break;
            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }

    [super rightMouseDown:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
    if ([threeFingerTapGestureRecognizer_ rightMouseUp:event]) {
        return;
    }

    if ([pointer_ mouseUp:event withTouches:numTouches_]) {
        return;
    }
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) &&
        reportingMouseDown) {
        // Mouse reporting is on
        reportingMouseDown = NO;
        int rx, ry;
        rx = (locationInTextView.x-MARGIN - visibleRect.origin.x)/charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y)/lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                [_delegate writeTask:[terminal mouseRelease:MOUSE_BUTTON_RIGHT
                                             withModifiers:[event modifierFlags]
                                                       atX:rx
                                                         Y:ry]];
                return;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }
    [super rightMouseUp:event];
}

- (void)rightMouseDragged:(NSEvent *)event
{
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) &&
        (locationInTextView.y > visibleRect.origin.y) &&
        reportingMouseDown) {
        // Mouse reporting is on.
        int rx, ry;
        rx = (locationInTextView.x -MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                [_delegate writeTask:[terminal mouseMotion:MOUSE_BUTTON_RIGHT
                                            withModifiers:[event modifierFlags]
                                                      atX:rx
                                                        Y:ry]];
                return;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }
    [super rightMouseDragged:event];
}

- (void)scrollWheel:(NSEvent *)event
{
    DLog(@"scrollWheel:%@", event);
    NSPoint locationInWindow, locationInTextView;
    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    if (([self xtermMouseReporting]) &&
        (locationInTextView.y > visibleRect.origin.y)) {
        // Mouse reporting is on.
        int rx, ry;
        rx = (locationInTextView.x-MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        VT100Terminal *terminal = [dataSource terminal];

        int buttonNumber;
        if ([event deltaY] > 0)
            buttonNumber = MOUSE_BUTTON_SCROLLDOWN;
        else
            buttonNumber = MOUSE_BUTTON_SCROLLUP;

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                if ([event deltaY] != 0) {
                    [_delegate writeTask:[terminal mousePress:buttonNumber
                                               withModifiers:[event modifierFlags]
                                                         atX:rx
                                                           Y:ry]];
                    return;
                }
                break;
            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }

    [super scrollWheel:event];
}

- (BOOL)setCursor:(NSCursor *)cursor
{
    if (cursor == cursor_) {
        return NO;
    }
    [cursor_ autorelease];
    cursor_ = [cursor retain];
    return YES;
}

- (void)updateCursor:(NSEvent *)event
{
    MouseMode mouseMode = [[dataSource terminal] mouseMode];

    BOOL changed = NO;
    if (([event modifierFlags] & kDragPaneModifiers) == kDragPaneModifiers) {
        changed = [self setCursor:[NSCursor openHandCursor]];
    } else if (([event modifierFlags] & (NSCommandKeyMask | NSAlternateKeyMask)) == (NSCommandKeyMask | NSAlternateKeyMask)) {
        changed = [self setCursor:[NSCursor crosshairCursor]];
    } else if (([event modifierFlags] & (NSAlternateKeyMask | NSCommandKeyMask)) == NSCommandKeyMask) {
        changed = [self setCursor:[NSCursor pointingHandCursor]];
    } else if ([self xtermMouseReporting] &&
               mouseMode != MOUSE_REPORTING_NONE &&
               mouseMode != MOUSE_REPORTING_HILITE) {
        changed = [self setCursor:xmrCursor];
    } else {
        changed = [self setCursor:textViewCursor];
    }
    if (changed) {
        [[_delegate SCROLLVIEW] setDocumentCursor:cursor_];
    }
}

// Reset underlined chars indicating cmd-clicakble url.
- (void)removeUnderline
{
    _underlineStartX = _underlineStartY = _underlineEndX = _underlineEndY = -1;
    if (self.currentUnderlineHostname) {
        [[AsyncHostLookupController sharedInstance] cancelRequestForHostname:self.currentUnderlineHostname];
    }
    self.currentUnderlineHostname = nil;
    [self setNeedsDisplay:YES];  // It would be better to just display the underlined/formerly underlined area.
    [self updateTrackingAreas];  // Cause mouseMoved to be (not) called on movement if cmd is down (up).
}

- (BOOL)respectHardNewlinesForURLs {
    static BOOL initialized;
    static BOOL respect;
    if (!initialized) {
        respect = ![[NSUserDefaults standardUserDefaults] boolForKey:@"IgnoreHardNewlinesInURLs"];
        initialized = YES;
    }
    return respect;
}

- (BOOL)reportingMouseClicks {
    if ([self xtermMouseReporting]) {
        VT100Terminal *terminal = [dataSource terminal];
        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                return YES;

            default:
                break;
        }
    }
    return NO;
}

- (BOOL)canOpenURL:(NSString *)aURLString onLine:(int)line
{
    // A URL is openable if Trouter can handle it or if it looks enough like a web URL to pass
    // muster.
    NSString* trimmedURLString;

    NSCharacterSet *charsToTrim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    trimmedURLString = [aURLString stringByTrimmingCharactersInSet:charsToTrim];

    NSString *workingDirectory = [dataSource workingDirectoryOnLine:line];
    if ([trouter canOpenPath:trimmedURLString workingDirectory:workingDirectory]) {
        return YES;
    }

    // If it has a slash and is limited to the URL character set, it could be a URL.
    return [self _stringLooksLikeURL:aURLString];
}

// Update range of underlined chars indicating cmd-clicakble url.
- (void)updateUnderlinedURLs:(NSEvent *)event
{
    if ([event modifierFlags] & NSCommandKeyMask) {
        NSPoint screenPoint = [NSEvent mouseLocation];
        NSRect windowRect = [[self window] convertRectFromScreen:NSMakeRect(screenPoint.x,
                                                                            screenPoint.y,
                                                                            0,
                                                                            0)];
        NSPoint locationInTextView = [self convertPoint:windowRect.origin fromView: nil];
        if (!NSPointInRect(locationInTextView, [self bounds])) {
            [self removeUnderline];
            return;
        }
        NSPoint viewPoint = [self windowLocationToRowCol:windowRect.origin];
        int x = viewPoint.x;
        int y = viewPoint.y;
        if (y < 0) {
            [self removeUnderline];
            return;
        } else {
            URLAction *action = [self urlActionForClickAtX:x
                                                         y:y
                                    respectingHardNewlines:[self respectHardNewlinesForURLs]];
            if (action) {
                _underlineStartX = action.range.start.x;
                _underlineStartY = action.range.start.y;
                _underlineEndX = action.range.end.x;
                _underlineEndY = action.range.end.y;
                
                if (action.actionType == kURLActionOpenURL) {
                    NSURL *url = [NSURL URLWithString:action.string];
                    if (![url.host isEqualToString:self.currentUnderlineHostname]) {
                        if (self.currentUnderlineHostname) {
                            [[AsyncHostLookupController sharedInstance] cancelRequestForHostname:self.currentUnderlineHostname];
                        }
                        if (url && url.host) {
                            self.currentUnderlineHostname = url.host;
                            [[AsyncHostLookupController sharedInstance] getAddressForHost:url.host
                                                                               completion:^(BOOL ok, NSString *hostname) {
                                                                                   if (!ok) {
                                                                                       [[NSNotificationCenter defaultCenter] postNotificationName:kHostnameLookupFailed
                                                                                                                                           object:hostname];
                                                                                   } else {
                                                                                       [[NSNotificationCenter defaultCenter] postNotificationName:kHostnameLookupSucceeded
                                                                                                                                           object:hostname];
                                                                                   }
                                                                               }];
                        }
                    }
                } else {
                    if (self.currentUnderlineHostname) {
                        [[AsyncHostLookupController sharedInstance] cancelRequestForHostname:self.currentUnderlineHostname];
                    }
                    self.currentUnderlineHostname = nil;
                }
            } else {
                [self removeUnderline];
                return;
            }
        }
    } else {
        [self removeUnderline];
        return;
    }

    [self setNeedsDisplay:YES];  // It would be better to just display the underlined/formerly underlined area.
    [self updateTrackingAreas];  // Cause mouseMoved to be (not) called on movement if cmd is down (up).
}

- (void)flagsChanged:(NSEvent *)theEvent
{
    [self updateCursor:theEvent];
    [self updateUnderlinedURLs:theEvent];
    [super flagsChanged:theEvent];
}

- (void)flagsChangedNotification:(NSNotification *)notification
{
    [self updateCursor:(NSEvent *)[notification object]];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    [pointer_ swipeWithEvent:event];
}

- (void)mouseExited:(NSEvent *)event
{
    mouseInRect_ = NO;
    [self updateUnderlinedURLs:event];
}

- (void)mouseEntered:(NSEvent *)event
{
    mouseInRect_ = YES;
    [self updateCursor:event];
    [self updateUnderlinedURLs:event];
    if ([[PreferencePanel sharedInstance] focusFollowsMouse] &&
            [[self window] alphaValue] > 0) {
        // Some windows automatically close when they lose key status and are
        // incompatible with FFM. Check if the key window or its controller implements
        // disableFocusFollowsMouse and if it returns YES do nothing.
        id obj = nil;
        if ([[NSApp keyWindow] respondsToSelector:@selector(disableFocusFollowsMouse)]) {
            obj = [NSApp keyWindow];
        } else if ([[[NSApp keyWindow] windowController] respondsToSelector:@selector(disableFocusFollowsMouse)]) {
            obj = [[NSApp keyWindow] windowController];
        }
        if (![obj disableFocusFollowsMouse]) {
            [[self window] makeKeyWindow];
        }
        if ([self isInKeyWindow]) {
            [_delegate textViewDidBecomeFirstResponder];
        }
    }
}

- (NSPoint)windowLocationToRowCol:(NSPoint)locationInWindow
{
    NSPoint locationInTextView = [self convertPoint:locationInWindow fromView: nil];
    int x, y;
    int width = [dataSource width];

    x = (locationInTextView.x - MARGIN + charWidth * kCharWidthFractionOffset)/charWidth;
    if (x < 0) {
        x = 0;
    }
    y = locationInTextView.y / lineHeight;

    if (x >= width) {
        x = width  - 1;
    }

    return NSMakePoint(x, y);
}

- (NSPoint)clickPoint:(NSEvent *)event
{
    NSPoint locationInWindow = [event locationInWindow];
    return [self windowLocationToRowCol:locationInWindow];
}

- (void)mouseDown:(NSEvent *)event
{
    if ([threeFingerTapGestureRecognizer_ mouseDown:event]) {
        return;
    }
    DLog(@"Mouse Down on %@ with event %@, num touches=%d", self, event, numTouches_);
    if ([self mouseDownImpl:event]) {
        [super mouseDown:event];
    }
}

- (BOOL)lineHasSoftEol:(int)y
{
    screen_char_t *theLine = [dataSource getLineAtIndex:y];
    int width = [dataSource width];
    return (theLine[width].code == EOL_SOFT);
}

- (int)lineNumberWithStartOfWholeLineIncludingLine:(int)y
{
    int i = y;
    while (i > 0 && [self lineHasSoftEol:i - 1]) {
        i--;
    }
    return i;
}

- (int)lineNumberWithEndOfWholeLineIncludingLine:(int)y
{
    int i = y + 1;
    int maxY = [dataSource numberOfLines];
    while (i < maxY && [self lineHasSoftEol:i - 1]) {
        i++;
    }
    return i - 1;
}

// Emulates a third mouse button event (up or down, based on 'isDown').
// Requires a real mouse event 'event' to build off of. This has the side
// effect of setting mouseDownIsThreeFingerClick_, which (when set) indicates
// that the current mouse-down state is "special" and disables certain actions
// such as dragging.
- (void)emulateThirdButtonPressDown:(BOOL)isDown withEvent:(NSEvent *)event {
    if (isDown) {
        mouseDownIsThreeFingerClick_ = isDown;
        DLog(@"emulateThirdButtonPressDown - set mouseDownIsThreeFingerClick=YES");
    }
    CGEventRef cgEvent = [event CGEvent];
    CGEventRef fakeCgEvent = CGEventCreateMouseEvent(NULL,
                                                     isDown ? kCGEventOtherMouseDown : kCGEventOtherMouseUp,
                                                     CGEventGetLocation(cgEvent),
                                                     2);
    CGEventSetIntegerValueField(fakeCgEvent, kCGMouseEventClickState, [event clickCount]);
    CGEventSetFlags(fakeCgEvent, CGEventGetFlags(cgEvent));
    NSEvent *fakeEvent = [NSEvent eventWithCGEvent:fakeCgEvent];
    int saved = numTouches_;
    numTouches_ = 1;
    if (isDown) {
        DLog(@"Emulate third button press down");
        [self otherMouseDown:fakeEvent];
    } else {
        DLog(@"Emulate third button press up");
        [self otherMouseUp:fakeEvent];
    }
    numTouches_ = saved;
    CFRelease(fakeCgEvent);
    if (!isDown) {
        mouseDownIsThreeFingerClick_ = isDown;
        DLog(@"emulateThirdButtonPressDown - set mouseDownIsThreeFingerClick=NO");
    }
}

// Returns yes if [super mouseDown:event] should be run by caller.
- (BOOL)mouseDownImpl:(NSEvent*)event
{
    const BOOL altPressed = ([event modifierFlags] & NSAlternateKeyMask) != 0;
    const BOOL cmdPressed = ([event modifierFlags] & NSCommandKeyMask) != 0;
    const BOOL shiftPressed = ([event modifierFlags] & NSShiftKeyMask) != 0;
    const BOOL ctrlPressed = ([event modifierFlags] & NSControlKeyMask) != 0;
    if (gDebugLogging && altPressed && cmdPressed && shiftPressed && ctrlPressed) {
        // Dump view hierarchy
        NSBeep();
        [[iTermController sharedInstance] dumpViewHierarchy];
        return NO;
    }
    [pointer_ notifyLeftMouseDown];
    mouseDownIsThreeFingerClick_ = NO;
    DLog(@"mouseDownImpl - set mouseDownIsThreeFingerClick=NO");
    if (([event modifierFlags] & kDragPaneModifiers) == kDragPaneModifiers) {
        [_delegate textViewBeginDrag];
        return NO;
    }
    if (numTouches_ == 3) {
        if ([[PreferencePanel sharedInstance] threeFingerEmulatesMiddle]) {
            [self emulateThirdButtonPressDown:YES withEvent:event];
        } else {
            // Perform user-defined gesture action, if any
            [pointer_ mouseDown:event withTouches:numTouches_];
            mouseDown = YES;
        }
        return NO;
    }
    if ([pointer_ eventEmulatesRightClick:event]) {
        [pointer_ mouseDown:event withTouches:numTouches_];
        return NO;
    }

    dragOk_ = YES;
    PTYTextView* frontTextView = [[iTermController sharedInstance] frontTextView];
    if (!cmdPressed &&
        frontTextView &&
        ![_delegate textViewInSameTabAsTextView:frontTextView]) {
        // Mouse clicks in inactive tab are always handled by superclass because we don't want clicks
        // to select a split pane to be xterm-mouse-reported. We do allow cmd-clicks to go through
        // incase you're clicking on a URL.
        return YES;
    }

    if (([event modifierFlags] & kDragPaneModifiers) == kDragPaneModifiers) {
        return YES;
    }

    NSPoint locationInWindow, locationInTextView;
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;
    int width = [dataSource width];

    locationInWindow = [event locationInWindow];
    locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    if (numTouches_ <= 1) {
        for (NSView *view in [self subviews]) {
            if ([view isKindOfClass:[PTYNoteView class]]) {
                PTYNoteView *noteView = (PTYNoteView *)view;
                [noteView.delegate.noteViewController setNoteHidden:YES];
            }
        }
    }

    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];

    if ([event eventNumber] != firstMouseEventNumber_ &&   // Not first mouse in formerly non-key app
        frontTextView == self &&                           // Is active session's textview
        ([self xtermMouseReporting]) &&                    // Xterm mouse reporting is on
        (locationInTextView.y > visibleRect.origin.y)) {   // Not inside the top margin
        // Mouse reporting is on.
        int rx, ry;
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        lastReportedX_ = rx;
        lastReportedY_ = ry;
        VT100Terminal *terminal = [dataSource terminal];

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                DebugLog(@"Do xterm mouse reporting");
                reportingMouseDown = YES;
                [_delegate writeTask:[terminal mousePress:MOUSE_BUTTON_LEFT
                                            withModifiers:[event modifierFlags]
                                                      atX:rx
                                                        Y:ry]];
                return NO;
                break;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }

    if ([event eventNumber] != firstMouseEventNumber_) {
        // Lock auto scrolling while the user is selecting text, but not for a first-mouse event
        // because drags are ignored for those.
        [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
    }

    if (mouseDownEvent != nil) {
        [mouseDownEvent release];
        mouseDownEvent = nil;
    }
    [event retain];
    mouseDownEvent = event;
    mouseDragged = NO;
    mouseDown = YES;
    mouseDownOnSelection = NO;
    mouseDownOnImage = NO;

    int clickCount = [event clickCount];
    DLog(@"clickCount=%d altPressed=%d cmdPressed=%d", clickCount, (int)altPressed, (int)cmdPressed);
    const BOOL isExtension = ([_selection hasSelection] && shiftPressed);
    if (isExtension && [_selection hasSelection]) {
        if (!_selection.live) {
            [_selection beginExtendingSelectionAt:VT100GridCoordMake(x, y)];
        }
    } else if (clickCount < 2) {
        // single click
        iTermSelectionMode mode;
        if (altPressed && cmdPressed) {
            mode = kiTermSelectionModeBox;
        } else {
            mode = kiTermSelectionModeCharacter;
        }

        if ((theImage = [self imageInfoAtCoord:VT100GridCoordMake(x, y)])) {
            mouseDownOnImage = YES;
        } else if ([_selection containsCoord:VT100GridCoordMake(x, y)]) {
            // not holding down shift key but there is an existing selection.
            // Possibly a drag coming up (if a cmd-drag follows)
            DLog(@"mouse down on selection");
            mouseDownOnSelection = YES;
            return YES;
        } else {
            // start a new selection
            [_selection beginSelectionAt:VT100GridCoordMake(x, y)
                                    mode:mode
                                  resume:NO
                                  append:(cmdPressed && !altPressed)];
            _selection.resumable = YES;
        }
    } else if (clickCount == 2) {
        [_selection beginSelectionAt:VT100GridCoordMake(x, y)
                                mode:kiTermSelectionModeWord
                              resume:YES
                              append:_selection.appending];
    } else if (clickCount == 3) {
        BOOL wholeLines = [[PreferencePanel sharedInstance] tripleClickSelectsFullLines];
        iTermSelectionMode mode =
            wholeLines ? kiTermSelectionModeWholeLine : kiTermSelectionModeLine;

        [_selection beginSelectionAt:VT100GridCoordMake(x, y)
                                mode:mode
                              resume:YES
                              append:_selection.appending];
    } else if (clickCount == 4) {
        [_selection beginSelectionAt:VT100GridCoordMake(x, y)
                                mode:kiTermSelectionModeSmart
                              resume:YES
                              append:_selection.appending];
    }

    DLog(@"Mouse down. selection set to %@", _selection);
    [_delegate refreshAndStartTimerIfNeeded];

    return NO;
}

static double Square(double n) {
    return n * n;
}

static double EuclideanDistance(NSPoint p1, NSPoint p2) {
    return sqrt(Square(p1.x - p2.x) + Square(p1.y - p2.y));
}

- (void)mouseUp:(NSEvent *)event
{
    if ([threeFingerTapGestureRecognizer_ mouseUp:event]) {
        return;
    }
    DLog(@"Mouse Up on %@ with event %@, numTouches=%d", self, event, numTouches_);
    firstMouseEventNumber_ = -1;  // Synergy seems to interfere with event numbers, so reset it here.
    if (mouseDownIsThreeFingerClick_) {
        [self emulateThirdButtonPressDown:NO withEvent:event];
        return;
    } else if (numTouches_ == 3 && mouseDown) {
        // Three finger tap is valid but not emulating middle button
        [pointer_ mouseUp:event withTouches:numTouches_];
        mouseDown = NO;
        return;
    }
    dragOk_ = NO;
    trouterDragged = NO;
    if ([pointer_ eventEmulatesRightClick:event]) {
        [pointer_ mouseUp:event withTouches:numTouches_];
        return;
    }
    PTYTextView* frontTextView = [[iTermController sharedInstance] frontTextView];
    const BOOL cmdPressed = ([event modifierFlags] & NSCommandKeyMask) != 0;
    if (!cmdPressed &&
        frontTextView &&
        ![_delegate textViewInSameTabAsTextView:frontTextView]) {
        // Mouse clicks in inactive tab are always handled by superclass but make it first responder.
        [[self window] makeFirstResponder: self];
        [super mouseUp:event];
        return;
    }

    selectionScrollDirection = 0;

    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInTextView = [self convertPoint: locationInWindow fromView: nil];

    BOOL isUnshiftedSingleClick = ([event clickCount] < 2 &&
                                   !mouseDragged &&
                                   !([event modifierFlags] & NSShiftKeyMask));
    BOOL willFollowLink = (isUnshiftedSingleClick &&
                           cmdPressed &&
                           [[PreferencePanel sharedInstance] cmdSelection]);

    // Send mouse up event to host if xterm mouse reporting is on
    if (frontTextView == self &&
        [self xtermMouseReporting] &&
        reportingMouseDown) {
        // Mouse reporting is on.
        reportingMouseDown = NO;
        int rx, ry;
        NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        lastReportedX_ = rx;
        lastReportedY_ = ry;
        VT100Terminal *terminal = [dataSource terminal];

        switch ([terminal mouseMode]) {
            case MOUSE_REPORTING_NORMAL:
            case MOUSE_REPORTING_BUTTON_MOTION:
            case MOUSE_REPORTING_ALL_MOTION:
                [_delegate writeTask:[terminal mouseRelease:MOUSE_BUTTON_LEFT
                                              withModifiers:[event modifierFlags]
                                                        atX:rx
                                                          Y:ry]];
                if (willFollowLink) {
                    // This is a special case. Cmd-click is treated like alt-click at the protocol
                    // level (because we use alt to disable mouse reporting, unfortunately). Few
                    // apps interpret alt-clicks specially, and we really want to handle cmd-click
                    // on links even when mouse reporting is on. Link following has to be done on
                    // mouse up to allow the user to drag links and to cancel accidental clicks (by
                    // doing mouseUp far away from mouseDown). So we report the cmd-click as an
                    // alt-click and then open the link. Note that cmd-alt-click isn't handled here
                    // because you won't get here if alt is pressed. Note that openTargetWithEvent:
                    // may not do anything if the pointer isn't over a clickable string.
                    [self openTargetWithEvent:event];
                }
                return;

            case MOUSE_REPORTING_NONE:
            case MOUSE_REPORTING_HILITE:
                // fall through
                break;
        }
    }

    // Unlock auto scrolling as the user as finished selecting text
    if (([self visibleRect].origin.y + [self visibleRect].size.height - [self excess]) / lineHeight == [dataSource numberOfLines]) {
        [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:NO];
    }

    if (mouseDown == NO) {
        DLog(@"Mouse up. Selection=%@", _selection);
        return;
    }
    mouseDown = NO;

    // make sure we have key focus
    [[self window] makeFirstResponder:self];

    [_selection endLiveSelection];
    if (isUnshiftedSingleClick) {
        // Just a click in the window.
        DLog(@"is a click in the window");

        BOOL altPressed = ([event modifierFlags] & NSAlternateKeyMask) != 0;
        if (altPressed && [[PreferencePanel sharedInstance] optionClickMovesCursor]) {
            // This moves the cursor, but not if mouse reporting is on for button clicks.
            VT100Terminal *terminal = [dataSource terminal];
            switch ([terminal mouseMode]) {
                case MOUSE_REPORTING_NORMAL:
                case MOUSE_REPORTING_BUTTON_MOTION:
                case MOUSE_REPORTING_ALL_MOTION:
                    // Reporting mouse clicks. The remote app gets preference.
                    break;

                default:
                    // Not reporting mouse clicks, so we'll move the cursor since the remote app can't.
                    if (!cmdPressed && [_delegate textViewShouldPlaceCursor]) {
                        [self placeCursorOnCurrentLineWithEvent:event];
                    }
                    break;
            }
        }

        if (!_selection.appending) {
            [_selection clearSelection];
        }
        if (willFollowLink) {
            if (altPressed) {
                [self openTargetInBackgroundWithEvent:event];
            } else {
                [self openTargetWithEvent:event];
            }
        } else {
            [_lastFindCoord release];
            _lastFindCoord = nil;
            NSPoint clickPoint = [self clickPoint:event];
            _lastFindCoord =
                [[SearchResult searchResultFromX:clickPoint.x
                                               y:clickPoint.y + [dataSource totalScrollbackOverflow]
                                             toX:0
                                               y:0] retain];
        }
    }

    if ([_selection hasSelection] && _delegate) {
        // if we want to copy our selection, do so
        if ([[PreferencePanel sharedInstance] copySelection]) {
            [self copySelectionAccordingToUserPreferences];
        }
    }

    DLog(@"Mouse up. selection=%@", _selection);

    [_delegate refreshAndStartTimerIfNeeded];
}

- (void)mouseMoved:(NSEvent *)event
{
    DLog(@"mouseMoved");
    VT100Terminal *terminal = [dataSource terminal];
    [self updateUnderlinedURLs:event];
    if (![self xtermMouseReporting]) {
        DLog(@"Mouse move event is dispatched but xtermMouseReporting is not enabled");
        return;
    }
#if DEBUG
    assert([terminal mouseMode] == MOUSE_REPORTING_ALL_MOTION);
#endif
    if ([terminal mouseMode] != MOUSE_REPORTING_ALL_MOTION) {
        DLog(@"Mouse move event is dispatched but mouseMode is not MOUSE_REPORTING_ALL_MOTION");
        return;
    }
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInTextView = [self convertPoint:locationInWindow fromView:nil];
    int rx, ry;
    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
    ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
    if (rx < 0) {
        rx = -1;
    }
    if (ry < 0) {
        ry = -1;
    }
    if (rx != lastReportedX_ || ry != lastReportedY_) {
        lastReportedX_ = rx;
        lastReportedY_ = ry;
        [_delegate writeTask:[terminal mouseMotion:MOUSE_BUTTON_NONE
                                     withModifiers:[event modifierFlags]
                                               atX:rx
                                                 Y:ry]];
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    DLog(@"mouseDragged");
    if (mouseDownIsThreeFingerClick_) {
        DLog(@"is three finger click");
        return;
    }
    // Prevent accidental dragging while dragging trouter item.
    BOOL dragThresholdMet = NO;
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInTextView = [self convertPoint:locationInWindow fromView:nil];
    locationInTextView.x = ceil(locationInTextView.x);
    locationInTextView.y = ceil(locationInTextView.y);
    // Clamp the y position to be within the view. Sometimes we get events we probably shouldn't.
    locationInTextView.y = MIN(self.frame.size.height - 1,
                               MAX(0, locationInTextView.y));
    NSRect  rectInTextView = [self visibleRect];
    int width = [dataSource width];

    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;

    NSPoint mouseDownLocation = [mouseDownEvent locationInWindow];
    if (EuclideanDistance(mouseDownLocation, locationInWindow) >= kDragThreshold) {
        dragThresholdMet = YES;
    }
    if ([event eventNumber] == firstMouseEventNumber_) {
        // We accept first mouse for the purposes of focusing or dragging a
        // split pane but not for making a selection.
        return;
    }
    if (!dragOk_) {
        DLog(@"drag not ok");
        return;
    }

    if (([self xtermMouseReporting]) && reportingMouseDown) {
        // Mouse reporting is on.
        int rx, ry;
        NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
        rx = (locationInTextView.x - MARGIN - visibleRect.origin.x) / charWidth;
        ry = (locationInTextView.y - visibleRect.origin.y) / lineHeight;
        if (rx < 0) {
            rx = -1;
        }
        if (ry < 0) {
            ry = -1;
        }
        if (rx != lastReportedX_ || ry != lastReportedY_) {
            lastReportedX_ = rx;
            lastReportedY_ = ry;
            VT100Terminal *terminal = [dataSource terminal];

            switch ([terminal mouseMode]) {
                case MOUSE_REPORTING_BUTTON_MOTION:
                case MOUSE_REPORTING_ALL_MOTION:
                    [_delegate writeTask:[terminal mouseMotion:MOUSE_BUTTON_LEFT
                                                 withModifiers:[event modifierFlags]
                                                           atX:rx
                                                             Y:ry]];
                case MOUSE_REPORTING_NORMAL:
                    DLog(@"Mouse drag. selection=%@", _selection);
                    return;
                    break;

                case MOUSE_REPORTING_NONE:
                case MOUSE_REPORTING_HILITE:
                    // fall through
                    break;
            }
        }
    }

    BOOL pressingCmdOnly = ([event modifierFlags] & (NSAlternateKeyMask | NSCommandKeyMask)) == NSCommandKeyMask;
    if (!pressingCmdOnly || dragThresholdMet) {
        DLog(@"mousedragged = yes");
        mouseDragged = YES;
    }


    if (mouseDownOnImage &&
        ([event modifierFlags] & NSCommandKeyMask) &&
        dragThresholdMet) {
        [self _dragImage:theImage forEvent:event];
    } else if (mouseDownOnSelection == YES &&
        ([event modifierFlags] & NSCommandKeyMask) &&
        dragThresholdMet) {
        DLog(@"drag and drop a selection");
        // Drag and drop a selection
        NSString *theSelectedText = [self selectedTextWithPad:NO];
        if ([theSelectedText length] > 0) {
            [self _dragText:theSelectedText forEvent:event];
            DLog(@"Mouse drag. selection=%@", _selection);
            return;
        }
    }

    if (pressingCmdOnly && !dragThresholdMet) {
        // If you're holding cmd (but not opt) then you're either trying to click on a link and
        // accidentally dragged a little bit, or you're trying to drag a selection. Do nothing until
        // the threshold is met.
        DLog(@"drag during cmd click");
        return;
    }
    if (mouseDownOnSelection == YES &&
        ([event modifierFlags] & (NSAlternateKeyMask | NSCommandKeyMask)) == (NSAlternateKeyMask | NSCommandKeyMask) &&
        !dragThresholdMet) {
        // Would be a drag of a rect region but mouse hasn't moved far enough yet. Prevent the
        // selection from changing.
        DLog(@"too-short drag of rect region");
        return;
    }

    if (![_selection hasSelection] && pressingCmdOnly && trouterDragged == NO) {
        DLog(@"do trouter check");
        // Only one Trouter check per drag
        trouterDragged = YES;

        // Drag a file handle (only possible when there is no selection).
        URLAction *action = [self urlActionForClickAtX:x y:y];
        NSString *path = action.fullPath;
        if (path == nil) {
            DLog(@"path is nil");
            return;
        }

        NSPoint dragPosition;
        NSImage *dragImage;

        NSArray *fileList = [NSArray arrayWithObject: path];
        NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard];
        [pboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
        [pboard setPropertyList:fileList forType:NSFilenamesPboardType];

        dragImage = [[NSWorkspace sharedWorkspace] iconForFile:path];
        dragPosition = [self convertPoint:[event locationInWindow] fromView:nil];
        dragPosition.x -= [dragImage size].width / 2;

        [self dragImage:dragImage
                     at:dragPosition
                 offset:NSZeroSize
                  event:event
             pasteboard:pboard
                 source:self
              slideBack:YES];

        // Valid drag, so we reset the flag because mouseUp doesn't get called when a drag is done
        trouterDragged = NO;
        DLog(@"did trouter drag");

        return;

    }

    int prevScrolling = selectionScrollDirection;
    if (locationInTextView.y <= rectInTextView.origin.y) {
        DLog(@"selection scroll up");
        selectionScrollDirection = -1;
        scrollingX = x;
        scrollingY = y;
        scrollingLocation = locationInTextView;
    } else if (locationInTextView.y >= rectInTextView.origin.y + rectInTextView.size.height) {
        DLog(@"selection scroll down");
        selectionScrollDirection = 1;
        scrollingX = x;
        scrollingY = y;
        scrollingLocation = locationInTextView;
    } else {
        DLog(@"selection scroll off");
        selectionScrollDirection = 0;
    }
    if (selectionScrollDirection && !prevScrolling) {
        DLog(@"selection scroll scheduling");
        [self scheduleSelectionScroll];
    }

    [self moveSelectionEndpointToX:x Y:y locationInTextView:locationInTextView];
}

#pragma mark PointerControllerDelegate

- (void)pasteFromClipboardWithEvent:(NSEvent *)event
{
    [self paste:nil];
}

- (void)pasteFromSelectionWithEvent:(NSEvent *)event
{
    [self pasteSelection:nil];
}

- (void)_openTargetWithEvent:(NSEvent *)event inBackground:(BOOL)openInBackground
{
    // Command click in place.
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;
    NSString *prefix = [self wrappedStringAtX:x
                                            y:y
                                          dir:-1
                          respectHardNewlines:NO];
    NSString *suffix = [self wrappedStringAtX:x
                                            y:y
                                          dir:1
                          respectHardNewlines:NO];

    URLAction *action = [self urlActionForClickAtX:x y:y];
    if (action) {
        switch (action.actionType) {
            case kURLActionOpenExistingFile:
                if (![trouter openPath:action.string
                      workingDirectory:action.workingDirectory
                                prefix:prefix
                                suffix:suffix]) {
                    [self _findUrlInString:action.string andOpenInBackground:openInBackground];
                }
                break;
                
            case kURLActionOpenURL:
                [self _findUrlInString:action.string andOpenInBackground:openInBackground];
                break;
                
            case kURLActionSmartSelectionAction: {
                [self performSelector:action.selector withObject:action];
                break;
            }
        }
    }
}

- (void)openTargetWithEvent:(NSEvent *)event
{
    [self _openTargetWithEvent:event inBackground:NO];
}

- (void)openTargetInBackgroundWithEvent:(NSEvent *)event
{
    [self _openTargetWithEvent:event inBackground:YES];
}

- (void)smartSelectWithEvent:(NSEvent *)event
{
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;

    [self smartSelectAtX:x y:y ignoringNewlines:NO];
}

- (void)smartSelectIgnoringNewlinesWithEvent:(NSEvent *)event
{
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;

    [self smartSelectAtX:x y:y ignoringNewlines:YES];
}

- (void)smartSelectAndMaybeCopyWithEvent:(NSEvent *)event
                        ignoringNewlines:(BOOL)ignoringNewlines
{
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;

    [self smartSelectAtX:x y:y ignoringNewlines:ignoringNewlines];
    if ([_selection hasSelection] && _delegate) {
        // if we want to copy our selection, do so
        if ([[PreferencePanel sharedInstance] copySelection]) {
            [self copySelectionAccordingToUserPreferences];
        }
    }
}

- (void)openContextMenuWithEvent:(NSEvent *)event {
    NSPoint clickPoint = [self clickPoint:event];
    openingContextMenu_ = YES;
    
    // Slowly moving away from using NSPoint for integer coordinates.
    validationClickPoint_ = VT100GridCoordMake(clickPoint.x, clickPoint.y);
    [NSMenu popUpContextMenu:[self contextMenuWithEvent:event] withEvent:event forView:self];
    validationClickPoint_ = VT100GridCoordMake(-1, -1);
    openingContextMenu_ = NO;
}

- (NSMenu *)contextMenuWithEvent:(NSEvent *)event
{
    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;

    NSMenu *menu = nil;
    if (x < MARGIN) {
        VT100ScreenMark *mark = [dataSource markOnLine:y];
        if (mark && mark.command.length) {
            menu = [self menuForMark:mark directory:[dataSource workingDirectoryOnLine:y]];
        }
    }

    VT100GridCoord coord = VT100GridCoordMake(x, y);
    if (!menu) {
        ImageInfo *imageInfo = [self imageInfoAtCoord:coord];

        if (!imageInfo &&
            ![_selection containsCoord:VT100GridCoordMake(x, y)]) {
            // Didn't click on selection.
            // Save the selection and do a smart selection. If we don't like the result, restore it.
            iTermSelection *savedSelection = [[_selection copy] autorelease];
            [self smartSelectWithEvent:event];
            NSCharacterSet *nonWhiteSpaceSet = [[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet];
            NSString *text = [self selectedText];
            if (!text ||
                !text.length ||
                [text rangeOfCharacterFromSet:nonWhiteSpaceSet].location == NSNotFound) {
                // If all we selected was white space, undo it.
                [_selection release];
                _selection = [savedSelection retain];
            }
        }
        [self setNeedsDisplay:YES];
        menu = [self menuAtCoord:coord];
    }
    return menu;
}

- (void)extendSelectionWithEvent:(NSEvent *)event
{
    if ([_selection hasSelection]) {
        NSPoint locationInWindow = [event locationInWindow];
        NSPoint locationInTextView = [self convertPoint:locationInWindow fromView:nil];
        NSPoint clickPoint = [self clickPoint:event];
        [_selection beginExtendingSelectionAt:VT100GridCoordMake(clickPoint.x, clickPoint.y)];
        [_selection endLiveSelection];
    }
}

- (void)nextTabWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectNextTab];
}

- (void)previousTabWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectPreviousTab];
}

- (void)nextWindowWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectNextWindow];
}

- (void)previousWindowWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectPreviousWindow];
}

- (void)movePaneWithEvent:(NSEvent *)event
{
    [self movePane:nil];
}

- (void)sendEscapeSequence:(NSString *)text withEvent:(NSEvent *)event
{
    [_delegate sendEscapeSequence:text];
}

- (void)sendHexCode:(NSString *)codes withEvent:(NSEvent *)event
{
    [_delegate sendHexCode:codes];
}

- (void)sendText:(NSString *)text withEvent:(NSEvent *)event
{
    [_delegate sendText:text];
}

- (void)selectPaneLeftWithEvent:(NSEvent *)event
{
    [_delegate selectPaneLeftInCurrentTerminal];
}

- (void)selectPaneRightWithEvent:(NSEvent *)event
{
    [_delegate selectPaneRightInCurrentTerminal];
}

- (void)selectPaneAboveWithEvent:(NSEvent *)event
{
    [_delegate selectPaneAboveInCurrentTerminal];
}

- (void)selectPaneBelowWithEvent:(NSEvent *)event
{
    [_delegate selectPaneBelowInCurrentTerminal];
}

- (void)newWindowWithProfile:(NSString *)guid withEvent:(NSEvent *)event
{
    [_delegate textViewCreateWindowWithProfileGuid:guid];
}

- (void)newTabWithProfile:(NSString *)guid withEvent:(NSEvent *)event
{
    [_delegate textViewCreateTabWithProfileGuid:guid];
}

- (void)newVerticalSplitWithProfile:(NSString *)guid withEvent:(NSEvent *)event
{
    [_delegate textViewSplitVertically:YES withProfileGuid:guid];
}

- (void)newHorizontalSplitWithProfile:(NSString *)guid withEvent:(NSEvent *)event
{
    [_delegate textViewSplitVertically:NO withProfileGuid:guid];
}

- (void)selectNextPaneWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectNextPane];
}

- (void)selectPreviousPaneWithEvent:(NSEvent *)event
{
    [_delegate textViewSelectPreviousPane];
}

- (void)placeCursorOnCurrentLineWithEvent:(NSEvent *)event
{
    BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];

    if (debugKeyDown) {
        NSLog(@"PTYTextView placeCursorOnCurrentLineWithEvent BEGIN %@", event);
    }
    DebugLog(@"PTYTextView placeCursorOnCurrentLineWithEvent");

    NSPoint clickPoint = [self clickPoint:event];
    int x = clickPoint.x;
    int y = clickPoint.y;
    int cursorY = [dataSource absoluteLineNumberOfCursor];
    int cursorX = [dataSource cursorX];
    int width = [dataSource width];
    VT100Terminal *terminal = [dataSource terminal];

    int i = abs(cursorX - x);
    int j = abs(cursorY - y);

    if (cursorX > x) {
        // current position is right of going-to-be x,
        // so first move to left, and (if necessary)
        // up or down afterwards
        while (i > 0) {
            [_delegate writeTask:[terminal keyArrowLeft:0]];
            i--;
        }
    }
    while (j > 0) {
        if (cursorY > y) {
            [_delegate writeTask:[terminal keyArrowUp:0]];
        } else {
            [_delegate writeTask:[terminal keyArrowDown:0]];
        }
        j--;
    }
    if (cursorX < x) {
        // current position is left of going-to-be x
        // so first moved up/down (if necessary)
        // and then/now to the right
        while (i > 0) {
            [_delegate writeTask:[terminal keyArrowRight:0]];
            i--;
        }
    }
    if (debugKeyDown) {
        NSLog(@"cursor at %d,%d (x,y) moved to %d,%d (x,y) [window width: %d]",
              cursorX, cursorY, x, y, width);
    }

    if (debugKeyDown) {
        NSLog(@"PTYTextView placeCursorOnCurrentLineWithEvent END");
    }
}

- (void)trimTrailingWhitespaceFromString:(NSMutableString *)string {
    NSCharacterSet *nonWhitespaceSet = [[NSCharacterSet whitespaceCharacterSet] invertedSet];
    NSRange rangeOfLastWantedCharacter = [string rangeOfCharacterFromSet:nonWhitespaceSet
                                                                 options:NSBackwardsSearch];
    if (rangeOfLastWantedCharacter.location == NSNotFound) {
        [string deleteCharactersInRange:NSMakeRange(0, string.length)];
    } else if (rangeOfLastWantedCharacter.location < string.length - 1) {
        NSUInteger i = rangeOfLastWantedCharacter.location + 1;
        [string deleteCharactersInRange:NSMakeRange(i, string.length - i)];
    }
}

- (VT100GridCoordRange)rangeByTrimmingNullsFromRange:(VT100GridCoordRange)range
                                          trimSpaces:(BOOL)trimSpaces
{
    VT100GridCoordRange result = range;
    int width = [dataSource width];
    int lineY = result.start.y;
    screen_char_t *line = [dataSource getLineAtIndex:lineY];
    while (!VT100GridCoordEquals(result.start, range.end)) {
        if (lineY != result.start.y) {
            lineY = result.start.y;
            line = [dataSource getLineAtIndex:lineY];
        }
        unichar code = line[result.start.x].code;
        BOOL trim = ((code == 0) ||
                     (trimSpaces && (code == ' ' || code == '\t' || code == TAB_FILLER)));
        if (trim) {
            result.start.x++;
            if (result.start.x == width) {
                result.start.x = 0;
                result.start.y++;
            }
        } else {
            break;
        }
    }

    while (!VT100GridCoordEquals(result.end, result.start)) {
        // x,y is the predecessor of result.end and is the cell to test.
        int x = result.end.x - 1;
        int y = result.end.y;
        if (x < 0) {
            x = width - 1;
            y = result.end.y - 1;
        }
        if (lineY != y) {
            lineY = y;
            line = [dataSource getLineAtIndex:y];
        }
        unichar code = line[x].code;
        BOOL trim = ((code == 0) ||
                     (trimSpaces && (code == ' ' || code == '\t' || code == TAB_FILLER)));
        if (trim) {
            result.end = VT100GridCoordMake(x, y);
        } else {
            break;
        }
    }

    return result;
}

- (NSString *)contentInRange:(VT100GridCoordRange)range
                         pad:(BOOL)pad
          includeLastNewline:(BOOL)includeLastNewline
      trimTrailingWhitespace:(BOOL)trimSelectionTrailingSpaces
                cappedAtSize:(int)maxBytes
{
    DLog(@"Find selected text in range %@ pad=%d, includeLastNewline=%d, trim=%d",
         VT100GridCoordRangeDescription(range), (int)pad, (int)includeLastNewline,
         (int)trimSelectionTrailingSpaces);
    int width = [dataSource width];
    assert(range.end.x - 1 <= width);
    const int estimatedSize = (range.end.y - range.start.y + 1) * (width + 1) + (range.end.x - range.start.x);
    NSMutableString* result = [NSMutableString stringWithCapacity:estimatedSize];
    int y, x1, x2;
    screen_char_t *theLine;
    BOOL endOfLine;
    int i;

    if (maxBytes < 0) {
        maxBytes = INT_MAX;
    }
    for (y = range.start.y; result.length < maxBytes && y <= range.end.y; y++) {
        theLine = [dataSource getLineAtIndex:y];

        x1 = y == range.start.y ? range.start.x : 0;
        x2 = y == range.end.y ? range.end.x - 1 : width - 1;
        for ( ; x1 <= x2; x1++) {
            if (theLine[x1].code == TAB_FILLER) {
                // Convert orphan tab fillers (those without a subsequent
                // tab character) into spaces.
                if ([self isTabFillerOrphanAtX:x1 Y:y]) {
                    [result appendString:@" "];
                }
            } else if (theLine[x1].code != DWC_RIGHT &&
                       theLine[x1].code != DWC_SKIP) {
                if (theLine[x1].code == 0) { // end of line?
                    // If there is no text after this, insert a hard line break.
                    endOfLine = YES;
                    for (i = x1 + 1; i <= x2 && endOfLine; i++) {
                        if (theLine[i].code != 0) {
                            endOfLine = NO;
                        }
                    }
                    if (endOfLine) {
                        if (pad) {
                            for (i = x1; i <= x2; i++) {
                                [result appendString:@" "];
                            }
                        }
                        if (theLine[width].code == EOL_HARD) {
                            if (trimSelectionTrailingSpaces) {
                                [self trimTrailingWhitespaceFromString:result];
                            }
                            if (includeLastNewline || y < range.end.y) {
                                [result appendString:@"\n"];
                            }
                        }
                        break;
                    } else {
                        [result appendString:@" "]; // replace mid-line null char with space
                    }
                } else if (x1 == x2 &&
                           y < range.end.y &&
                           theLine[width].code == EOL_HARD) {
                    // Hard line break
                    [result appendString:ScreenCharToStr(&theLine[x1])];
                    if (trimSelectionTrailingSpaces) {
                        [self trimTrailingWhitespaceFromString:result];
                    }
                    [result appendString:@"\n"];  // hard break
                } else {
                    // Normal character
                    [result appendString:ScreenCharToStr(&theLine[x1])];
                }
            }
        }
    }

    if (trimSelectionTrailingSpaces) {
        [self trimTrailingWhitespaceFromString:result];
    }
    return result;
}

- (IBAction)selectAll:(id)sender
{
    // Set the selection region to the whole text.
    [_selection beginSelectionAt:VT100GridCoordMake(0, 0)
                            mode:kiTermSelectionModeCharacter
                          resume:NO
                          append:NO];
    [_selection moveSelectionEndpointTo:VT100GridCoordMake([dataSource width],
                                                           [dataSource numberOfLines] - 1)];
    [_selection endLiveSelection];
}

- (void)deselect
{
    [_selection clearSelection];
}

- (NSString *)selectedText
{
    return [self selectedTextWithPad:NO];
}

- (NSString *)selectedTextWithPad:(BOOL)pad
{
    return [self selectedTextWithPad:pad cappedAtSize:0];
}

- (NSString *)selectedTextWithPad:(BOOL)pad
                     cappedAtSize:(int)maxBytes
{
    if (![_selection hasSelection]) {
        DLog(@"startx < 0 so there is no selected text");
        return nil;
    }
    BOOL copyLastNewline = [[PreferencePanel sharedInstance] copyLastNewline];
    BOOL trimWhitespace = [[PreferencePanel sharedInstance] trimTrailingWhitespace];
    NSMutableString *theSelectedText = [[NSMutableString alloc] init];
    int width = [dataSource width];
    __block BOOL first = YES;
    [_selection enumerateSelectedRanges:^(VT100GridCoordRange range, BOOL *stop) {
        int cap = INT_MAX;
        if (maxBytes > 0) {
            cap = maxBytes - [theSelectedText length];
            if (cap <= 0) {
                cap = 0;
                *stop = YES;
            }
        }
        if (cap != 0) {
            if (!first) {
                if (![theSelectedText hasSuffix:@"\n"]) {
                    [theSelectedText appendString:@"\n"];
                }
            } else {
                first = NO;
            }
            [theSelectedText appendString:[self contentInRange:range
                                                           pad:NO
                                            includeLastNewline:copyLastNewline
                                        trimTrailingWhitespace:trimWhitespace
                                                  cappedAtSize:cap]];
        }
    }];
    return theSelectedText;
}

- (NSAttributedString *)selectedAttributedTextWithPad:(BOOL)pad
{
    if (![_selection hasSelection]) {
        DLog(@"startx < 0 so there is no selected text");
        return nil;
    }
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    __block BOOL first = YES;
    [_selection enumerateSelectedRanges:^(VT100GridCoordRange range, BOOL *stop) {
        if (!first) {
            if (![[result string] hasSuffix:@"\n"]) {
                NSDictionary *attributes = [result attributesAtIndex:[result length] - 1
                                                      effectiveRange:NULL];
                NSAttributedString *newline =
                    [[[NSAttributedString alloc] initWithString:@"\n"
                                                     attributes:attributes] autorelease];
                [result appendAttributedString:newline];
            }
        } else {
            first = NO;
        }
        [result appendAttributedString:[self attributedContentInRange:range
                                                                  pad:pad]];
    }];
    return result;
}

- (NSString *)content
{
    return [self contentInRange:VT100GridCoordRangeMake(0,
                                                        0,
                                                        [dataSource width],
                                                        [dataSource numberOfLines] - 1)
                            pad:NO
             includeLastNewline:YES
         trimTrailingWhitespace:NO
                   cappedAtSize:-1];
}

- (void)splitTextViewVertically:(id)sender
{
    [_delegate textViewSplitVertically:YES withProfileGuid:nil];
}

- (void)splitTextViewHorizontally:(id)sender
{
    [_delegate textViewSplitVertically:NO withProfileGuid:nil];
}

- (void)movePane:(id)sender
{
    [_delegate textViewMovePane];
}

- (void)clearTextViewBuffer:(id)sender
{
    [dataSource clearBuffer];
}

- (void)addViewForNote:(PTYNoteViewController *)note
{
    // Make sure scrollback overflow is reset.
    [self refresh];
    [note.view removeFromSuperview];
    [self addSubview:note.view];
    [self updateNoteViewFrames];
    [note setNoteHidden:NO];
}


- (void)addNote:(id)sender
{
    if ([_selection hasSelection]) {
        PTYNoteViewController *note = [[[PTYNoteViewController alloc] init] autorelease];
        [dataSource addNote:note inRange:_selection.lastRange];
        
        // Make sure scrollback overflow is reset.
        [self refresh];
        [note.view removeFromSuperview];
        [self addSubview:note.view];
        [self updateNoteViewFrames];
        [note setNoteHidden:NO];
        [note beginEditing];
    }
}

- (void)downloadWithSCP:(id)sender
{
    if (![_selection hasSelection]) {
        return;
    }
    SCPPath *scpPath = nil;
    NSString *selectedText = [[self selectedText] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [selectedText componentsSeparatedByString:@"\n"];
    if (parts.count != 1) {
        return;
    }
    NSString *unescapedText = parts[0];
    NSString *text = [unescapedText stringWithEscapedShellCharacters];
    scpPath = [dataSource scpPathForFile:text onLine:_selection.lastRange.start.y];
    [_delegate startDownloadOverSCP:scpPath];
    
    NSDictionary *attributes =
        @{ NSForegroundColorAttributeName: selectedTextColor,
           NSBackgroundColorAttributeName: selectionColor,
           NSFontAttributeName: primaryFont.font };
    NSSize size = [selectedText sizeWithAttributes:attributes];
    size.height = lineHeight;
    NSImage* image = [[[NSImage alloc] initWithSize:size] autorelease];
    [image lockFocus];
    [selectedText drawAtPoint:NSMakePoint(0, 0) withAttributes:attributes];
    [image unlockFocus];
    
    VT100GridCoordRange range = _selection.lastRange;
    NSRect windowRect = [self convertRect:NSMakeRect(range.start.x * charWidth + MARGIN,
                                                     range.start.y * lineHeight,
                                                     0,
                                                     0)
                                   toView:nil];
    NSPoint point = [[self window] convertRectToScreen:windowRect].origin;
    point.y -= lineHeight;
    [[FileTransferManager sharedInstance] animateImage:image
                            intoDownloadsMenuFromPoint:point
                                              onScreen:[[self window] screen]];
}

- (void)showNotes:(id)sender
{
    for (PTYNoteViewController *note in [dataSource notesInRange:VT100GridCoordRangeMake(validationClickPoint_.x,
                                                                                         validationClickPoint_.y,
                                                                                         validationClickPoint_.x + 1,
                                                                                         validationClickPoint_.y)]) {
        [note setNoteHidden:NO];
    }
}

- (void)updateNoteViewFrames
{
    for (NSView *view in [self subviews]) {
        if ([view isKindOfClass:[PTYNoteView class]]) {
            PTYNoteView *noteView = (PTYNoteView *)view;
            PTYNoteViewController *note =
                (PTYNoteViewController *)noteView.delegate.noteViewController;
            VT100GridCoordRange coordRange = [dataSource coordRangeOfNote:note];
            if (coordRange.end.y >= 0) {
                [note setAnchor:NSMakePoint(coordRange.end.x * charWidth + MARGIN,
                                            (1 + coordRange.end.y) * lineHeight)];
            }
        }
    }
    [dataSource removeInaccessibleNotes];
}

- (void)editTextViewSession:(id)sender
{
    [_delegate textViewEditSession];
}

- (void)toggleBroadcastingInput:(id)sender
{
    [_delegate textViewToggleBroadcastingInput];
}

- (void)closeTextViewSession:(id)sender
{
    [_delegate textViewCloseWithConfirmation];
}

- (void)copySelectionAccordingToUserPreferences
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"CopyWithStylesByDefault"]) {
        [self copyWithStyles:self];
    } else {
        [self copy:self];
    }
}

- (void)copy:(id)sender
{
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];
    NSString *copyString;

    DLog(@"-[PTYTextView copy:] called");
    copyString = [self selectedText];
    DLog(@"Have selected text of length %d. selection=%@", (int)[copyString length], _selection);
    if (copyString) {
        [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:self];
        [pboard setString:copyString forType:NSStringPboardType];
    }

    [[PasteboardHistory sharedInstance] save:copyString];
}

- (IBAction)copyWithStyles:(id)sender
{
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];
    
    DLog(@"-[PTYTextView copyWithStyles:] called");
    NSString *copyString = [self selectedText];
    NSAttributedString *copyAttributedString = [self selectedAttributedTextWithPad:NO];
    DLog(@"Have selected text of length %d. selection=%@", (int)[copyString length], _selection);
    NSMutableArray *types = [NSMutableArray array];
    if (copyString) {
        [types addObject:NSStringPboardType];
    }
    if (copyAttributedString) {
        [types addObject:NSRTFPboardType];
    }
    [pboard declareTypes:types owner:self];
    if (copyString) {
        [pboard setString:copyString forType:NSStringPboardType];
    }
    if (copyAttributedString) {
        NSData *RTFData = [copyAttributedString RTFFromRange:NSMakeRange(0, [copyAttributedString length])
                                          documentAttributes:nil];
        [pboard setData:RTFData forType:NSRTFPboardType];
    }
    
    [[PasteboardHistory sharedInstance] save:copyString];
}

// Returns a dictionary to pass to NSAttributedString.
- (NSDictionary *)charAttributes:(screen_char_t)c
{
    BOOL isBold = c.bold;
    NSColor *fgColor = [self colorForCode:c.foregroundColor
                                    green:c.fgGreen
                                     blue:c.fgBlue
                                colorMode:c.foregroundColorMode
                                     bold:isBold
                             isBackground:NO];
    NSColor *bgColor = [self colorForCode:c.backgroundColor
                                    green:c.bgGreen
                                     blue:c.bgBlue
                                colorMode:c.backgroundColorMode
                                     bold:NO
                             isBackground:YES];

    int underlineStyle = c.underline ? (NSUnderlineStyleSingle | NSUnderlineByWordMask) : 0;

    BOOL isItalic = c.italic;
    PTYFontInfo *fontInfo = [self getFontForChar:c.code
                                       isComplex:c.complexChar
                                      renderBold:&isBold
                                    renderItalic:&isItalic];

    return @{ NSForegroundColorAttributeName: fgColor,
              NSBackgroundColorAttributeName: bgColor,
              NSFontAttributeName: fontInfo.font,
              NSUnderlineStyleAttributeName: @(underlineStyle) };
}


- (NSAttributedString *)attributedContentInRange:(VT100GridCoordRange)range pad:(BOOL)pad
{
    int width = [dataSource width];
    NSMutableAttributedString* result = [[[NSMutableAttributedString alloc] init] autorelease];
    int y, x1, x2;
    screen_char_t *theLine;
    BOOL endOfLine;
    int i;

    for (y = range.start.y; y <= range.end.y; y++) {
        theLine = [dataSource getLineAtIndex:y];

        x1 = y == range.start.y ? range.start.x : 0;
        x2 = y == range.end.y ? range.end.x - 1 : width - 1;
        for ( ; x1 <= x2; x1++) {
            screen_char_t c = theLine[x1];
            if (c.code == TAB_FILLER) {
                // Convert orphan tab fillers (those without a subsequent
                // tab character) into spaces.
                if ([self isTabFillerOrphanAtX:x1 Y:y]) {
                    [result iterm_appendString:@" " withAttributes:[self charAttributes:c]];
                }
            } else if (c.code != DWC_RIGHT &&
                       c.code != DWC_SKIP) {
                if (c.code == 0) { // end of line?
                    // If there is no text after this, insert a hard line break.
                    endOfLine = YES;
                    for (i = x1 + 1; i <= x2 && endOfLine; i++) {
                        if (theLine[i].code != 0) {
                            endOfLine = NO;
                        }
                    }
                    if (endOfLine) {
                        if (pad) {
                            for (i = x1; i <= x2; i++) {
                                [result iterm_appendString:@" "
                                            withAttributes:[self charAttributes:theLine[i]]];
                            }
                        }
                        if (y < range.end.y && theLine[width].code == EOL_HARD) {
                            [result iterm_appendString:@"\n"
                                        withAttributes:[self charAttributes:theLine[width - 1]]];
                        }
                        break;
                    } else {
                        // replace mid-line null char with space
                        [result iterm_appendString:@" " withAttributes:[self charAttributes:c]];
                    }
                } else if (x1 == x2 &&
                           y < range.end.y &&
                           theLine[width].code == EOL_HARD) {
                    // Hard line break
                    [result iterm_appendString:ScreenCharToStr(&c)
                                withAttributes:[self charAttributes:c]];
                    [result iterm_appendString:@"\n"
                                withAttributes:[self charAttributes:theLine[width - 1]]];
                } else {
                    // Normal character
                    [result iterm_appendString:ScreenCharToStr(&c)
                                withAttributes:[self charAttributes:c]];
                }
            }
        }
    }

    return result;
}

- (void)paste:(id)sender
{
    NSString* info = [_delegate textViewPasteboardString];
    if (info) {
        [[PasteboardHistory sharedInstance] save:info];
    }

    if ([_delegate respondsToSelector:@selector(paste:)]) {
        [_delegate paste:sender];
    }
}

- (NSTimeInterval)selectionTime
{
    return selectionTime_;
}

- (void)pasteSelection:(id)sender
{
    [_delegate textViewPasteFromSessionWithMostRecentSelection];
}

- (IBAction)pasteBase64Encoded:(id)sender {
    [_delegate textViewPasteWithEncoding:kTextViewPasteEncodingBase64];
}

- (BOOL)_broadcastToggleable
{
    // There used to be a restriction that you could not toggle broadcasting on
    // the current session if no others were on, but that broke the feature for
    // focus-follows-mouse users. This is an experiment to see if removing that
    // restriction works. 9/8/12
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(paste:)) {
        NSPasteboard *pboard = [NSPasteboard generalPasteboard];
        // Check if there is a string type on the pasteboard
        return ([pboard stringForType:NSStringPboardType] != nil);
    }
    if ([item action ] == @selector(cut:)) {
        // Never allow cut.
        return NO;
    }
    if ([item action]==@selector(toggleBroadcastingInput:) &&
        [self _broadcastToggleable]) {
        return YES;
    }
    if ([item action]==@selector(saveDocumentAs:)) {
        return [self isAnyCharSelected];
    } else if ([item action] == @selector(selectAll:) ||
               [item action]==@selector(splitTextViewVertically:) ||
               [item action]==@selector(splitTextViewHorizontally:) ||
               [item action]==@selector(clearTextViewBuffer:) ||
               [item action]==@selector(editTextViewSession:) ||
               [item action]==@selector(closeTextViewSession:) ||
               [item action]==@selector(movePane:) ||
               ([item action] == @selector(print:) && [item tag] != 1)) {
        // We always validate the above commands
        return YES;
    }
    if ([item action]==@selector(mail:) ||
        [item action]==@selector(browse:) ||
        [item action]==@selector(searchInBrowser:) ||
        [item action]==@selector(addNote:) ||
        [item action]==@selector(copy:) ||
        [item action]==@selector(copyWithStyles:) ||
        [item action]==@selector(pasteSelection:) ||
        ([item action]==@selector(print:) && [item tag] == 1)) { // print selection
        // These commands are allowed only if there is a selection.
        return [_selection hasSelection];
    }
    if ([item action] == @selector(downloadWithSCP:)) {
        return ([self _haveShortSelection] &&
                [_selection hasSelection] &&
                [dataSource scpPathForFile:[self selectedText]
                                    onLine:_selection.lastRange.start.y] != nil);
    }
    if ([item action]==@selector(showNotes:)) {
        return validationClickPoint_.x >= 0 &&
               [[dataSource notesInRange:VT100GridCoordRangeMake(validationClickPoint_.x,
                                                                 validationClickPoint_.y,
                                                                 validationClickPoint_.x + 1,
                                                                 validationClickPoint_.y)] count] > 0;
    }

    // Image actions
    if ([item action] == @selector(saveImageAs:) ||
        [item action] == @selector(copyImage:) ||
        [item action] == @selector(openImage:) ||
        [item action] == @selector(inspectImage:)) {
        return YES;
    }
    if ([item action] == @selector(reRunCommand:)) {
        return YES;
    }
    if ([item action] == @selector(pasteBase64Encoded:)) {
        return [_delegate textViewCanPasteFile];
    }

    SEL theSel = [item action];
    if ([NSStringFromSelector(theSel) hasPrefix:@"contextMenuAction"]) {
        return YES;
    }
    return NO;
}

- (BOOL)_haveShortSelection
{
    int width = [dataSource width];
    return [_selection hasSelection] && [_selection length] <= width;
}
                                 
- (SEL)selectorForSmartSelectionAction:(NSDictionary *)action
{
    // The selector's name must begin with contextMenuAction to
    // pass validateMenuItem.
    switch ([ContextMenuActionPrefsController actionForActionDict:action]) {
        case kOpenFileContextMenuAction:
            return @selector(contextMenuActionOpenFile:);

        case kOpenUrlContextMenuAction:
            return @selector(contextMenuActionOpenURL:);

        case kRunCommandContextMenuAction:
            return @selector(contextMenuActionRunCommand:);

        case kRunCoprocessContextMenuAction:
            return @selector(contextMenuActionRunCoprocess:);

        case kSendTextContextMenuAction:
            return @selector(contextMenuActionSendText:);
    }
}

- (BOOL)addCustomActionsToMenu:(NSMenu *)theMenu matchingText:(NSString *)textWindow line:(int)line
{
    BOOL didAdd = NO;
    NSArray* rulesArray = smartSelectionRules_ ? smartSelectionRules_ : [SmartSelectionController defaultRules];
    const int numRules = [rulesArray count];

    for (int j = 0; j < numRules; j++) {
        NSDictionary *rule = [rulesArray objectAtIndex:j];
        NSString *regex = [SmartSelectionController regexInRule:rule];
        for (int i = 0; i <= textWindow.length; i++) {
            NSString* substring = [textWindow substringWithRange:NSMakeRange(i, [textWindow length] - i)];
            NSError* regexError = nil;
            NSArray *components = [substring captureComponentsMatchedByRegex:regex
                                                                     options:0
                                                                       range:NSMakeRange(0, [substring length])
                                                                       error:&regexError];
            if (components.count) {
                NSLog(@"Components for %@ are %@", regex, components);
                NSArray *actions = [SmartSelectionController actionsInRule:rule];
                for (NSDictionary *action in actions) {
                    SEL mySelector = [self selectorForSmartSelectionAction:action];
                    NSString *theTitle =
                        [ContextMenuActionPrefsController titleForActionDict:action
                                                       withCaptureComponents:components
                                                            workingDirectory:[dataSource workingDirectoryOnLine:line]
                                                                  remoteHost:[dataSource remoteHostOnLine:line]];

                    NSMenuItem *theItem = [[[NSMenuItem alloc] initWithTitle:theTitle
                                                                      action:mySelector
                                                               keyEquivalent:@""] autorelease];
                    NSString *parameter =
                        [ContextMenuActionPrefsController parameterForActionDict:action
                                                           withCaptureComponents:components
                                                                workingDirectory:[dataSource workingDirectoryOnLine:line]
                                                                      remoteHost:[dataSource remoteHostOnLine:line]];
                    [theItem setRepresentedObject:parameter];
                    [theItem setTarget:self];
                    [theMenu addItem:theItem];
                    didAdd = YES;
                }
                break;
            }
        }
    }
    return didAdd;
}

- (void)contextMenuActionOpenFile:(id)sender
{
    NSLog(@"Open file: '%@'", [sender representedObject]);
    [[NSWorkspace sharedWorkspace] openFile:[[sender representedObject] stringByExpandingTildeInPath]];
}

- (void)contextMenuActionOpenURL:(id)sender
{
    NSURL *url = [NSURL URLWithString:[sender representedObject]];
    if (url) {
        NSLog(@"Open URL: %@", [sender representedObject]);
        [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        NSLog(@"%@ is not a URL", [sender representedObject]);
    }
}

- (void)contextMenuActionRunCommand:(id)sender
{
    NSString *command = [sender representedObject];
    NSLog(@"Run command: %@", command);
    [NSThread detachNewThreadSelector:@selector(runCommand:)
                             toTarget:[self class]
                           withObject:command];
}

+ (void)runCommand:(NSString *)command
{

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    system([command UTF8String]);
    [pool drain];
}

- (void)contextMenuActionRunCoprocess:(id)sender
{
    NSString *command = [sender representedObject];
    NSLog(@"Run coprocess: %@", command);
    [_delegate launchCoprocessWithCommand:command];
}

- (void)contextMenuActionSendText:(id)sender
{
    NSString *command = [sender representedObject];
    NSLog(@"Send text: %@", command);
    [_delegate insertText:command];
}

// This method is called by control-click or by clicking the gear icon in the session title bar.
// Two-finger tap (or presumably right click with a mouse) would go through mouseUp->
// PointerController->openContextMenuWithEvent.
- (NSMenu *)menuForEvent:(NSEvent *)theEvent
{
    if (theEvent) {
        // Control-click
        return [self contextMenuWithEvent:theEvent];
    } else {
        // Gear icon in session title view.
        return [self menuAtCoord:VT100GridCoordMake(-1, -1)];
    }
}

- (void)saveImageAs:(id)sender {
    ImageInfo *imageInfo = [sender representedObject];
    NSSavePanel* panel = [NSSavePanel savePanel];

    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory,
                                                         NSUserDomainMask,
                                                         YES);
    NSString *directory;
    if (paths.count > 0) {
        directory = paths[0];
    } else {
        directory = NSHomeDirectory();
    }

    panel.directoryURL = [NSURL fileURLWithPath:directory];
    panel.nameFieldStringValue = [imageInfo.filename lastPathComponent];
    panel.allowedFileTypes = @[ @"png", @"bmp", @"gif", @"jp2", @"jpeg", @"jpg", @"tiff" ];
    panel.allowsOtherFileTypes = NO;
    panel.canCreateDirectories = YES;
    [panel setExtensionHidden:NO];

    if ([panel runModal] == NSOKButton) {
        NSBitmapImageFileType fileType = NSPNGFileType;
        NSString *filename = [panel legacyFilename];
        if ([filename hasSuffix:@".bmp"]) {
            fileType = NSBMPFileType;
        } else if ([filename hasSuffix:@".gif"]) {
            fileType = NSGIFFileType;
        } else if ([filename hasSuffix:@".jp2"]) {
            fileType = NSJPEG2000FileType;
        } else if ([filename hasSuffix:@".jpg"] || [filename hasSuffix:@".jpeg"]) {
            fileType = NSJPEGFileType;
        } else if ([filename hasSuffix:@".png"]) {
            fileType = NSPNGFileType;
        } else if ([filename hasSuffix:@".tiff"]) {
            fileType = NSTIFFFileType;
        }

        NSBitmapImageRep *rep = [[imageInfo.image representations] objectAtIndex:0];
        NSData *data = [rep representationUsingType:fileType properties:nil];
        [data writeToFile:[panel legacyFilename] atomically:NO];
    }
}

- (void)copyImage:(id)sender {
    ImageInfo *imageInfo = [sender representedObject];
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];
    if (imageInfo.image) {
        [pboard declareTypes:[NSArray arrayWithObject:NSTIFFPboardType] owner:self];
        NSBitmapImageRep *rep = [[imageInfo.image representations] objectAtIndex:0];
        NSData *tiff = [rep representationUsingType:NSTIFFFileType properties:nil];
        [pboard setData:tiff forType:NSTIFFPboardType];
    }
}

- (void)openImage:(id)sender {
    ImageInfo *imageInfo = [sender representedObject];
    if (imageInfo.image) {
        CFUUIDRef   uuid;
        CFStringRef uuidStr;

        uuid = CFUUIDCreate(NULL);
        uuidStr = CFUUIDCreateString(NULL, uuid);

        NSString *filename = [NSString stringWithFormat:@"iterm2TempImage.%@.tiff", uuidStr];

        CFRelease(uuidStr);
        CFRelease(uuid);

        NSBitmapImageRep *rep = [[imageInfo.image representations] objectAtIndex:0];
        NSData *tiff = [rep representationUsingType:NSTIFFFileType properties:nil];
        [tiff writeToFile:filename atomically:NO];
        [[NSWorkspace sharedWorkspace] openFile:filename];
    }
}

- (void)inspectImage:(id)sender {
    ImageInfo *imageInfo = [sender representedObject];
    if (imageInfo) {
        NSString *text = [NSString stringWithFormat:
                          @"Filename: %@\n"
                          @"Dimensions: %d x %d",
                          imageInfo.filename,
                          (int)imageInfo.image.size.width,
                          (int)imageInfo.image.size.height];

        NSAlert *alert = [NSAlert alertWithMessageText:text
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@""];

        [alert layout];
        [alert runModal];
    }
}

- (ImageInfo *)imageInfoAtCoord:(VT100GridCoord)coord
{
    if (coord.x < 0) {
        return nil;
    }
    screen_char_t* theLine = [dataSource getLineAtIndex:coord.y];
    if (theLine && coord.x < [dataSource width] && theLine[coord.x].image) {
        return GetImageInfo(theLine[coord.x].code);
    } else {
        return nil;
    }
}

- (void)reRunCommand:(id)sender
{
    NSString *command = [sender representedObject];
    [_delegate insertText:[command stringByAppendingString:@"\n"]];
}

- (NSMenu *)menuForMark:(VT100ScreenMark *)mark directory:(NSString *)directory
{
    NSMenu *theMenu;

    // Allocate a menu
    theMenu = [[NSMenu alloc] initWithTitle:@"Contextual Menu"];

    NSMenuItem *theItem = [[[NSMenuItem alloc] init] autorelease];
    theItem.title = [NSString stringWithFormat:@"Command: %@", mark.command];
    [theMenu addItem:theItem];

    if (directory) {
        theItem = [[[NSMenuItem alloc] init] autorelease];
        theItem.title = [NSString stringWithFormat:@"Directory: %@", directory];
        [theMenu addItem:theItem];
    }

    theItem = [[[NSMenuItem alloc] init] autorelease];
    theItem.title = [NSString stringWithFormat:@"Return code: %d", mark.code];
    [theMenu addItem:theItem];

    [theMenu addItem:[NSMenuItem separatorItem]];

    theItem = [[[NSMenuItem alloc] initWithTitle:@"Re-run Command"
                                          action:@selector(reRunCommand:)
                                   keyEquivalent:@""] autorelease];
    [theItem setRepresentedObject:mark.command];
    [theMenu addItem:theItem];

    return theMenu;
}

- (NSMenu *)menuAtCoord:(VT100GridCoord)coord
{
    NSMenu *theMenu;

    // Allocate a menu
    theMenu = [[NSMenu alloc] initWithTitle:@"Contextual Menu"];
    ImageInfo *imageInfo = [self imageInfoAtCoord:coord];
    if (imageInfo) {
        // Show context menu for an image.
        NSArray *entryDicts =
            @[ @{ @"title": @"Save Image As…",
                  @"selector": @"saveImageAs:" },
               @{ @"title": @"Copy Image",
                  @"selector": @"copyImage:" },
               @{ @"title": @"Open Image",
                  @"selector": @"openImage:" },
               @{ @"title": @"Inspect",
                  @"selector": @"inspectImage:" } ];
        for (NSDictionary *entryDict in entryDicts) {
            NSMenuItem *item;

            item = [[[NSMenuItem alloc] initWithTitle:entryDict[@"title"]
                                               action:NSSelectorFromString(entryDict[@"selector"])
                                        keyEquivalent:@""] autorelease];
            [item setRepresentedObject:imageInfo];
            [theMenu addItem:item];
        }
        return theMenu;
    }

    if ([self _haveShortSelection]) {
        BOOL addedItem = NO;
        NSString *text = [self selectedText];
        if ([text intValue]) {
            NSMenuItem *theItem = [[[NSMenuItem alloc] init] autorelease];
            theItem.title = [NSString stringWithFormat:@"%d = 0x%x", [text intValue], [text intValue]];
            [theMenu addItem:theItem];
            addedItem = YES;
        } else if ([text hasPrefix:@"0x"] && [text length] <= 10) {
            NSScanner *scanner = [NSScanner scannerWithString:text];

            [scanner setScanLocation:2]; // bypass 0x
            unsigned result;
            if ([scanner scanHexInt:&result]) {
                if ((int)result >= 0) {
                    NSMenuItem *theItem = [[[NSMenuItem alloc] init] autorelease];
                    theItem.title = [NSString stringWithFormat:@"0x%x = %d", result, result];
                    [theMenu addItem:theItem];
                    addedItem = YES;
                } else {
                    NSMenuItem *theItem = [[[NSMenuItem alloc] init] autorelease];
                    theItem.title = [NSString stringWithFormat:@"0x%x = %d or %u", result, result, result];
                    [theMenu addItem:theItem];
                    addedItem = YES;
                }
            }
        }
        if (addedItem) {
            [theMenu addItem:[NSMenuItem separatorItem]];
        }
    }

    // Menu items for acting on text selections
    NSString *scpTitle = @"Download with scp";
    if ([self _haveShortSelection]) {
        SCPPath *scpPath = [dataSource scpPathForFile:[self selectedText]
                                               onLine:_selection.lastRange.start.y];
        if (scpPath) {
            scpTitle = [NSString stringWithFormat:@"Download with scp from %@", scpPath.hostname];
        }
    }

    [theMenu addItemWithTitle:scpTitle
                       action:@selector(downloadWithSCP:)
                keyEquivalent:@""];
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Open Selection as URL",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(browse:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Search Google for Selection",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(searchInBrowser:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Send Email to Selected Address",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(mail:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Custom actions
    if ([_selection hasSelection] &&
        [_selection length] < kMaxSelectedTextLengthForCustomActions) {
        NSString *selectedText = [self selectedTextWithPad:NO cappedAtSize:1024];
        if ([self addCustomActionsToMenu:theMenu matchingText:selectedText line:coord.y]) {
            [theMenu addItem:[NSMenuItem separatorItem]];
        }
    }

    // Split pane options
    [theMenu addItemWithTitle:@"Split Pane Vertically" action:@selector(splitTextViewVertically:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:@"Split Pane Horizontally" action:@selector(splitTextViewHorizontally:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:@"Move Session to Split Pane" action:@selector(movePane:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:@"Move Session to Window" action:@selector(moveSessionToWindow:) keyEquivalent:@""];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Copy,  paste, and save
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Copy",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(copy:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Paste",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(paste:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Save",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(saveDocumentAs:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Select all
    [theMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Select All",@"iTerm", [NSBundle bundleForClass: [self class]], @"Context menu")
                     action:@selector(selectAll:) keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Clear buffer
    [theMenu addItemWithTitle:@"Clear Buffer"
                       action:@selector(clearTextViewBuffer:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Make note
    [theMenu addItemWithTitle:@"Annotate Selection"
                       action:@selector(addNote:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];
    
    [theMenu addItemWithTitle:@"Show Note"
                       action:@selector(showNotes:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Edit Session
    [theMenu addItemWithTitle:@"Edit Session..."
                       action:@selector(editTextViewSession:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Toggle broadcast
    [theMenu addItemWithTitle:@"Toggle Broadcasting Input"
                       action:@selector(toggleBroadcastingInput:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Separator
    [theMenu addItem:[NSMenuItem separatorItem]];

    // Close current pane
    [theMenu addItemWithTitle:@"Close"
                       action:@selector(closeTextViewSession:)
                keyEquivalent:@""];
    [[theMenu itemAtIndex:[theMenu numberOfItems] - 1] setTarget:self];

    // Ask the delegate if there is anything to be added
    if ([[self delegate] respondsToSelector:@selector(menuForEvent:menu:)]) {
        [[self delegate] menuForEvent:nil menu:theMenu];
    }

    return [theMenu autorelease];
}

- (void)mail:(id)sender
{
    NSString* mailto;

    if ([[self selectedText] hasPrefix:@"mailto:"]) {
        mailto = [NSString stringWithString:[self selectedText]];
    } else {
        mailto = [NSString stringWithFormat:@"mailto:%@", [self selectedText]];
    }

    NSString* escapedString = (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL,
                                                                                  (CFStringRef)mailto,
                                                                                  (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                                                                  NULL,
                                                                                  kCFStringEncodingUTF8 );

    NSURL* url = [NSURL URLWithString:escapedString];
    [escapedString release];

    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)browse:(id)sender
{
    [self _findUrlInString:[self selectedText]
          andOpenInBackground:NO];
}

- (void)searchInBrowser:(id)sender
{
    NSString* url =
        [NSString stringWithFormat:[[PreferencePanel sharedInstance] searchCommand],
                                   [[self selectedText] stringWithPercentEscape]];
    [self _findUrlInString:url
          andOpenInBackground:NO];
}

//
// Drag and Drop methods for our text view
//

//
// Called when our drop area is entered
//
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    extendedDragNDrop = YES;

    return [self dragOperationForSender:sender];
}

//
// Called when the dragged object is moved within our drop area
//
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return [self dragOperationForSender:sender];
}

//
// Called when the dragged object leaves our drop area
//
- (void)draggingExited:(id <NSDraggingInfo>)sender
{
    // We don't do anything special, so let the parent NSTextView handle this.
    [super draggingExited:sender];

    // Reset our handler flag
    extendedDragNDrop = NO;
}

//
// Called when the dragged item is about to be released in our drop area.
//
- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
    BOOL result;

    // Check if parent NSTextView knows how to handle this.
    result = [super prepareForDragOperation: sender];

    // If parent class does not know how to deal with this drag type, check if we do.
    if (result != YES &&
        [self dragOperationForSender:sender] != NSDragOperationNone) {
        result = YES;
    }

    return result;
}

- (BOOL)hostIsLocal:(NSString *)host {
    NSArray *hostAddresses = [[NSHost hostWithName:host] addresses];
    NSArray *localAddresses = [[NSHost currentHost] addresses];
    for (NSString *hostAddress in hostAddresses) {
        if ([localAddresses containsObject:hostAddress]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)confirmUploadOfFiles:(NSArray *)files toPath:(SCPPath *)path {
    NSString *text;
    if (files.count == 0) {
        return NO;
    }
    if (files.count == 1) {
        text = [NSString stringWithFormat:@"Ok to scp\n%@\nto\n%@@%@:%@?",
                [files componentsJoinedByString:@", "],
                path.username, path.hostname, path.path];
    } else {
        text = [NSString stringWithFormat:@"Ok to scp the following files:\n%@\n\nto\n%@@%@:%@?",
                [files componentsJoinedByString:@", "],
                path.username, path.hostname, path.path];
    }
    NSAlert *alert = [NSAlert alertWithMessageText:text
                                     defaultButton:@"OK"
                                   alternateButton:@"Cancel"
                                       otherButton:nil
                         informativeTextWithFormat:@""];
    
    [alert layout];
    NSInteger button = [alert runModal];
    return (button == NSAlertDefaultReturn);
}

- (void)maybeUpload:(NSArray *)tuple {
    NSArray *propertyList = tuple[0];
    SCPPath *dropScpPath = tuple[1];
    if ([self confirmUploadOfFiles:propertyList toPath:dropScpPath]) {
        [self.delegate uploadFiles:propertyList toPath:dropScpPath];
    }
}

//
// Called when the dragged item is released in our drop area.
//
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    unsigned int dragOperation;
    BOOL res = NO;

    // If parent class does not know how to deal with this drag type, check if we do.
    if (extendedDragNDrop) {
        NSPasteboard *pb = [sender draggingPasteboard];
        NSArray *propertyList = nil;
        NSString *aString;
        int i;

        dragOperation = [sender draggingSourceOperationMask];
        if (dragOperation & kPasteDragOperation) {
            // Paste string or filenames in.
            NSArray *types = [pb types];

            if ([types containsObject:NSFilenamesPboardType]) {
                propertyList = [pb propertyListForType:NSFilenamesPboardType];

                for (i = 0; i < (int)[propertyList count]; i++) {
                    // Ignore text clippings
                    NSString *filename = (NSString*)[propertyList objectAtIndex:i];  // this contains the POSIX path to a file
                    NSDictionary *filenamesAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filename
                                                                                                         error:nil];
                    if (([filenamesAttributes fileHFSTypeCode] == 'clpt' &&
                         [filenamesAttributes fileHFSCreatorCode] == 'MACS') ||
                        [[filename pathExtension] isEqualToString:@"textClipping"] == YES) {
                        continue;
                    }

                    // Just paste the file names into the shell after escaping special characters.
                    if ([_delegate respondsToSelector:@selector(pasteString:)]) {
                        NSMutableString *path;

                        path = [[NSMutableString alloc] initWithString:(NSString*)[propertyList objectAtIndex:i]];

                        // get rid of special characters
                        [_delegate pasteString:[path stringWithEscapedShellCharacters]];
                        [_delegate pasteString:@" "];
                        [path release];

                        res = YES;
                    }
                }
            }
            if (!res && [types containsObject:NSStringPboardType]) {
                aString = [pb stringForType:NSStringPboardType];
                if (aString != nil) {
                    if ([_delegate respondsToSelector:@selector(pasteString:)]) {
                        [_delegate pasteString:aString];
                        res = YES;
                    }
                }
            }
        } else if (dragOperation & kUploadDragOperation) {
            // Upload a file.
            NSArray *types = [pb types];
            
            propertyList = [pb propertyListForType:NSFilenamesPboardType];
            NSPoint windowDropPoint = [sender draggingLocation];
            NSPoint dropPoint = [self convertPoint:windowDropPoint fromView:nil];
            int dropLine = dropPoint.y / lineHeight;
            SCPPath *dropScpPath = [dataSource scpPathForFile:@"" onLine:dropLine];
            if ([types containsObject:NSFilenamesPboardType]) {
                // This is all so the mouse cursor will change to a plain arrow instead of the
                // drop target cursor.
                [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
                [[self window] makeKeyAndOrderFront:nil];
                [self performSelector:@selector(maybeUpload:)
                           withObject:@[ propertyList, dropScpPath ]
                           afterDelay:0];
                return YES;
            }
            return NO;
        }

    }

    return res;
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
    // If we did no handle the drag'n'drop, ask our parent to clean up
    // I really wish the concludeDragOperation would have a useful exit value.
    if (!extendedDragNDrop) {
        [super concludeDragOperation:sender];
    }

    extendedDragNDrop = NO;
}

// Save method
- (void)saveDocumentAs:(id)sender
{
    NSData *aData;
    NSSavePanel *aSavePanel;
    NSString *aString;

    // We get our content of the textview or selection, if any
    aString = [self selectedText];
    if (!aString) {
        aString = [self content];
    }

    aData = [aString dataUsingEncoding:[_delegate textViewEncoding]
                  allowLossyConversion:YES];

    // initialize a save panel
    aSavePanel = [NSSavePanel savePanel];
    [aSavePanel setAccessoryView:nil];

    NSString *path = @"";
    NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask,
                                                               YES);
    if ([searchPaths count]) {
        path = [searchPaths objectAtIndex:0];
    }

    NSString* nowStr = [[NSDate date] descriptionWithCalendarFormat:@"Log at %Y-%m-%d %H.%M.%S.txt"
                                                           timeZone:nil
                                                             locale:[[NSUserDefaults standardUserDefaults] dictionaryRepresentation]];

    if ([aSavePanel legacyRunModalForDirectory:path file:nowStr] == NSFileHandlingPanelOKButton) {
        if (![aData writeToFile:[aSavePanel legacyFilename] atomically:YES]) {
            NSBeep();
        }
    }
}

// Print
- (void)print:(id)sender
{
    NSRect visibleRect;
    int lineOffset, numLines;
    int type = sender ? [sender tag] : 0;

    switch (type) {
        case 0: // visible range
            visibleRect = [[self enclosingScrollView] documentVisibleRect];
            // Starting from which line?
            lineOffset = visibleRect.origin.y/lineHeight;
            // How many lines do we need to draw?
            numLines = visibleRect.size.height/lineHeight;
            [self printContent:[self contentInRange:VT100GridCoordRangeMake(0,
                                                                            lineOffset,
                                                                            [dataSource width],
                                                                            lineOffset + numLines - 1)
                                                pad:NO
                                 includeLastNewline:YES
                             trimTrailingWhitespace:NO
                                       cappedAtSize:-1]];
            break;
        case 1: // text selection
            [self printContent: [self selectedTextWithPad:NO]];
            break;
        case 2: // entire buffer
            [self printContent: [self content]];
            break;
    }
}

- (void)printContent:(NSString *)aString
{
    NSPrintInfo *aPrintInfo;

    aPrintInfo = [NSPrintInfo sharedPrintInfo];
    [aPrintInfo setHorizontalPagination: NSFitPagination];
    [aPrintInfo setVerticalPagination: NSAutoPagination];
    [aPrintInfo setVerticallyCentered: NO];

    // Create a temporary view with the contents, change to black on white, and
    // print it.
    NSTextView *tempView;
    NSMutableAttributedString *theContents;

    tempView = [[NSTextView alloc] initWithFrame:[[self enclosingScrollView] documentVisibleRect]];
    theContents = [[NSMutableAttributedString alloc] initWithString:aString];
    [theContents addAttributes: [NSDictionary dictionaryWithObjectsAndKeys:
        [NSColor textBackgroundColor], NSBackgroundColorAttributeName,
        [NSColor textColor], NSForegroundColorAttributeName,
        [NSFont userFixedPitchFontOfSize: 0], NSFontAttributeName, NULL]
                         range: NSMakeRange(0, [theContents length])];
    [[tempView textStorage] setAttributedString: theContents];
    [theContents release];

    // Now print the temporary view.
    [[NSPrintOperation printOperationWithView:tempView
                                    printInfo:aPrintInfo] runOperation];
    [tempView release];
}

#pragma mark - NSTextInput

- (void)doCommandBySelector:(SEL)aSelector
{
    if (gCurrentKeyEventTextView && self != gCurrentKeyEventTextView) {
        // See comment in -keyDown:
        DLog(@"Rerouting doCommandBySelector from %@ to %@", self, gCurrentKeyEventTextView);
        [gCurrentKeyEventTextView doCommandBySelector:aSelector];
        return;
    }
    DLog(@"doCommandBySelector:%@", NSStringFromSelector(aSelector));
}

// NSTextInput
- (void)insertText:(id)aString
{
    if ([aString isKindOfClass:[NSAttributedString class]]) {
        aString = [aString string];
    }
    if (gCurrentKeyEventTextView && self != gCurrentKeyEventTextView) {
        // See comment in -keyDown:
        DLog(@"Rerouting insertText from %@ to %@", self, gCurrentKeyEventTextView);
        [gCurrentKeyEventTextView insertText:aString];
        return;
    }
    DLog(@"PTYTextView insertText:%@", aString);
    if ([self hasMarkedText]) {
        BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];
        if (debugKeyDown) {
            NSLog(@"insertText: clear marked text");
        }
        IM_INPUT_MARKEDRANGE = NSMakeRange(0, 0);
        [markedText release];
        markedText=nil;
        imeOffset = 0;
    }
    if (![_selection hasSelection]) {
        [self resetFindCursor];
    }

    if ([(NSString*)aString length]>0) {
        if ([_delegate respondsToSelector:@selector(insertText:)])
            [_delegate insertText:aString];
        else
            [super insertText:aString];

        IM_INPUT_INSERT = YES;
    }

    if ([self hasMarkedText]) {
        // In case imeOffset changed, the frame height must adjust.
        [_delegate refreshAndStartTimerIfNeeded];
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
    firstMouseEventNumber_ = [theEvent eventNumber];
    return YES;
}

// NSTextInput
- (void)setMarkedText:(id)aString selectedRange:(NSRange)selRange
{
    BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];
    if (debugKeyDown) {
        NSLog(@"set marked text to %@; range %@", aString, [NSValue valueWithRange:selRange]);
    }
    [markedText release];
    if ([aString isKindOfClass:[NSAttributedString class]]) {
        markedText = [[NSAttributedString alloc] initWithString:[aString string]
                                                     attributes:[self markedTextAttributes]];
    } else {
        markedText = [[NSAttributedString alloc] initWithString:aString
                                                     attributes:[self markedTextAttributes]];
    }
    IM_INPUT_MARKEDRANGE = NSMakeRange(0,[markedText length]);
    IM_INPUT_SELRANGE = selRange;

    // Compute the proper imeOffset.
    int dirtStart;
    int dirtEnd;
    int dirtMax;
    imeOffset = 0;
    do {
        dirtStart = ([dataSource cursorY] - 1 - imeOffset) * [dataSource width] + [dataSource cursorX] - 1;
        dirtEnd = dirtStart + [self inputMethodEditorLength];
        dirtMax = [dataSource height] * [dataSource width];
        if (dirtEnd > dirtMax) {
            ++imeOffset;
        }
    } while (dirtEnd > dirtMax);

    if (![markedText length]) {
        // The call to refresh won't invalidate the IME rect because
        // there is no IME any more. If the user backspaced over the only
        // char in the IME buffer then this causes it be erased.
        [self invalidateInputMethodEditorRect];
    }
    [_delegate refreshAndStartTimerIfNeeded];
    [self scrollEnd];
}

// NSTextInput
- (void)unmarkText
{
    BOOL debugKeyDown = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DebugKeyDown"] boolValue];
    if (debugKeyDown) {
        NSLog(@"clear marked text");
    }
    // As far as I can tell this is never called.
    IM_INPUT_MARKEDRANGE = NSMakeRange(0, 0);
    imeOffset = 0;
    [self invalidateInputMethodEditorRect];
    [_delegate refreshAndStartTimerIfNeeded];
    [self scrollEnd];
}

// NSTextInput
- (BOOL)hasMarkedText
{
    BOOL result;

    if (IM_INPUT_MARKEDRANGE.length > 0) {
        result = YES;
    } else {
        result = NO;
    }
    return result;
}

// NSTextInput
- (NSRange)markedRange
{
    if (IM_INPUT_MARKEDRANGE.length > 0) {
        return NSMakeRange([dataSource cursorX]-1, IM_INPUT_MARKEDRANGE.length);
    } else {
        return NSMakeRange([dataSource cursorX]-1, 0);
    }
}

// NSTextInput
- (NSRange)selectedRange
{
    return NSMakeRange(NSNotFound, 0);
}

// NSTextInput
- (NSArray *)validAttributesForMarkedText
{
    return [NSArray arrayWithObjects:NSForegroundColorAttributeName,
        NSBackgroundColorAttributeName,
        NSUnderlineStyleAttributeName,
        NSFontAttributeName,
        nil];
}

// NSTextInput
- (NSAttributedString *)attributedSubstringFromRange:(NSRange)theRange
{
    return [markedText attributedSubstringFromRange:NSMakeRange(0,theRange.length)];
}

// NSTextInput
- (NSUInteger)characterIndexForPoint:(NSPoint)thePoint
{
    return MAX(0, thePoint.x / charWidth);
}

// NSTextInput
- (long)conversationIdentifier
{
    return (long)self; //not sure about this
}

// NSTextInput
- (NSRect)firstRectForCharacterRange:(NSRange)theRange
{
    int y = [dataSource cursorY] - 1;
    int x = [dataSource cursorX] - 1;

    NSRect rect=NSMakeRect(x * charWidth + MARGIN,
                           (y + [dataSource numberOfLines] - [dataSource height] + 1) * lineHeight,
                           charWidth * theRange.length,
                           lineHeight);
    rect.origin=[[self window] convertBaseToScreen:[self convertPoint:rect.origin
                                                               toView:nil]];

    return rect;
}

- (BOOL)findInProgress
{
    return _findInProgress || searchingForNextResult_;
}

- (void)setTrouterPrefs:(NSDictionary *)prefs
{
    trouter.prefs = prefs;
}

- (void)setSmartSelectionRules:(NSArray *)rules
{
    [smartSelectionRules_ autorelease];
    smartSelectionRules_ = [rules copy];
}

- (BOOL)growSelectionLeft
{
    if (![_selection hasSelection]) {
        return NO;
    }
    VT100GridCoordRange range = _selection.firstRange;
    int x = range.start.x;
    int y = range.start.y;
    --x;
    if (x < 0) {
        x = [dataSource width] - 1;
        --y;
        if (y < 0) {
            return NO;
        }
        // Stop at a hard eol
        screen_char_t* theLine = [dataSource getLineAtIndex:y];
        if (theLine[[dataSource width]].code == EOL_HARD) {
            return NO;
        }
    }

    VT100GridCoordRange wordRange;
    [self getWordForX:x
                    y:y
                range:&wordRange];
    
    VT100GridCoordRange existingRange = _selection.firstRange;
    [_selection setFirstRange:VT100GridCoordRangeMake(wordRange.start.x,
                                                      wordRange.start.y,
                                                      existingRange.end.x,
                                                      existingRange.end.y)
                         mode:kiTermSelectionModeCharacter];

    return YES;
}

- (void)growSelectionRight
{
    if (![_selection hasSelection]) {
        return;
    }
    VT100GridCoordRange range = _selection.lastRange;
    int x = range.end.x;
    int y = range.start.y;
    if (x >= [dataSource width]) {
        // Stop at a hard eol
        screen_char_t* theLine = [dataSource getLineAtIndex:y];
        if (theLine[[dataSource width]].code == EOL_HARD) {
            return;
        }
        x = 0;
        ++y;
        if (y >= [dataSource numberOfLines]) {
            return;
        }
    }

    VT100GridCoordRange wordRange;
    [self getWordForX:x
                    y:y
                range:&wordRange];

    VT100GridCoordRange existingRange = _selection.lastRange;
    [_selection setLastRange:VT100GridCoordRangeMake(existingRange.start.x,
                                                     existingRange.start.y,
                                                     wordRange.end.x,
                                                     wordRange.end.y)
                        mode:kiTermSelectionModeCharacter];
}

// Add a match to resultMap_
- (void)addSearchResult:(SearchResult *)searchResult {
    int width = [dataSource width];
    for (long long y = searchResult->absStartY; y <= searchResult->absEndY; y++) {
        NSNumber* key = [NSNumber numberWithLongLong:y];
        NSMutableData* data = [resultMap_ objectForKey:key];
        BOOL set = NO;
        if (!data) {
            data = [NSMutableData dataWithLength:(width / 8 + 1)];
            char* b = [data mutableBytes];
            memset(b, 0, (width / 8) + 1);
            set = YES;
        }
        char* b = [data mutableBytes];
        int lineEndX = MIN(searchResult->endX + 1, width);
        int lineStartX = searchResult->startX;
        if (searchResult->absEndY > y) {
            lineEndX = width;
        }
        if (y > searchResult->absStartY) {
            lineStartX = 0;
        }
        for (int i = lineStartX; i < lineEndX; i++) {
            const int byteIndex = i/8;
            const int bit = 1 << (i & 7);
            if (byteIndex < [data length]) {
                b[byteIndex] |= bit;
            }
        }
        if (set) {
            [resultMap_ setObject:data forKey:key];
        }
    }
}

// Select the next highlighted result by searching findResults_ for a match just before/after the
// current selection.
- (BOOL)_selectNextResultForward:(BOOL)forward withOffset:(int)offset
{
    long long overflowAdustment = [dataSource totalScrollbackOverflow] - [dataSource scrollbackOverflow];
    long long width = [dataSource width];
    long long maxPos = -1;
    long long minPos = -1;
    int start;
    int stride;
    if (forward) {
        start = [findResults_ count] - 1;
        stride = -1;
        if (!_lastFindCoord) {
            minPos = -1;
        } else {
            minPos = _lastFindCoord->startX + _lastFindCoord->absStartY * width + offset;
        }
    } else {
        start = 0;
        stride = 1;
        if (!_lastFindCoord) {
            maxPos = (1 + [dataSource numberOfLines] + overflowAdustment) * width;
        } else {
            maxPos = _lastFindCoord->startX + _lastFindCoord->absStartY * width - offset;
        }
    }
    BOOL found = NO;
    BOOL redraw = NO;
    int i = start;
    for (int j = 0; !found && j < [findResults_ count]; j++) {
        SearchResult* r = [findResults_ objectAtIndex:i];
        long long pos = r->startX + (long long)r->absStartY * width;
        if (!found &&
            ((maxPos >= 0 && pos <= maxPos) ||
             (minPos >= 0 && pos >= minPos))) {
                found = YES;
                redraw = YES;
                [_selection clearSelection];
                VT100GridCoordRange theRange =
                    VT100GridCoordRangeMake(r->startX,
                                            r->absStartY - overflowAdustment,
                                            r->endX + 1,  // half-open
                                            r->absEndY - overflowAdustment);
                iTermSubSelection *sub;
                sub = [iTermSubSelection subSelectionWithRange:theRange
                                                          mode:kiTermSelectionModeCharacter];
                [_selection addSubSelection:sub];
        }
        i += stride;
    }

    if (!found && !foundResult_ && [findResults_ count] > 0) {
        // Wrap around
        SearchResult* r = [findResults_ objectAtIndex:start];
        found = YES;
        [_selection clearSelection];
        VT100GridCoordRange theRange =
            VT100GridCoordRangeMake(r->startX,
                                    r->absStartY - overflowAdustment,
                                    r->endX + 1,  // half-open
                                    r->absEndY - overflowAdustment);
        iTermSubSelection *sub;
        sub = [iTermSubSelection subSelectionWithRange:theRange
                                                  mode:kiTermSelectionModeCharacter];
        [_selection addSubSelection:sub];
        if (forward) {
            [self beginFlash:FlashWrapToTop];
        } else {
            [self beginFlash:FlashWrapToBottom];
        }
    }

    if (found) {
        // Lock scrolling after finding text
        [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];

        VT100GridCoordRange range = _selection.lastRange;
        [self _scrollToCenterLine:range.end.y];
        [self setNeedsDisplay:YES];
        [_lastFindCoord release];
        _lastFindCoord = [[SearchResult searchResultFromX:range.start.x
                                                        y:(long long)range.start.y + overflowAdustment
                                                      toX:0
                                                        y:0] retain];
        foundResult_ = YES;
    }

    if (!_findInProgress && !foundResult_) {
        // Clear the selection.
        [_selection clearSelection];
        [_lastFindCoord release];
        _lastFindCoord = nil;
        redraw = YES;
    }

    if (redraw) {
        [self setNeedsDisplay:YES];
    }

    return found;
}

- (FindContext *)initialFindContext
{
    return initialFindContext_;
}

// continueFind is called by a timer in the client until it returns NO. It does
// two things:
// 1. If _findInProgress is true, search for more results in the dataSource and
//   call _addResultFromX:absY:toX:toAbsY: for each.
// 2. If searchingForNextResult_ is true, highlight the next result before/after
//   the current selection and flip searchingForNextResult_ to false.
- (BOOL)continueFind
{
    BOOL more = NO;
    BOOL redraw = NO;

    assert([self findInProgress]);
    if (_findInProgress) {
        // Collect more results.
        more = [dataSource continueFindAllResults:findResults_
                                        inContext:[dataSource findContext]];
    }
    if (!more) {
        _findInProgress = NO;
    }
    // Add new results to map.
    for (int i = nextOffset_; i < [findResults_ count]; i++) {
        SearchResult* r = [findResults_ objectAtIndex:i];
        [self addSearchResult:r];
        redraw = YES;
    }
    nextOffset_ = [findResults_ count];

    // Highlight next result if needed.
    if (searchingForNextResult_) {
        if ([self _selectNextResultForward:searchingForward_
                                withOffset:findOffset_]) {
            searchingForNextResult_ = NO;
        }
    }

    if (redraw) {
        [self setNeedsDisplay:YES];
    }
    return more;
}

- (void)resetFindCursor
{
    [_lastFindCoord release];
    _lastFindCoord = nil;
}

- (BOOL)findString:(NSString *)aString
  forwardDirection:(BOOL)direction
      ignoringCase:(BOOL)ignoreCase
             regex:(BOOL)regex
        withOffset:(int)offset
{
    searchingForward_ = direction;
    findOffset_ = offset;
    if ([findString_ isEqualToString:aString] &&
        findRegex_ == regex &&
        findIgnoreCase_ == ignoreCase) {
        foundResult_ = NO;  // select the next item before/after the current selection.
        searchingForNextResult_ = YES;
        // I would like to call _selectNextResultForward:withOffset: here, but
        // it results in drawing errors (drawing is clipped to the findbar for
        // some reason). So we return YES and continueFind is run from a timer
        // and everything works fine. The 100ms delay introduced is not
        // noticable.
        return YES;
    } else {
        // Begin a brand new search.
        if (_findInProgress) {
            [[dataSource findContext] reset];
        }

        [_lastFindCoord release];
        long long findY =
            (long long)([dataSource numberOfLines] + 1) + [dataSource totalScrollbackOverflow];
        _lastFindCoord = [[SearchResult searchResultFromX:0
                                                        y:findY
                                                      toX:0
                                                        y:0] retain];

        // Search backwards from the end. This is slower than searching
        // forwards, but most searches are reverse searches begun at the end,
        // so it will get a result sooner.
        [dataSource setFindString:aString
                 forwardDirection:NO
                     ignoringCase:ignoreCase
                            regex:regex
                      startingAtX:0
                      startingAtY:[dataSource numberOfLines] + 1 + [dataSource totalScrollbackOverflow]
                       withOffset:0
                        inContext:[dataSource findContext]
                  multipleResults:YES];

        [initialFindContext_ copyFromFindContext:[dataSource findContext]];  // TODO test this
        initialFindContext_.results = nil;
        [dataSource saveFindContextAbsPos];
        _findInProgress = YES;

        // Reset every bit of state.
        [self clearHighlights];

        // Initialize state with new values.
        findRegex_ = regex;
        findIgnoreCase_ = ignoreCase;
        findResults_ = [[NSMutableArray alloc] init];
        searchingForNextResult_ = YES;
        findString_ = [aString copy];

        [self setNeedsDisplay:YES];
        return YES;
    }
}

- (void)clearHighlights
{
    [findString_ release];
    findString_ = nil;
    [findResults_ release];
    findResults_ = nil;
    nextOffset_ = 0;
    foundResult_ = NO;
    [resultMap_ removeAllObjects];
    searchingForNextResult_ = NO;
}

// transparency
- (double)transparency
{
    return (transparency);
}

- (void)setTransparency:(double)fVal
{
    transparency = fVal;
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (double)blend
{
    return blend;
}

- (void)setBlend:(double)fVal
{
    blend = MIN(MAX(0.3, fVal), 1);
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setSmartCursorColor:(BOOL)value
{
    colorInvertedCursor = value;
    [dimmedColorCache_ removeAllObjects];
}

- (void)setMinimumContrast:(double)value
{
    minimumContrast_ = value;
    [memoizedContrastingColor_ release];
    memoizedContrastingColor_ = nil;
    [dimmedColorCache_ removeAllObjects];
}

- (void)setDimmingAmount:(double)value
{
    dimmingAmount_ = value;
    [cachedBackgroundColor_ release];
    cachedBackgroundColor_ = nil;
    [dimmedColorCache_ removeAllObjects];
    [[self superview] setNeedsDisplay:YES];
}

- (BOOL)useTransparency
{
    return [_delegate textViewWindowUsesTransparency];
}

// service stuff
- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
    if (sendType != nil && [sendType isEqualToString: NSStringPboardType]) {
        return self;
    }

    return ([super validRequestorForSendType: sendType returnType: returnType]);
}

// Service
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard types:(NSArray *)types
{
    NSString *copyString;

    // It is agonizingly slow to copy hundreds of thousands of lines just because the context
    // menu is opening. Services use this to get access to the clipboard contents but
    // it's lousy to hang for a few minutes for a feature that won't be used very much, esp. for
    // such large selections. In OS 10.9 this is called when opening the context menu, even though
    // it is deprecated by 10.9 (!).
    copyString = [self selectedTextWithPad:NO cappedAtSize:100000];

    if (copyString && [copyString length]>0) {
        [pboard declareTypes: [NSArray arrayWithObject: NSStringPboardType] owner: self];
        [pboard setString: copyString forType: NSStringPboardType];
        return YES;
    }

    return NO;
}

// Service
- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
    return NO;
}

// This textview is about to be hidden behind another tab.
- (void)aboutToHide
{
    selectionScrollDirection = 0;
}

// Called from a timer. Update the alpha value for the graphic and request
// that the view be redrawn.
- (void)setFlashAlpha
{
    NSDate* now = [NSDate date];
    double interval = [now timeIntervalSinceDate:lastFlashUpdate_];
    double ratio = interval / 0.016;
    // Decrement proprotionate to the time between calls (exactly 0.05 if time
    // was 0.016 sec).
    flashing_ -= 0.05 * ratio;
    if (flashing_ < 0) {
        // All done.
        flashing_ = 0;
    } else {
        // Schedule another decrementation.
        [lastFlashUpdate_ release];
        lastFlashUpdate_ = [now retain];
        [NSTimer scheduledTimerWithTimeInterval:0.016
                                         target:self
                                       selector:@selector(setFlashAlpha)
                                       userInfo:nil
                                        repeats:NO];
    }
    [self setNeedsDisplay:YES];
}

- (void)beginFlash:(FlashImage)image
{
    flashImage_ = image;
    if (flashing_ == 0) {
        // The timer is not running so start it.
        [lastFlashUpdate_ release];
        lastFlashUpdate_ = [[NSDate date] retain];
        [NSTimer scheduledTimerWithTimeInterval:0.016
                                         target:self
                                       selector:@selector(setFlashAlpha)
                                       userInfo:nil
                                        repeats:NO];
    }
    // Turn the image to opaque and ask to redraw the screen.
    if ([[PreferencePanel sharedInstance] traditionalVisualBell]) {
        flashing_ = 0.33;
    } else {
        flashing_ = 1;
    }
    [self setNeedsDisplay:YES];
}

- (void)highlightMarkOnLine:(int)line {
    CGFloat y = line * lineHeight;
    SolidColorView *blue = [[[SolidColorView alloc] initWithFrame:NSMakeRect(0, y, self.frame.size.width, lineHeight) color:[NSColor blueColor]] autorelease];
    blue.alphaValue = 0;
    [self addSubview:blue];
    [[NSAnimationContext currentContext] setDuration:0.5];
    blue.animator.alphaValue = 0.75;
    [blue performSelector:@selector(removeFromSuperview) withObject:nil afterDelay:0.75];
}

- (NSRect)cursorRect
{
    NSRect frame = [self visibleRect];
    double x = MARGIN + charWidth * ([dataSource cursorX] - 1);
    double y = frame.origin.y + lineHeight * ([dataSource cursorY] - 1);
    return NSMakeRect(x, y, charWidth, lineHeight);
}

- (NSPoint)cursorLocationInScreenCoordinates
{
    NSRect cursorFrame = [self cursorRect];
    double x = cursorFrame.origin.x + cursorFrame.size.width / 2;
    double y = cursorFrame.origin.y + cursorFrame.size.height / 2;
    if ([self hasMarkedText]) {
        x = imeCursorLastPos_.x + 1;
        y = imeCursorLastPos_.y + lineHeight / 2;
    }
    NSPoint p = NSMakePoint(x, y);
    p = [self convertPoint:p toView:nil];
    p = [[self window] convertBaseToScreen:p];
    return p;
}

// Returns the location of the cursor relative to the origin of findCursorWindow_.
- (NSPoint)globalCursorLocation
{
    NSPoint p = [self cursorLocationInScreenCoordinates];
    p = [findCursorWindow_ convertScreenToBase:p];
    return p;
}

// Returns the proper frame for findCursorWindow_, including every screen that the
// "hole" will be in.
- (NSRect)_cursorScreenFrame
{
    NSRect frame = NSZeroRect;
    for (NSScreen *aScreen in [NSScreen screens]) {
        NSRect screenFrame = [aScreen frame];
        if (NSIntersectsRect([[self window] frame], screenFrame)) {
            frame = NSUnionRect(frame, screenFrame);
        }
    }
    if (NSEqualRects(frame, NSZeroRect)) {
        frame = [[self window] frame];
    }
    return frame;
}

- (void)createFindCursorWindow
{
    findCursorWindow_ = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                    styleMask:NSBorderlessWindowMask
                                                      backing:NSBackingStoreBuffered
                                                        defer:YES];
    [findCursorWindow_ setOpaque:NO];
    [findCursorWindow_ makeKeyAndOrderFront:nil];
    [findCursorWindow_ setLevel:NSFloatingWindowLevel];
    [findCursorWindow_ setAlphaValue:0];
    [findCursorWindow_ setFrame:[self _cursorScreenFrame] display:YES];
    [[NSAnimationContext currentContext] setDuration:0.5];
    [[findCursorWindow_ animator] setAlphaValue:0.7];

    findCursorView_ = [[FindCursorView alloc] initWithFrame:NSMakeRect(0, 0, [[self window] frame].size.width, [[self window] frame].size.height)];
    NSPoint p = [self globalCursorLocation];
    findCursorView_.cursor = p;
    [findCursorWindow_ setContentView:findCursorView_];
    [findCursorView_ release];

    findCursorBlinkTimer_ = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                             target:self
                                                           selector:@selector(invalidateCursor)
                                                           userInfo:nil
                                                            repeats:YES];
}

- (void)invalidateCursor
{
    int HEIGHT = [dataSource height];
    NSRect rect = [self cursorRect];
    int yStart = [dataSource cursorY] - 1;
    rect.origin.y = (yStart + [dataSource numberOfLines] - HEIGHT + 1) * lineHeight - [self cursorHeight];
    rect.size.height = [self cursorHeight];
    [self setNeedsDisplayInRect:rect];
}

- (void)beginFindCursor:(BOOL)hold
{
    [self showCursor];
    if (!findCursorView_) {
        [self createFindCursorWindow];
    } else {
        [findCursorWindow_ setAlphaValue:1];
    }
    [findCursorTeardownTimer_ invalidate];
    autoHideFindCursor_ = NO;
    if (hold) {
        findCursorTeardownTimer_ = [NSTimer scheduledTimerWithTimeInterval:kFindCursorHoldTime
                                                                    target:self
                                                                  selector:@selector(startCloseFindCursorWindow)
                                                                  userInfo:nil
                                                                   repeats:NO];
    } else {
        findCursorTeardownTimer_ = nil;
    }
}

- (void)placeFindCursorOnAutoHide
{
    autoHideFindCursor_ = YES;
}

- (BOOL)isFindingCursor
{
    return findCursorView_ != nil;
}

- (void)startCloseFindCursorWindow
{
    findCursorTeardownTimer_ = nil;
    if (autoHideFindCursor_ && [self isFindingCursor]) {
        [self endFindCursor];
    }
}

- (void)closeFindCursorWindow:(NSTimer *)timer
{
    NSWindowController *win = [timer userInfo];
    [win close];
    [findCursorBlinkTimer_ invalidate];
    findCursorBlinkTimer_ = nil;
    findCursorTeardownTimer_ = nil;
}

- (void)endFindCursor
{
    [[findCursorWindow_ animator] setAlphaValue:0];
    [findCursorTeardownTimer_ invalidate];
    findCursorTeardownTimer_ = [NSTimer scheduledTimerWithTimeInterval:[[NSAnimationContext currentContext] duration]
                                                                target:self
                                                              selector:@selector(closeFindCursorWindow:)
                                                              userInfo:findCursorWindow_
                                                               repeats:NO];
    findCursorWindow_ = nil;
    findCursorView_ = nil;
}

// The background color is cached separately from other dimmed colors because
// it may be used with different alpha values than foreground colors.
- (NSColor *)cachedDimmedBackgroundColorWithAlpha:(double)alpha
{
    if (!cachedBackgroundColor_ || cachedBackgroundColorAlpha_ != alpha) {
        [cachedBackgroundColor_ release];
        cachedBackgroundColor_ = [[self _dimmedColorFrom:[[self defaultBGColor] colorWithAlphaComponent:alpha]] retain];
        cachedBackgroundColorAlpha_ = alpha;
    }
    return cachedBackgroundColor_;
}

- (void)drawFlippedBackground:(NSRect)bgRect toPoint:(NSPoint)dest
{
    PTYScrollView* scrollView = (PTYScrollView*)[self enclosingScrollView];
    BOOL hasBGImage = [scrollView hasBackgroundImage];
    double alpha = 1.0 - transparency;
    if (hasBGImage) {
        [(PTYScrollView *)[self enclosingScrollView] drawBackgroundImageRect:bgRect
                                                                     toPoint:dest
                                                             useTransparency:[self useTransparency]];
                // Blend default bg color
        NSColor *aColor = [self colorForCode:ALTSEM_BG_DEFAULT
                                       green:0
                                        blue:0
                                   colorMode:ColorModeAlternate
                                        bold:NO
                                isBackground:YES];
        [[aColor colorWithAlphaComponent:1 - blend] set];
        NSRectFillUsingOperation(NSMakeRect(dest.x + bgRect.origin.x,
                                            dest.y + bgRect.origin.y,
                                            bgRect.size.width,
                                            bgRect.size.height), NSCompositeSourceOver);
    } else {
        // No bg image
        if (![self useTransparency]) {
            alpha = 1;
        }
        if (!dimOnlyText_) {
            [[self cachedDimmedBackgroundColorWithAlpha:alpha] set];
        } else {
            [[[self defaultBGColor] colorWithAlphaComponent:alpha] set];
        }
        NSRect fillDest = bgRect;
        fillDest.origin.y += fillDest.size.height;
        NSRectFillUsingOperation(fillDest, NSCompositeCopy);
    }
}

- (void)drawBackground:(NSRect)bgRect toPoint:(NSPoint)dest
{
    PTYScrollView* scrollView = (PTYScrollView*)[self enclosingScrollView];
    BOOL hasBGImage = [scrollView hasBackgroundImage];
    double alpha = 1.0 - transparency;
    if (hasBGImage) {
        [(PTYScrollView *)[self enclosingScrollView] drawBackgroundImageRect:bgRect
                                                                     toPoint:dest
                                                             useTransparency:[self useTransparency]];
        // Blend default bg color over bg image.
        NSColor *aColor = [self colorForCode:ALTSEM_BG_DEFAULT
                                       green:0
                                        blue:0
                                   colorMode:ColorModeAlternate
                                        bold:NO
                                isBackground:YES];
        [[aColor colorWithAlphaComponent:1 - blend] set];
        NSRectFillUsingOperation(NSMakeRect(dest.x + bgRect.origin.x,
                                            dest.y + bgRect.origin.y,
                                            bgRect.size.width,
                                            bgRect.size.height),
                                 NSCompositeSourceOver);
    } else {
        // No bg image
        if (![self useTransparency]) {
            alpha = 1;
        }
        if (!dimOnlyText_) {
            [[self cachedDimmedBackgroundColorWithAlpha:alpha] set];
        } else {
            [[[self defaultBGColor] colorWithAlphaComponent:alpha] set];
        }
        NSRectFillUsingOperation(bgRect, NSCompositeCopy);
    }
}

- (void)drawBackground:(NSRect)bgRect
{
    PTYScrollView* scrollView = (PTYScrollView*)[self enclosingScrollView];
    BOOL hasBGImage = [scrollView hasBackgroundImage];
    double alpha = 1.0 - transparency;
    if (hasBGImage) {
        [(PTYScrollView *)[self enclosingScrollView] drawBackgroundImageRect:bgRect
                                                             useTransparency:[self useTransparency]];
                // Blend default bg color over bg iamge.
        NSColor *aColor = [self colorForCode:ALTSEM_BG_DEFAULT
                                       green:0
                                        blue:0
                                   colorMode:ColorModeAlternate
                                        bold:NO
                                isBackground:YES];
        [[aColor colorWithAlphaComponent:1 - blend] set];
        NSRectFillUsingOperation(bgRect, NSCompositeSourceOver);
    } else {
        // Either draw a normal bg or, if transparency is off, blend the default bg color over the bg image.
        if (![self useTransparency]) {
            alpha = 1;
        }
        if (!dimOnlyText_) {
            [[self cachedDimmedBackgroundColorWithAlpha:alpha] set];
        } else {
            [[[self defaultBGColor] colorWithAlphaComponent:alpha] set];
        }
        NSRectFillUsingOperation(bgRect, NSCompositeCopy);
    }
}

- (BOOL)getAndResetChangedSinceLastExpose
{
    BOOL temp = changedSinceLastExpose_;
    changedSinceLastExpose_ = NO;
    return temp;
}

- (BOOL)isAnyCharSelected
{
    return [_selection hasSelection];
}

- (NSString *)getWordForX:(int)x
                        y:(int)y
                    range:(VT100GridCoordRange *)rangePtr
{
    int tmpX;
    int tmpY;
    int x1;
    int yStart;
    int x2;
    int y2;
    int width = [dataSource width];

    if (x < 0) {
        x = 0;
    }
    if (x >= width) {
        x = width - 1;
    }

    // Search backward from (x, y) to find the beginning of the word.
    tmpX = x;
    tmpY = y;
    // If the char at (x,y) is not whitespace, then go into a mode where
    // word characters are selected as blocks; else go into a mode where
    // whitespace is selected as a block.
    screen_char_t* initialLine = [dataSource getLineAtIndex:tmpY];
    assert(initialLine);
    screen_char_t sct = initialLine[tmpX];
    BOOL selectWordChars = [self classifyChar:sct.code isComplex:sct.complexChar] != CHARTYPE_WHITESPACE;

    while (tmpX >= 0) {
        screen_char_t* theLine = [dataSource getLineAtIndex:tmpY];

        if ([self shouldSelectCharForWord:theLine[tmpX].code isComplex:theLine[tmpX].complexChar selectWordChars:selectWordChars]) {
            tmpX--;
            if (tmpX < 0 && tmpY > 0) {
                // Wrap tmpX, tmpY to the end of the previous line.
                theLine = [dataSource getLineAtIndex:tmpY-1];
                if (theLine[width].code != EOL_HARD) {
                    // check if there's a hard line break
                    tmpY--;
                    tmpX = width - 1;
                }
            }
        } else {
            break;
        }
    }
    if (tmpX != x) {
        // Advance back to the right of the char that caused us to break.
        tmpX++;
    }

    // Ensure the values are sane, although I think none of these cases will
    // ever occur.
    if (tmpX < 0) {
        tmpX = 0;
    }
    if (tmpY < 0) {
        tmpY = 0;
    }
    if (tmpX >= width) {
        tmpX = 0;
        tmpY++;
    }
    if (tmpY >= [dataSource numberOfLines]) {
        tmpY = [dataSource numberOfLines] - 1;
    }

    // Save to startx, starty.
    if (rangePtr) {
        rangePtr->start.x = tmpX;
        rangePtr->start.y = tmpY;
    }
    x1 = tmpX;
    yStart = tmpY;


    // Search forward from x to find the end of the word.
    tmpX = x;
    tmpY = y;
    while (tmpX < width) {
        screen_char_t* theLine = [dataSource getLineAtIndex:tmpY];
        if ([self shouldSelectCharForWord:theLine[tmpX].code isComplex:theLine[tmpX].complexChar selectWordChars:selectWordChars]) {
            tmpX++;
            if (tmpX >= width && tmpY < [dataSource numberOfLines]) {
                if (theLine[width].code != EOL_HARD) {
                    // check if there's a hard line break
                    tmpY++;
                    tmpX = 0;
                }
            }
        } else {
            break;
        }
    }

    // Back off from trailing char.
    if (tmpX != x) {
        tmpX--;
    }

    // Sanity checks.
    if (tmpX < 0) {
        tmpX = width - 1;
        tmpY--;
    }
    if (tmpY < 0) {
        tmpY = 0;
    }
    if (tmpX >= width) {
        tmpX = width - 1;
    }
    if (tmpY >= [dataSource numberOfLines]) {
        tmpY = [dataSource numberOfLines] - 1;
    }

    // Save to endx, endy.
    if (rangePtr) {
        rangePtr->end.x = tmpX+1;
        rangePtr->end.y = tmpY;
    }

    // Grab the contents to return.
    x2 = tmpX+1;
    y2 = tmpY;

    return [self contentInRange:VT100GridCoordRangeMake(x1, yStart, x2, y2)
                            pad:YES
             includeLastNewline:NO
         trimTrailingWhitespace:NO
                   cappedAtSize:-1];
}

- (double)perceivedBrightness:(NSColor*)c
{
    return PerceivedBrightness([c redComponent], [c greenComponent], [c blueComponent]);
}

#pragma mark - Trouter Delegate

- (void)trouterLaunchCoprocessWithCommand:(NSString *)command {
    [_delegate launchCoprocessWithCommand:command];
}

#pragma mark - Private methods

- (PTYFontInfo*)getFontForChar:(UniChar)ch
                     isComplex:(BOOL)complex
                    renderBold:(BOOL*)renderBold
                  renderItalic:(BOOL*)renderItalic
{
    BOOL isBold = *renderBold && useBoldFont;
    BOOL isItalic = *renderItalic && useItalicFont;
    *renderBold = NO;
    *renderItalic = NO;
    PTYFontInfo* theFont;
    BOOL usePrimary = !useNonAsciiFont_ || (!complex && (ch < 128));

    PTYFontInfo *rootFontInfo = usePrimary ? primaryFont : secondaryFont;
    theFont = rootFontInfo;

    if (isBold && isItalic) {
        theFont = rootFontInfo.boldItalicVersion;
        if (!theFont && rootFontInfo.boldVersion) {
            theFont = rootFontInfo.boldVersion;
            *renderItalic = YES;
        } else if (!theFont && rootFontInfo.italicVersion) {
            theFont = rootFontInfo.italicVersion;
            *renderBold = YES;
        } else if (!theFont) {
            theFont = rootFontInfo;
            *renderBold = YES;
            *renderItalic = YES;
        }
    } else if (isBold) {
        theFont = rootFontInfo.boldVersion;
        if (!theFont) {
            theFont = rootFontInfo;
            *renderBold = YES;
        }
    } else if (isItalic) {
        theFont = rootFontInfo.italicVersion;
        if (!theFont) {
            theFont = rootFontInfo;
            *renderItalic = YES;
        }
    }

    return theFont;
}

// Returns true if the sequence of characters starting at (x, y) is not repeated
// TAB_FILLERs followed by a tab.
- (BOOL)isTabFillerOrphanAtX:(int)x Y:(int)y
{
    const int realWidth = [dataSource width] + 1;
    screen_char_t buffer[realWidth];
    screen_char_t* theLine = [dataSource getLineAtIndex:y withBuffer:buffer];
    int maxSearch = [dataSource width];
    while (maxSearch > 0) {
        if (x == [dataSource width]) {
            x = 0;
            ++y;
            if (y == [dataSource numberOfLines]) {
                return YES;
            }
            theLine = [dataSource getLineAtIndex:y withBuffer:buffer];
        }
        if (theLine[x].code != TAB_FILLER) {
            if (theLine[x].code == '\t') {
                return NO;
            } else {
                return YES;
            }
        }
        ++x;
        --maxSearch;
    }
    return YES;
}

// Returns true iff the tab character after a run of TAB_FILLERs starting at
// (x,y) is selected.
- (BOOL)isFutureTabSelectedAfterX:(int)x Y:(int)y
{
    const int realWidth = [dataSource width] + 1;
    screen_char_t buffer[realWidth];
    screen_char_t* theLine = [dataSource getLineAtIndex:y withBuffer:buffer];
    while (x < [dataSource width] && theLine[x].code == TAB_FILLER) {
        ++x;
    }
    if ([_selection containsCoord:VT100GridCoordMake(x, y)] &&
        theLine[x].code == '\t') {
        return YES;
    } else {
        return NO;
    }
}

- (NSColor*)colorWithRed:(double)r green:(double)g blue:(double)b alpha:(double)a withPerceivedBrightness:(CGFloat)t
{
    /*
     Given:
     a vector c [c1, c2, c3] (the starting color)
     a vector e [e1, e2, e3] (an extreme color we are moving to, normally black or white)
     a vector A [a1, a2, a3] (the perceived brightness transform)
     a linear function f(Y)=AY (perceived brightness for color Y)
     a constant t (target perceived brightness)
     find a vector X such that F(X)=t
     and X lies on a straight line between c and e

     Define a parametric vector x(p) = [x1(p), x2(p), x3(p)]:
     x1(p) = p*e1 + (1-p)*c1
     x2(p) = p*e2 + (1-p)*c2
     x3(p) = p*e3 + (1-p)*c3

     when p=0, x=c
     when p=1, x=e

     the line formed by x(p) from p=0 to p=1 is the line from c to e.

     Our goal: find the value of p where f(x(p))=t

     We know that:
                            [x1(p)]
     f(X) = AX = [a1 a2 a3] [x2(p)] = a1x1(p) + a2x2(p) + a3x3(p)
                            [x3(p)]
     Expand and solve for p:
        t = a1*(p*e1 + (1-p)*c1) + a2*(p*e2 + (1-p)*c2) + a3*(p*e3 + (1-p)*c3)
        t = a1*(p*e1 + c1 - p*c1) + a2*(p*e2 + c2 - p*c2) + a3*(p*e3 + c3 - p*c3)
        t = a1*p*e1 + a1*c1 - a1*p*c1 + a2*p*e2 + a2*c2 - a2*p*c2 + a3*p*e3 + a3*c3 - a3*p*c3
        t = a1*p*e1 - a1*p*c1 + a2*p*e2 - a2*p*c2 + a3*p*e3 - a3*p*c3 + a1*c1 + a2*c2 + a3*c3
        t = p*(a2*e1 - a1*c1 + a2*e2 - a2*c2 + a3*e3 - a3*c3) + a1*c1 + a2*c2 + a3*c3
        t - (a1*c1 + a2*c2 + a3*c3) = p*(a1*e1 - a1*c1 + a2*e2 - a2*c2 + a3*e3 - a3*c3)
        p = (t - (a1*c1 + a2*c2 + a3*c3)) / (a1*e1 - a1*c1 + a2*e2 - a2*c2 + a3*e3 - a3*c3)
     */
    const CGFloat c1 = r;
    const CGFloat c2 = g;
    const CGFloat c3 = b;

    CGFloat k;
    if (PerceivedBrightness(r, g, b) < t) {
        k = 1;
    } else {
        k = 0;
    }
    const CGFloat e1 = k;
    const CGFloat e2 = k;
    const CGFloat e3 = k;

    const CGFloat a1 = RED_COEFFICIENT;
    const CGFloat a2 = GREEN_COEFFICIENT;
    const CGFloat a3 = BLUE_COEFFICIENT;

    const CGFloat p = (t - (a1*c1 + a2*c2 + a3*c3)) / (a1*(e1 - c1) + a2*(e2 - c2) + a3*(e3 - c3));

    const CGFloat x1 = p * e1 + (1 - p) * c1;
    const CGFloat x2 = p * e2 + (1 - p) * c2;
    const CGFloat x3 = p * e3 + (1 - p) * c3;

    return [self _dimmedColorFrom:[NSColor colorWithCalibratedRed:x1 green:x2 blue:x3 alpha:a]];
}

- (NSColor*)computeColorWithComponents:(double *)mainComponents
         withContrastAgainstComponents:(double *)otherComponents
{
    const double r = mainComponents[0];
    const double g = mainComponents[1];
    const double b = mainComponents[2];
    const double a = mainComponents[3];

    const double or = otherComponents[0];
    const double og = otherComponents[1];
    const double ob = otherComponents[2];

    double mainBrightness = PerceivedBrightness(r, g, b);
    double otherBrightness = PerceivedBrightness(or, og, ob);
    CGFloat brightnessDiff = fabs(mainBrightness - otherBrightness);
    if (brightnessDiff < minimumContrast_) {
        CGFloat error = fabs(brightnessDiff - minimumContrast_);
        CGFloat targetBrightness = mainBrightness;
        if (mainBrightness < otherBrightness) {
            targetBrightness -= error;
            if (targetBrightness < 0) {
                const double alternative = otherBrightness + minimumContrast_;
                const double baseContrast = otherBrightness;
                const double altContrast = MIN(alternative, 1) - otherBrightness;
                if (altContrast > baseContrast) {
                    targetBrightness = alternative;
                }
            }
        } else {
            targetBrightness += error;
            if (targetBrightness > 1) {
                const double alternative = otherBrightness - minimumContrast_;
                const double baseContrast = 1 - otherBrightness;
                const double altContrast = otherBrightness - MAX(alternative, 0);
                if (altContrast > baseContrast) {
                    targetBrightness = alternative;
                }
            }
        }
        targetBrightness = MIN(MAX(0, targetBrightness), 1);
        return [self colorWithRed:r
                            green:g
                             blue:b
                            alpha:a
                    withPerceivedBrightness:targetBrightness];
    } else {
        return nil;
    }
}

- (NSColor*)color:(NSColor*)mainColor withContrastAgainst:(NSColor*)otherColor
{
    double rgb[4];
    rgb[0] = [mainColor redComponent];
    rgb[1] = [mainColor greenComponent];
    rgb[2] = [mainColor blueComponent];
    rgb[3] = [mainColor alphaComponent];

    double orgb[3];
    orgb[0] = [otherColor redComponent];
    orgb[1] = [otherColor greenComponent];
    orgb[2] = [otherColor blueComponent];

    if (!memoizedContrastingColor_ ||
        memcmp(rgb, memoizedMainRGB_, sizeof(rgb)) ||
        memcmp(orgb, memoizedOtherRGB_, sizeof(orgb))) {
        // We memoize the last returned value not so much for performance as for
        // consistency. It ensures that two consecutive calls for the same color
        // will return the same pointer. See the note at the call site in
        // _constructRuns:theLine:...matches:.
        [memoizedContrastingColor_ release];
        memoizedContrastingColor_ = [[self computeColorWithComponents:rgb
                                        withContrastAgainstComponents:orgb] retain];
        if (!memoizedContrastingColor_) {
            memoizedContrastingColor_ = [mainColor retain];
        }
        memmove(memoizedMainRGB_, rgb, sizeof(rgb));
        memmove(memoizedOtherRGB_, orgb, sizeof(orgb));
    }
    return memoizedContrastingColor_;
}

- (CRun *)_constructRuns:(NSPoint)initialPoint
                 theLine:(screen_char_t *)theLine
                     row:(int)row
                reversed:(BOOL)reversed
              bgselected:(BOOL)bgselected
                   width:(const int)width
              indexRange:(NSRange)indexRange
                 bgColor:(NSColor*)bgColor
                 matches:(NSData*)matches
                 storage:(CRunStorage *)storage
{
    BOOL inUnderlinedRange = NO;
    CRun *firstRun = NULL;
    CAttrs attrs = { 0 };
    CRun *currentRun = NULL;
    const char* matchBytes = [matches bytes];
    int lastForegroundColor = -1;
    int lastFgGreen = -1;
    int lastFgBlue = -1;
    int lastForegroundColorMode = -1;
    int lastBold = 2;  // Bold is a one-bit field so it can never equal 2.
    NSColor *lastColor = nil;
    CGFloat curX = 0;
    for (int i = indexRange.location; i < indexRange.location + indexRange.length; i++) {
        if (theLine[i].code == DWC_RIGHT) {
            continue;
        }
        if (_underlineStartX >= 0) {
            if (row == _underlineStartY && row == _underlineEndY) {
                // Whole underline is on one line; this char is underlined if between start,end X.
                inUnderlinedRange = (i >= _underlineStartX && i < _underlineEndX);
            } else if (row == _underlineStartY && i >= _underlineStartX) {
                // Underline spans multiple lines, starting at this one. This char is underlined if
                // at least at the startX column.
                inUnderlinedRange = YES;
            } else if (row == _underlineEndY && i < _underlineEndX) {
                // Underline spans multiple lines, ending at this one. This char is underlined if
                // before or at the endX column.
                inUnderlinedRange = YES;
            } else if (row > _underlineStartY && row < _underlineEndY) {
                // Underline spans multiple lines. This is not the first or last line, so all chars
                // in it are underlined.
                inUnderlinedRange = YES;
            } else {
                // Underline spans multiple lines. This is the first or last line, but outside the
                // underlined range.
                inUnderlinedRange = NO;
            }
        }

        BOOL doubleWidth = i < width - 1 && (theLine[i + 1].code == DWC_RIGHT);
        unichar thisCharUnichar = 0;
        NSString* thisCharString = nil;
        CGFloat thisCharAdvance;

        if (!useNonAsciiFont_ || (theLine[i].code < 128 && !theLine[i].complexChar)) {
            attrs.antiAlias = asciiAntiAlias;
        } else {
            attrs.antiAlias = nonasciiAntiAlias;
        }
        BOOL isSelection = NO;

        // Figure out the color for this char.
        if (bgselected) {
            // Is a selection.
            isSelection = YES;
            // NOTE: This could be optimized by caching the color.
            CRunAttrsSetColor(&attrs, storage, [self _dimmedColorFrom:selectedTextColor]);
        } else {
            // Not a selection.
            if (reversed &&
                theLine[i].foregroundColor == ALTSEM_FG_DEFAULT &&
                theLine[i].foregroundColorMode == ColorModeAlternate) {
                // Has default foreground color so use background color.
                if (!dimOnlyText_) {
                    CRunAttrsSetColor(&attrs, storage, [self _dimmedColorFrom:defaultBGColor]);
                } else {
                    CRunAttrsSetColor(&attrs, storage, defaultBGColor);
                }
            } else {
                if (theLine[i].foregroundColor == lastForegroundColor &&
                    theLine[i].fgGreen == lastFgGreen &&
                    theLine[i].fgBlue == lastFgBlue &&
                    theLine[i].foregroundColorMode == lastForegroundColorMode &&
                    theLine[i].bold == lastBold) {
                    // Looking up colors with -colorForCode:... is expensive and it's common to
                    // have consecutive characters with the same color.
                    CRunAttrsSetColor(&attrs, storage, lastColor);
                } else {
                    // Not reversed or not subject to reversing (only default
                    // foreground color is drawn in reverse video).
                    lastForegroundColor = theLine[i].foregroundColor;
                    lastFgGreen = theLine[i].fgGreen;
                    lastFgBlue = theLine[i].fgBlue;
                    lastForegroundColorMode = theLine[i].foregroundColorMode;
                    lastBold = theLine[i].bold;
                    CRunAttrsSetColor(&attrs,
                                      storage,
                                      [self colorForCode:theLine[i].foregroundColor
                                                   green:theLine[i].fgGreen
                                                    blue:theLine[i].fgBlue
                                               colorMode:theLine[i].foregroundColorMode
                                                    bold:theLine[i].bold
                                            isBackground:NO]);
                    lastColor = attrs.color;
                }
            }
        }

        if (matches && !isSelection) {
            // Test if this is a highlighted match from a find.
            int theIndex = i / 8;
            int mask = 1 << (i & 7);
            if (theIndex < [matches length] && matchBytes[theIndex] & mask) {
                CRunAttrsSetColor(&attrs,
                                  storage,
                                  [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:1]);
            }
        }

        if (minimumContrast_ > 0.001 && bgColor) {
            // TODO: Way too much time spent here. Use previous char's color if it is the same.
            CRunAttrsSetColor(&attrs,
                              storage,
                              [self color:attrs.color withContrastAgainst:bgColor]);
        }
        BOOL drawable;
        if (blinkShow || ![self _charBlinks:theLine[i]]) {
            // This char is either not blinking or during the "on" cycle of the
            // blink. It should be drawn.

            // Set the character type and its unichar/string.
            if (theLine[i].complexChar) {
                thisCharString = ComplexCharToStr(theLine[i].code);
                if (!thisCharString) {
                    // A bug that's happened more than once is that code gets
                    // set to 0 but complexChar is left set to true.
                    NSLog(@"No complex char for code %d", (int)theLine[i].code);
                    thisCharString = @"";
                    drawable = NO;
                } else {
                    drawable = YES;  // TODO: not all unicode is drawable
                }
            } else {
                thisCharString = nil;
                // Non-complex char
                // TODO: There are other spaces in unicode that should be supported.
                drawable = (theLine[i].code != 0 &&
                            theLine[i].code != '\t' &&
                            !(theLine[i].code >= ITERM2_PRIVATE_BEGIN &&
                              theLine[i].code <= ITERM2_PRIVATE_END));

                if (drawable) {
                    thisCharUnichar = theLine[i].code;
                }
            }
        } else {
            // Chatacter hidden because of blinking.
            drawable = NO;
        }
        if (theLine[i].underline || inUnderlinedRange) {
            // This is not as fast as possible, but is nice and simple. Always draw underlined text
            // even if it's just a blank.
            drawable = YES;
        }
        // Set all other common attributes.
        if (doubleWidth) {
            thisCharAdvance = charWidth * 2;
        } else {
            thisCharAdvance = charWidth;
        }

        if (drawable) {
            BOOL fakeBold = theLine[i].bold;
            BOOL fakeItalic = theLine[i].italic;
            attrs.fontInfo = [self getFontForChar:theLine[i].code
                                        isComplex:theLine[i].complexChar
                                       renderBold:&fakeBold
                                     renderItalic:&fakeItalic];
            attrs.fakeBold = fakeBold;
            attrs.fakeItalic = fakeItalic;
            attrs.underline = theLine[i].underline || inUnderlinedRange;
            attrs.imageCode = theLine[i].image ? theLine[i].code : 0;
            attrs.imageColumn = theLine[i].foregroundColor;
            attrs.imageLine = theLine[i].backgroundColor;
            if (theLine[i].image) {
                thisCharString = @"I";
            }
            if (inUnderlinedRange && !self.currentUnderlineHostname) {
                attrs.color = [NSColor colorWithCalibratedRed:0.023 green:0.270 blue:0.678 alpha:1];
            }
            if (!currentRun) {
                firstRun = currentRun = malloc(sizeof(CRun));
                CRunInitialize(currentRun, &attrs, storage, curX);
            }
            if (thisCharString) {
                currentRun = CRunAppendString(currentRun,
                                              &attrs,
                                              thisCharString,
                                              theLine[i].code,
                                              thisCharAdvance,
                                              curX);
            } else {
                currentRun = CRunAppend(currentRun, &attrs, thisCharUnichar, thisCharAdvance, curX);
            }
        } else {
            if (currentRun) {
                CRunTerminate(currentRun);
            }
            attrs.fakeBold = NO;
            attrs.fakeItalic = NO;
            attrs.fontInfo = nil;
        }

        curX += thisCharAdvance;
    }
    return firstRun;
}

- (void)selectFont:(NSFont *)font inContext:(CGContextRef)ctx
{
    if (font != selectedFont_) {
        // This method is really slow so avoid doing it when it's not necessary
        CGContextSelectFont(ctx,
                            [[font fontName] UTF8String],
                            [font pointSize],
                            kCGEncodingMacRoman);
        [selectedFont_ release];
        selectedFont_ = [font retain];
    }
}

// Note: caller must nil out selectedFont_ after the graphics context becomes invalid.
- (int)_drawSimpleRun:(CRun *)currentRun
                  ctx:(CGContextRef)ctx
         initialPoint:(NSPoint)initialPoint
{
    int firstMissingGlyph;
    CGGlyph *glyphs = CRunGetGlyphs(currentRun, &firstMissingGlyph);
    if (!glyphs) {
        return -1;
    }

    size_t numCodes = currentRun->length;
    size_t length = numCodes;
    if (firstMissingGlyph >= 0) {
        length = firstMissingGlyph;
    }
    [self selectFont:currentRun->attrs.fontInfo.font inContext:ctx];
    CGContextSetFillColorSpace(ctx, [[currentRun->attrs.color colorSpace] CGColorSpace]);
    int componentCount = [currentRun->attrs.color numberOfComponents];

    CGFloat components[componentCount];
    [currentRun->attrs.color getComponents:components];
    CGContextSetFillColor(ctx, components);

    double y = initialPoint.y + lineHeight + currentRun->attrs.fontInfo.baselineOffset;
    int x = initialPoint.x + currentRun->x;
    // Flip vertically and translate to (x, y).
    CGFloat m21 = 0.0;
    if (currentRun->attrs.fakeItalic) {
        m21 = 0.2;
    }
    CGContextSetTextMatrix(ctx, CGAffineTransformMake(1.0,  0.0,
                                                      m21, -1.0,
                                                      x, y));

    void *advances = CRunGetAdvances(currentRun);
    CGContextShowGlyphsWithAdvances(ctx, glyphs, advances, length);

    if (currentRun->attrs.fakeBold) {
        // If anti-aliased, drawing twice at the same position makes the strokes thicker.
        // If not anti-alised, draw one pixel to the right.
        CGContextSetTextMatrix(ctx, CGAffineTransformMake(1.0,  0.0,
                                                          m21, -1.0,
                                                          x + (currentRun->attrs.antiAlias ? _antiAliasedShift : 1),
                                                          y));

        CGContextShowGlyphsWithAdvances(ctx, glyphs, advances, length);
    }
    return firstMissingGlyph;
}

- (CGColorRef)cgColorForColor:(NSColor *)color {
    const NSInteger numberOfComponents = [color numberOfComponents];
    CGFloat components[numberOfComponents];
    CGColorSpaceRef colorSpace = [[color colorSpace] CGColorSpace];

    [color getComponents:(CGFloat *)&components];

    return (CGColorRef)[(id)CGColorCreate(colorSpace, components) autorelease];
}

- (NSBezierPath *)bezierPathForBoxDrawingCode:(int)code {
    //  0 1 2
    //  3 4 5
    //  6 7 8
    NSArray *points = nil;
    // The points array is a series of numbers from the above grid giving the
    // sequence of points to move the pen to.
    switch (code) {
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_LEFT:  // ┘
            points = @[ @(3), @(4), @(1) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_LEFT:  // ┐
            points = @[ @(3), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_RIGHT:  // ┌
            points = @[ @(7), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_RIGHT:  // └
            points = @[ @(1), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_HORIZONTAL:  // ┼
            points = @[ @(3), @(5), @(4), @(1), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_HORIZONTAL:  // ─
            points = @[ @(3), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_RIGHT:  // ├
            points = @[ @(1), @(4), @(5), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_LEFT:  // ┤
            points = @[ @(1), @(4), @(3), @(4), @(7) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_HORIZONTAL:  // ┴
            points = @[ @(3), @(4), @(1), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_HORIZONTAL:  // ┬
            points = @[ @(3), @(4), @(7), @(4), @(5) ];
            break;
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL:  // │
            points = @[ @(1), @(7) ];
            break;
        default:
            break;
    }
    CGFloat xs[] = { 0, charWidth / 2, charWidth };
    CGFloat ys[] = { 0, lineHeight / 2, lineHeight };
    NSBezierPath *path = [NSBezierPath bezierPath];
    BOOL first = YES;
    for (NSNumber *n in points) {
        CGFloat x = xs[n.intValue % 3];
        CGFloat y = ys[n.intValue / 3];
        NSPoint p = NSMakePoint(x, y);
        if (first) {
            [path moveToPoint:p];
            first = NO;
        } else {
            [path lineToPoint:p];
        }
    }
    return path;
}

- (void)_advancedDrawRun:(CRun *)complexRun at:(NSPoint)pos
{
    if (complexRun->attrs.imageCode > 0) {
        ImageInfo *imageInfo = GetImageInfo(complexRun->attrs.imageCode);
        NSImage *image = [imageInfo imageEmbeddedInRegionOfSize:NSMakeSize(charWidth * imageInfo.size.width,
                                                                           lineHeight * imageInfo.size.height)];
        NSSize chunkSize = NSMakeSize(image.size.width / imageInfo.size.width,
                                      image.size.height / imageInfo.size.height);
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform translateXBy:pos.x yBy:pos.y + lineHeight];
        [transform scaleXBy:1.0 yBy:-1.0];
        [transform concat];

        [defaultBGColor set];
        NSRectFill(NSMakeRect(0, 0, charWidth * complexRun->numImageCells, lineHeight));

        [image drawInRect:NSMakeRect(0, 0, charWidth * complexRun->numImageCells, lineHeight)
                 fromRect:NSMakeRect(chunkSize.width * complexRun->attrs.imageColumn,
                                     image.size.height - lineHeight - chunkSize.height * complexRun->attrs.imageLine,
                                     chunkSize.width * complexRun->numImageCells,
                                     chunkSize.height)
                operation:NSCompositeSourceOver
                 fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }
    NSGraphicsContext *ctx = [NSGraphicsContext currentContext];
    NSColor *color = complexRun->attrs.color;

    switch (complexRun->key) {
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_RIGHT:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL_AND_LEFT:
        case ITERM_BOX_DRAWINGS_LIGHT_UP_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_DOWN_AND_HORIZONTAL:
        case ITERM_BOX_DRAWINGS_LIGHT_VERTICAL: {
            NSBezierPath *path = [self bezierPathForBoxDrawingCode:complexRun->key];
            [ctx saveGraphicsState];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:pos.x yBy:pos.y];
            [transform concat];
            [color set];
            [path stroke];
            [ctx restoreGraphicsState];
            return;
        }

        default:
            break;
    }
    NSString *str = complexRun->string;
    PTYFontInfo *fontInfo = complexRun->attrs.fontInfo;
    BOOL fakeBold = complexRun->attrs.fakeBold;
    BOOL fakeItalic = complexRun->attrs.fakeItalic;
    BOOL antiAlias = complexRun->attrs.antiAlias;

    NSDictionary* attrs;
    attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                fontInfo.font, NSFontAttributeName,
                color, NSForegroundColorAttributeName,
                nil];
    [ctx saveGraphicsState];
    [ctx setCompositingOperation:NSCompositeSourceOver];
    if (StringContainsCombiningMark(str)) {
      // This renders characters with combining marks better but is slower.
      NSMutableAttributedString* attributedString =
          [[[NSMutableAttributedString alloc] initWithString:str
                                                  attributes:attrs] autorelease];
      // This code used to use -[NSAttributedString drawWithRect:options] but
      // it does a lousy job rendering multiple combining marks. This is close
      // to what WebKit does and appears to be the highest quality text
      // rendering available. However, this path is only available in 10.7+.

      CTLineRef lineRef = CTLineCreateWithAttributedString((CFAttributedStringRef)attributedString);
      CFArrayRef runs = CTLineGetGlyphRuns(lineRef);
      CGContextRef cgContext = (CGContextRef) [ctx graphicsPort];
      CGContextSetFillColorWithColor(cgContext, [self cgColorForColor:color]);
      CGContextSetStrokeColorWithColor(cgContext, [self cgColorForColor:color]);

      CGFloat m21 = 0.0;
      if (fakeItalic) {
          m21 = 0.2;
      }

      CGAffineTransform textMatrix = CGAffineTransformMake(1.0,  0.0,
                                                           m21, -1.0,
                                                           pos.x, pos.y + fontInfo.baselineOffset + lineHeight);
      CGContextSetTextMatrix(cgContext, textMatrix);

      for (CFIndex j = 0; j < CFArrayGetCount(runs); j++) {
          CTRunRef run = CFArrayGetValueAtIndex(runs, j);
          CFRange range;
          range.length = 0;
          range.location = 0;
          size_t length = CTRunGetGlyphCount(run);
          const CGGlyph *buffer = CTRunGetGlyphsPtr(run);
          const CGPoint *positions = CTRunGetPositionsPtr(run);
          CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
          CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, cgContext);
          if (fakeBold) {
              CGContextTranslateCTM(cgContext, antiAlias ? _antiAliasedShift : 1, 0);
              CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, cgContext);
              CGContextTranslateCTM(cgContext, antiAlias ? -_antiAliasedShift : -1, 0);
          }
      }
      CFRelease(lineRef);
    } else {
        CGFloat width = CRunGetAdvances(complexRun)[0].width;
        NSMutableAttributedString* attributedString =
            [[[NSMutableAttributedString alloc] initWithString:str
                                                    attributes:attrs] autorelease];
        // Note that drawInRect doesn't use the right baseline, but drawWithRect
        // does.
        //
        // This technique was picked because it can find glyphs that aren't in the
        // selected font (e.g., tests/radical.txt). It does a fairly nice job on
        // laying out combining marks. For now, it fails in two known cases:
        // 1. Enclosing marks (q in a circle shows as a q)
        // 2. U+239d, a part of a paren for graphics drawing, doesn't quite render
        //    right (though it appears to need to render in another char's cell).
        // Other rejected approaches included using CTFontGetGlyphsForCharacters+
        // CGContextShowGlyphsWithAdvances, which doesn't render thai characters
        // correctly in UTF-8-demo.txt.
        //
        // We use width*2 so that wide characters that are not double width chars
        // render properly. These are font-dependent. See tests/suits.txt for an
        // example.
        [attributedString drawWithRect:NSMakeRect(pos.x,
                                                  pos.y + fontInfo.baselineOffset + lineHeight,
                                                  width*2,
                                                  lineHeight)
                               options:0];  // NSStringDrawingUsesLineFragmentOrigin
        if (fakeBold) {
            // If anti-aliased, drawing twice at the same position makes the strokes thicker.
            // If not anti-alised, draw one pixel to the right.
            [attributedString drawWithRect:NSMakeRect(pos.x + (antiAlias ? 0 : 1),
                                                      pos.y + fontInfo.baselineOffset + lineHeight,
                                                      width*2,
                                                      lineHeight)
                                   options:0];  // NSStringDrawingUsesLineFragmentOrigin
        }
    }
    [ctx restoreGraphicsState];
}

- (void)drawRun:(CRun *)currentRun
            ctx:(CGContextRef)ctx
   initialPoint:(NSPoint)initialPoint
        storage:(CRunStorage *)storage {
    NSPoint startPoint = NSMakePoint(initialPoint.x + currentRun->x, initialPoint.y);
    CGContextSetShouldAntialias(ctx, currentRun->attrs.antiAlias);

    // If there is an underline, save some values before the run gets chopped up.
    CGFloat runWidth = 0;
    int length = currentRun->string ? 1 : currentRun->length;
    NSSize *advances = nil;
    if (currentRun->attrs.underline) {
        advances = CRunGetAdvances(currentRun);
        for (int i = 0; i < length; i++) {
            runWidth += advances[i].width;
        }
    }
    
    if (!currentRun->string) {
        // Non-complex, except for glyphs we can't find.
        while (currentRun->length) {
            int firstComplexGlyph = [self _drawSimpleRun:currentRun
                                                     ctx:ctx
                                            initialPoint:initialPoint];
            if (firstComplexGlyph < 0) {
                break;
            }
            CRun *complexRun = CRunSplit(currentRun, firstComplexGlyph);
            [self _advancedDrawRun:complexRun
                                at:NSMakePoint(initialPoint.x + complexRun->x, initialPoint.y)];
            CRunFree(complexRun);
        }
    } else {
        // Complex
        [self _advancedDrawRun:currentRun
                            at:NSMakePoint(initialPoint.x + currentRun->x, initialPoint.y)];
    }

    // Draw underline
    if (currentRun->attrs.underline) {
        [currentRun->attrs.color set];
        NSRectFill(NSMakeRect(startPoint.x,
                              startPoint.y + lineHeight - 2,
                              runWidth,
                              1));
    }
}

- (void)_drawRunsAt:(NSPoint)initialPoint
                run:(CRun *)run
            storage:(CRunStorage *)storage
            context:(CGContextRef)ctx
{
    CGContextSetTextDrawingMode(ctx, kCGTextFill);
    while (run) {
        [self drawRun:run ctx:ctx initialPoint:initialPoint storage:storage];
        run = run->next;
    }
}

- (void)_drawCharactersInLine:(screen_char_t *)theLine
                          row:(int)row
                      inRange:(NSRange)indexRange
              startingAtPoint:(NSPoint)initialPoint
                   bgselected:(BOOL)bgselected
                     reversed:(BOOL)reversed
                      bgColor:(NSColor*)bgColor
                      matches:(NSData*)matches
                      context:(CGContextRef)ctx
{
    const int width = [dataSource width];
    CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:width];
    CRun *run = [self _constructRuns:initialPoint
                             theLine:theLine
                                 row:row
                            reversed:reversed
                          bgselected:bgselected
                               width:width
                          indexRange:indexRange
                             bgColor:bgColor
                             matches:matches
                             storage:storage];

    if (run) {
        [self _drawRunsAt:initialPoint run:run storage:storage context:ctx];
        CRunFree(run);
    }
}

- (void)_drawStripesInRect:(NSRect)rect
{
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];

    const CGFloat kStripeWidth = 40;
    const double kSlope = 1;

    for (CGFloat x = kSlope * -fmod(rect.origin.y, kStripeWidth * 2) -2 * kStripeWidth ;
         x < rect.origin.x + rect.size.width;
         x += kStripeWidth * 2) {
        if (x + 2 * kStripeWidth + rect.size.height * kSlope < rect.origin.x) {
            continue;
        }
        NSBezierPath* thePath = [NSBezierPath bezierPath];

        [thePath moveToPoint:NSMakePoint(x, rect.origin.y + rect.size.height)];
        [thePath lineToPoint:NSMakePoint(x + kSlope * rect.size.height, rect.origin.y)];
        [thePath lineToPoint:NSMakePoint(x + kSlope * rect.size.height + kStripeWidth, rect.origin.y)];
        [thePath lineToPoint:NSMakePoint(x + kStripeWidth, rect.origin.y + rect.size.height)];
        [thePath closePath];

        [[[NSColor redColor] colorWithAlphaComponent:0.15] set];
        [thePath fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}

// Draw a run of background color/image and foreground text.
- (void)drawRunStartingAtIndex:(const int)firstIndex  // Index into line of first char
                           row:(int)row               // Row number of line
                         endAt:(const int)lastIndex   // Index into line of last char
                       yOrigin:(const double)yOrigin  // Top left corner of rect to draw into
                       toPoint:(NSPoint * const)toPoint  // If not nil, an offset for drawing
                    hasBGImage:(const BOOL)hasBGImage  // If set, draw a bg image (else solid colors only)
             defaultBgColorPtr:(NSColor **)defaultBgColorPtr  // Pass in default bg color; may be changed.
      alphaIfTransparencyInUse:(const double)alphaIfTransparencyInUse  // Alpha value to use if transparency is on
                       bgColor:(const int)bgColor      // bg color code (or red component if 24 bit)
                   bgColorMode:(const ColorMode)bgColorMode  // bg color mode
                        bgBlue:(const int)bgBlue       // blue component if 24 bit
                       bgGreen:(const int)bgGreen      // green component if 24 bit
                      reversed:(const BOOL)reversed    // reverse video?
                    bgselected:(const BOOL)bgselected  // is selected text?
                       isMatch:(const BOOL)isMatch     // is Find On Page match?
                       stripes:(const BOOL)stripes     // bg is striped?
                          line:(screen_char_t *)theLine  // Whole screen line
                       matches:(NSData *)matches // Bitmask of Find On Page matches
                       context:(CGContextRef)ctx       // Graphics context
{
    NSColor *aColor = *defaultBgColorPtr;

    NSRect bgRect = NSMakeRect(floor(MARGIN + firstIndex * charWidth),
                               yOrigin,
                               ceil((lastIndex - firstIndex) * charWidth),
                               lineHeight);

    if (hasBGImage) {
        if (toPoint) {
            [(PTYScrollView *)[self enclosingScrollView] drawBackgroundImageRect:bgRect
                                                                         toPoint:NSMakePoint(toPoint->x + bgRect.origin.x,
                                                                                             toPoint->y + bgRect.size.height)
                                                                 useTransparency:[self useTransparency]];
        } else {
            [(PTYScrollView *)[self enclosingScrollView] drawBackgroundImageRect:bgRect
                                                                 useTransparency:[self useTransparency]];
        }
    }
    if (!hasBGImage ||
        (isMatch && !bgselected) ||
        !(bgColor == ALTSEM_BG_DEFAULT && bgColorMode == ColorModeAlternate) ||
        bgselected) {
        // There's no bg image, or there's a nondefault bg on a bg image.
        // We are not drawing an unmolested background image. Some
        // background fill must be drawn. If there is a background image
        // it will be blended with the bg color.

        if (isMatch && !bgselected) {
            aColor = [NSColor colorWithCalibratedRed:1 green:1 blue:0 alpha:1];
        } else if (bgselected) {
            aColor = [self selectionColorForCurrentFocus];
        } else {
            if (reversed && bgColor == ALTSEM_BG_DEFAULT && bgColorMode == ColorModeAlternate) {
                // Reverse video is only applied to default background-
                // color chars.
                aColor = [self colorForCode:ALTSEM_FG_DEFAULT
                                      green:0
                                       blue:0
                                  colorMode:ColorModeAlternate
                                       bold:NO
                               isBackground:NO];
            } else {
                // Use the regular background color.
                aColor = [self colorForCode:bgColor
                                      green:bgGreen
                                       blue:bgBlue
                                  colorMode:bgColorMode
                                       bold:NO
                               isBackground:(bgColor == ALTSEM_BG_DEFAULT)];
            }
        }
        aColor = [aColor colorWithAlphaComponent:alphaIfTransparencyInUse];
        [aColor set];
        if (toPoint) {
            bgRect.origin.x += toPoint->x;
            bgRect.origin.y = toPoint->y;
        }
        NSRectFillUsingOperation(bgRect,
                                 hasBGImage ? NSCompositeSourceOver : NSCompositeCopy);
    } else if (hasBGImage) {
        // There is a bg image and no special background on it. Blend
        // in the default background color.
        aColor = [self colorForCode:ALTSEM_BG_DEFAULT
                              green:0
                               blue:0
                          colorMode:ColorModeAlternate
                               bold:NO
                       isBackground:YES];
        aColor = [aColor colorWithAlphaComponent:1 - blend];
        [aColor set];
        NSRectFillUsingOperation(bgRect, NSCompositeSourceOver);
    }
    *defaultBgColorPtr = aColor;

    // Draw red stripes in the background if sending input to all sessions
    if (stripes) {
        [self _drawStripesInRect:bgRect];
    }

    NSPoint textOrigin;
    if (toPoint) {
        textOrigin = NSMakePoint(toPoint->x + MARGIN + firstIndex * charWidth,
                                 toPoint->y);
    } else {
        textOrigin = NSMakePoint(MARGIN + firstIndex * charWidth,
                                 yOrigin);
    }
    
    // Highlight cursor line
    int cursorLine = [dataSource cursorY] - 1 + [dataSource numberOfScrollbackLines];
    if (_highlightCursorLine && row == cursorLine) {
        [[NSColor colorWithCalibratedRed:.65 green:.91 blue:1 alpha:.25] set];
        NSRect rect = NSMakeRect(textOrigin.x,
                                 textOrigin.y,
                                 (lastIndex - firstIndex) * charWidth,
                                 lineHeight);
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
        [[NSColor colorWithCalibratedRed:.65 green:.91 blue:1 alpha:.25] set];

        rect.size.height = 1;
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);

        rect.origin.y += lineHeight - 1;
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    }

    [self _drawCharactersInLine:theLine
                            row:row
                        inRange:NSMakeRange(firstIndex, lastIndex - firstIndex)
                startingAtPoint:textOrigin
                     bgselected:bgselected
                       reversed:reversed
                        bgColor:aColor
                        matches:matches
                        context:ctx];
}

- (BOOL)_drawLine:(int)line
              AtY:(double)curY
          toPoint:(NSPoint*)toPoint
        charRange:(NSRange)charRange
          context:(CGContextRef)ctx
{
    BOOL anyBlinking = NO;
#ifdef DEBUG_DRAWING
    int screenstartline = [self frame].origin.y / lineHeight;
    DebugLog([NSString stringWithFormat:@"Draw line %d (%d on screen)", line, (line - screenstartline)]);
#endif
    const BOOL stripes = useBackgroundIndicator_ && [_delegate textViewSessionIsBroadcastingInput];
    int WIDTH = [dataSource width];
    screen_char_t* theLine = [dataSource getLineAtIndex:line];
    PTYScrollView* scrollView = (PTYScrollView*)[self enclosingScrollView];
    BOOL hasBGImage = [scrollView hasBackgroundImage];
    double selectedAlpha = 1.0 - transparency;
    double alphaIfTransparencyInUse = [self useTransparency] ? 1.0 - transparency : 1.0;
    BOOL reversed = [[dataSource terminal] screenMode];
    NSColor *aColor = nil;

    // Redraw margins ------------------------------------------------------------------------------
    NSRect leftMargin = NSMakeRect(0, curY, MARGIN, lineHeight);
    NSRect rightMargin;
    NSRect visibleRect = [self visibleRect];
    rightMargin.origin.x = charWidth * WIDTH;
    rightMargin.origin.y = curY;
    rightMargin.size.width = visibleRect.size.width - rightMargin.origin.x;
    rightMargin.size.height = lineHeight;

    aColor = [self colorForCode:ALTSEM_BG_DEFAULT
                          green:0
                           blue:0
                      colorMode:ColorModeAlternate
                           bold:NO
                   isBackground:YES];

    aColor = [aColor colorWithAlphaComponent:selectedAlpha];
    [aColor set];
    if (hasBGImage) {
        if (toPoint) {
            [scrollView drawBackgroundImageRect:leftMargin
                                        toPoint:NSMakePoint(toPoint->x + leftMargin.origin.x,
                                                            toPoint->y + leftMargin.size.height)
                                useTransparency:[self useTransparency]];
            [scrollView drawBackgroundImageRect:rightMargin
                                        toPoint:NSMakePoint(toPoint->x + rightMargin.origin.x,
                                                            toPoint->y + rightMargin.size.height)
                                useTransparency:[self useTransparency]];
            // Blend default bg color over bg iamge.
            [[aColor colorWithAlphaComponent:1 - blend] set];
            NSRectFillUsingOperation(NSMakeRect(toPoint->x + leftMargin.origin.x,
                                                toPoint->y + leftMargin.origin.y,
                                                leftMargin.size.width,
                                                leftMargin.size.height), NSCompositeSourceOver);
            NSRectFillUsingOperation(NSMakeRect(toPoint->x + rightMargin.origin.x,
                                                toPoint->y + rightMargin.origin.y,
                                                rightMargin.size.width,
                                                rightMargin.size.height), NSCompositeSourceOver);
        } else {
            [scrollView drawBackgroundImageRect:leftMargin
                                useTransparency:[self useTransparency]];
            [scrollView drawBackgroundImageRect:rightMargin
                                useTransparency:[self useTransparency]];

            // Blend default bg color over bg iamge.
            [[aColor colorWithAlphaComponent:1 - blend] set];
            NSRectFillUsingOperation(leftMargin, NSCompositeSourceOver);
            NSRectFillUsingOperation(rightMargin, NSCompositeSourceOver);
        }
        [aColor set];
    } else {
        // No BG image
        if (toPoint) {
            NSRectFill(NSMakeRect(toPoint->x + leftMargin.origin.x,
                                  toPoint->y,
                                  leftMargin.size.width,
                                  leftMargin.size.height));
            NSRectFill(NSMakeRect(toPoint->x + rightMargin.origin.x,
                                  toPoint->y,
                                  rightMargin.size.width,
                                  rightMargin.size.height));
        } else {
            if (hasBGImage) {
                NSRectFillUsingOperation(leftMargin, NSCompositeSourceOver);
                NSRectFillUsingOperation(rightMargin, NSCompositeSourceOver);
            } else {
                aColor = [aColor colorWithAlphaComponent:alphaIfTransparencyInUse];
                [aColor set];
                NSRectFill(leftMargin);
                NSRectFill(rightMargin);
            }
        }
    }

    // Indicate marks in margin --
    VT100ScreenMark *mark = [dataSource markOnLine:line];
    if (mark) {
        NSImage *image = mark.code ? markErrImage_ : markImage_;
        CGFloat offset = (lineHeight - markImage_.size.height) / 2.0;
        [image drawAtPoint:NSMakePoint(leftMargin.origin.x,
                                       leftMargin.origin.y + offset)
                  fromRect:NSMakeRect(0, 0, markImage_.size.width, markImage_.size.height)
                 operation:NSCompositeSourceOver
                  fraction:1.0];
    }
    // Draw text and background --------------------------------------------------------------------
    // Contiguous sections of background with the same colour
    // are combined into runs and draw as one operation
    int bgstart = -1;
    int j = charRange.location;
    int bgColor = 0;
    int bgGreen = 0;
    int bgBlue = 0;
    ColorMode bgColorMode = ColorModeNormal;
    BOOL bgselected = NO;
    BOOL isMatch = NO;
    NSData* matches = [resultMap_ objectForKey:[NSNumber numberWithLongLong:line + [dataSource totalScrollbackOverflow]]];
    const char* matchBytes = [matches bytes];

    // Iterate over each character in the line.
    // Go one past where we really need to go to simplify the code.  // TODO(georgen): Fix that.
    int limit = charRange.location + charRange.length;
    NSIndexSet *selectedIndexes = [_selection selectedIndexesOnLine:line];
    while (j < limit) {
        if (theLine[j].code == DWC_RIGHT) {
            // Do not draw the right-hand side of double-width characters.
            j++;
            continue;
        }
        if (blinkAllowed_ && theLine[j].blink) {
            anyBlinking = YES;
        }

        BOOL selected;
        if (theLine[j].code == DWC_SKIP) {
            selected = NO;
        } else if (theLine[j].code == TAB_FILLER) {
            if ([self isTabFillerOrphanAtX:j Y:line]) {
                // Treat orphaned tab fillers like spaces.
                selected = [selectedIndexes containsIndex:j];
            } else {
                // Select all leading tab fillers iff the tab is selected.
                selected = [self isFutureTabSelectedAfterX:j Y:line];
            }
        } else {
            selected = [selectedIndexes containsIndex:j];
        }
        BOOL double_width = j < WIDTH - 1 && (theLine[j+1].code == DWC_RIGHT);
        BOOL match = NO;
        if (matchBytes) {
            // Test if this char is a highlighted match from a Find.
            const int theIndex = j / 8;
            const int bitMask = 1 << (j & 7);
            match = theIndex < [matches length] && (matchBytes[theIndex] & bitMask);
        }

        if (j != limit && bgstart < 0) {
            // Start new run
            bgstart = j;
            bgColor = theLine[j].backgroundColor;
            bgGreen = theLine[j].bgGreen;
            bgBlue = theLine[j].bgBlue;
            bgColorMode = theLine[j].backgroundColorMode;
            bgselected = selected;
            isMatch = match;
        }

        if (j != limit &&
            bgselected == selected &&
            theLine[j].backgroundColor == bgColor &&
            theLine[j].bgGreen == bgGreen &&
            theLine[j].bgBlue == bgBlue &&
            theLine[j].backgroundColorMode == bgColorMode &&
            match == isMatch) {
            // Continue the run
            j += (double_width ? 2 : 1);
        } else if (bgstart >= 0) {
            // This run is finished, draw it

            [self drawRunStartingAtIndex:bgstart
                                     row:line
                                   endAt:j
                                 yOrigin:curY
                                 toPoint:toPoint
                              hasBGImage:hasBGImage
                       defaultBgColorPtr:&aColor
                alphaIfTransparencyInUse:alphaIfTransparencyInUse
                                 bgColor:bgColor
                             bgColorMode:bgColorMode
                                  bgBlue:bgBlue
                                 bgGreen:bgGreen
                                reversed:reversed
                              bgselected:bgselected
                                 isMatch:isMatch
                                 stripes:stripes
                                    line:theLine
                                 matches:matches
                                 context:ctx];
            bgstart = -1;
            // Return to top of loop without incrementing j so this
            // character gets the chance to start its own run
        } else {
            // Don't need to draw and not on a run, move to next char
            j += (double_width ? 2 : 1);
        }
    }
    if (bgstart >= 0) {
        // Draw last run, if necesary.
        [self drawRunStartingAtIndex:bgstart
                                 row:line
                               endAt:j
                             yOrigin:curY
                             toPoint:toPoint
                          hasBGImage:hasBGImage
                   defaultBgColorPtr:&aColor
            alphaIfTransparencyInUse:alphaIfTransparencyInUse
                             bgColor:bgColor
                         bgColorMode:bgColorMode
                              bgBlue:bgBlue
                             bgGreen:bgGreen
                            reversed:reversed
                          bgselected:bgselected
                             isMatch:isMatch
                             stripes:stripes
                                line:theLine
                             matches:matches
                             context:ctx];
    }

    NSArray *noteRanges = [dataSource charactersWithNotesOnLine:line];
    if (noteRanges.count) {
        for (NSValue *value in noteRanges) {
            VT100GridRange range = [value gridRangeValue];
            CGFloat x = range.location * charWidth + MARGIN;
            CGFloat y = line * lineHeight;
            [[NSColor yellowColor] set];
            
            CGFloat maxX = MIN(self.bounds.size.width - MARGIN, range.length * charWidth + x);
            CGFloat w = maxX - x;
            NSRectFill(NSMakeRect(x, y + lineHeight - 1.5, w, 1));
            [[NSColor orangeColor] set];
            NSRectFill(NSMakeRect(x, y + lineHeight - 1, w, 1));
        }

    }

    return anyBlinking;
}


- (void)_drawCharacter:(screen_char_t)screenChar
               fgColor:(int)fgColor
               fgGreen:(int)fgGreen
                fgBlue:(int)fgBlue
           fgColorMode:(ColorMode)fgColorMode
                fgBold:(BOOL)fgBold
                   AtX:(double)X
                     Y:(double)Y
           doubleWidth:(BOOL)double_width
         overrideColor:(NSColor*)overrideColor
               context:(CGContextRef)ctx
{
    screen_char_t temp = screenChar;
    temp.foregroundColor = fgColor;
    temp.fgGreen = fgGreen;
    temp.fgBlue = fgBlue;
    temp.foregroundColorMode = fgColorMode;
    temp.bold = fgBold;

    CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:1];
    // Draw the characters.
    CRun *run = [self _constructRuns:NSMakePoint(X, Y)
                             theLine:&temp
                                 row:(int)Y
                            reversed:NO
                          bgselected:NO
                               width:[dataSource width]
                          indexRange:NSMakeRange(0, 1)
                             bgColor:nil
                             matches:nil
                             storage:storage];
    if (run) {
        CRun *head = run;
        // If an override color is given, change the runs' colors.
        if (overrideColor) {
            while (run) {
                CRunAttrsSetColor(&run->attrs, run->storage, overrideColor);
                run = run->next;
            }
        }
        [self _drawRunsAt:NSMakePoint(X, Y) run:head storage:storage context:ctx];
        CRunFree(head);
    }

    // draw underline
    if (screenChar.underline && screenChar.code) {
        if (overrideColor) {
            [overrideColor set];
        } else {
            [[self colorForCode:fgColor
                          green:fgGreen
                           blue:fgBlue
                      colorMode:ColorModeAlternate
                           bold:fgBold
                   isBackground:NO] set];
        }

        NSRectFill(NSMakeRect(X,
                              Y + lineHeight - 2,
                              double_width ? charWidth * 2 : charWidth,
                              1));
    }
}

// Compute the length, in charWidth cells, of the input method text.
- (int)inputMethodEditorLength
{
    if (![self hasMarkedText]) {
        return 0;
    }
    NSString* str = [markedText string];

    const int maxLen = [str length] * kMaxParts;
    screen_char_t buf[maxLen];
    screen_char_t fg, bg;
    memset(&bg, 0, sizeof(bg));
    memset(&fg, 0, sizeof(fg));
    int len;
    StringToScreenChars(str,
                        buf,
                        fg,
                        bg,
                        &len,
                        [_delegate textViewAmbiguousWidthCharsAreDoubleWidth],
                        NULL);

    // Count how many additional cells are needed due to double-width chars
    // that span line breaks being wrapped to the next line.
    int x = [dataSource cursorX] - 1;  // cursorX is 1-based
    int width = [dataSource width];
    int extra = 0;
    int curX = x;
    for (int i = 0; i < len; ++i) {
        if (curX == 0 && buf[i].code == DWC_RIGHT) {
            ++extra;
            ++curX;
        }
        ++curX;
        curX %= width;
    }
    return len + extra;
}

- (BOOL)drawInputMethodEditorTextAt:(int)xStart
                                  y:(int)yStart
                              width:(int)width
                             height:(int)height
                       cursorHeight:(double)cursorHeight
                                ctx:(CGContextRef)ctx
{
    // draw any text for NSTextInput
    if ([self hasMarkedText]) {
        NSString* str = [markedText string];
        const int maxLen = [str length] * kMaxParts;
        screen_char_t buf[maxLen];
        screen_char_t fg = {0}, bg = {0};
        fg.foregroundColor = ALTSEM_FG_DEFAULT;
        fg.foregroundColorMode = ColorModeAlternate;
        fg.bold = NO;
        fg.italic = NO;
        fg.blink = NO;
        fg.underline = NO;
        memset(&bg, 0, sizeof(bg));
        int len;
        int cursorIndex = (int)IM_INPUT_SELRANGE.location;
        StringToScreenChars(str,
                            buf,
                            fg,
                            bg,
                            &len,
                            [_delegate textViewAmbiguousWidthCharsAreDoubleWidth],
                            &cursorIndex);
        int cursorX = 0;
        int baseX = floor(xStart * charWidth + MARGIN);
        int i;
        int y = (yStart + [dataSource numberOfLines] - height) * lineHeight;
        int cursorY = y;
        int x = baseX;
        int preWrapY = 0;
        BOOL justWrapped = NO;
        BOOL foundCursor = NO;
        for (i = 0; i < len; ) {
            const int remainingCharsInBuffer = len - i;
            const int remainingCharsInLine = width - xStart;
            int charsInLine = MIN(remainingCharsInLine,
                                  remainingCharsInBuffer);
            int skipped = 0;
            if (charsInLine + i < len &&
                buf[charsInLine + i].code == DWC_RIGHT) {
                // If we actually drew 'charsInLine' chars then half of a
                // double-width char would be drawn. Skip it and draw it on the
                // next line.
                skipped = 1;
                --charsInLine;
            }
            // Draw the background.
            NSRect r = NSMakeRect(x,
                                  y,
                                  charsInLine * charWidth,
                                  lineHeight);
            if (!dimOnlyText_) {
                [[self _dimmedColorFrom:defaultBGColor] set];
            } else {
                [defaultBGColor set];
            }
            NSRectFill(r);

            // Draw the characters.
            CRunStorage *storage = [CRunStorage cRunStorageWithCapacity:charsInLine];
            CRun *run = [self _constructRuns:NSMakePoint(x, y)
                                     theLine:buf
                                         row:y
                                    reversed:NO
                                  bgselected:NO
                                       width:[dataSource width]
                                  indexRange:NSMakeRange(i, charsInLine)
                                     bgColor:nil
                                     matches:nil
                                     storage:storage];
            if (run) {
                [self _drawRunsAt:NSMakePoint(x, y) run:run storage:storage context:ctx];
                CRunFree(run);
            }

            // Draw an underline.
            [defaultFGColor set];
            NSRect s = NSMakeRect(x,
                                  y + lineHeight - 1,
                                  charsInLine * charWidth,
                                  1);
            NSRectFill(s);

            // Save the cursor's cell coords
            if (i <= cursorIndex && i + charsInLine > cursorIndex) {
                // The char the cursor is at was drawn in this line.
                const int cellsAfterStart = cursorIndex - i;
                cursorX = x + charWidth * cellsAfterStart;
                cursorY = y;
                foundCursor = YES;
            }

            // Advance the cell and screen coords.
            xStart += charsInLine + skipped;
            if (xStart == width) {
                justWrapped = YES;
                preWrapY = y;
                xStart = 0;
                yStart++;
            } else {
                justWrapped = NO;
            }
            x = floor(xStart * charWidth + MARGIN);
            y = (yStart + [dataSource numberOfLines] - height) * lineHeight;
            i += charsInLine;
        }

        if (!foundCursor && i == cursorIndex) {
            if (justWrapped) {
                cursorX = MARGIN + width * charWidth;
                cursorY = preWrapY;
            } else {
                cursorX = x;
                cursorY = y;
            }
        }
        const double kCursorWidth = 2.0;
        double rightMargin = MARGIN + [dataSource width] * charWidth;
        if (cursorX + kCursorWidth >= rightMargin) {
            // Make sure the cursor doesn't draw in the margin. Shove it left
            // a little bit so it fits.
            cursorX = rightMargin - kCursorWidth;
        }
        NSRect cursorFrame = NSMakeRect(cursorX,
                                        cursorY,
                                        2.0,
                                        cursorHeight);
        imeCursorLastPos_ = cursorFrame.origin;
        if ([self isFindingCursor]) {
            NSPoint cp = [self globalCursorLocation];
            if (!NSEqualPoints(findCursorView_.cursor, cp)) {
                findCursorView_.cursor = cp;
                [findCursorView_ setNeedsDisplay:YES];
            }
        }
        [[self _dimmedColorFrom:[NSColor colorWithCalibratedRed:1 green:1 blue:0 alpha:1]] set];
        NSRectFill(cursorFrame);

        return TRUE;
    }
    return FALSE;
}

- (double)cursorHeight
{
    return lineHeight;
}

- (void)_drawCursor
{
    [self _drawCursorTo:nil];
}

- (NSColor*)_charBackground:(screen_char_t)c
{
    if ([[dataSource terminal] screenMode]) {
        // reversed
        return [self colorForCode:c.foregroundColor
                            green:c.fgGreen
                             blue:c.fgBlue
                        colorMode:c.foregroundColorMode
                             bold:c.bold
                     isBackground:YES];
    } else {
        // normal
        return [self colorForCode:c.backgroundColor
                            green:c.bgGreen
                             blue:c.bgBlue
                        colorMode:c.backgroundColorMode
                             bold:false
                     isBackground:YES];
    }
}

- (double)_brightnessOfCharBackground:(screen_char_t)c
{
    return [self perceivedBrightness:[[self _charBackground:c] colorUsingColorSpaceName:NSCalibratedRGBColorSpace]];
}

// Return the value in 'values' closest to target.
- (CGFloat)_minimumDistanceOf:(CGFloat)target fromAnyValueIn:(NSArray*)values
{
    CGFloat md = 1;
    for (NSNumber* n in values) {
        CGFloat dist = fabs(target - [n doubleValue]);
        if (dist < md) {
            md = dist;
        }
    }
    return md;
}

// Return the value between 0 and 1 that is farthest from any value in 'constraints'.
- (CGFloat)_farthestValueFromAnyValueIn:(NSArray*)constraints
{
    if ([constraints count] == 0) {
        return 0;
    }

    NSArray* sortedConstraints = [constraints sortedArrayUsingSelector:@selector(compare:)];
    double minVal = [[sortedConstraints objectAtIndex:0] doubleValue];
    double maxVal = [[sortedConstraints lastObject] doubleValue];

    CGFloat bestDistance = 0;
    CGFloat bestValue = -1;
    CGFloat prev = [[sortedConstraints objectAtIndex:0] doubleValue];
    for (NSNumber* np in sortedConstraints) {
        CGFloat n = [np doubleValue];
        const CGFloat dist = fabs(n - prev) / 2;
        if (dist > bestDistance) {
            bestDistance = dist;
            bestValue = (n + prev) / 2;
        }
        prev = n;
    }
    if (minVal > bestDistance) {
        bestValue = 0;
        bestDistance = minVal;
    }
    if (1 - maxVal > bestDistance) {
        bestValue = 1;
        bestDistance = 1 - maxVal;
    }
    DLog(@"Best distance is %f", (float)bestDistance);

    return bestValue;
}

- (NSColor *)_randomColor
{
    double r = arc4random() % 256;
    double g = arc4random() % 256;
    double b = arc4random() % 256;
    return [NSColor colorWithDeviceRed:r/255.0
                                 green:g/255.0
                                  blue:b/255.0
                                 alpha:1];
}

- (void)_drawCursorTo:(NSPoint*)toOrigin
{
    DLog(@"_drawCursorTo:%@", toOrigin ? (id)[NSValue valueWithPoint:*toOrigin] : (id)@"nil");

    int WIDTH, HEIGHT;
    screen_char_t* theLine;
    int yStart, x1;
    double cursorWidth, cursorHeight;
    double curX, curY;
    BOOL double_width;
    double alpha = [self useTransparency] ? 1.0 - transparency : 1.0;
    const BOOL reversed = [[dataSource terminal] screenMode];

    WIDTH = [dataSource width];
    HEIGHT = [dataSource height];
    x1 = [dataSource cursorX] - 1;
    yStart = [dataSource cursorY] - 1;

    NSRect docVisibleRect = [[self enclosingScrollView] documentVisibleRect];
    int lastVisibleLine = docVisibleRect.origin.y / [self lineHeight] + HEIGHT;
    int cursorLine = [dataSource numberOfLines] - [dataSource height] + [dataSource cursorY] - [dataSource scrollbackOverflow];
    if (cursorLine > lastVisibleLine) {
        return;
    }
    if (cursorLine < 0) {
        return;
    }

    if (charWidth < charWidthWithoutSpacing) {
        cursorWidth = charWidth;
    } else {
        cursorWidth = charWidthWithoutSpacing;
    }
    cursorHeight = [self cursorHeight];

    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (x1 != oldCursorX || yStart != oldCursorY) {
        lastTimeCursorMoved_ = now;
    }
    if ([self blinkingCursor] &&
        [self isInKeyWindow] &&
        [_delegate textViewIsActiveSession] &&
        now - lastTimeCursorMoved_ > 0.5) {
        // Allow the cursor to blink if it is configured, the window is key, this session is active
        // in the tab, and the cursor has not moved for half a second.
        showCursor = blinkShow;
    } else {
        showCursor = YES;
    }

    // Draw the regular cursor only if there's not an IME open as it draws its
    // own cursor.
    DLog(@"_drawCursorTo: hasMarkedText=%d, CURSOR=%d, showCursor=%d, x1=%d, yStart=%d, WIDTH=%d, HEIGHT=%d",
         (int)[self hasMarkedText], (int)CURSOR, (int)showCursor, (int)x1, (int)yStart, (int)WIDTH, (int)HEIGHT);
    if (![self hasMarkedText] && CURSOR) {
        if (showCursor && x1 <= WIDTH && x1 >= 0 && yStart >= 0 && yStart < HEIGHT) {
            // get the cursor line
            screen_char_t* lineAbove = nil;
            screen_char_t* lineBelow = nil;
            theLine = [dataSource getLineAtScreenIndex:yStart];
            if (yStart > 0) {
                lineAbove = [dataSource getLineAtScreenIndex:yStart - 1];
            }
            if (yStart < HEIGHT) {
                lineBelow = [dataSource getLineAtScreenIndex:yStart + 1];
            }
            double_width = 0;
            screen_char_t screenChar = theLine[x1];
            if (x1 == WIDTH) {
                screenChar = theLine[x1 - 1];
                screenChar.code = 0;
                screenChar.complexChar = NO;
            }
            int aChar = screenChar.code;
            if (aChar) {
                if (aChar == DWC_RIGHT && x1 > 0) {
                    x1--;
                    screenChar = theLine[x1];
                    aChar = screenChar.code;
                }
                double_width = (x1 < WIDTH-1) && (theLine[x1+1].code == DWC_RIGHT);
            }
            curX = floor(x1 * charWidth + MARGIN);
            curY = toOrigin ? toOrigin->y + (yStart + 1) * lineHeight - cursorHeight :
                (yStart + [dataSource numberOfLines] - HEIGHT + 1) * lineHeight - cursorHeight;
            if (!toOrigin && [self isFindingCursor]) {
                NSPoint cp = [self globalCursorLocation];
                if (!NSEqualPoints(findCursorView_.cursor, cp)) {
                    findCursorView_.cursor = cp;
                    [findCursorView_ setNeedsDisplay:YES];
                }
            }
            NSColor *bgColor;
            if (colorInvertedCursor) {
                if (reversed) {
                    bgColor = [self colorForCode:screenChar.backgroundColor
                                           green:screenChar.bgGreen
                                            blue:screenChar.bgBlue
                                       colorMode:screenChar.backgroundColorMode
                                            bold:screenChar.bold
                                    isBackground:NO];
                    bgColor = [bgColor colorWithAlphaComponent:alpha];
                } else {
                    bgColor = [self colorForCode:screenChar.foregroundColor
                                           green:screenChar.fgGreen
                                            blue:screenChar.fgBlue
                                       colorMode:screenChar.foregroundColorMode
                                            bold:screenChar.bold
                                    isBackground:NO];
                    bgColor = [bgColor colorWithAlphaComponent:alpha];
                }

                NSMutableArray* constraints = [NSMutableArray arrayWithCapacity:2];
                CGFloat bgBrightness = [self perceivedBrightness:[bgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace]];
                if (x1 > 0) {
                    [constraints addObject:[NSNumber numberWithDouble:[self _brightnessOfCharBackground:theLine[x1 - 1]]]];
                }
                if (x1 < WIDTH) {
                    [constraints addObject:[NSNumber numberWithDouble:[self _brightnessOfCharBackground:theLine[x1 + 1]]]];
                }
                if (lineAbove) {
                    [constraints addObject:[NSNumber numberWithDouble:[self _brightnessOfCharBackground:lineAbove[x1]]]];
                }
                if (lineBelow) {
                    [constraints addObject:[NSNumber numberWithDouble:[self _brightnessOfCharBackground:lineBelow[x1]]]];
                }
                if ([self _minimumDistanceOf:bgBrightness fromAnyValueIn:constraints] < gSmartCursorBgThreshold) {
                    CGFloat b = [self _farthestValueFromAnyValueIn:constraints];
                    bgColor = [NSColor colorWithCalibratedRed:b green:b blue:b alpha:1];
                }

                [bgColor set];
                DLog(@"Set cursor color=%@", bgColor);
            } else {
                bgColor = [self defaultCursorColor];
                [[bgColor colorWithAlphaComponent:alpha] set];
                DLog(@"Set cursor color=%@", [bgColor colorWithAlphaComponent:alpha]);
            }
            if ([self isFindingCursor]) {
                [[self _randomColor] set];
                DLog(@"Set random cursor color");
            }

            BOOL frameOnly;
            switch (cursorType_) {
                case CURSOR_BOX:
                    // draw the box
                    DLog(@"draw cursor box at %f,%f size %fx%f", (float)curX, (float)curY, (float)ceil(cursorWidth * (double_width ? 2 : 1)), cursorHeight);
                    if (([self isInKeyWindow] && [_delegate textViewIsActiveSession]) ||
                        [_delegate textViewShouldDrawFilledInCursor]) {
                        frameOnly = NO;
                        NSRectFill(NSMakeRect(curX,
                                              curY,
                                              ceil(cursorWidth * (double_width ? 2 : 1)),
                                              cursorHeight));
                    } else {
                        frameOnly = YES;
                        NSFrameRect(NSMakeRect(curX,
                                               curY,
                                               ceil(cursorWidth * (double_width ? 2 : 1)),
                                               cursorHeight));
                    }
                    // draw any character on cursor if we need to
                    if (aChar) {
                        // Have a char at the cursor position.
                        if (colorInvertedCursor && !frameOnly) {
                            // Pick background color for text if is key window, otherwise use fg color for text.
                            int fgColor;
                            int fgGreen;
                            int fgBlue;
                            ColorMode fgColorMode;
                            BOOL fgBold;
                            BOOL isBold;
                            NSColor* overrideColor = nil;
                            if ([self isInKeyWindow]) {
                                // Draw a character in background color when
                                // window is key.
                                fgColor = screenChar.backgroundColor;
                                fgGreen = screenChar.bgGreen;
                                fgBlue = screenChar.bgBlue;
                                fgColorMode = screenChar.backgroundColorMode;
                                fgBold = NO;
                            } else {
                                // Draw character in foreground color when there
                                // is just a frame around it.
                                fgColor = screenChar.foregroundColor;
                                fgGreen = screenChar.fgGreen;
                                fgBlue = screenChar.fgBlue;
                                fgColorMode = screenChar.foregroundColorMode;
                                fgBold = screenChar.bold;
                            }
                            isBold = screenChar.bold;

                            // Ensure text has enough contrast by making it black/white if the char's color would be close to the cursor bg.
                            NSColor* proposedForeground = [[self colorForCode:fgColor
                                                                        green:fgGreen
                                                                         blue:fgBlue
                                                                    colorMode:fgColorMode
                                                                         bold:fgBold
                                                                 isBackground:NO] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
                            CGFloat fgBrightness = [self perceivedBrightness:proposedForeground];
                            CGFloat bgBrightness = [self perceivedBrightness:[bgColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace]];
                            if (!frameOnly && fabs(fgBrightness - bgBrightness) < gSmartCursorFgThreshold) {
                                // foreground and background are very similar. Just use black and
                                // white.
                                if (bgBrightness < 0.5) {
                                    overrideColor = [self _dimmedColorFrom:[NSColor colorWithCalibratedRed:1 green:1 blue:1 alpha:1]];
                                } else {
                                    overrideColor = [self _dimmedColorFrom:[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:1]];
                                }
                            }

                            BOOL saved = useBrightBold;
                            useBrightBold = NO;
                            [self _drawCharacter:screenChar
                                         fgColor:fgColor
                                         fgGreen:fgGreen
                                          fgBlue:fgBlue
                                     fgColorMode:fgColorMode
                                          fgBold:isBold
                                             AtX:x1 * charWidth + MARGIN
                                               Y:curY + cursorHeight - lineHeight
                                     doubleWidth:double_width
                                   overrideColor:overrideColor
                                         context:ctx];
                            useBrightBold = saved;
                        } else {
                            // Non-inverted cursor or cursor is frame
                            int theColor;
                            int theGreen;
                            int theBlue;
                            ColorMode theMode;
                            BOOL isBold;
                            if ([self isInKeyWindow]) {
                                theColor = ALTSEM_CURSOR;
                                theGreen = 0;
                                theBlue = 0;
                                theMode = ColorModeAlternate;
                            } else {
                                theColor = screenChar.foregroundColor;
                                theGreen = screenChar.fgGreen;
                                theBlue = screenChar.fgBlue;
                                theMode = screenChar.foregroundColorMode;
                            }
                            isBold = screenChar.bold;

                            [self _drawCharacter:screenChar
                                         fgColor:theColor
                                         fgGreen:theGreen
                                          fgBlue:theBlue
                                     fgColorMode:theMode
                                          fgBold:isBold
                                             AtX:x1 * charWidth + MARGIN
                                               Y:curY + cursorHeight - lineHeight
                                     doubleWidth:double_width
                                   overrideColor:nil
                                         context:ctx];
                        }
                    }

                    break;

                case CURSOR_VERTICAL:
                    DLog(@"draw cursor vline at %f,%f size %fx%f", (float)curX, (float)curY, (float)1, cursorHeight);
                    NSRectFill(NSMakeRect(curX, curY, 1, cursorHeight));
                    break;

                case CURSOR_UNDERLINE:
                    DLog(@"draw cursor underline at %f,%f size %fx%f", (float)curX, (float)curY, (float)ceil(cursorWidth * (double_width ? 2 : 1)), 2.0);
                    NSRectFill(NSMakeRect(curX,
                                          curY + lineHeight - 2,
                                          ceil(cursorWidth * (double_width ? 2 : 1)),
                                          2));
                    break;
            }
        }
    }

    oldCursorX = x1;
    oldCursorY = yStart;
    [selectedFont_ release];
    selectedFont_ = nil;
}

- (void)_useBackgroundIndicatorChanged:(NSNotification *)notification
{
    useBackgroundIndicator_ = [(iTermApplicationDelegate *)[[NSApplication sharedApplication] delegate] useBackgroundPatternIndicator];
    [self setNeedsDisplay:YES];
}

- (void)_scrollToLine:(int)line
{
    NSRect aFrame;
    aFrame.origin.x = 0;
    aFrame.origin.y = line * lineHeight;
    aFrame.size.width = [self frame].size.width;
    aFrame.size.height = lineHeight;
    [self scrollRectToVisible:aFrame];
}

- (void)_scrollToCenterLine:(int)line
{
    NSRect visible = [self visibleRect];
    int visibleLines = (visible.size.height - VMARGIN*2) / lineHeight;
    int lineMargin = (visibleLines - 1) / 2;
    double margin = lineMargin * lineHeight;

    NSRect aFrame;
    aFrame.origin.x = 0;
    aFrame.origin.y = MAX(0, line * lineHeight - margin);
    aFrame.size.width = [self frame].size.width;
    aFrame.size.height = margin * 2 + lineHeight;
    double end = aFrame.origin.y + aFrame.size.height;
    NSRect total = [self frame];
    if (end > total.size.height) {
        double err = end - total.size.height;
        aFrame.size.height -= err;
    }
    [self scrollRectToVisible:aFrame];
}

- (void)scrollBottomOfRectToBottomOfVisibleArea:(NSRect)rect {
    NSPoint p = rect.origin;
    p.y += rect.size.height;
    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    visibleRect.size.height -= [self excess];
    visibleRect.size.height -= VMARGIN;
    p.y -= visibleRect.size.height;
    p.y = MAX(0, p.y);
    [[[self enclosingScrollView] contentView] scrollToPoint:p];
}

- (void)scrollLineNumberRangeIntoView:(VT100GridRange)range {
    NSRect visibleRect = [[self enclosingScrollView] documentVisibleRect];
    int firstVisibleLine = visibleRect.origin.y / lineHeight;
    int lastVisibleLine = firstVisibleLine + [dataSource height];
    if (range.location >= firstVisibleLine && range.location + range.length <= lastVisibleLine) {
      // Already visible
      return;
    }
    if (range.length < [dataSource height]) {
        [self _scrollToCenterLine:range.location + range.length / 2];
    } else {
        NSRect aFrame;
        aFrame.origin.x = 0;
        aFrame.origin.y = range.location * lineHeight;
        aFrame.size.width = [self frame].size.width;
        aFrame.size.height = range.length * lineHeight;

        [self scrollBottomOfRectToBottomOfVisibleArea:aFrame];
    }
    [(PTYScroller*)([[self enclosingScrollView] verticalScroller]) setUserScroll:YES];
}

- (BOOL)_haveHardNewlineAtY:(int)y
{
    screen_char_t *theLine;
    theLine = [dataSource getLineAtIndex:y];
    const int w = [dataSource width];
    return !theLine[w].complexChar && theLine[w].code == EOL_HARD;
}

- (NSString*)_getCharacterAtX:(int)x Y:(int)y
{
    screen_char_t *theLine;
    theLine = [dataSource getLineAtIndex:y];

    if (theLine[x].complexChar) {
        return ComplexCharToStr(theLine[x].code);
    } else {
        return [NSString stringWithCharacters:&theLine[x].code length:1];
    }
}

- (NSCharacterSet *)wordSeparatorCharacterSet
{
    NSMutableCharacterSet *charset = [[[NSMutableCharacterSet alloc] init] autorelease];
    [charset formUnionWithCharacterSet:[NSCharacterSet whitespaceCharacterSet]];

    NSMutableCharacterSet *complement = [[[NSMutableCharacterSet alloc] init] autorelease];
    [complement formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
    [complement addCharactersInString:[[PreferencePanel sharedInstance] wordChars]];
    [complement addCharactersInRange:NSMakeRange(DWC_RIGHT, 1)];
    [complement addCharactersInRange:NSMakeRange(DWC_SKIP, 1)];
    [charset formUnionWithCharacterSet:[complement invertedSet]];
    
    return charset;
}
- (PTYCharType)classifyChar:(unichar)ch
                  isComplex:(BOOL)complex
{
    NSString* aString = CharToStr(ch, complex);
    UTF32Char longChar = CharToLongChar(ch, complex);

    if (longChar == DWC_RIGHT || longChar == DWC_SKIP) {
        return CHARTYPE_DW_FILLER;
    } else if (!longChar ||
               [[NSCharacterSet whitespaceCharacterSet] longCharacterIsMember:longChar] ||
               ch == TAB_FILLER) {
        return CHARTYPE_WHITESPACE;
    } else if ([[NSCharacterSet alphanumericCharacterSet] longCharacterIsMember:longChar] ||
               [[[PreferencePanel sharedInstance] wordChars] rangeOfString:aString].length != 0) {
        return CHARTYPE_WORDCHAR;
    } else {
        // Non-alphanumeric, non-whitespace, non-word, not double-width filler.
        // Miscellaneous symbols, etc.
        return CHARTYPE_OTHER;
    }
}

- (BOOL)shouldSelectCharForWord:(unichar)ch
                      isComplex:(BOOL)complex
                selectWordChars:(BOOL)selectWordChars
{
    switch ([self classifyChar:ch isComplex:complex]) {
        case CHARTYPE_WHITESPACE:
            return !selectWordChars;
            break;

        case CHARTYPE_WORDCHAR:
        case CHARTYPE_DW_FILLER:
            return selectWordChars;
            break;

        case CHARTYPE_OTHER:
            return NO;
            break;
    };
    return NO;
}

+ (NSCharacterSet *)urlCharacterSet
{
    static NSMutableCharacterSet* urlChars;
    if (!urlChars) {
        NSString *chars = [[NSUserDefaults standardUserDefaults] stringForKey:@"URLCharacterSet"];
        if (!chars) {
            // Note: square brackets are included for ipv6 addresses like http://[2600:3c03::f03c:91ff:fe96:6a7a]/
            chars = @".?\\/:;%=&_-,+~#@!*'()|[]";

        }
        urlChars = [[NSMutableCharacterSet characterSetWithCharactersInString:chars] retain];
        [urlChars formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
        [urlChars retain];
    }

    return urlChars;
}

+ (NSCharacterSet *)filenameCharacterSet
{
    static NSMutableCharacterSet* filenameChars;
    if (!filenameChars) {
        filenameChars = [[NSCharacterSet whitespaceCharacterSet] mutableCopy];
        [filenameChars formUnionWithCharacterSet:[PTYTextView urlCharacterSet]];
    }

    return filenameChars;
}

- (BOOL)_stringLooksLikeURL:(NSString*)s
{
    // This is much harder than it sounds.
    // [NSURL URLWithString] is supposed to do this, but it doesn't accept IDN-encoded domains like
    // http://例子.测试
    // Just about any word can be a URL in the local search path. The code that calls this prefers false
    // positives, so just make sure it's not empty and doesn't have illegal characters.
    if ([s rangeOfCharacterFromSet:[[PTYTextView urlCharacterSet] invertedSet]].location != NSNotFound) {
        return NO;
    }
    if ([s length] == 0) {
        return NO;
    }
    
    NSRange slashRange = [s rangeOfString:@"/"];
    return (slashRange.length > 0 && slashRange.location > 0);  // Must contain a slash, but must not start with it.
}

// Any sequence of words separated by spaces or tabs could be a filename. Search the neighborhood
// of words for a valid filename. For example, beforeString could be "blah blah ~/Library/Appli" and
// afterString could be "cation Support/Screen Sharing foo bar baz". This searches outward from
// the point between beforeString and afterString to find a valid path, and would return
// "~/Library/Application Support/Screen sharing" if such a file exists.
- (NSMutableString *)_bruteforcePathFromBeforeString:(NSMutableString *)beforeString
                                         afterString:(NSMutableString *)afterString
                                    workingDirectory:(NSString *)workingDirectory
                                charsTakenFromPrefix:(int *)charsTakenFromPrefixPtr
{
    // Remove escaping slashes
    NSString *removeEscapingSlashes = @"\\\\([ \\(\\[\\]\\\\)])";

    DLog(@"Brute force path from prefix <<%@>>, suffix <<%@>> directory=%@",
         beforeString, afterString, workingDirectory);

    [beforeString replaceOccurrencesOfRegex:removeEscapingSlashes withString:@"$1"];
    [afterString replaceOccurrencesOfRegex:removeEscapingSlashes withString:@"$1"];
    beforeString = [[beforeString copy] autorelease];
    // The parens here cause "Foo bar" to become {"Foo", " ", "bar"} rather than {"Foo", "bar"}.
    // Also, there is some kind of weird bug in regexkit. If you do [[beforeChunks mutableCopy] autoRelease]
    // then the items in the array get over-released.
    NSArray *beforeChunks = [beforeString componentsSeparatedByRegex:@"([\t ])"];
    NSArray *afterChunks = [afterString componentsSeparatedByRegex:@"([\t ])"];
    NSMutableString *left = [NSMutableString string];
    // Bail after 100 iterations if nothing is still found.
    int limit = 100;

    NSMutableSet *paths = [NSMutableSet set];
    NSMutableSet *befores = [NSMutableSet set];

    DLog(@"before chunks=%@", beforeChunks);
    DLog(@"after chunks=%@", afterChunks);

    for (int i = [beforeChunks count]; i >= 0; i--) {
        NSString *beforeChunk = @"";
        if (i < [beforeChunks count]) {
            beforeChunk = [beforeChunks objectAtIndex:i];
        }

        if ([befores containsObject:beforeChunk]) {
            continue;
        }
        [befores addObject:beforeChunk];

        [left insertString:beforeChunk atIndex:0];
        NSMutableString *possiblePath = [NSMutableString stringWithString:left];

        // Do not search more than 10 chunks forward to avoid starving leftward search.
        for (int j = 0; j < [afterChunks count] && j < 10; j++) {
            [possiblePath appendString:[afterChunks objectAtIndex:j]];
            if ([paths containsObject:[NSString stringWithString:possiblePath]]) {
                continue;
            }
            [paths addObject:[[possiblePath copy] autorelease]];

            if ([trouter getFullPath:possiblePath workingDirectory:workingDirectory lineNumber:NULL]) {
                if (charsTakenFromPrefixPtr) {
                    *charsTakenFromPrefixPtr = left.length;
                }
                DLog(@"Using path %@", possiblePath);
                return possiblePath;
            }

            if (--limit == 0) {
                return nil;
            }
        }
    }
    return nil;
}

// Find the bounding rectangle of what could possibly be a single semantic
// string with a character at xi,yi. Lines of | characters are treated as a
// vertical bound.
- (NSRect)boundingRectForCharAtX:(int)xi y:(int)yi
{
    int w = [dataSource width];
    int h = [dataSource numberOfLines];
    int minX = 0;
    int maxX = w - 1;

    // Find lines of at least two | characters on either side of xi,yi to define the min and max
    // horizontal bounds.
    for (int i = xi; i >= 0; i--) {
        if ([[self _getCharacterAtX:i Y:yi] isEqualToString:@"|"] &&
            ((yi > 0 && [[self _getCharacterAtX:i Y:yi - 1] isEqualToString:@"|"]) ||
             (yi < h - 1 && [[self _getCharacterAtX:i Y:yi + 1] isEqualToString:@"|"]))) {
            minX = i + 1;
            break;
        }
    }
    for (int i = xi; i < w; i++) {
        if ([[self _getCharacterAtX:i Y:yi] isEqualToString:@"|"] &&
            ((yi > 0 && [[self _getCharacterAtX:i Y:yi - 1] isEqualToString:@"|"]) ||
             (yi < h - 1 && [[self _getCharacterAtX:i Y:yi + 1] isEqualToString:@"|"]))) {
            maxX = i - 1;
            break;
        }
    }

    // We limit the esarch to 10 lines in each direction.
    // See how high the lines of pipes go
    int minY = MAX(0, yi - 10);
    int maxY = MIN(h - 1, yi + 10);
    for (int i = yi; i >= yi - 10 && i >= 0; i--) {
        if (minX != 0) {
            if (![[self _getCharacterAtX:minX - 1 Y:i] isEqualToString:@"|"]) {
                minY = i + 1;
                break;
            }
        }
        if (maxX != w - 1) {
            if (![[self _getCharacterAtX:maxX + 1 Y:i] isEqualToString:@"|"]) {
                minY = i + 1;
                break;
            }
        }
    }

    // See how low the lines of pipes go
    for (int i = yi; i < h && i < yi + 10; i++) {
        if (minX != 0) {
            if (![[self _getCharacterAtX:minX - 1 Y:i] isEqualToString:@"|"]) {
                maxY = i - 1;
                break;
            }
        }
        if (maxX != w - 1) {
            if (![[self _getCharacterAtX:maxX + 1 Y:i] isEqualToString:@"|"]) {
                maxY = i - 1;
                break;
            }
        }
    }

    return NSMakeRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

// Find the prefix (if dir < 0) or suffix (dir > 0) of a string having a
// character at xi,yi.
// If respectHardNewlines is true, then a hard newline always terminates the
// string.
- (NSString *)wrappedStringAtX:(int)xi
                             y:(int)yi
                           dir:(int)dir
           respectHardNewlines:(BOOL)respectHardNewlines
{
    int w = [dataSource width];
    int h = [dataSource height];
    if (yi < 0 || yi >= [dataSource numberOfLines]) {
        return @"";
    }
    int x = xi;
    int y = yi;
    NSRect bounds = [self boundingRectForCharAtX:xi y:yi];
    int minX = bounds.origin.x;
    int maxX = bounds.origin.x + bounds.size.width - 1;
    int minY = bounds.origin.y;
    int maxY = bounds.origin.y + bounds.size.height - 1;

    // Walk characters until a hard newline (if respected) or the edge of the screen.
    NSMutableString *s = [NSMutableString string];
    screen_char_t *theLine = [dataSource getLineAtIndex:y];
    BOOL first = YES;
    BOOL lastWasTabFiller = NO;
    while (y >= minY && y <= maxY) {
        NSString* curChar = [self _getCharacterAtX:x Y:y];

        if (first && dir < 0) {
            // Skip first char when going backwards to avoid getting it in both directions
            first = NO;
        } else if ([curChar isEqualToString:@"\\"] && x == maxX) {
            // Ignore backslash in last position of line
        } else {
            // This is the normal case. Append or prepend the character at (x,y) to s.
            NSString *value = nil;
            if (theLine[x].code == TAB_FILLER) {
                if ([self isTabFillerOrphanAtX:x Y:y]) {
                    value = @" ";
                }
                lastWasTabFiller = YES;
            } else {
                // TODO: This will cause tabs to be double-inserted.
                if (dir < 0 && lastWasTabFiller) {
                    [s insertString:@"\t" atIndex:0];
                }
                lastWasTabFiller = NO;
                if (theLine[x].code != DWC_RIGHT &&
                       theLine[x].code != DWC_SKIP) {
                    value = curChar;
                }
            }
            if (value && [value length] > 0) {
                if ([value length] == 1 && [value characterAtIndex:0] == 0) {
                    value = @" ";
                }
                if (dir > 0) {
                    [s appendString:value];
                } else {
                    [s insertString:value atIndex:0];
                }
            }
        }

        // Advance x and then wrap around to the next/previous line if possible.
        x += dir;
        if (x < minX) {
            // We've gone off the left edge and would like to move to the right edge of the previous line.
            x = maxX;
            --y;
            if (respectHardNewlines && y >= minY && minX == 0 && [self _haveHardNewlineAtY:y]) {
                // Can't wrap because there is a hard newline in the way.
                break;
            }
            if (y >= 0) {
                theLine = [dataSource getLineAtIndex:y];
            }
        } else if (x > maxX) {
            // We've gone off the right edge and would like to move to the left edge of the next line.
            x = minX;
            ++y;
            if (respectHardNewlines && y <= maxY && maxX == w - 1 && [self _haveHardNewlineAtY:y-1]) {
                // Can't wrap because there is a hard newline in the way.
                break;
            }
            if (y < h) {
                theLine = [dataSource getLineAtIndex:y];
            }
        }
    }

    return s;
}

// Returns a substring of contiguous characters only from a given character set
// including some character in the middle of the "haystack" (source) string.
- (NSString *)stringInString:(NSString *)haystack
             includingOffset:(int)offset
            fromCharacterSet:(NSCharacterSet *)charSet
        charsTakenFromPrefix:(int*)charsTakenFromPrefixPtr
{
    if (![haystack length]) {
        if (charsTakenFromPrefixPtr) {
            *charsTakenFromPrefixPtr = 0;
        }
        return @"";
    }
    NSRange firstBadCharRange = [haystack rangeOfCharacterFromSet:[charSet invertedSet]
                                                          options:NSBackwardsSearch
                                                            range:NSMakeRange(0, offset)];
    NSRange lastBadCharRange = [haystack rangeOfCharacterFromSet:[charSet invertedSet]
                                                         options:0
                                                           range:NSMakeRange(offset, [haystack length] - offset)];
    int start = 0;
    int end = [haystack length];
    if (firstBadCharRange.location != NSNotFound) {
        start = firstBadCharRange.location + 1;
        if (charsTakenFromPrefixPtr) {
            *charsTakenFromPrefixPtr = offset - start;
        }
    } else if (charsTakenFromPrefixPtr) {
        *charsTakenFromPrefixPtr = offset;
    }

    if (lastBadCharRange.location != NSNotFound) {
        end = lastBadCharRange.location;
    }

    return [haystack substringWithRange:NSMakeRange(start, end - start)];
}

// Returns the coord gotten by starting at |coord| and advancing |n| steps.
- (VT100GridCoord)coord:(VT100GridCoord)coord plus:(int)n
{
    coord.x += n;
    int width = [dataSource width];
    while (coord.x < 0) {
        coord.y--;
        coord.x += width;
    }
    while (coord.x >= width) {
        coord.x -= width;
        coord.y++;
    }
    return coord;
}
                                 
// Returns the range of coordinates gotten by starting at |coord|, backing up
// |backup| steps, and having its terminus |length| cells after that location.
- (VT100GridCoordRange)coordRangeFromCoord:(VT100GridCoord)coord
                                       startingCharsBefore:(int)backup
                                                    length:(int)length
{
    VT100GridCoordRange range;
    range.start = [self coord:coord plus:-backup];
    range.end = [self coord:coord plus:length - backup];
    return range;
}
                                 
- (URLAction *)urlActionForClickAtX:(int)x y:(int)y respectingHardNewlines:(BOOL)respectHardNewlines
{
    NSString *prefix = [self wrappedStringAtX:x y:y dir:-1 respectHardNewlines:respectHardNewlines];
    NSString *suffix = [self wrappedStringAtX:x y:y dir:1 respectHardNewlines:respectHardNewlines];
    NSString *possibleFilePart1 = [self stringInString:prefix
                                       includingOffset:[prefix length] - 1
                                      fromCharacterSet:[PTYTextView filenameCharacterSet]
                                  charsTakenFromPrefix:NULL];
    NSString *possibleFilePart2 = [self stringInString:suffix
                                       includingOffset:0
                                      fromCharacterSet:[PTYTextView filenameCharacterSet]
                                   charsTakenFromPrefix:NULL];

    int fileCharsTaken = 0;

    NSString *workingDirectory = [dataSource workingDirectoryOnLine:y];
    if (!workingDirectory) {
        // Well, just try the current directory then.
        workingDirectory = [_delegate textViewCurrentWorkingDirectory];
    }
    if (!workingDirectory) {
        workingDirectory = @"";
    }
    // First, try to locate an existing filename at this location.
    NSString *filename = [self _bruteforcePathFromBeforeString:[[possibleFilePart1 mutableCopy] autorelease]
                                                   afterString:[[possibleFilePart2 mutableCopy] autorelease]
                                              workingDirectory:workingDirectory
                                          charsTakenFromPrefix:&fileCharsTaken];

    // Don't consider / to be a valid filename because it's useless and single/double slashes are
    // pretty common.
    if (filename && ![[filename stringByReplacingOccurrencesOfString:@"//" withString:@"/"] isEqualToString:@"/"]) {
        DLog(@"Accepting filename from brute force search: %@", filename);
        // If you clicked on an existing filename, use it.
        URLAction *action = [URLAction urlActionToOpenExistingFile:filename];
        action.range = [self coordRangeFromCoord:VT100GridCoordMake(x, y)
                             startingCharsBefore:fileCharsTaken
                                          length:filename.length];
        action.fullPath = [trouter getFullPath:filename
                              workingDirectory:workingDirectory
                                    lineNumber:NULL];
        action.workingDirectory = workingDirectory;
        return action;
    }

    DLog(@"Brute force search failed, try smart selection.");
    // Next, see if smart selection matches anything with an action.
    VT100GridCoordRange smartRange;
    NSDictionary *rule = [self smartSelectAtX:x
                                            y:y
                                           to:&smartRange
                             ignoringNewlines:NO
                               actionRequired:YES];
    NSArray *actions = [SmartSelectionController actionsInRule:rule];
    DLog(@"  Smart selection produces these actions: %@", actions);
    if (actions.count) {
        NSString *content = [self contentInRange:smartRange
                                             pad:NO
                              includeLastNewline:NO
                          trimTrailingWhitespace:NO
                                    cappedAtSize:-1];
        DLog(@"  Actions match this content: %@", content);
        URLAction *action = [URLAction urlActionToPerformSmartSelectionRule:rule onString:content];
        action.range = smartRange;
        NSError *regexError;
        NSArray *components = [content captureComponentsMatchedByRegex:[SmartSelectionController regexInRule:rule]
                                                               options:0
                                                                 range:NSMakeRange(0, content.length)
                                                                 error:&regexError];
        action.selector = [self selectorForSmartSelectionAction:actions[0]];
        action.representedObject = [ContextMenuActionPrefsController parameterForActionDict:actions[0]
                                                                      withCaptureComponents:components
                                                                           workingDirectory:workingDirectory
                                                                                 remoteHost:[dataSource remoteHostOnLine:y]];
        return action;
    }

    // No luck. Look for something vaguely URL-like.
    int prefixChars;
    NSString *joined = [prefix stringByAppendingString:suffix];
    DLog(@"Smart selection found nothing. Look for URL-like things in %@ around offset %d",
         joined, (int)[prefix length]);
    NSString *possibleUrl = [self stringInString:joined
                                 includingOffset:[prefix length]
                                fromCharacterSet:[PTYTextView urlCharacterSet]
                            charsTakenFromPrefix:&prefixChars];
    DLog(@"String of just permissible chars is %@", possibleUrl);
    NSString *originalMatch = possibleUrl;
    int offset, length;
    possibleUrl = [self urlInString:possibleUrl offset:&offset length:&length];
    DLog(@"URL in string is %@", possibleUrl);
    if (!possibleUrl) {
        return nil;
    }
    // If possibleUrl contains a :, make sure something can handle that scheme.
    BOOL ruledOutBasedOnScheme = NO;
    if ([possibleUrl rangeOfString:@":"].length > 0) {
        NSURL *url = [NSURL URLWithString:possibleUrl];
        ruledOutBasedOnScheme = (!url || [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url] == nil);
        DLog(@"There seems to be a scheme. ruledOut=%d", (int)ruledOutBasedOnScheme);
    }
    
    if ([self _stringLooksLikeURL:[originalMatch substringWithRange:NSMakeRange(offset, length)]] &&
         !ruledOutBasedOnScheme) {
        DLog(@"%@ looks like a URL and it's not ruled out based on scheme. Go for it.",
             [originalMatch substringWithRange:NSMakeRange(offset, length)]);
        URLAction *action = [URLAction urlActionToOpenURL:possibleUrl];
        action.range = [self coordRangeFromCoord:VT100GridCoordMake(x, y)
                             startingCharsBefore:prefixChars - offset
                                          length:length];
        return action;
    } else {
        DLog(@"%@ is either not plausibly a URL or was ruled out based on scheme. Fail.",
             [originalMatch substringWithRange:NSMakeRange(offset, length)]);
        return nil;
    }
}

- (void)hostnameLookupFailed:(NSNotification *)notification {
    if ([[notification object] isEqualToString:self.currentUnderlineHostname]) {
        self.currentUnderlineHostname = nil;
        _underlineStartX = _underlineStartY = _underlineEndX = _underlineEndY = -1;
        [self setNeedsDisplay:YES];
    }
}

- (void)hostnameLookupSucceeded:(NSNotification *)notification {
    if ([[notification object] isEqualToString:self.currentUnderlineHostname]) {
        self.currentUnderlineHostname = nil;
        [self setNeedsDisplay:YES];
    }
}

- (URLAction *)urlActionForClickAtX:(int)x y:(int)y
{
    // I tried respecting hard newlines if that is a legal URL, but that's such a broad definition
    // that it doesn't work well. Hard EOLs mid-url are very common. Let's try always ignoring them.
    return [self urlActionForClickAtX:x
                                    y:y
               respectingHardNewlines:[self respectHardNewlinesForURLs]];
}

- (VT100GridCoordRange)rangeForMatchingParen:(NSString *)wordStartingWithParen atCoord:(VT100GridCoord)coord
{
    unichar matchingParenthesis, sameParenthesis;
    NSString* theChar;
    int level = 0, direction;
    int x1, yStart;
    int w = [dataSource width];
    int h = [dataSource numberOfLines];
    VT100GridCoordRange result = VT100GridCoordRangeMake(-1, -1, -1, -1);
    if (!wordStartingWithParen || [wordStartingWithParen length] < 1) {
        return result;
    }

    [wordStartingWithParen getCharacters:&sameParenthesis range:NSMakeRange(0, 1)];
    switch (sameParenthesis) {
        case '(':
            matchingParenthesis = ')';
            direction = 0;
            break;
        case ')':
            matchingParenthesis = '(';
            direction = 1;
            break;
        case '[':
            matchingParenthesis = ']';
            direction = 0;
            break;
        case ']':
            matchingParenthesis = '[';
            direction = 1;
            break;
        case '{':
            matchingParenthesis = '}';
            direction = 0;
            break;
        case '}':
            matchingParenthesis = '{';
            direction = 1;
            break;
        default:
            return result;
    }

    if (direction) {
        x1 = coord.x - 1;
        yStart = coord.y;
        if (x1 < 0) {
            yStart--;
            x1 = w - 1;
        }
        for (; x1 >= 0 && yStart >= 0; ) {
            theChar = [self _getCharacterAtX:x1 Y:yStart];
            if ([theChar isEqualToString:[NSString stringWithCharacters:&sameParenthesis length:1]]) {
                level++;
            } else if ([theChar isEqualToString:[NSString stringWithCharacters:&matchingParenthesis length:1]]) {
                level--;
                if (level<0) break;
            }
            x1--;
            if (x1 < 0) {
                yStart--;
                x1 = w - 1;
            }
        }
        if (level < 0) {
            result = VT100GridCoordRangeMake(x1, yStart, coord.x + 1, coord.y);
        }
    } else {
        x1 = coord.x + 1;
        yStart = coord.y;
        if (x1 >= w) {
            yStart++;
            x1 = 0;
        }

        for (; x1 < w && yStart < h; ) {
            theChar = [self _getCharacterAtX:x1 Y:yStart];
            if ([theChar isEqualToString:[NSString stringWithCharacters:&sameParenthesis length:1]]) {
                level++;
            } else if ([theChar isEqualToString:[NSString stringWithCharacters:&matchingParenthesis length:1]]) {
                level--;
                if (level < 0) {
                    break;
                }
            }
            x1++;
            if (x1 >= w) {
                yStart++;
                x1 = 0;
            }
        }
        if (level < 0) {
            result = VT100GridCoordRangeMake(coord.x, coord.y, x1 + 1, yStart);
        }
    }

    return result;
}

// Returns the drag operation to use. It is determined from the type of thing
// being dragged, the modifiers pressed, and where it's being dropped.
- (NSDragOperation)dragOperationForSender:(id <NSDraggingInfo>)sender
{
    NSString *sourceType;
    unsigned int iResult = 0;

    iResult = NSDragOperationNone;

    
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray *types = [pb types];
    NSPoint windowDropPoint = [sender draggingLocation];
    NSPoint dropPoint = [self convertPoint:windowDropPoint fromView:nil];
    int dropLine = dropPoint.y / lineHeight;
    SCPPath *dropScpPath = [dataSource scpPathForFile:@"" onLine:dropLine];

    // It's ok to upload if a file is being dragged in and the drop location has a remote host path.
    BOOL uploadOK = ([types containsObject:NSFilenamesPboardType] && dropScpPath);

    // It's ok to paste if the the drag obejct is either a file or a string.
    BOOL pasteOK = !![[sender draggingPasteboard] availableTypeFromArray:@[ NSFilenamesPboardType, NSStringPboardType ]];
    
    // The source defines the kind of operations it allows with
    // -draggingSourceOperationMask. Pressing modifier keys will change its
    // value by masking out all but one bit (if the sender allows modifiers
    // to affect dragging).
    NSDragOperation sourceMask = [sender draggingSourceOperationMask];
    NSDragOperation both = (kUploadDragOperation | kPasteDragOperation);
    if ((sourceMask & both) == both && pasteOK) {
        // No modifier key was pressed and pasting is OK, so select the paste operation.
        return kPasteDragOperation;
    } else if ((sourceMask & kUploadDragOperation) && uploadOK) {
        // Either Option was pressed or the sender allows Copy but not Generic,
        // and it's ok to upload, so select the upload operation.
        return kUploadDragOperation;
    } else if ((sourceMask & kPasteDragOperation) && pasteOK) {
        // Either Command was prsesed or the sender allows Generic but not
        // copy, and it's ok to paste, so select the paste operation.
        return kPasteDragOperation;
    } else {
        // No luck.
        return NSDragOperationNone;
    }
}

- (int)_lineLength:(int)y
{
    screen_char_t *theLine = [dataSource getLineAtIndex:y];
    int x;
    for (x = [dataSource width] - 1; x >= 0; x--) {
        if (theLine[x].code) {
            break;
        }
    }
    return x + 1;
}

- (BOOL)_isBlankLine:(int)y
{
    NSString *lineContents;

    lineContents = [self contentInRange:VT100GridCoordRangeMake(0, y, [dataSource width], y)
                                    pad:YES
                     includeLastNewline:NO
                 trimTrailingWhitespace:NO
                           cappedAtSize:-1];
    const char* utf8 = [lineContents UTF8String];
    for (int i = 0; utf8[i]; ++i) {
        if (utf8[i] != ' ') {
            return NO;
        }
    }
    return YES;
}


- (void)_openSemanticHistoryForUrl:(NSString *)aURLString
                            atLine:(long long)line
                      inBackground:(BOOL)background
                            prefix:(NSString *)prefix
                            suffix:(NSString *)suffix
{
    NSString* trimmedURLString;

    trimmedURLString = [aURLString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSString *workingDirectory = [dataSource workingDirectoryOnLine:line];
    if (![trouter openPath:trimmedURLString
              workingDirectory:workingDirectory
                    prefix:prefix
                    suffix:suffix]) {
        [self _findUrlInString:aURLString
              andOpenInBackground:background];
    }

    return;
}

// Opens a URL in the default browser in background or foreground
// Don't call this unless you know that iTerm2 is NOT the handler for this scheme!
- (void)openURL:(NSURL *)url inBackground:(BOOL)background
{
    if (background) {
        NSArray* urls = [NSArray arrayWithObject:url];
        [[NSWorkspace sharedWorkspace] openURLs:urls
                                           withAppBundleIdentifier:nil
                                           options:NSWorkspaceLaunchWithoutActivation
                                           additionalEventParamDescriptor:nil
                                           launchIdentifiers:nil];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

// This handles a few kinds of URLs, after trimming whitespace from the beginning and end:
// 1. Well formed strings like:
//    "http://example.com/foo?query#fragment"
// 2. URLs in parens:
//    "(http://example.com/foo?query#fragment)" -> http://example.com/foo?query#fragment
// 3. URLs at the end of a sentence:
//    "http://example.com/foo?query#fragment." -> http://example.com/foo?query#fragment
// 4. Case 2 & 3 combined:
//    "(http://example.com/foo?query#fragment)." -> http://example.com/foo?query#fragment
// 5. Strings without a scheme (http is assumed, previous cases do not apply)
//    "example.com/foo?query#fragment" -> http://example.com/foo?query#fragment
// *offset will be set to the number of characters at the start of aURLString that were skipped past.
// offset may be nil. If |length| is not nil, then *length will be set to the number of chars matched
// in |aURLString|.
- (NSString *)urlInString:(NSString *)aURLString offset:(int *)offset length:(int *)length
{
    NSString* trimmedURLString;
    
    trimmedURLString = [aURLString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (![trimmedURLString length]) {
        return nil;
    }
    if (offset) {
        *offset = 0;
    }
    
    NSRange range = [trimmedURLString rangeOfString:@":"];
    if (range.location == NSNotFound) {
        if (length) {
            *length = trimmedURLString.length;
        }
        trimmedURLString = [NSString stringWithFormat:@"http://%@", trimmedURLString];
    } else {
        if (length) {
            *length = trimmedURLString.length;
        }
        // Search backwards for the start of the scheme.
        for (int i = range.location - 1; 0 <= i; i--) {
            unichar c = [trimmedURLString characterAtIndex:i];
            if (!isalnum(c)) {
                // Remove garbage before the scheme part
                trimmedURLString = [trimmedURLString substringFromIndex:i + 1];
                if (offset) {
                    *offset = i + 1;
                }
                if (length) {
                    *length = trimmedURLString.length;
                }
                if (c == '(') {
                    // If an open parenthesis is right before the
                    // scheme part, remove the closing parenthesis
                    NSRange closer = [trimmedURLString rangeOfString:@")"];
                    if (closer.location != NSNotFound) {
                        trimmedURLString = [trimmedURLString substringToIndex:closer.location];
                        if (length) {
                            *length = trimmedURLString.length;
                        }
                    }
                }
                break;
            }
        }
    }
    
    // Remove trailing punctuation.
    NSArray *punctuation = @[ @".", @",", @";", @":", @"!" ];
    BOOL found;
    do {
        found = NO;
        for (NSString *pchar in punctuation) {
            if ([trimmedURLString hasSuffix:pchar]) {
                trimmedURLString = [trimmedURLString substringToIndex:trimmedURLString.length - 1];
                found = YES;
                if (length) {
                    (*length)--;
                }
            }
        }
    } while (found);

    return trimmedURLString;
}

// If iTerm2 is the handler for the scheme, then the bookmark is launched directly.
// Otherwise it's passed to the OS to launch.
- (void)_findUrlInString:(NSString *)aURLString andOpenInBackground:(BOOL)background
{
    NSString *trimmedURLString = [self urlInString:aURLString offset:NULL length:NULL];
    if (!trimmedURLString) {
        return;
    }
    NSString* escapedString =
        (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL,
                                                            (CFStringRef)trimmedURLString,
                                                            (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                                            NULL,
                                                            kCFStringEncodingUTF8);

    NSURL *url = [NSURL URLWithString:escapedString];
    [escapedString release];

    Profile *bm = [[PreferencePanel sharedInstance] handlerBookmarkForURL:[url scheme]];

    if (bm != nil)  {
        [_delegate launchProfileInCurrentTerminal:bm withURL:trimmedURLString];
    } else {
        [self openURL:url inBackground:background];
    }

}

- (void)_dragImage:(ImageInfo *)imageInfo forEvent:(NSEvent *)theEvent
{
    NSSize region = NSMakeSize(charWidth * imageInfo.size.width,
                               lineHeight * imageInfo.size.height);
    NSImage *icon = [imageInfo imageEmbeddedInRegionOfSize:region];

    // get the pasteboard
    NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard];
    [pboard declareTypes:[NSArray arrayWithObject:NSTIFFPboardType] owner:self];
    NSBitmapImageRep *rep = [[imageInfo.image representations] objectAtIndex:0];
    NSData *tiff = [rep representationUsingType:NSTIFFFileType properties:nil];
    [pboard setData:tiff forType:NSTIFFPboardType];

    // tell our app not switch windows (currently not working)
    [NSApp preventWindowOrdering];

    // drag from center of the image
    NSPoint dragPoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];

    VT100GridCoord coord = VT100GridCoordMake((dragPoint.x - MARGIN) / charWidth,
                                              dragPoint.y / lineHeight);
    screen_char_t* theLine = [dataSource getLineAtIndex:coord.y];
    if (theLine &&
        coord.x < [dataSource width] &&
        theLine[coord.x].image &&
        theLine[coord.x].code == imageInfo.code) {
        // Get the cell you clicked on (small y at top of view)
        VT100GridCoord pos = GetPositionOfImageInChar(theLine[coord.x]);

        // Get the top-left origin of the image in cell coords
        VT100GridCoord imageCellOrigin = VT100GridCoordMake(coord.x - pos.x,
                                                            coord.y - pos.y);

        // Compute the pixel coordinate of the image's top left point
        NSPoint imageTopLeftPoint = NSMakePoint(imageCellOrigin.x * charWidth + MARGIN,
                                                imageCellOrigin.y * lineHeight);

        // Compute the distance from the click location to the image's origin
        NSPoint offset = NSMakePoint(dragPoint.x - imageTopLeftPoint.x,
                                     dragPoint.y - imageTopLeftPoint.y);

        // Adjust the drag point so the image won't jump as soon as the drag begins.
        dragPoint.x -= offset.x;
        dragPoint.y += region.height - offset.y;
    }

    // start the drag
    [self dragImage:icon
                 at:dragPoint
             offset:NSMakeSize(0.0, 0.0)
              event:mouseDownEvent
         pasteboard:pboard
             source:self
          slideBack:YES];
}

- (void)_dragText:(NSString *)aString forEvent:(NSEvent *)theEvent
{
    NSImage *anImage;
    int length;
    NSString *tmpString;
    NSPasteboard *pboard;
    NSArray *pbtypes;
    NSSize imageSize;
    NSPoint dragPoint;
    NSSize dragOffset = NSMakeSize(0.0, 0.0);

    length = [aString length];
    if ([aString length] > 15) {
        length = 15;
    }

    imageSize = NSMakeSize(charWidth*length, lineHeight);
    anImage = [[NSImage alloc] initWithSize: imageSize];
    [anImage lockFocus];
    if ([aString length] > 15)
        tmpString = [NSString stringWithFormat: @"%@...", [aString substringWithRange: NSMakeRange(0, 12)]];
    else
        tmpString = [aString substringWithRange: NSMakeRange(0, length)];

    [tmpString drawInRect: NSMakeRect(0, 0, charWidth*length, lineHeight) withAttributes: nil];
    [anImage unlockFocus];
    [anImage autorelease];

    // get the pasteboard
    pboard = [NSPasteboard pasteboardWithName:NSDragPboard];

    // Declare the types and put our tabViewItem on the pasteboard
    pbtypes = [NSArray arrayWithObjects: NSStringPboardType, nil];
    [pboard declareTypes: pbtypes owner: self];
    [pboard setString: aString forType: NSStringPboardType];

    // tell our app not switch windows (currently not working)
    [NSApp preventWindowOrdering];

    // drag from center of the image
    dragPoint = [self convertPoint: [theEvent locationInWindow] fromView: nil];
    dragPoint.x -= imageSize.width/2;

    // start the drag
    [self dragImage:anImage at: dragPoint offset:dragOffset
              event: mouseDownEvent pasteboard:pboard source:self slideBack:YES];

}

- (BOOL)_wasAnyCharSelected
{
    return [_oldSelection hasSelection];
}

- (void)_pointerSettingsChanged:(NSNotification *)notification
{
    BOOL track = [pointer_ viewShouldTrackTouches];
    [self setAcceptsTouchEvents:track];
    [self setWantsRestingTouches:track];
    [threeFingerTapGestureRecognizer_ release];
    threeFingerTapGestureRecognizer_ = nil;
    if (track) {
        if ([self useThreeFingerTapGestureRecognizer]) {
            threeFingerTapGestureRecognizer_ = [[ThreeFingerTapGestureRecognizer alloc] initWithTarget:self
                                                                                              selector:@selector(threeFingerTap:)];
        }
    } else {
        numTouches_ = 0;
    }
}

- (void)_settingsChanged:(NSNotification *)notification
{
    [dimmedColorCache_ removeAllObjects];
    [self setNeedsDisplay:YES];
    [self setDimOnlyText:[[PreferencePanel sharedInstance] dimOnlyText]];
}

- (NSRect)gridRect {
    NSRect visibleRect = [self visibleRect];
    int lineStart = [dataSource numberOfLines] - [dataSource height];
    int lineEnd = [dataSource numberOfLines];
    return NSMakeRect(visibleRect.origin.x,
                      lineStart * lineHeight,
                      visibleRect.origin.x + visibleRect.size.width,
                      (lineEnd - lineStart + 1) * lineHeight);
}

- (void)setNeedsDisplayOnLine:(int)y inRange:(VT100GridRange)range
{
    NSRect dirtyRect;
    const int x = range.location;
    const int maxX = range.location + range.length - 1;
    
    dirtyRect.origin.x = MARGIN + x * charWidth;
    dirtyRect.origin.y = y * lineHeight;
    dirtyRect.size.width = (maxX - x + 1) * charWidth;
    dirtyRect.size.height = lineHeight;
    
    if (showTimestamps_) {
        dirtyRect.size.width = self.visibleRect.size.width - dirtyRect.origin.x;
    }
    // Add a character on either side for glyphs that render unexpectedly wide.
    dirtyRect.origin.x -= charWidth;
    dirtyRect.size.width += 2 * charWidth;
    DLog(@"Line %d is dirty from %d to %d, set rect %@ dirty",
         y, x, maxX, [NSValue valueWithRect:dirtyRect]);
    [self setNeedsDisplayInRect:dirtyRect];
}

// WARNING: Do not call this function directly. Call
// -[refresh] instead, as it ensures scrollback overflow
// is dealt with so that this function can dereference
// [dataSource dirty] correctly.
- (BOOL)updateDirtyRects
{
    BOOL anythingIsBlinking = NO;
    BOOL foundDirty = NO;
    if ([dataSource scrollbackOverflow] != 0) {
        NSAssert([dataSource scrollbackOverflow] == 0, @"updateDirtyRects called with nonzero overflow");
    }
#ifdef DEBUG_DRAWING
    [self appendDebug:[NSString stringWithFormat:@"updateDirtyRects called. Scrollback overflow is %d. Screen is: %@", [dataSource scrollbackOverflow], [dataSource debugString]]];
    DebugLog(@"updateDirtyRects called");
#endif

    // Check each line for dirty selected text
    // If any is found then deselect everything
    [self _deselectDirtySelectedText];

    // Flip blink bit if enough time has passed. Mark blinking cursor dirty
    // when it blinks.
    BOOL redrawBlink = [self _updateBlink];
    int WIDTH = [dataSource width];

    // Any characters that changed selection status since the last update or
    // are blinking should be set dirty.
    anythingIsBlinking = [self _markChangedSelectionAndBlinkDirty:redrawBlink width:WIDTH];

    // Copy selection position to detect change in selected chars next call.
    [_oldSelection release];
    _oldSelection = [_selection copy];

    // Redraw lines with dirty characters
    int lineStart = [dataSource numberOfLines] - [dataSource height];
    int lineEnd = [dataSource numberOfLines];
    // lineStart to lineEnd is the region that is the screen when the scrollbar
    // is at the bottom of the frame.
#ifdef DEBUG_DRAWING
    if (gDebugLogging) {
        DebugLog([NSString stringWithFormat:@"Search lines [%d, %d) for dirty", lineStart, lineEnd]);
    }

    NSMutableString* dirtyDebug = [NSMutableString stringWithString:@"updateDirtyRects found these dirty lines:\n"];
    int screenindex=0;
#endif
    BOOL irEnabled = [[PreferencePanel sharedInstance] instantReplay];
    long long totalScrollbackOverflow = [dataSource totalScrollbackOverflow];
    int allDirty = [dataSource isAllDirty] ? 1 : 0;
    [dataSource resetAllDirty];

    int currentCursorX = [dataSource cursorX] - 1;
    int currentCursorY = [dataSource cursorY] - 1;
    if (prevCursorX != currentCursorX ||
        prevCursorY != currentCursorY) {
        // Mark previous and current cursor position dirty
        DLog(@"Mark previous cursor position %d,%d dirty", prevCursorX, prevCursorY);
        int maxX = [dataSource width] - 1;
        if (_highlightCursorLine) {
            [dataSource setLineDirtyAtY:prevCursorY];
            DLog(@"Mark current cursor line %d dirty", currentCursorY);
            [dataSource setLineDirtyAtY:currentCursorY];
        } else {
            [dataSource setCharDirtyAtCursorX:MIN(maxX, prevCursorX) Y:prevCursorY];
            DLog(@"Mark current cursor position %d,%d dirty", currentCursorX, currentCursorY);
            [dataSource setCharDirtyAtCursorX:MIN(maxX, currentCursorX) Y:currentCursorY];
        }
        // Set prevCursor[XY] to new cursor position
        prevCursorX = currentCursorX;
        prevCursorY = currentCursorY;
    }

    // Remove results from dirty lines and mark parts of the view as needing display.
    if (allDirty) {
        foundDirty = YES;
        for (int y = lineStart; y < lineEnd; y++) {
            [resultMap_ removeObjectForKey:[NSNumber numberWithLongLong:y + totalScrollbackOverflow]];
        }
        [self setNeedsDisplayInRect:[self gridRect]];
#ifdef DEBUG_DRAWING
        NSLog(@"allDirty is set, redraw the whole view");
#endif
    } else {
        for (int y = lineStart; y < lineEnd; y++) {
            VT100GridRange range = [dataSource dirtyRangeForLine:y - lineStart];
            if (range.length > 0) {
                foundDirty = YES;
                [resultMap_ removeObjectForKey:[NSNumber numberWithLongLong:y + totalScrollbackOverflow]];
                [self setNeedsDisplayOnLine:y inRange:range];
#ifdef DEBUG_DRAWING
                NSLog(@"line %d has dirty characters", y);
#endif
            }
        }
    }

    // Always mark the IME as needing to be drawn to keep things simple.
    if ([self hasMarkedText]) {
        [self invalidateInputMethodEditorRect];
    }

    // Unset the dirty bit for all chars.
    DebugLog(@"updateDirtyRects resetDirty");
#ifdef DEBUG_DRAWING
    [self appendDebug:dirtyDebug];
#endif
    [dataSource resetDirty];

    if (irEnabled && foundDirty) {
        [dataSource saveToDvr];
    }

    if (foundDirty && [dataSource shouldSendContentsChangedNotification]) {
        changedSinceLastExpose_ = YES;
        [_delegate textViewPostTabContentsChangedNotification];
    }

    if (foundDirty && gDebugLogging) {
        // Dump the screen contents
        DebugLog([dataSource debugString]);
    }

    return blinkAllowed_ && anythingIsBlinking;
}

- (void)invalidateInputMethodEditorRect
{
    if ([dataSource width] == 0) {
        return;
    }
    int imeLines = ([dataSource cursorX] - 1 + [self inputMethodEditorLength] + 1) / [dataSource width] + 1;

    NSRect imeRect = NSMakeRect(MARGIN,
                                ([dataSource cursorY] - 1 + [dataSource numberOfLines] - [dataSource height]) * lineHeight,
                                [dataSource width] * charWidth,
                                imeLines * lineHeight);
    [self setNeedsDisplayInRect:imeRect];
}

- (void)moveSelectionEndpointToX:(int)x Y:(int)y locationInTextView:(NSPoint)locationInTextView
{
    if (_selection.live) {
        DLog(@"Move selection endpoint to %d,%d, coord=%@",
             x, y, [NSValue valueWithPoint:locationInTextView]);
        int width = [dataSource width];
        if (locationInTextView.y == 0) {
            x = y = 0;
        } else if (locationInTextView.x < MARGIN && _selection.liveRange.start.y < y) {
            // complete selection of previous line
            x = width;
            y--;
        }
        if (y >= [dataSource numberOfLines]) {
            y = [dataSource numberOfLines] - 1;
        }
        [_selection moveSelectionEndpointTo:VT100GridCoordMake(x, y)];
        DLog(@"moveSelectionEndpoint. selection=%@", _selection);
    }
}

- (void)_deselectDirtySelectedText
{
    if (![self isAnyCharSelected]) {
        return;
    }

    int width = [dataSource width];
    int lineStart = [dataSource numberOfLines] - [dataSource height];
    int lineEnd = [dataSource numberOfLines];
    int cursorX = [dataSource cursorX] - 1;
    int cursorY = [dataSource cursorY] + [dataSource numberOfLines] - [dataSource height] - 1;
    for (int y = lineStart; y < lineEnd && [_selection hasSelection]; y++) {
        NSIndexSet *selectedIndexes = [_selection selectedIndexesOnLine:y];
        if ([selectedIndexes count] == 0) {
            continue;
        }
        NSIndexSet *dirtyIndexes = [dataSource dirtyIndexesOnLine:y - lineStart];
        if ([dirtyIndexes count] == 0) {
            continue;
        }
        
        // Look for any character that is dirty, selected, and is NOT the cursor.
        [dirtyIndexes enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
            [selectedIndexes enumerateRangesInRange:range
                                            options:0
                                         usingBlock:^(NSRange innerRange, BOOL *innerStop) {
                // This condition is to test if the range we got is just the cursor. If it's not,
                // then it satisfies the condition of being selected and dirty and not the cursor.
                if (y != cursorY ||  // not the cursor's line
                    innerRange.length > 1 ||  // cursor is only one character long (TODO: DWCs)
                    innerRange.location != cursorX) {  // It's just 1 char, but it's not the cursor
                    // Remove the selection and stop enumerating.
                    *innerStop = YES;
                    *stop = YES;
                    [_selection clearSelection];
                    DebugLog(@"found selected dirty noncursor");
                }
            }];
        }];
    }
}

- (BOOL)_updateBlink
{
    // Time to redraw blinking text or cursor?
    struct timeval now;
    BOOL redrawBlink = NO;
    gettimeofday(&now, NULL);
    double timeDelta = now.tv_sec - lastBlink.tv_sec;
    timeDelta += (now.tv_usec - lastBlink.tv_usec) / 1000000.0;
    if (timeDelta >= [[PreferencePanel sharedInstance] timeBetweenBlinks]) {
        blinkShow = !blinkShow;
        lastBlink = now;
        redrawBlink = YES;

        if ([self blinkingCursor] &&
            [self isInKeyWindow]) {
            // Blink flag flipped and there is a blinking cursor. Make it redraw.
            [self setCursorNeedsDisplay];
        }
        DebugLog(@"time to redraw blinking text");
    }
  return redrawBlink;
}

- (BOOL)_markChangedSelectionAndBlinkDirty:(BOOL)redrawBlink width:(int)width
{
    BOOL anyBlinkers = NO;
    // Visible chars that have changed selection status are dirty
    // Also mark blinking text as dirty if needed
    int lineStart = ([self visibleRect].origin.y + VMARGIN) / lineHeight;  // add VMARGIN because stuff under top margin isn't visible.
    int lineEnd = ceil(([self visibleRect].origin.y + [self visibleRect].size.height - [self excess]) / lineHeight);
    if (lineStart < 0) {
        lineStart = 0;
    }
    if (lineEnd > [dataSource numberOfLines]) {
        lineEnd = [dataSource numberOfLines];
    }
    for (int y = lineStart; y < lineEnd; y++) {
        if (blinkAllowed_) {
            // First, mark blinking chars as dirty.
            screen_char_t* theLine = [dataSource getLineAtIndex:y];
            for (int x = 0; x < width; x++) {
                BOOL charBlinks = [self _charBlinks:theLine[x]];
                anyBlinkers |= charBlinks;
                BOOL blinked = redrawBlink && charBlinks;
                if (blinked) {
                    NSRect dirtyRect = [self visibleRect];
                    dirtyRect.origin.y = y * lineHeight;
                    dirtyRect.size.height = lineHeight;
                    if (gDebugLogging) {
                        DLog(@"Found blinking char on line %d", y);
                    }
                    [self setNeedsDisplayInRect:dirtyRect];
                    break;
                }
            }
        }
        
        // Now mark chars whose selection status has changed as needing display.
        NSIndexSet *areSelected = [_selection selectedIndexesOnLine:y];
        NSIndexSet *wereSelected = [_oldSelection selectedIndexesOnLine:y];
        if (![areSelected isEqualToIndexSet:wereSelected]) {
            // Just redraw the whole line for simplicity.
            NSRect dirtyRect = [self visibleRect];
            dirtyRect.origin.y = y * lineHeight;
            dirtyRect.size.height = lineHeight;
            if (gDebugLogging) {
                DLog(@"found selection change on line %d", y);
            }
            [self setNeedsDisplayInRect:dirtyRect];
        }
    }
    return anyBlinkers;
}

#pragma mark - iTermSelectionDelegate

- (void)selectionDidChange:(iTermSelection *)selection {
    if ([selection hasSelection]) {
        selectionTime_ = [[NSDate date] timeIntervalSince1970];
    } else {
        selectionTime_ = 0;
    }
    [_delegate refreshAndStartTimerIfNeeded];
    DLog(@"Update selection time to %lf. selection=%@", (double)selectionTime_, selection);
}

- (VT100GridRange)selectionRangeOfTerminalNullsOnLine:(int)lineNumber {
    int length = [self _lineLength:lineNumber];
    int width = [dataSource width];
    return VT100GridRangeMake(length, width - length);
}

- (VT100GridCoordRange)selectionRangeForParentheticalAt:(VT100GridCoord)coord {
    NSString *theString = [self contentInRange:VT100GridCoordRangeMake(coord.x,
                                                                       coord.y,
                                                                       coord.x + 1,
                                                                       coord.y)
                                           pad:NO
                            includeLastNewline:NO
                        trimTrailingWhitespace:NO
                                  cappedAtSize:-1];
    return [self rangeForMatchingParen:theString
                               atCoord:coord];
}

- (VT100GridCoordRange)selectionRangeForWordAt:(VT100GridCoord)coord {
    VT100GridCoordRange range;
    [self getWordForX:coord.x y:coord.y range:&range];
    return range;
}

- (VT100GridCoordRange)selectionRangeForSmartSelectionAt:(VT100GridCoord)coord {
    VT100GridCoordRange range;
    [self smartSelectAtX:coord.x
                       y:coord.y
                      to:&range
        ignoringNewlines:NO
          actionRequired:NO];
    return range;
}

- (VT100GridCoordRange)selectionRangeForWrappedLineAt:(VT100GridCoord)coord {
    int start = [self lineNumberWithStartOfWholeLineIncludingLine:coord.y];
    int end = [self lineNumberWithEndOfWholeLineIncludingLine:coord.y];
    return VT100GridCoordRangeMake(0, start, [dataSource width], end);
}

- (VT100GridCoordRange)selectionRangeForLineAt:(VT100GridCoord)coord {
    return VT100GridCoordRangeMake(0, coord.y, [dataSource width], coord.y);
}

- (VT100GridCoord)selectionPredecessorOfCoord:(VT100GridCoord)coord {
    screen_char_t *theLine;
    do {
        coord.x--;
        if (coord.x < 0) {
            coord.x = [dataSource width] - 1;
            coord.y--;
            if (coord.y < 0) {
                coord.x = coord.y = 0;
                break;
            }
        }
        
        theLine = [dataSource getLineAtIndex:coord.y];
    } while (theLine[coord.x].code == DWC_RIGHT);
    return coord;
}

@end
