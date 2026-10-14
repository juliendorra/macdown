//
//  MPDocument.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 6/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPDocument.h"
#import <WebKit/WebKit.h>
#import <JJPluralForm/JJPluralForm.h>
#import <hoedown/html.h>
#import "hoedown_html_patch.h"
#import "HGMarkdownHighlighter.h"
#import "MPUtilities.h"
#import "MPAutosaving.h"
#import "NSColor+HTML.h"
#import "NSDocumentController+Document.h"
#import "NSPasteboard+Types.h"
#import "NSString+Lookup.h"
#import "NSTextView+Autocomplete.h"
#import "DOMNode+Text.h"
#import "MPPreferences.h"
#import "MPDocumentSplitView.h"
#import "MPEditorView.h"
#import "MPRenderer.h"
#import "MPPreferencesViewController.h"
#import "MPEditorPreferencesViewController.h"
#import "MPExportPanelAccessoryViewController.h"
#import "MPMathJaxListener.h"
#import "MPToolbarController.h"

static NSString * const kMPDefaultAutosaveName = @"Untitled";


NS_INLINE NSString *MPEditorPreferenceKeyWithValueKey(NSString *key)
{
    if (!key.length)
        return @"editor";
    NSString *first = [[key substringToIndex:1] uppercaseString];
    NSString *rest = [key substringFromIndex:1];
    return [NSString stringWithFormat:@"editor%@%@", first, rest];
}

NS_INLINE NSDictionary *MPEditorKeysToObserve()
{
    static NSDictionary *keys = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        keys = @{@"automaticDashSubstitutionEnabled": @NO,
                 @"automaticDataDetectionEnabled": @NO,
                 @"automaticQuoteSubstitutionEnabled": @NO,
                 @"automaticSpellingCorrectionEnabled": @NO,
                 @"automaticTextReplacementEnabled": @NO,
                 @"continuousSpellCheckingEnabled": @NO,
                 @"enabledTextCheckingTypes": @(NSTextCheckingAllTypes),
                 @"grammarCheckingEnabled": @NO};
    });
    return keys;
}

NS_INLINE NSSet *MPEditorPreferencesToObserve()
{
    static NSSet *keys = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        keys = [NSSet setWithObjects:
            @"editorBaseFontInfo", @"extensionFootnotes",
            @"editorHorizontalInset", @"editorVerticalInset",
            @"editorWidthLimited", @"editorMaximumWidth", @"editorLineSpacing",
            @"editorOnRight", @"editorStyleName", @"editorShowWordCount",
            @"editorScrollsPastEnd", nil
        ];
    });
    return keys;
}

NS_INLINE NSString *MPRectStringForAutosaveName(NSString *name)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@", name];
    NSString *rectString = [defaults objectForKey:key];
    return rectString;
}

@implementation NSURL (Convert)

- (NSString *)absoluteBaseURLString
{
    // Remove fragment (#anchor) and query string.
    NSString *base = self.absoluteString;
    base = [base componentsSeparatedByString:@"?"].firstObject;
    base = [base componentsSeparatedByString:@"#"].firstObject;
    return base;
}

@end


@implementation MPPreferences (Hoedown)
- (int)extensionFlags
{
    int flags = 0;
    if (self.extensionAutolink)
        flags |= HOEDOWN_EXT_AUTOLINK;
    if (self.extensionFencedCode)
        flags |= HOEDOWN_EXT_FENCED_CODE;
    if (self.extensionFootnotes)
        flags |= HOEDOWN_EXT_FOOTNOTES;
    if (self.extensionHighlight)
        flags |= HOEDOWN_EXT_HIGHLIGHT;
    if (!self.extensionIntraEmphasis)
        flags |= HOEDOWN_EXT_NO_INTRA_EMPHASIS;
    if (self.extensionQuote)
        flags |= HOEDOWN_EXT_QUOTE;
    if (self.extensionStrikethough)
        flags |= HOEDOWN_EXT_STRIKETHROUGH;
    if (self.extensionSuperscript)
        flags |= HOEDOWN_EXT_SUPERSCRIPT;
    if (self.extensionTables)
        flags |= HOEDOWN_EXT_TABLES;
    if (self.extensionUnderline)
        flags |= HOEDOWN_EXT_UNDERLINE;
    if (self.htmlMathJax)
        flags |= HOEDOWN_EXT_MATH;
    if (self.htmlMathJaxInlineDollar)
        flags |= HOEDOWN_EXT_MATH_EXPLICIT;
    return flags;
}

- (int)rendererFlags
{
    int flags = 0;
    if (self.htmlTaskList)
        flags |= HOEDOWN_HTML_USE_TASK_LIST;
    if (self.htmlLineNumbers)
        flags |= HOEDOWN_HTML_BLOCKCODE_LINE_NUMBERS;
    if (self.htmlHardWrap)
        flags |= HOEDOWN_HTML_HARD_WRAP;
    if (self.htmlCodeBlockAccessory == MPCodeBlockAccessoryCustom)
        flags |= HOEDOWN_HTML_BLOCKCODE_INFORMATION;
    return flags;
}
@end


@interface MPDocument ()
    <NSSplitViewDelegate, NSTextViewDelegate,
     WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
     MPAutosaving, MPRendererDataSource, MPRendererDelegate>

typedef NS_ENUM(NSUInteger, MPWordCountType) {
    MPWordCountTypeWord,
    MPWordCountTypeCharacter,
    MPWordCountTypeCharacterNoSpaces,
};

@property (weak) IBOutlet NSToolbar *toolbar;
@property (weak) IBOutlet MPDocumentSplitView *splitView;
@property (weak) IBOutlet NSView *editorContainer;
@property (unsafe_unretained) IBOutlet MPEditorView *editor;
@property (weak) IBOutlet NSLayoutConstraint *editorPaddingBottom;
@property (weak) IBOutlet NSView *previewContainer;
@property (strong) WKWebView *preview;
@property (strong) NSURL *previewDirectory;
@property (copy) NSString *pendingPreviewHTML;
@property (copy) NSString *pendingPreviewMarkdown;
@property (copy) NSString *previewEditingMarkdown;
@property (copy) NSString *loadingPreviewMarkdown;
@property BOOL previewInteractionPrepared;
@property (copy) NSString *previewInteractionToken;
@property NSUInteger previewInteractionSequence;
@property NSUInteger previewSourceOffset;
@property BOOL previewRendersTOC;
@property BOOL previewIsComposing;
@property BOOL previewDefersRendering;
@property BOOL applyingPreviewEdit;
@property (strong) NSNumber *previewCaret;
@property CGFloat previewContentHeight;
@property CGFloat previewVisibleHeight;
@property NSUInteger previewGeneration;
@property BOOL previewMetricsPending;
@property BOOL previewLayoutPending;
@property BOOL forcePreviewNavigation;
@property BOOL previewScrollPending;
@property BOOL editorGeometryDirty;
@property NSSize editorGeometrySize;
@property CGFloat editorGeometryVisibleHeight;
@property (weak) IBOutlet NSPopUpButton *wordCountWidget;
@property (strong) IBOutlet MPToolbarController *toolbarController;
@property (copy, nonatomic) NSString *autosaveName;
@property (strong) HGMarkdownHighlighter *highlighter;
@property (strong) MPRenderer *renderer;
@property CGFloat previousSplitRatio;
@property BOOL manualRender;
@property BOOL copying;
@property BOOL printing;
@property BOOL shouldHandleBoundsChange;
@property BOOL isPreviewReady;
@property (strong) NSURL *currentBaseUrl;
@property CGFloat lastPreviewScrollTop;
@property (nonatomic, readonly) BOOL needsHtml;
@property (nonatomic) NSUInteger totalWords;
@property (nonatomic) NSUInteger totalCharacters;
@property (nonatomic) NSUInteger totalCharactersNoSpaces;
@property (strong) NSMenuItem *wordsMenuItem;
@property (strong) NSMenuItem *charMenuItem;
@property (strong) NSMenuItem *charNoSpacesMenuItem;
@property (nonatomic) BOOL needsToUnregister;
@property (nonatomic) BOOL alreadyRenderingInWeb;
@property (strong) NSArray<NSNumber *> *webViewHeaderLocations;
@property (strong) NSArray<NSNumber *> *editorHeaderLocations;
@property (nonatomic) BOOL inLiveScroll;

// Store file content in initializer until nib is loaded.
@property (copy) NSString *loadedString;

- (void)scaleWebview;
- (void)syncScrollers;
-(void) updateHeaderLocations;

@end

@implementation MPDocument

#pragma mark - Accessor

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}

- (NSString *)markdown
{
    return self.editor.string;
}

- (void)setMarkdown:(NSString *)markdown
{
    self.editor.string = markdown;
}

- (NSString *)html
{
    return self.renderer.currentHtml;
}

- (BOOL)toolbarVisible
{
    return self.windowForSheet.toolbar.visible;
}

- (BOOL)previewVisible
{
    return (self.previewContainer.frame.size.width != 0.0);
}

- (BOOL)editorVisible
{
    return (self.editorContainer.frame.size.width != 0.0);
}

- (BOOL)needsHtml
{
    if (self.preferences.markdownManualRender)
        return NO;
    return (self.previewVisible || self.preferences.editorShowWordCount);
}

