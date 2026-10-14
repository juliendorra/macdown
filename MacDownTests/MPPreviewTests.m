#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "MPDocument.h"

@interface MPPreviewTests : XCTestCase
@end

@implementation MPPreviewTests
- (void)testPreviewSelectionAndEditingPreserveMarkdown
{
    MPDocument *document = [[MPDocument alloc] init];
    NSString *source = @"# Café 😀\n\nHello **bold** and [link](https://example.com).";
    XCTAssertTrue([document readFromData:[source dataUsingEncoding:NSUTF8StringEncoding]
        ofType:@"net.daringfireball.markdown" error:NULL]);
    [document makeWindowControllers];
    XCTAssertNotNil(document.windowControllers.firstObject.window);
    [document showWindows];
    WKWebView *preview = [document valueForKey:@"preview"];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [[document valueForKey:@"isPreviewReady"] boolValue];
    }] evaluatedWithObject:document handler:nil];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    XCTestExpectation *selection = [self expectationWithDescription:@"Preview text selected"];
    [preview callAsyncJavaScript:@"const n=document.querySelector('strong').firstChild;"
        "const r=document.createRange();r.selectNodeContents(n);getSelection().removeAllRanges();getSelection().addRange(r);"
        "const s=window.__macdownPreviewSelection();return s && {start:s.start,end:s.end};"
        arguments:@{} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result,NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqual([result[@"start"] unsignedIntegerValue], [source rangeOfString:@"bold"].location);
            [selection fulfill];
        }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    NSTextView *editor = [document valueForKey:@"editor"];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return NSEqualRanges(editor.selectedRange, [source rangeOfString:@"bold"]);
    }] evaluatedWithObject:document handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTestExpectation *edit = [self expectationWithDescription:@"Preview edit submitted"];
    [preview callAsyncJavaScript:@"return window.__macdownPreviewReplace('better');"
        arguments:@{} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id result,NSError *error) {
            XCTAssertNil(error); XCTAssertTrue([result boolValue]); [edit fulfill];
        }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    NSString *expected = [source stringByReplacingOccurrencesOfString:@"**bold**" withString:@"**better**"];
    // AppKit updates the document's change count when the undo group closes,
    // after the text storage has already received the preview edit.
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [document.markdown isEqualToString:expected] && document.isDocumentEdited;
    }] evaluatedWithObject:document handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertTrue(document.isDocumentEdited);
    XCTAssertEqualObjects([[NSString alloc] initWithData:[document dataOfType:@"net.daringfireball.markdown" error:NULL]
        encoding:NSUTF8StringEncoding], expected);
    [document close];
}

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
