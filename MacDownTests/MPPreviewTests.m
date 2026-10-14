#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "MPDocument.h"

@interface MPPreviewTests : XCTestCase
@end

@implementation MPPreviewTests
- (void)testPreviewLoadsRelativeImagesAndSupportsPrinting
{
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *file = [directory URLByAppendingPathComponent:@"document.md"];
    NSString *markdown = @"# Preview\n\n![Local image](image.svg)\n\nHello **world**.";
    [markdown writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='red'/></svg>"
        writeToURL:[directory URLByAppendingPathComponent:@"image.svg"] atomically:YES
        encoding:NSUTF8StringEncoding error:NULL];
    NSError *error = nil;
    MPDocument *document = [[MPDocument alloc] initWithContentsOfURL:file
        ofType:@"net.daringfireball.markdown" error:&error];
    XCTAssertNotNil(document, @"%@", error);
    [document makeWindowControllers];
    // NSDocument creates its controller lazily; force the nib to load before
    // checking the preview outlets or waiting for its navigation.
    XCTAssertNotNil(document.windowControllers.firstObject.window);
    WKWebView *preview = [document valueForKey:@"preview"];
    XCTAssertTrue([preview isKindOfClass:WKWebView.class]);
    NSPredicate *ready = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [[document valueForKey:@"isPreviewReady"] boolValue];
    }];
    [self expectationForPredicate:ready evaluatedWithObject:document handler:nil];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    XCTestExpectation *image = [self expectationWithDescription:@"Relative image loaded"];
    [preview evaluateJavaScript:@"({text: document.body.innerText, width: document.images[0].naturalWidth})"
        completionHandler:^(id result, NSError *jsError) {
            XCTAssertNil(jsError);
            XCTAssertTrue([result[@"text"] containsString:@"Hello world"]);
            XCTAssertEqual([result[@"width"] integerValue], 24);
            [image fulfill];
        }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertNotNil([document printOperationWithSettings:@{} error:&error]);
    [document close];
    [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
}
@end