- (void)setTotalWords:(NSUInteger)value
{
    _totalWords = value;
    NSString *key = NSLocalizedString(@"WORDS_PLURAL_STRING", @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.wordsMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setTotalCharacters:(NSUInteger)value
{
    _totalCharacters = value;
    NSString *key = NSLocalizedString(@"CHARACTERS_PLURAL_STRING", @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.charMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setTotalCharactersNoSpaces:(NSUInteger)value
{
    _totalCharactersNoSpaces = value;
    NSString *key = NSLocalizedString(@"CHARACTERS_NO_SPACES_PLURAL_STRING",
                                      @"");
    NSInteger rule = kJJPluralFormRule.integerValue;
    self.charNoSpacesMenuItem.title =
        [JJPluralForm pluralStringForNumber:value withPluralForms:key
                            usingPluralRule:rule localizeNumeral:NO];
}

- (void)setAutosaveName:(NSString *)autosaveName
{
    _autosaveName = autosaveName;
    self.splitView.autosaveName = autosaveName;
}


#pragma mark - Override

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    self.isPreviewReady = NO;
    self.shouldHandleBoundsChange = YES;
    self.previousSplitRatio = -1.0;
    self.editorGeometryDirty = YES;
    
    return self;
}

- (NSString *)windowNibName
{
    return @"MPDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller
{
    [super windowControllerDidLoadNib:controller];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // All files use their absolute path to keep their window states.
    NSString *autosaveName = kMPDefaultAutosaveName;
    if (self.fileURL)
        autosaveName = self.fileURL.absoluteString;
    controller.window.frameAutosaveName = autosaveName;
    self.autosaveName = autosaveName;

    // Perform initial resizing manually because for some reason untitled
    // documents do not pick up the autosaved frame automatically in 10.10.
    NSString *rectString = MPRectStringForAutosaveName(autosaveName);
    if (!rectString)
        rectString = MPRectStringForAutosaveName(kMPDefaultAutosaveName);
    if (rectString)
        [controller.window setFrameFromString:rectString];

    self.highlighter =
        [[HGMarkdownHighlighter alloc] initWithTextView:self.editor
                                           waitInterval:0.12];
    self.renderer = [[MPRenderer alloc] init];
    self.renderer.dataSource = self;
    self.renderer.delegate = self;

    for (NSString *key in MPEditorPreferencesToObserve())
    {
        [defaults addObserver:self forKeyPath:key
                      options:NSKeyValueObservingOptionNew context:NULL];
    }
    for (NSString *key in MPEditorKeysToObserve())
    {
        [self.editor addObserver:self forKeyPath:key
                         options:NSKeyValueObservingOptionNew context:NULL];
    }

    self.editor.postsFrameChangedNotifications = YES;
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    MPMathJaxListener *listener = [[MPMathJaxListener alloc] init];
    listener.target = self;
    [configuration.userContentController addScriptMessageHandler:listener name:@"previewScroll"];
    [configuration.userContentController addScriptMessageHandler:listener
        contentWorld:WKContentWorld.defaultClientWorld name:@"previewInteraction"];
    [configuration.userContentController addScriptMessageHandler:listener
        contentWorld:WKContentWorld.defaultClientWorld name:@"previewScroll"];
    // Coalesce native scroll notifications to one per animation frame.
    NSString *scrollScript = @"let pending = false; addEventListener('scroll', () => {"
        "if (pending) return; pending = true; requestAnimationFrame(() => {"
        "pending = false; window.webkit.messageHandlers.previewScroll.postMessage(scrollY);"
        "}); }, {passive: true});";
    [configuration.userContentController addUserScript:[[WKUserScript alloc]
        initWithSource:scrollScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES]];
    NSURL *updateURL = [NSBundle.mainBundle URLForResource:@"preview-update"
        withExtension:@"js" subdirectory:@"Extensions"];
    NSString *updateScript = [NSString stringWithContentsOfURL:updateURL
        encoding:NSUTF8StringEncoding error:NULL];
    if (updateScript.length)
        [configuration.userContentController addUserScript:[[WKUserScript alloc]
            initWithSource:updateScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:YES inContentWorld:WKContentWorld.defaultClientWorld]];
    NSURL *editingURL = [NSBundle.mainBundle URLForResource:@"preview-edit"
        withExtension:@"js" subdirectory:@"Extensions"];
    NSString *editingScript = [NSString stringWithContentsOfURL:editingURL
        encoding:NSUTF8StringEncoding error:NULL];
    if (editingScript.length)
        [configuration.userContentController addUserScript:[[WKUserScript alloc]
            initWithSource:editingScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:YES inContentWorld:WKContentWorld.defaultClientWorld]];
    self.preview = [[WKWebView alloc] initWithFrame:self.previewContainer.bounds configuration:configuration];
    self.preview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.preview.navigationDelegate = self;
    self.preview.UIDelegate = self;
    [self.previewContainer addSubview:self.preview];
    self.previewDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.previewDirectory
        withIntermediateDirectories:YES attributes:nil error:NULL];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(editorTextDidChange:)
                   name:NSTextDidChangeNotification object:self.editor];
    [center addObserver:self selector:@selector(editorLayoutDidChange:)
                   name:NSTextStorageDidProcessEditingNotification object:self.editor.textStorage];
    [center addObserver:self selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:[NSUserDefaults standardUserDefaults]];
    [center addObserver:self selector:@selector(editorBoundsDidChange:)
                   name:NSViewBoundsDidChangeNotification
                 object:self.editor.enclosingScrollView.contentView];
    [center addObserver:self selector:@selector(editorFrameDidChange:)
                   name:NSViewFrameDidChangeNotification object:self.editor];
    [center addObserver:self selector:@selector(didRequestEditorReload:)
                   name:MPDidRequestEditorSetupNotification object:nil];
    [center addObserver:self selector:@selector(didRequestPreviewReload:)
                   name:MPDidRequestPreviewRenderNotification object:nil];
    [center addObserver:self selector:@selector(willStartLiveScroll:)
                   name:NSScrollViewWillStartLiveScrollNotification
                 object:self.editor.enclosingScrollView];
    [center addObserver:self selector:@selector(didEndLiveScroll:)
                   name:NSScrollViewDidEndLiveScrollNotification
                 object:self.editor.enclosingScrollView];
    self.needsToUnregister = YES;

    self.wordsMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL
                                             keyEquivalent:@""];
    self.charMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL
                                            keyEquivalent:@""];
    self.charNoSpacesMenuItem = [[NSMenuItem alloc] initWithTitle:@""
                                                           action:NULL
                                                    keyEquivalent:@""];

    NSPopUpButton *wordCountWidget = self.wordCountWidget;
    [wordCountWidget removeAllItems];
    [wordCountWidget.menu addItem:self.wordsMenuItem];
    [wordCountWidget.menu addItem:self.charMenuItem];
    [wordCountWidget.menu addItem:self.charNoSpacesMenuItem];
    [wordCountWidget selectItemAtIndex:self.preferences.editorWordCountType];
    wordCountWidget.alphaValue = 0.9;
    wordCountWidget.hidden = !self.preferences.editorShowWordCount;
    wordCountWidget.enabled = NO;

    // These needs to be queued until after the window is shown, so that editor
    // can have the correct dimention for size-limiting and stuff. See
    // https://github.com/uranusjr/macdown/issues/236
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [self setupEditor:nil];
        [self redrawDivider];
        [self reloadFromLoadedString];
    }];
}

- (void)reloadFromLoadedString
{
    if (self.loadedString && self.editor && self.renderer && self.highlighter)
    {
        self.editor.string = self.loadedString;
        self.loadedString = nil;
        [self.renderer parseAndRenderNow];
        [self.highlighter parseAndHighlightNow];
    }
}

- (void)close
{
    if (self.needsToUnregister) 
    {
        // Close can be called multiple times, but this can only be done once.
        // http://www.cocoabuilder.com/archive/cocoa/240166-nsdocument-close-method-calls-itself.html
        self.needsToUnregister = NO;

        // Need to cleanup these so that callbacks won't crash the app.
        [self.highlighter deactivate];
        self.highlighter.targetTextView = nil;
        self.highlighter = nil;
        [self.renderer cancelPendingRender];
        self.renderer = nil;
        ++self.previewGeneration;
        self.isPreviewReady = NO;
        self.alreadyRenderingInWeb = NO;
        [self.preview stopLoading];
        self.preview.navigationDelegate = nil;
        self.preview.UIDelegate = nil;
        [self.preview.configuration.userContentController removeAllScriptMessageHandlers];
        [self.preview removeFromSuperview];
        self.preview = nil;
        self.pendingPreviewHTML = nil;
        self.pendingPreviewMarkdown = nil;
        self.previewEditingMarkdown = nil;
        self.loadingPreviewMarkdown = nil;
        self.previewInteractionToken = nil;
        [[NSFileManager defaultManager] removeItemAtURL:self.previewDirectory error:NULL];

        [[NSNotificationCenter defaultCenter] removeObserver:self];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        for (NSString *key in MPEditorPreferencesToObserve())
            [defaults removeObserver:self forKeyPath:key];
        for (NSString *key in MPEditorKeysToObserve())
            [self.editor removeObserver:self forKeyPath:key];
    }

    [super close];
}

