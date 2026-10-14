#import <XCTest/XCTest.h>
#import "MPRenderer.h"
#import <hoedown/document.h>

@interface MPRendererTests : XCTestCase <MPRendererDataSource, MPRendererDelegate>
@property (copy) NSString *markdown;
@property (strong) MPRenderer *renderer;
@property (strong) XCTestExpectation *rendered;
@property NSUInteger renderCount;
@end

@implementation MPRendererTests
- (void)setUp
{
    [super setUp];
    self.renderer = [[MPRenderer alloc] init];
    self.renderer.dataSource = self;
    self.renderer.delegate = self;
    self.renderCount = 0;
}
- (void)tearDown
{
    [self.renderer cancelPendingRender];
    self.renderer = nil;
    [super tearDown];
}
- (void)testRapidTypingPublishesOnlyLatestMarkdown
{
    self.rendered = [self expectationWithDescription:@"Newest render"];
    for (NSUInteger i = 0; i < 100; i++) {
        self.markdown = [NSString stringWithFormat:@"# Draft %lu", (unsigned long)i];
        [self.renderer parseAndRenderLater];
    }
    self.markdown = @"# Final café 😀\n\n**Complete**";
    [self.renderer parseAndRenderNow];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(self.renderCount, 1u);
    XCTAssertTrue([self.renderer.currentHtml containsString:@"Final café 😀"]);
    XCTAssertTrue([self.renderer.currentHtml containsString:@"<strong>Complete</strong>"]);
}
- (void)testCancelledRenderDoesNotCallClosedDocument
{
    self.rendered = [self expectationWithDescription:@"No callback after close"];
    self.rendered.inverted = YES;
    self.markdown = @"# Cancel me";
    [self.renderer parseAndRenderLater];
    [self.renderer cancelPendingRender];
    [self waitForExpectationsWithTimeout:0.3 handler:nil];
    XCTAssertEqual(self.renderCount, 0u);
}
- (NSString *)rendererMarkdown:(MPRenderer *)renderer { return self.markdown; }
- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer { return @"Test"; }
- (int)rendererExtensions:(MPRenderer *)renderer { return HOEDOWN_EXT_FENCED_CODE; }
- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererRendersTOC:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererHasMermaid:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererHasGraphviz:(MPRenderer *)renderer { return NO; }
- (BOOL)rendererHasMathJax:(MPRenderer *)renderer { return NO; }
- (NSString *)rendererStyleName:(MPRenderer *)renderer { return nil; }
- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer { return nil; }
- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)renderer { return MPCodeBlockAccessoryNone; }
- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html
{
    XCTAssertTrue(NSThread.isMainThread);
    self.renderCount++;
    [self.rendered fulfill];
}
@end