+ (BOOL)autosavesInPlace
{
    return YES;
}

+ (NSArray *)writableTypes
{
    return @[@"net.daringfireball.markdown"];
}

- (BOOL)isDocumentEdited
{
    // Prevent save dialog on an unnamed, empty document. The file will still
    // show as modified (because it is), but no save dialog will be presented
    // when the user closes it.
    if (!self.presentedItemURL && !self.editor.string.length)
        return NO;
    return [super isDocumentEdited];
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName
             error:(NSError *__autoreleasing *)outError
{
    if (self.preferences.editorEnsuresNewlineAtEndOfFile)
    {
        NSCharacterSet *newline = [NSCharacterSet newlineCharacterSet];
        NSString *text = self.editor.string;
        NSUInteger end = text.length;
        if (end && ![newline characterIsMember:[text characterAtIndex:end - 1]])
        {
            NSRange selection = self.editor.selectedRange;
            [self.editor insertText:@"\n" replacementRange:NSMakeRange(end, 0)];
            self.editor.selectedRange = selection;
        }
    }
    return [super writeToURL:url ofType:typeName error:outError];
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    return [self.editor.string dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName
               error:(NSError **)outError
{
    NSString *content = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    if (!content)
        return NO;

    self.loadedString = content;
    [self reloadFromLoadedString];
    return YES;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel
{
    savePanel.extensionHidden = NO;
    if (self.fileURL && self.fileURL.isFileURL)
    {
        NSString *path = self.fileURL.path;

        // Use path of parent directory if this is a file. Otherwise this is it.
        BOOL isDir = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path
                                                           isDirectory:&isDir];
        if (!exists || !isDir)
            path = [path stringByDeletingLastPathComponent];

        savePanel.directoryURL = [NSURL fileURLWithPath:path];
    }
    else
    {
        // Suggest a file name for new documents.
        NSString *fileName = self.presumedFileName;
        if (fileName && ![fileName hasExtension:@"md"])
        {
            fileName = [fileName stringByAppendingPathExtension:@"md"];
            savePanel.nameFieldStringValue = fileName;
        }
    }
    
    // Get supported extensions from plist
    static NSMutableArray *supportedExtensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedExtensions = [NSMutableArray array];
        NSDictionary *infoDict = [NSBundle mainBundle].infoDictionary;
        for (NSDictionary *docType in infoDict[@"CFBundleDocumentTypes"])
        {
            NSArray *exts = docType[@"CFBundleTypeExtensions"];
            if (exts.count)
            {
                [supportedExtensions addObjectsFromArray:exts];
            }
        }
    });
    
    savePanel.allowedFileTypes = supportedExtensions;
    savePanel.allowsOtherFileTypes = YES; // Allow all extensions.
    
    return [super prepareSavePanel:savePanel];
}

- (NSPrintInfo *)printInfo
{
    NSPrintInfo *info = [super printInfo];
    if (!info)
        info = [[NSPrintInfo sharedPrintInfo] copy];
    info.horizontalPagination = NSAutoPagination;
    info.verticalPagination = NSAutoPagination;
    info.verticallyCentered = NO;
    info.topMargin = 50.0;
    info.leftMargin = 0.0;
    info.rightMargin = 0.0;
    info.bottomMargin = 50.0;
    return info;
}

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary *)printSettings
                                           error:(NSError *__autoreleasing *)e
{
    NSPrintInfo *info = [self.printInfo copy];
    [info.dictionary addEntriesFromDictionary:printSettings];

    NSPrintOperation *op = [self.preview printOperationWithPrintInfo:info];
    return op;
}

- (void)printDocumentWithSettings:(NSDictionary *)printSettings
                   showPrintPanel:(BOOL)showPrintPanel delegate:(id)delegate
                 didPrintSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    self.printing = YES;
    NSInvocation *invocation = nil;
    if (delegate && selector)
    {
        NSMethodSignature *signature =
            [delegate methodSignatureForSelector:selector];
        invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = delegate;
        invocation.selector = selector;
        [invocation setArgument:&contextInfo atIndex:4];
        [invocation retainArguments];
    }
    [super printDocumentWithSettings:printSettings
                      showPrintPanel:showPrintPanel delegate:self
                    didPrintSelector:@selector(document:didPrint:context:)
                         contextInfo:(__bridge_retained void *)invocation];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    BOOL result = [super validateUserInterfaceItem:item];
    SEL action = item.action;
    if (action == @selector(toggleToolbar:))
    {
        NSMenuItem *it = ((NSMenuItem *)item);
        it.title = self.toolbarVisible ?
            NSLocalizedString(@"Hide Toolbar",
                              @"Toggle reveal toolbar") :
            NSLocalizedString(@"Show Toolbar",
                              @"Toggle reveal toolbar");
    }
    else if (action == @selector(togglePreviewPane:))
    {
        NSMenuItem *it = ((NSMenuItem *)item);
        it.hidden = (!self.previewVisible && self.previousSplitRatio < 0.0);
        it.title = self.previewVisible ?
            NSLocalizedString(@"Hide Preview Pane",
                              @"Toggle preview pane menu item") :
            NSLocalizedString(@"Restore Preview Pane",
                              @"Toggle preview pane menu item");

    }
    else if (action == @selector(toggleEditorPane:))
    {
        NSMenuItem *it = (NSMenuItem*)item;
        it.title = self.editorVisible ?
        NSLocalizedString(@"Hide Editor Pane",
                          @"Toggle editor pane menu item") :
        NSLocalizedString(@"Restore Editor Pane",
                          @"Toggle editor pane menu item");
    }
    return result;
}


#pragma mark - NSSplitViewDelegate

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
    [self redrawDivider];
    self.editor.editable = self.editorVisible;
}


#pragma mark - NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (commandSelector == @selector(insertTab:))
        return ![self textViewShouldInsertTab:textView];
    else if (commandSelector == @selector(insertBacktab:))
        return ![self textViewShouldInsertBacktab:textView];
    else if (commandSelector == @selector(insertNewline:))
        return ![self textViewShouldInsertNewline:textView];
    else if (commandSelector == @selector(deleteBackward:))
        return ![self textViewShouldDeleteBackward:textView];
    else if (commandSelector == @selector(moveToLeftEndOfLine:))
        return ![self textViewShouldMoveToLeftEndOfLine:textView];
    return NO;
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                              replacementString:(NSString *)str
{
    // Ignore if this originates from an IM marked text commit event.
    if (NSIntersectionRange(textView.markedRange, range).length)
        return YES;

    if (self.preferences.editorCompleteMatchingCharacters)
    {
        BOOL strikethrough = self.preferences.extensionStrikethough;
        if ([textView completeMatchingCharactersForTextInRange:range
                                                    withString:str
                                          strikethroughEnabled:strikethrough])
            return NO;
    }
    
	// For every change, set the typing attributes
	if (range.location > 0) {
		NSRange prevRange = range;
		prevRange.location -= 1;
		prevRange.length = 1;

		NSDictionary *attr = [[textView attributedString] fontAttributesInRange:prevRange];
		[textView setTypingAttributes:attr];
	}

    return YES;
}

#pragma mark - Fake NSTextViewDelegate

- (BOOL)textViewShouldInsertTab:(NSTextView *)textView
{
    if (textView.selectedRange.length != 0)
    {
        [self indent:nil];
        return NO;
    }
    else if (self.preferences.editorConvertTabs)
    {
        [textView insertSpacesForTab];
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldInsertBacktab:(NSTextView *)textView
{
    [self unindent:nil];
    return NO;
}

- (BOOL)textViewShouldInsertNewline:(NSTextView *)textView
{
    if ([textView insertMappedContent])
        return NO;

    BOOL inserts = self.preferences.editorInsertPrefixInBlock;
    if (inserts && [textView completeNextListItem:
            self.preferences.editorAutoIncrementNumberedLists])
        return NO;
    if (inserts && [textView completeNextBlockquoteLine])
        return NO;
    if ([textView completeNextIndentedLine])
        return NO;
    return YES;
}

- (BOOL)textViewShouldDeleteBackward:(NSTextView *)textView
{
    NSRange selectedRange = textView.selectedRange;
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        NSUInteger location = selectedRange.location;
        if ([textView deleteMatchingCharactersAround:location])
            return NO;
    }
    if (self.preferences.editorConvertTabs && !selectedRange.length)
    {
        NSUInteger location = selectedRange.location;
        if ([textView unindentForSpacesBefore:location])
            return NO;
    }
    return YES;
}

- (BOOL)textViewShouldMoveToLeftEndOfLine:(NSTextView *)textView
{
    if (!self.preferences.editorSmartHome)
        return YES;
    NSUInteger cur = textView.selectedRange.location;
    NSUInteger location =
        [textView.string locationOfFirstNonWhitespaceCharacterInLineBefore:cur];
    if (location == cur || cur == 0)
        return YES;
    else if (cur >= textView.string.length)
        cur = textView.string.length - 1;

    // We don't want to jump rows when the line is wrapped. (#103)
    // If the line is wrapped, the target will be higher than the current glyph.
    NSLayoutManager *manager = textView.layoutManager;
    NSTextContainer *container = textView.textContainer;
    NSRect targetRect =
        [manager boundingRectForGlyphRange:NSMakeRange(location, 1)
                           inTextContainer:container];
    NSRect currentRect =
        [manager boundingRectForGlyphRange:NSMakeRange(cur, 1)
                           inTextContainer:container];
    if (targetRect.origin.y != currentRect.origin.y)
        return YES;

    textView.selectedRange = NSMakeRange(location, 0);
    return NO;
}


#pragma mark - WKNavigationDelegate

- (void)finishPreviewNavigation
{
    self.isPreviewReady = YES;
    self.alreadyRenderingInWeb = NO;
    if (self.pendingPreviewHTML)
    {
        NSString *html = self.pendingPreviewHTML;
        self.pendingPreviewHTML = nil;
        [self loadPreviewHTML:html];
        return;
    }
    if (!self.previewInteractionPrepared)
    {
    if (![self.loadingPreviewMarkdown isEqualToString:self.editor.string])
    {
        [self.renderer parseAndRenderNow];
        return;
    }
    self.previewEditingMarkdown = self.loadingPreviewMarkdown;
    self.previewInteractionToken = NSUUID.UUID.UUIDString;
    self.previewInteractionSequence = 0;
    [self.preview callAsyncJavaScript:
        @"return window.__macdownPreviewPrepare?.(source, token, offset, toc, caret);"
        arguments:@{@"source": self.previewEditingMarkdown ?: @"",
                    @"token": self.previewInteractionToken ?: @"",
                    @"offset": @(self.previewSourceOffset), @"toc": @(self.previewRendersTOC),
                    @"caret": self.previewCaret ?: NSNull.null}
        inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
    }
    self.previewCaret = nil;
    [self scaleWebview];
    [self updateHeaderLocations];
    if (self.preferences.editorSyncScrolling)
        [self syncScrollers];
    else
        [self.preview evaluateJavaScript:[NSString stringWithFormat:@"scrollTo(0, %f)",
            self.lastPreviewScrollTop] completionHandler:nil];
    if (self.preferences.editorShowWordCount)
        [self updateWordCount];
    [self redrawDivider];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    [self finishPreviewNavigation];
    // Images and MathJax may finish after the initial navigation. Refresh the
    // geometry once typesetting has completed, without blocking AppKit.
    NSUInteger generation = self.previewGeneration;
    __weak MPDocument *weakSelf = self;
    [webView callAsyncJavaScript:@"return await new Promise(resolve => { if (window.MathJax && MathJax.Hub) "
        "MathJax.Hub.Queue(() => resolve(true)); else resolve(true); });"
        arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
            MPDocument *doc = weakSelf;
            if (!doc || generation != doc.previewGeneration) return;
            [doc updateHeaderLocations];
        }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
     withError:(NSError *)error
{
    if (error.code != NSURLErrorCancelled)
        [self finishPreviewNavigation];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
     withError:(NSError *)error
{
    [self webView:webView didFailNavigation:navigation withError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    self.alreadyRenderingInWeb = NO;
    self.isPreviewReady = NO;
    self.pendingPreviewHTML = nil;
    self.pendingPreviewMarkdown = nil;
    self.previewIsComposing = NO;
    self.previewDefersRendering = NO;
    [self.renderer parseAndRenderNow];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    if (action.navigationType == WKNavigationTypeLinkActivated)
    {
        NSURL *url = action.request.URL;
        if ([self isCurrentBaseUrl:url] ||
            [url.absoluteBaseURLString isEqualToString:webView.URL.absoluteBaseURLString])
        {
            // The temporary preview file and document base both refer to this page.
            if (url.fragment.length)
            {
                NSData *json = [NSJSONSerialization dataWithJSONObject:@[url.fragment] options:0 error:NULL];
                NSString *argument = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                NSString *script = [NSString stringWithFormat:
                    @"(() => { const n = document.getElementById(%@[0]); if(n) n.scrollIntoView(); })()", argument];
                [webView evaluateJavaScript:script completionHandler:nil];
            }
        }
        else
            [self openOrCreateFileForUrl:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    // Markdown may contain frames or scripts. Keep the preview document in place.
    if (action.targetFrame.isMainFrame && action.navigationType != WKNavigationTypeOther)
    {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)userContentController:(WKUserContentController *)controller
     didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.name isEqualToString:@"previewInteraction"])
    {
        if (message.frameInfo.isMainFrame && message.webView == self.preview
                && [message.body isKindOfClass:NSDictionary.class])
            [self handlePreviewInteraction:message.body];
        return;
    }
    id layout = [message.body isKindOfClass:NSDictionary.class] ? message.body[@"layout"] : nil;
    if (message.frameInfo.isMainFrame && [layout isKindOfClass:NSNumber.class]
            && [layout boolValue] && self.isPreviewReady)
    {
        if (self.previewMetricsPending) self.previewLayoutPending = YES;
        else [self updateHeaderLocations];
        return;
    }
    if (message.frameInfo.isMainFrame && [message.body isKindOfClass:NSNumber.class])
        self.lastPreviewScrollTop = [message.body doubleValue];
}

// Validate every mutation against the exact source lineage shown in the page.
// JS updates optimistically so fast typing does not wait for the render debounce.
- (void)handlePreviewInteraction:(NSDictionary *)body
{
    NSString *kind = body[@"kind"];
    if (![kind isKindOfClass:NSString.class]
            || ![body[@"token"] isKindOfClass:NSString.class]
            || ![body[@"token"] isEqualToString:self.previewInteractionToken]) return;
    NSNumber *sequence = body[@"sequence"];
    if (![sequence isKindOfClass:NSNumber.class]
            || sequence.doubleValue != self.previewInteractionSequence
            || ![self.editor.string isEqualToString:self.previewEditingMarkdown])
    {
        [self.preview callAsyncJavaScript:@"window.__macdownPreviewInvalidate?.();"
            arguments:@{} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
        self.previewIsComposing = NO;
        self.previewDefersRendering = NO;
        [self.renderer parseAndRenderNow];
        return;
    }
    if ([kind isEqualToString:@"composition"] || [kind isEqualToString:@"deferRender"])
    {
        if (![body[@"active"] isKindOfClass:NSNumber.class]) return;
        if ([kind isEqualToString:@"composition"]) self.previewIsComposing = [body[@"active"] boolValue];
        else self.previewDefersRendering = [body[@"active"] boolValue];
        if (!self.previewIsComposing && !self.previewDefersRendering)
        {
            self.pendingPreviewHTML = nil;
            self.pendingPreviewMarkdown = nil;
            [self.renderer parseAndRenderNow];
        }
        return;
    }
    if ([kind isEqualToString:@"historyUndo"] || [kind isEqualToString:@"historyRedo"])
    {
        if ([kind isEqualToString:@"historyUndo"] && self.editor.undoManager.canUndo)
            [self.editor.undoManager undo];
        else if ([kind isEqualToString:@"historyRedo"] && self.editor.undoManager.canRedo)
            [self.editor.undoManager redo];
        self.previewCaret = @(self.editor.selectedRange.location);
        [self.renderer parseAndRenderNow];
        return;
    }
    NSNumber *start = body[@"start"], *length = body[@"length"];
    NSUInteger count = self.editor.string.length;
    if (![start isKindOfClass:NSNumber.class] || ![length isKindOfClass:NSNumber.class]
            || !isfinite(start.doubleValue) || !isfinite(length.doubleValue)
            || start.doubleValue < 0 || length.doubleValue < 0
            || start.doubleValue > count || length.doubleValue > count - start.unsignedIntegerValue
            || start.doubleValue != start.unsignedIntegerValue
            || length.doubleValue != length.unsignedIntegerValue) return;
    NSRange range = NSMakeRange(start.unsignedIntegerValue, length.unsignedIntegerValue);
    if ([kind isEqualToString:@"selection"])
    {
        BOOL shouldHandle = self.shouldHandleBoundsChange;
        self.shouldHandleBoundsChange = NO;
        self.editor.selectedRange = range;
        [self.editor scrollRangeToVisible:range];
        self.shouldHandleBoundsChange = shouldHandle;
        return;
    }
    if (![kind isEqualToString:@"replace"] || ![body[@"expected"] isKindOfClass:NSString.class]
            || ![body[@"replacement"] isKindOfClass:NSString.class]
            || ![[self.editor.string substringWithRange:range] isEqualToString:body[@"expected"]]) return;
    self.applyingPreviewEdit = YES;
    [self.editor insertText:body[@"replacement"] replacementRange:range];
    self.applyingPreviewEdit = NO;
    self.previewInteractionSequence++;
    self.previewEditingMarkdown = [self.editor.string copy];
    self.previewCaret = @(range.location + [body[@"replacement"] length]);
    // Preview editing remains live when the source editor uses manual rendering.
    [self.renderer parseAndRenderLater];
}

#pragma mark - MPRendererDataSource

- (NSString *)rendererMarkdown:(MPRenderer *)renderer
{
    return self.editor.string;
}

- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer
{
    NSString *n = self.fileURL.lastPathComponent.stringByDeletingPathExtension;
    return n ? n : @"";
}


#pragma mark - MPRendererDelegate

- (int)rendererExtensions:(MPRenderer *)renderer
{
    return self.preferences.extensionFlags;
}

- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer
{
    return self.preferences.extensionSmartyPants;
}

- (BOOL)rendererRendersTOC:(MPRenderer *)renderer
{
    return self.preferences.htmlRendersTOC;
}

- (NSString *)rendererStyleName:(MPRenderer *)renderer
{
    return self.preferences.htmlStyleName;
}

- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)renderer
{
    return self.preferences.htmlDetectFrontMatter;
}

- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer
{
    return self.preferences.htmlSyntaxHighlighting;
}

- (BOOL)rendererHasMermaid:(MPRenderer *)renderer
{
    return self.preferences.htmlMermaid;
}

- (BOOL)rendererHasGraphviz:(MPRenderer *)renderer
{
    return self.preferences.htmlGraphviz;
}

- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)renderer
{
    return self.preferences.htmlCodeBlockAccessory;
}

- (BOOL)rendererHasMathJax:(MPRenderer *)renderer
{
    return self.preferences.htmlMathJax;
}

- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer
{
    return self.preferences.htmlHighlightingThemeName;
}

- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html
{
    // Copy must also work while an older preview is loading.
    if (self.copying)
    {
        self.copying = NO;
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard writeObjects:@[renderer.currentHtml]];
    }
    if (self.printing)
        return;
    if (self.alreadyRenderingInWeb || self.previewIsComposing || self.previewDefersRendering)
    {
        self.pendingPreviewHTML = html;
        self.pendingPreviewMarkdown = renderer.currentMarkdown;
        return;
    }
    [self loadPreviewHTML:html];
}

- (void)loadPreviewHTML:(NSString *)html
{
    NSString *source = self.pendingPreviewMarkdown ?: self.renderer.currentMarkdown ?: @"";
    self.pendingPreviewMarkdown = nil;
    if (![source isEqualToString:self.editor.string])
    {
        [self.renderer parseAndRenderNow];
        return;
    }
    self.loadingPreviewMarkdown = source;
    self.previewInteractionPrepared = NO;
    self.previewSourceOffset = self.renderer.currentSourceOffset;
    self.previewRendersTOC = self.renderer.currentRendersTOC;
    NSURL *baseURL = self.fileURL ?: self.preferences.htmlDefaultDirectoryUrl;
    BOOL canUpdate = !self.forcePreviewNavigation && self.isPreviewReady
        && [self.currentBaseUrl isEqual:baseURL];
    self.forcePreviewNavigation = NO;
    self.alreadyRenderingInWeb = YES;
    self.isPreviewReady = NO;
    ++self.previewGeneration;
    self.previewMetricsPending = NO;
    self.previewLayoutPending = NO;
    self.currentBaseUrl = baseURL;
    self.manualRender = self.preferences.markdownManualRender;
    // loadHTMLString does not grant WKWebView access to file resources. Load a
    // temporary file with an explicit base instead, preserving relative images,
    // user stylesheets, and bundled scripts. MacDown is an unsandboxed file editor.
    NSString *base = [self.currentBaseUrl.absoluteString ?: @"" stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    base = [base stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    html = [html stringByReplacingOccurrencesOfString:@"<head>" withString:
        [NSString stringWithFormat:@"<head><base href=\"%@\">", base]];
    if (canUpdate)
    {
        NSString *token = NSUUID.UUID.UUIDString;
        NSUInteger generation = self.previewGeneration;
        __weak MPDocument *weakSelf = self;
        [self.preview callAsyncJavaScript:
            @"if(window.__macdownPreviewMatches && !window.__macdownPreviewMatches(previous, sequence)) return 'stale';"
             "if(!window.__macdownUpdate || !window.__macdownUpdate(html, resources)) return false;"
             "window.__macdownPreviewPrepare?.(source, token, offset, toc, caret); return true;"
            arguments:@{@"html": html, @"resources": NSBundle.mainBundle.resourceURL.absoluteString,
                @"previous": self.previewEditingMarkdown ?: @"", @"sequence": @(self.previewInteractionSequence),
                @"source": source, @"token": token, @"offset": @(self.previewSourceOffset),
                @"toc": @(self.previewRendersTOC), @"caret": self.previewCaret ?: NSNull.null}
            inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld
            completionHandler:^(id result, NSError *error) {
                MPDocument *doc = weakSelf;
                if (!doc || generation != doc.previewGeneration) return;
                if ([result isKindOfClass:NSString.class] && [result isEqualToString:@"stale"])
                {
                    doc.alreadyRenderingInWeb = NO;
                    doc.isPreviewReady = YES;
                    doc.pendingPreviewHTML = nil;
                    doc.pendingPreviewMarkdown = nil;
                    [doc.renderer parseAndRenderNow];
                }
                else if (error || ![result isKindOfClass:NSNumber.class] || ![result boolValue])
                    [doc navigatePreviewHTML:html];
                else
                {
                    doc.previewEditingMarkdown = source;
                    doc.previewInteractionToken = token;
                    doc.previewInteractionSequence = 0;
                    doc.previewInteractionPrepared = YES;
                    [doc finishPreviewNavigation];
                }
            }];
        return;
    }
    [self navigatePreviewHTML:html];
}

- (void)navigatePreviewHTML:(NSString *)html
{
    NSURL *url = [self.previewDirectory URLByAppendingPathComponent:@"preview.html"];
    NSError *error = nil;
    if (![html writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error])
    {
        self.alreadyRenderingInWeb = NO;
        [self presentError:error];
        return;
    }
    [self.preview loadFileURL:url allowingReadAccessToURL:[NSURL fileURLWithPath:@"/" isDirectory:YES]];
}

#pragma mark - Notification handler

- (void)editorTextDidChange:(NSNotification *)notification
{
    if (!self.applyingPreviewEdit)
    {
        self.previewCaret = nil;
        self.previewIsComposing = NO;
        self.previewDefersRendering = NO;
        self.pendingPreviewHTML = nil;
        self.pendingPreviewMarkdown = nil;
    }
    self.editorGeometryDirty = YES;
    if (self.needsHtml)
        [self.renderer parseAndRenderLater];
}

- (void)editorLayoutDidChange:(NSNotification *)notification
{
    // The background highlighter changes font attributes after a render can
    // finish. Those changes must invalidate cached glyph positions too.
    self.editorGeometryDirty = YES;
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    MPRenderer *renderer = self.renderer;

    // Force update if we're switching from manual to auto, or renderer settings
    // changed.
    int rendererFlags = self.preferences.rendererFlags;
    if ((!self.preferences.markdownManualRender && self.manualRender)
            || renderer.rendererFlags != rendererFlags)
    {
        renderer.rendererFlags = rendererFlags;
        [renderer parseAndRenderLater];
    }
    else
    {
        [renderer parseIfPreferencesChanged];
        [renderer renderIfPreferencesChanged];
    }
}

- (void)editorFrameDidChange:(NSNotification *)notification
{
    if (self.preferences.editorWidthLimited)
        [self adjustEditorInsets];
}

- (void)willStartLiveScroll:(NSNotification *)notification
{
    [self updateHeaderLocations];
    _inLiveScroll = YES;
}

-(void)didEndLiveScroll:(NSNotification *)notification
{
    _inLiveScroll = NO;
}

- (void)editorBoundsDidChange:(NSNotification *)notification
{
    if (!self.shouldHandleBoundsChange)
        return;

    if (self.preferences.editorSyncScrolling)
    {
        @synchronized(self) {
            self.shouldHandleBoundsChange = NO;
            if(!_inLiveScroll){
                [self updateHeaderLocations];
            }
            
            [self syncScrollers];
            self.shouldHandleBoundsChange = YES;
        }
    }
}

- (void)didRequestEditorReload:(NSNotification *)notification
{
    NSString *key =
        notification.userInfo[MPDidRequestEditorSetupNotificationKeyName];
    [self setupEditor:key];
}

- (void)didRequestPreviewReload:(NSNotification *)notification
{
    [self render:nil];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context
{
    if (object == self.editor)
    {
        if (!self.highlighter.isActive)
            return;
        id value = change[NSKeyValueChangeNewKey];
        NSString *preferenceKey = MPEditorPreferenceKeyWithValueKey(keyPath);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:value forKey:preferenceKey];
    }
    else if (object == [NSUserDefaults standardUserDefaults])
    {
        if (self.highlighter.isActive)
            [self setupEditor:keyPath];
        [self redrawDivider];
    }
}


#pragma mark - IBAction

- (IBAction)copyHtml:(id)sender
{
    // Dis-select things in WebView so that it's more obvious we're NOT
    // respecting the selection range.
    [self.preview evaluateJavaScript:@"getSelection().removeAllRanges()" completionHandler:nil];

    // If the preview is hidden, the HTML are not updating on text change.
    // Perform one extra rendering so that the HTML is up to date, and do the
    // copy in the rendering callback.
    if (!self.needsHtml)
    {
        self.copying = YES;
        [self.renderer parseAndRenderNow];
        return;
    }
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[self.renderer.currentHtml]];
}

- (IBAction)exportHtml:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"html"];
    if (self.presumedFileName)
        panel.nameFieldStringValue = self.presumedFileName;

    MPExportPanelAccessoryViewController *controller =
        [[MPExportPanelAccessoryViewController alloc] init];
    controller.stylesIncluded = (BOOL)self.preferences.htmlStyleName;
    controller.highlightingIncluded = self.preferences.htmlSyntaxHighlighting;
    panel.accessoryView = controller.view;

    NSWindow *w = self.windowForSheet;
    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;
        BOOL styles = controller.stylesIncluded;
        BOOL highlighting = controller.highlightingIncluded;
        NSString *html = [self.renderer HTMLForExportWithStyles:styles
                                                   highlighting:highlighting];
        [html writeToURL:panel.URL atomically:NO encoding:NSUTF8StringEncoding
                   error:NULL];
    }];
}

- (IBAction)exportPdf:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"pdf"];
    if (self.presumedFileName)
        panel.nameFieldStringValue = self.presumedFileName;
    
    NSWindow *w = nil;
    NSArray *windowControllers = self.windowControllers;
    if (windowControllers.count > 0)
        w = [windowControllers[0] window];

    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;

        NSDictionary *settings = @{
            NSPrintJobDisposition: NSPrintSaveJob,
            NSPrintJobSavingURL: panel.URL,
        };
        [self printDocumentWithSettings:settings showPrintPanel:NO delegate:nil
                       didPrintSelector:NULL contextInfo:NULL];
    }];
}

- (IBAction)convertToH1:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:1];
}

- (IBAction)convertToH2:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:2];
}

- (IBAction)convertToH3:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:3];
}

- (IBAction)convertToH4:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:4];
}

- (IBAction)convertToH5:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:5];
}

- (IBAction)convertToH6:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:6];
}

- (IBAction)convertToParagraph:(id)sender
{
    [self.editor makeHeaderForSelectedLinesWithLevel:0];
}

- (IBAction)toggleStrong:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"**" suffix:@"**"];
}

- (IBAction)toggleEmphasis:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"*" suffix:@"*"];
}

- (IBAction)toggleInlineCode:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"`" suffix:@"`"];
}

- (IBAction)toggleStrikethrough:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"~~" suffix:@"~~"];
}

- (IBAction)toggleUnderline:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"_" suffix:@"_"];
}

- (IBAction)toggleHighlight:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"==" suffix:@"=="];
}

- (IBAction)toggleComment:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"<!--" suffix:@"-->"];
}

- (IBAction)toggleLink:(id)sender
{
    BOOL inserted = [self.editor toggleForMarkupPrefix:@"[" suffix:@"]()"];
    if (!inserted)
        return;

    NSRange selectedRange = self.editor.selectedRange;
    NSUInteger location = selectedRange.location + selectedRange.length + 2;
    selectedRange = NSMakeRange(location, 0);

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *url = [pb URLForType:NSPasteboardTypeString].absoluteString;
    if (url)
    {
        [self.editor insertText:url replacementRange:selectedRange];
        selectedRange.length = url.length;
    }
    self.editor.selectedRange = selectedRange;
}

- (IBAction)toggleImage:(id)sender
{
    BOOL inserted = [self.editor toggleForMarkupPrefix:@"![" suffix:@"]()"];
    if (!inserted)
        return;

    NSRange selectedRange = self.editor.selectedRange;
    NSUInteger location = selectedRange.location + selectedRange.length + 2;
    selectedRange = NSMakeRange(location, 0);

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *url = [pb URLForType:NSPasteboardTypeString].absoluteString;
    if (url)
    {
        [self.editor insertText:url replacementRange:selectedRange];
        selectedRange.length = url.length;
    }
    self.editor.selectedRange = selectedRange;
}

- (IBAction)toggleOrderedList:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^[0-9]+ \\S" prefix:@"1. "];
}

- (IBAction)toggleUnorderedList:(id)sender
{
    NSString *marker = self.preferences.editorUnorderedListMarker;
    [self.editor toggleBlockWithPattern:@"^[\\*\\+-] \\S" prefix:marker];
}

- (IBAction)toggleBlockquote:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^> \\S" prefix:@"> "];
}

- (IBAction)indent:(id)sender
{
    NSString *padding = @"\t";
    if (self.preferences.editorConvertTabs)
        padding = @"    ";
    [self.editor indentSelectedLinesWithPadding:padding];
}

- (IBAction)unindent:(id)sender
{
    [self.editor unindentSelectedLines];
}

- (IBAction)insertNewParagraph:(id)sender
{
    NSRange range = self.editor.selectedRange;
    NSUInteger location = range.location;
    NSUInteger length = range.length;
    NSString *content = self.editor.string;
    NSInteger newlineBefore = [content locationOfFirstNewlineBefore:location];
    NSUInteger newlineAfter =
        [content locationOfFirstNewlineAfter:location + length - 1];

    // If we are on an empty line, treat as normal return key; otherwise insert
    // two newlines.
    if (location == newlineBefore + 1 && location == newlineAfter)
        [self.editor insertNewline:self];
    else
        [self.editor insertText:@"\n\n"];
}

- (IBAction)setEditorOneQuarter:(id)sender
{
    [self setSplitViewDividerLocation:0.25];
}

- (IBAction)setEditorThreeQuarters:(id)sender
{
    [self setSplitViewDividerLocation:0.75];
}

- (IBAction)setEqualSplit:(id)sender
{
    [self setSplitViewDividerLocation:0.5];
}

- (IBAction)toggleToolbar:(id)sender
{
    [self.windowForSheet toggleToolbarShown:sender];
}

- (IBAction)togglePreviewPane:(id)sender
{
    [self toggleSplitterCollapsingEditorPane:NO];
}

- (IBAction)toggleEditorPane:(id)sender
{
    [self toggleSplitterCollapsingEditorPane:YES];
}

- (IBAction)render:(id)sender
{
    self.previewDefersRendering = NO;
    // Explicit refresh must reread same-URL stylesheet/script resources too.
    self.forcePreviewNavigation = YES;
    [self.renderer parseAndRenderLater];
}


#pragma mark - Private

- (void)toggleSplitterCollapsingEditorPane:(BOOL)forEditorPane
{
    BOOL isVisible = forEditorPane ? self.editorVisible : self.previewVisible;
    BOOL editorOnRight = self.preferences.editorOnRight;

    float targetRatio = ((forEditorPane == editorOnRight) ? 1.0 : 0.0);

    if (isVisible)
    {
        CGFloat oldRatio = self.splitView.dividerLocation;
        if (oldRatio != 0.0 && oldRatio != 1.0)
        {
            // We don't want to save these values, since they are meaningless.
            // The user should be able to switch between 100% editor and 100%
            // preview without losing the old ratio.
            self.previousSplitRatio = oldRatio;
        }
        [self setSplitViewDividerLocation:targetRatio];
    }
    else
    {
        // We have an inconsistency here, let's just go back to 0.5,
        // otherwise nothing will happen
        if (self.previousSplitRatio < 0.0)
            self.previousSplitRatio = 0.5;

        [self setSplitViewDividerLocation:self.previousSplitRatio];
    }
}

- (void)setupEditor:(NSString *)changedKey
{
    self.editorGeometryDirty = YES;
    [self.highlighter deactivate];

    if (!changedKey || [changedKey isEqualToString:@"extensionFootnotes"])
    {
        int extensions = pmh_EXT_NOTES;
        if (self.preferences.extensionFootnotes)
            extensions = pmh_EXT_NONE;
        self.highlighter.extensions = extensions;
    }

    if (!changedKey || [changedKey isEqualToString:@"editorHorizontalInset"]
            || [changedKey isEqualToString:@"editorVerticalInset"]
            || [changedKey isEqualToString:@"editorWidthLimited"]
            || [changedKey isEqualToString:@"editorMaximumWidth"])
    {
        [self adjustEditorInsets];
    }

    if (!changedKey || [changedKey isEqualToString:@"editorBaseFontInfo"]
            || [changedKey isEqualToString:@"editorStyleName"]
            || [changedKey isEqualToString:@"editorLineSpacing"])
    {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineSpacing = self.preferences.editorLineSpacing;
        self.editor.defaultParagraphStyle = [style copy];
        NSFont *font = [self.preferences.editorBaseFont copy];
        if (font)
            self.editor.font = font;
        self.editor.textColor = nil;
        self.editor.backgroundColor = [NSColor clearColor];
        self.highlighter.styles = nil;
        [self.highlighter readClearTextStylesFromTextView];

        NSString *themeName = [self.preferences.editorStyleName copy];
        if (themeName.length)
        {
            NSString *path = MPThemePathForName(themeName);
            NSString *themeString = MPReadFileOfPath(path);
            [self.highlighter applyStylesFromStylesheet:themeString
                                       withErrorHandler:
                ^(NSArray *errorMessages) {
                    self.preferences.editorStyleName = nil;
                }];
        }

        CALayer *layer = [CALayer layer];
        CGColorRef backgroundCGColor = self.editor.backgroundColor.CGColor;
        if (backgroundCGColor)
            layer.backgroundColor = backgroundCGColor;
        self.editorContainer.layer = layer;
    }
    
    if ([changedKey isEqualToString:@"editorBaseFontInfo"])
    {
        [self scaleWebview];
    }

    if (!changedKey || [changedKey isEqualToString:@"editorShowWordCount"])
    {
        if (self.preferences.editorShowWordCount)
        {
            self.wordCountWidget.hidden = NO;
            self.editorPaddingBottom.constant = 35.0;
            [self updateWordCount];
        }
        else
        {
            self.wordCountWidget.hidden = YES;
            self.editorPaddingBottom.constant = 0.0;
        }
    }

    if (!changedKey || [changedKey isEqualToString:@"editorScrollsPastEnd"])
    {
        self.editor.scrollsPastEnd = self.preferences.editorScrollsPastEnd;
        NSRect contentRect = self.editor.contentRect;
        NSSize minSize = self.editor.enclosingScrollView.contentSize;
        if (contentRect.size.height < minSize.height)
            contentRect.size.height = minSize.height;
        if (contentRect.size.width < minSize.width)
            contentRect.size.width = minSize.width;
        self.editor.frame = contentRect;
    }

    if (!changedKey)
    {
        NSClipView *contentView = self.editor.enclosingScrollView.contentView;
        contentView.postsBoundsChangedNotifications = YES;

        NSDictionary *keysAndDefaults = MPEditorKeysToObserve();
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        for (NSString *key in keysAndDefaults)
        {
            NSString *preferenceKey = MPEditorPreferenceKeyWithValueKey(key);
            id value = [defaults objectForKey:preferenceKey];
            value = value ? value : keysAndDefaults[key];
            [self.editor setValue:value forKey:key];
        }
    }

    if (!changedKey || [changedKey isEqualToString:@"editorOnRight"])
    {
        BOOL editorOnRight = self.preferences.editorOnRight;
        NSArray *subviews = self.splitView.subviews;
        if ((!editorOnRight && subviews[0] == self.previewContainer)
            || (editorOnRight && subviews[1] == self.previewContainer))
        {
            [self.splitView swapViews];
            if (!self.previewVisible && self.previousSplitRatio >= 0.0)
                self.previousSplitRatio = 1.0 - self.previousSplitRatio;

            // Need to queue this or the views won't be initialised correctly.
            // Don't really know why, but this works.
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                self.splitView.needsLayout = YES;
            }];
        }
    }

    [self.highlighter activate];
    self.editor.automaticLinkDetectionEnabled = NO;
}

- (void)adjustEditorInsets
{
    CGFloat x = self.preferences.editorHorizontalInset;
    CGFloat y = self.preferences.editorVerticalInset;
    if (self.preferences.editorWidthLimited)
    {
        CGFloat editorWidth = self.editor.frame.size.width;
        CGFloat maxWidth = self.preferences.editorMaximumWidth;
        if (editorWidth > 2 * x + maxWidth)
            x = (editorWidth - maxWidth) * 0.45;
        // We tend to expect things in an editor to shift to left a bit.
        // Hence the 0.45 instead of 0.5 (which whould feel a bit too much).
    }
    self.editor.textContainerInset = NSMakeSize(x, y);
}

- (void)redrawDivider
{
    if (!self.editorVisible)
    {
        // If the editor is not visible, detect preview's background color via
        // DOM query and use it instead. This is more expensive; we should try
        // to avoid it.
        // TODO: Is it possible to cache this until the user switches the style?
        // Will need to take account of the user MODIFIES the style without
        // switching. Complicated. This will do for now.
        __weak MPDocument *weakSelf = self;
        [self.preview evaluateJavaScript:@"getComputedStyle(document.body).backgroundColor"
            completionHandler:^(id value, NSError *error) {
                if (!weakSelf.editorVisible && [value isKindOfClass:NSString.class])
                    weakSelf.splitView.dividerColor = [NSColor colorWithHTMLName:value];
            }];
    }
    else if (!self.previewVisible)
    {
        // If the editor is visible, match its background color.
        self.splitView.dividerColor = self.editor.backgroundColor;
    }
    else
    {
        // If both sides are visible, draw a default "transparent" divider.
        // This works around the possibile problem of divider's color being too
        // similar to both the editor and preview and being obscured.
        self.splitView.dividerColor = nil;
    }
}

- (void)scaleWebview
{
    CGFloat scale = self.preferences.previewZoomRelativeToBaseFontSize
        ? self.preferences.editorBaseFontSize / 14.0 : 1.0;
    self.preview.pageZoom = scale > 0 ? scale : 1.0;
}

- (void)updateHeaderLocations
{
    if (self.previewMetricsPending || !self.isPreviewReady)
        return;
    self.previewMetricsPending = YES;
    NSUInteger generation = self.previewGeneration;
    __weak MPDocument *weakSelf = self;
    [self.preview evaluateJavaScript:@"({height: document.documentElement.scrollHeight, "
        "visible: innerHeight, headers: Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,img:only-child'), "
        "n => n.getBoundingClientRect().top + scrollY)})"
        completionHandler:^(id result, NSError *error) {
            MPDocument *doc = weakSelf;
            if (!doc || generation != doc.previewGeneration) return;
            doc.previewMetricsPending = NO;
            if (![result isKindOfClass:NSDictionary.class]) return;
            doc.previewContentHeight = [result[@"height"] doubleValue];
            doc.previewVisibleHeight = [result[@"visible"] doubleValue];
            doc.webViewHeaderLocations = result[@"headers"];
            if (doc.preferences.editorSyncScrolling) [doc syncScrollers];
            if (doc.previewLayoutPending)
            {
                doc.previewLayoutPending = NO;
                [doc updateHeaderLocations];
            }
        }];
    NSSize editorSize = self.editor.enclosingScrollView.documentView.bounds.size;
    CGFloat visibleHeight = NSHeight(self.editor.enclosingScrollView.contentView.bounds);
    if (!self.editorGeometryDirty && NSEqualSizes(editorSize, self.editorGeometrySize)
            && visibleHeight == self.editorGeometryVisibleHeight)
        return;
    self.editorGeometryDirty = NO;
    self.editorGeometrySize = editorSize;
    self.editorGeometryVisibleHeight = visibleHeight;
    NSMutableArray<NSNumber *> *locations = [NSMutableArray array];
    NSLayoutManager *layoutManager = self.editor.layoutManager;
    NSString *text = self.editor.string;
    static NSRegularExpression *dashRegex, *headerRegex, *imgRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dashRegex = [NSRegularExpression regularExpressionWithPattern:@"^[-]+$" options:0 error:NULL];
        headerRegex = [NSRegularExpression regularExpressionWithPattern:@"^#+\\s" options:0 error:NULL];
        imgRegex = [NSRegularExpression regularExpressionWithPattern:@"^!\\[[^\\]]*\\]\\([^)]*\\)$" options:0 error:NULL];
    });
    BOOL previousLineHadContent = NO;
    // Enumerate ranges in the source rather than allocating an array of every
    // line. Only likely heading/image lines need a regular-expression match.
    for (NSUInteger offset = 0; offset < text.length; ) {
        NSUInteger start, end, contentsEnd;
        [text getLineStart:&start end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(offset, 0)];
        NSRange line = NSMakeRange(start, contentsEnd - start);
        unichar first = line.length ? [text characterAtIndex:start] : 0;
        BOOL dash = first == '-' && [dashRegex numberOfMatchesInString:text options:0 range:line];
        BOOL header = (previousLineHadContent && dash)
            || (first == '#' && [headerRegex numberOfMatchesInString:text options:0 range:line])
            || (first == '!' && [imgRegex numberOfMatchesInString:text options:0 range:line]);
        if (header) {
            NSRange glyphs = [layoutManager glyphRangeForCharacterRange:line actualCharacterRange:NULL];
            NSRect rect = [layoutManager boundingRectForGlyphRange:glyphs inTextContainer:self.editor.textContainer];
            CGFloat y = NSMidY(rect);
            if (y <= editorSize.height - visibleHeight) [locations addObject:@(y)];
        }
        previousLineHadContent = line.length && !dash;
        offset = end;
    }

    _editorHeaderLocations = [locations copy];
}

- (void)syncScrollers
{
    CGFloat editorContentHeight = ceilf(NSHeight(self.editor.enclosingScrollView.documentView.bounds));
    CGFloat editorVisibleHeight = ceilf(NSHeight(self.editor.enclosingScrollView.contentView.bounds));
    CGFloat previewContentHeight = self.previewContentHeight;
    CGFloat previewVisibleHeight = self.previewVisibleHeight;
    NSInteger relativeHeaderIndex = -1; // -1 is start of document, before any other header
    CGFloat currY = NSMinY(self.editor.enclosingScrollView.contentView.bounds);
    CGFloat minY = 0;
    CGFloat maxY = 0;
    
    if (editorVisibleHeight <= 0 || previewVisibleHeight <= 0 || !self.isPreviewReady)
        return;

    // align the documents at the middle of the screen, except at top/bottom of document
    CGFloat topTaper = MAX(0, MIN(1.0, currY / editorVisibleHeight));
    CGFloat bottomTaper = 1.0 - MAX(0, MIN(1.0, (currY - editorContentHeight + 2 * editorVisibleHeight) / editorVisibleHeight));
    CGFloat adjustmentForScroll = topTaper * bottomTaper * editorVisibleHeight / 2;

    // We start by splitting our document into lines, and then searching
    // line by line for headers or images.
    for (NSNumber *headerYNum in _editorHeaderLocations) {
        CGFloat headerY = [headerYNum floatValue];
        headerY -= adjustmentForScroll;
        
        if (headerY < currY)
        {
            // The header is before our current scroll position. the closest
            // of these will be our first reference node
            relativeHeaderIndex += 1;
            minY = headerY;
        } else if (maxY == 0 && headerY < editorContentHeight - editorVisibleHeight)
        {
            // Skip any headers that are within the last screen of the editor.
            // we'll interpolate to the end of the document in that case.
            maxY = headerY;
        }
    }
    
    // Usually, we'll be scrolling between two reference nodes, but toward the end
    // of the document we'll ignore nodes and reference the end of the document instead
    BOOL interpolateToEndOfDocument = NO;
    
    if (maxY == 0)
    {
        // We only have a reference node before our current position,
        // but not after, so we'll use the end of the document.
        maxY = editorContentHeight - editorVisibleHeight + adjustmentForScroll;
        interpolateToEndOfDocument = YES;
    }

    // We are currently at currY offset, between minY and maxY, which represent
    // headers indexed by relativeHeaderIndex and relativeHeaderIndex+1.
    currY = MAX(0, currY - minY);
    maxY -= minY;
    minY -= minY;
    CGFloat percentScrolledBetweenHeaders = MAX(0, MIN(1.0, currY / MAX(1.0, maxY)));
    
    // Now that we know where the editor position is relative to two reference nodes,
    // we need to find the positions of those nodes in the HTML preview
    CGFloat topHeaderY = 0;
    CGFloat bottomHeaderY = previewContentHeight - previewVisibleHeight;
    
    // Find the Y positions in the preview window that we're scrolling between
    if (relativeHeaderIndex >= 0 && (NSInteger)[_webViewHeaderLocations count] > relativeHeaderIndex)
    {
        topHeaderY = floorf([_webViewHeaderLocations[relativeHeaderIndex] doubleValue]) - adjustmentForScroll;
    }
    
    if (!interpolateToEndOfDocument && [_webViewHeaderLocations count] > relativeHeaderIndex + 1)
    {
        bottomHeaderY = ceilf([_webViewHeaderLocations[relativeHeaderIndex + 1] doubleValue]) - adjustmentForScroll;
    }
    
    // Now we scroll percentScrolledBetweenHeaders percent between those two positions in the webview
    CGFloat previewY = topHeaderY + (bottomHeaderY - topHeaderY) * percentScrolledBetweenHeaders;
    previewY = MAX(0, MIN(previewY, MAX(0, previewContentHeight - previewVisibleHeight)));
    // Bound WebKit IPC while trackpads deliver high frequency scroll events.
    self.lastPreviewScrollTop = previewY;
    if (self.previewScrollPending) return;
    self.previewScrollPending = YES;
    __weak MPDocument *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MPDocument *doc = weakSelf;
        doc.previewScrollPending = NO;
        [doc.preview evaluateJavaScript:[NSString stringWithFormat:@"scrollTo(0, %f)",
            doc.lastPreviewScrollTop] completionHandler:nil];
    });
}

- (void)setSplitViewDividerLocation:(CGFloat)ratio
{
    BOOL wasVisible = self.previewVisible;
    [self.splitView setDividerLocation:ratio];
    if (!wasVisible && self.previewVisible
            && !self.preferences.markdownManualRender)
        [self.renderer parseAndRenderNow];
    [self setupEditor:NSStringFromSelector(@selector(editorHorizontalInset))];
}

- (NSString *)presumedFileName
{
    if (self.fileURL)
        return self.fileURL.lastPathComponent.stringByDeletingPathExtension;

    NSString *title = nil;
    NSString *string = self.editor.string;
    if (self.preferences.htmlDetectFrontMatter)
        title = [[[string frontMatter:NULL] objectForKey:@"title"] description];
    if (title)
        return title;

    title = string.titleString;
    if (!title)
        return NSLocalizedString(@"Untitled", @"default filename if no title can be determined");

    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[/|:]"
                                                          options:0 error:NULL];
    });

    NSRange range = NSMakeRange(0, title.length);
    title = [regex stringByReplacingMatchesInString:title options:0 range:range
                                       withTemplate:@"-"];
    return title;
}

- (void)updateWordCount
{
    NSUInteger generation = self.previewGeneration;
    __weak MPDocument *weakSelf = self;
    // Count the rendered text using Foundation's language-aware word enumeration.
    // Code blocks contribute characters, and inline code contributes one word.
    NSString *script = @"(() => { const words = [], chars = []; let inline = 0; "
        "function walk(n, code) { if(n.nodeType === 3) { chars.push(n.nodeValue); "
        "if(!code) words.push(n.nodeValue); return; } if(n.nodeType !== 1) return; "
        "if(['SCRIPT','STYLE','HEAD'].includes(n.tagName)) return; "
        "const c = code || n.tagName === 'CODE'; "
        "if(n.tagName === 'CODE' && n.parentElement.tagName !== 'PRE' && n.textContent.trim()) inline++; "
        "Array.from(n.childNodes).forEach(k => walk(k,c)); } walk(document.body,false); "
        "return {words: words, chars: chars.join(''), inline: inline}; })()";
    [self.preview evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        MPDocument *doc = weakSelf;
        if (!doc || generation != doc.previewGeneration || ![result isKindOfClass:NSDictionary.class]) return;
        NSUInteger words = [result[@"inline"] unsignedIntegerValue];
        for (NSString *text in result[@"words"]) words += text.numberOfWords;
        NSString *text = result[@"chars"];
        doc.totalWords = words;
        doc.totalCharacters = text.lengthWithoutNewlines;
        doc.totalCharactersNoSpaces = text.lengthWithoutWhitespacesAndNewlines;
        doc.wordCountWidget.enabled = YES;
    }];
}

- (BOOL)isCurrentBaseUrl:(NSURL *)another
{
    NSString *mine = self.currentBaseUrl.absoluteBaseURLString;
    NSString *theirs = another.absoluteBaseURLString;
    return mine == theirs || [mine isEqualToString:theirs];
}


#define OPEN_FAIL_ALERT_INFORMATIVE NSLocalizedString( \
@"Please check the path of your link is correct. Turn on \
“Automatically create link targets” If you want MacDown to \
create nonexistent link targets for you.", \
@"preview navigation error information")

#define AUTO_CREATE_FAIL_ALERT_INFORMATIVE NSLocalizedString( \
@"MacDown can’t create a file for the clicked link because \
the current file is not saved anywhere yet. Save the \
current file somewhere to enable this feature.", \
@"preview navigation error information")


- (void)openOrCreateFileForUrl:(NSURL *)url
{
    // Simply open the file if it is not local, or exists already.
    BOOL file = url.isFileURL;
    BOOL reachable = !file || [url checkResourceIsReachableAndReturnError:NULL];
    
    // If the file is local but doesn't exist, check if a file with
    // the .md extension exists.
    if (file && !reachable && [url.pathExtension isEqualToString:@""])
    {
        NSURL *markdownURL = [url URLByAppendingPathExtension:@"md"];
        if ([markdownURL checkResourceIsReachableAndReturnError:NULL])
        {
            reachable = YES;
            url = markdownURL;
        }
    }
    
    if (reachable)
    {
        [[NSWorkspace sharedWorkspace] openURL:url];
        return;
    }

    // Show an error if the user doesn't want us to create it automatically.
    if (!self.preferences.createFileForLinkTarget)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"File not found at path:\n%@",
            @"preview navigation error message");
        alert.messageText = [NSString stringWithFormat:template, url.path];
        alert.informativeText = OPEN_FAIL_ALERT_INFORMATIVE;
        [alert runModal];
        return;
    }

    // We can only create a file if the current file is saved. (Why?)
    if (!self.fileURL)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"Can’t create file:\n%@", @"preview navigation error message");
        alert.messageText = [NSString stringWithFormat:template,
                             url.lastPathComponent];
        alert.informativeText = AUTO_CREATE_FAIL_ALERT_INFORMATIVE;
        [alert runModal];
    }

    // Try to created the file.
    NSDocumentController *controller =
        [NSDocumentController sharedDocumentController];

    NSError *error = nil;
    id doc = [controller createNewEmptyDocumentForURL:url
                                              display:YES error:&error];
    if (!doc)
    {
        NSAlert *alert = [[NSAlert alloc] init];
        NSString *template = NSLocalizedString(
            @"Can’t create file:\n%@",
            @"preview navigation error message");
        alert.messageText =
            [NSString stringWithFormat:template, url.lastPathComponent];
        template = NSLocalizedString(
            @"An error occurred while creating the file:\n%@",
            @"preview navigation error information");
        alert.informativeText =
            [NSString stringWithFormat:template, error.localizedDescription];
        [alert runModal];
    }
}


- (void)document:(NSDocument *)doc didPrint:(BOOL)ok context:(void *)context
{
    if ([doc respondsToSelector:@selector(setPrinting:)])
        ((MPDocument *)doc).printing = NO;
    if (context)
    {
        NSInvocation *invocation = (__bridge_transfer NSInvocation *)context;
        if ([invocation isKindOfClass:[NSInvocation class]])
        {
            [invocation setArgument:&doc atIndex:2];
            [invocation setArgument:&ok atIndex:3];
            [invocation invoke];
        }
    }
}

@end
