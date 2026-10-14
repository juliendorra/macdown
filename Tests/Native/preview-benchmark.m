// Loaded only into a separate development app process by benchmark-preview.py.
// Does not modify the user's installed app, documents, or saved preferences.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import "MPRenderer.h"

@interface NSObject (PreviewBenchmark)
- (NSPrintOperation *)printOperationWithSettings:(NSDictionary *)settings error:(NSError **)error;
- (void)render:(id)sender;
- (void)updateHeaderLocations;
- (void)render;
@end

static NSUserDefaults *isolatedDefaults;
static NSString *defaultsSuite;
static id benchmarkDefaults(id object, SEL selector) { return isolatedDefaults; }
static id ignoreSharedRead(id object, SEL selector, id key, id suite) { return nil; }
static void ignoreSharedWrite(id object, SEL selector, id value, id key, id suite) {}

static NSUInteger navigations;
static WKNavigation *(*originalLoad)(id, SEL, NSURL *, NSURL *);
static WKNavigation *countLoad(id view, SEL selector, NSURL *url, NSURL *access) {
    navigations++;
    return originalLoad(view, selector, url, access);
}
static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static double footprint(void) {
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? info.phys_footprint / 1048576.0 : -1;
}
static void require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"BENCHMARK FAILED: %@", message); exit(2); }
}

@interface MPBenchmarkOutput : NSObject
@property (strong) id original;
@property NSUInteger length;
@property NSUInteger calls;
@property BOOL forwardsOutput;
@end
@implementation MPBenchmarkOutput
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [self.original methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.original]; }
- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html {
    self.length = html.length; self.calls++;
    if (self.forwardsOutput) [self.original renderer:renderer didProduceHTMLOutput:html];
}
@end

@interface MPPreviewBenchmark : NSObject
@property (strong) NSDocument *document;
@property (strong) WKWebView *preview;
@property (strong) NSString *source;
@property (strong) NSMutableDictionary *results;
@property (strong) NSMutableArray *latencies;
@property NSUInteger iteration;
@property NSUInteger initialNavigations;
@property double deadline;
@property double started;
- (void)start;
@end
@implementation MPPreviewBenchmark
- (void)after:(double)delay run:(dispatch_block_t)block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}
- (void)waitFor:(NSString *)marker completion:(dispatch_block_t)completion {
    if(now() >= self.deadline) {
        NSLog(@"TIMEOUT ready %@ rendering %@ html length %lu",[self.document valueForKey:@"isPreviewReady"],[self.document valueForKey:@"alreadyRenderingInWeb"],(unsigned long)[[[self.document valueForKey:@"renderer"] currentHtml] length]);
        [self.preview evaluateJavaScript:@"({text:document.body.innerText,images:Array.from(document.images).map(i=>({src:i.src,width:i.naturalWidth}))})" completionHandler:^(id result,NSError *error){NSLog(@"TIMEOUT DOM %@ %@",result,error);exit(2);}];
        return;
    }
    BOOL ready = [[self.document valueForKey:@"isPreviewReady"] boolValue]
        && ![[self.document valueForKey:@"alreadyRenderingInWeb"] boolValue];
    MPRenderer *renderer = [self.document valueForKey:@"renderer"];
    if (!ready || ![renderer.currentHtml containsString:marker]) {
        [self after:0.005 run:^{ [self waitFor:marker completion:completion]; }]; return;
    }
    [self.preview callAsyncJavaScript:@"return document.body.innerText.includes(marker) && document.images[0]?.naturalWidth === 24;"
        arguments:@{@"marker":marker} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            if (error || ![result boolValue]) [self after:0.005 run:^{ [self waitFor:marker completion:completion]; }];
            else completion();
        }];
}
- (void)start {
    self.results = [NSMutableDictionary dictionary]; self.latencies = [NSMutableArray array];
    NSString *path = NSProcessInfo.processInfo.environment[@"MACDOWN_BENCHMARK_DOCUMENT"];
    self.source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    require(self.source.length > 0, @"Missing fixture");
    for (NSDocument *doc in [NSDocumentController.sharedDocumentController.documents copy]) [doc close];
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:path]
        display:YES completionHandler:^(NSDocument *doc, BOOL wasOpen, NSError *error) {
            require(doc && !error, error.description ?: @"Cannot open fixture");
            self.document = doc; self.preview = [doc valueForKey:@"preview"];
            self.deadline = now() + 15;
            [self waitFor:@"PERFMARKER0" completion:^{
                [self after:1 run:^{
                    self.results[@"loaded_app_mib"] = @(footprint());
                    // The Python parent samples all new helper processes here.
                    puts("BENCHMARK_MEMORY_READY"); fflush(stdout);
                    [self after:2 run:^{ self.initialNavigations = navigations; [self edit]; }];
                }];
            }];
        }];
}
- (void)edit {
    if (self.iteration == 22) {
        puts("BENCHMARK_MEMORY_AFTER_EDITS"); fflush(stdout);
        [self after:2 run:^{ [self measureTemplateAndScroll]; }]; return;
    }
    self.iteration++;
    NSString *marker = [NSString stringWithFormat:@"PERFMARKER%lu", (unsigned long)self.iteration];
    NSTextView *editor = [self.document valueForKey:@"editor"];
    editor.string = [self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:marker];
    self.started = now(); self.deadline = now() + 15;
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    [self waitFor:marker completion:^{
        // Include the intentional 120 ms typing debounce. Exclude two warmups.
        if (self.iteration > 2) [self.latencies addObject:@((now() - self.started)*1000)];
        [self edit];
    }];
}
- (void)measureTemplateAndScroll {
    self.results[@"edit_dom_ready_ms"] = self.latencies;
    self.results[@"edit_navigations"] = @(navigations - self.initialNavigations);
    self.results[@"edited_app_mib"] = @(footprint());
    MPRenderer *renderer = [self.document valueForKey:@"renderer"];
    MPBenchmarkOutput *output = [[MPBenchmarkOutput alloc] init]; output.original = renderer.delegate;
    renderer.delegate = (id)output;
    double start = now();
    for (NSUInteger i=0; i<200; i++) @autoreleasepool { [renderer render]; }
    self.results[@"html_assembly_200_ms"] = @((now()-start)*1000);
    require(output.length > 0, @"Empty HTML assembly"); renderer.delegate = output.original;
    start = now();
    // Measure synchronous main-thread mapping work; JS requests are async.
    for (NSUInteger i=0; i<50; i++) {
        [self.document setValue:@NO forKey:@"previewMetricsPending"];
        [self.document updateHeaderLocations];
    }
    self.results[@"scroll_mapping_50_main_thread_ms"] = @((now()-start)*1000);
    NSArray *headings=[self.document valueForKey:@"editorHeaderLocations"];
    require(headings.count > 0, @"Editor heading geometry missing");
    self.results[@"editor_heading_count"] = @(headings.count);
    self.results[@"editor_heading_positions"] = headings;
    self.results[@"editor_heading_first"] = [headings subarrayWithRange:NSMakeRange(0,MIN(3,headings.count))];
    self.results[@"editor_heading_last"] = [headings subarrayWithRange:NSMakeRange(headings.count-MIN(3,headings.count),MIN(3,headings.count))];
    NSTextView *textView=[self.document valueForKey:@"editor"];
    self.results[@"editor_document_height"] = @(NSHeight(textView.enclosingScrollView.documentView.bounds));
    self.results[@"editor_viewport_height"] = @(NSHeight(textView.enclosingScrollView.contentView.bounds));
    [self after:1 run:^{ [self checkStableNodes]; }];
}
- (void)checkStableNodes {
    [self.preview evaluateJavaScript:@"window.webkit.messageHandlers.previewScroll.postMessage({layout: []}); window.__benchmarkSentinel = 1; document.images[0].__benchmarkIdentity=1; document.querySelector('pre').__benchmarkIdentity=1; true"
        completionHandler:^(id value, NSError *error) {
            require(!error, error.description);
            NSTextView *editor = [self.document valueForKey:@"editor"];
            editor.string = [self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFSTABLE"];
            self.deadline = now() + 15;
            [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
            [self waitFor:@"PERFSTABLE" completion:^{
                [self.preview evaluateJavaScript:@"({page:window.__benchmarkSentinel===1,image:document.images[0].__benchmarkIdentity===1,code:document.querySelector('pre').__benchmarkIdentity===1,tokens:document.querySelectorAll('.token').length,tasks:Array.from(document.querySelectorAll('.task-list-item input')).every(i=>i.disabled)})"
                    completionHandler:^(id result,NSError *failure) {
                        require(!failure, failure.description); self.results[@"retained_nodes"] = result;
                        if ([self.document respondsToSelector:NSSelectorFromString(@"navigatePreviewHTML:")])
                            require([result[@"page"] boolValue] && [result[@"image"] boolValue] && [result[@"code"] boolValue], @"Fast path failed to retain page/image/code");
                        require([result[@"tokens"] integerValue] > 0, @"Code highlighting missing");
                        require([result[@"tasks"] boolValue], @"Task checkbox behavior changed");
                        [self checkRapidEdits];
                    }];
            }];
        }];
}
- (void)checkRapidEdits {
    MPRenderer *renderer = [self.document valueForKey:@"renderer"];
    MPBenchmarkOutput *output = [[MPBenchmarkOutput alloc] init];
    output.original = renderer.delegate; output.forwardsOutput = YES;
    renderer.delegate = (id)output;
    NSTextView *editor = [self.document valueForKey:@"editor"];
    for (NSUInteger i=0; i<100; i++) {
        editor.string = [NSString stringWithFormat:@"# Draft %lu",(unsigned long)i];
        [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    }
    editor.string = [self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFRAPID"];
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    self.deadline = now()+15;
    [self waitFor:@"PERFRAPID" completion:^{
        require(output.calls == 1, @"Rapid edits published stale or duplicate results");
        renderer.delegate = output.original;
        self.results[@"rapid_edits_latest_only"] = @YES; [self checkScriptFallback];
    }];
}
- (void)checkScriptFallback {
    NSUInteger previous = navigations;
    NSTextView *editor = [self.document valueForKey:@"editor"];
    editor.string = [[self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFSCRIPT"]
        stringByAppendingString:@"\n<script>window.__benchmarkCustom=(window.__benchmarkCustom||0)+1; addEventListener('load',()=>{ window.__macdownUpdate=()=>({unexpected:true}); });</script>\n"];
    self.deadline = now()+15;
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    [self waitFor:@"PERFSCRIPT" completion:^{
        require(navigations > previous, @"Custom script did not use navigation fallback");
        [self.preview evaluateJavaScript:@"window.__benchmarkCustom" completionHandler:^(id result,NSError *error) {
            require(!error && [result integerValue]==1, @"Custom script lifecycle changed");
            self.results[@"custom_script_fallback"] = @YES; [self checkLanguageChange];
        }];
    }];
}
- (void)checkLanguageChange {
    NSUInteger previous = navigations;
    NSTextView *editor = [self.document valueForKey:@"editor"];
    editor.string = [[self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFLANGUAGE"]
        stringByReplacingOccurrencesOfString:@"```javascript\nconst answer = 42;" withString:@"```ruby\nanswer = 42"];
    self.deadline = now()+15;
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    [self waitFor:@"PERFLANGUAGE" completion:^{
        require(navigations > previous, @"Changed scripts did not reload");
        [self.preview evaluateJavaScript:@"document.querySelectorAll('code.language-ruby .token').length"
            completionHandler:^(id result,NSError *error){
                require(!error && [result integerValue]>0, @"New language was not highlighted");
                self.results[@"language_change"] = @YES; [self checkInlineEvent];
            }];
    }];
}
- (void)checkInlineEvent {
    NSUInteger previous = navigations;
    NSTextView *editor = [self.document valueForKey:@"editor"];
    editor.string = [[self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFEVENT"]
        stringByAppendingString:@"\n<img src='image.svg' onload='window.__benchmarkEvent=1'>\n"];
    self.deadline = now()+15;
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    [self waitFor:@"PERFEVENT" completion:^{
        require(navigations > previous, @"Inline event did not use fallback");
        [self.preview evaluateJavaScript:@"window.__benchmarkEvent" completionHandler:^(id result,NSError *error){
            require(!error && [result integerValue]==1, @"Inline event lifecycle changed");
            self.results[@"inline_event_fallback"] = @YES; [self checkImageResize];
        }];
    }];
}
- (void)checkImageResize {
    NSTextView *editor = [self.document valueForKey:@"editor"];
    editor.string = [self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFIMAGEBASE"];
    self.deadline = now()+15;
    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
    [self waitFor:@"PERFIMAGEBASE" completion:^{
        [self.preview evaluateJavaScript:@"document.documentElement.scrollHeight" completionHandler:^(id height,NSError *error){
            require(!error, error.description);
            editor.string = [[self.source stringByReplacingOccurrencesOfString:@"PERFMARKER0" withString:@"PERFIMAGE"]
                stringByAppendingString:@"\n![Tall image](tall.svg)\n"];
            self.deadline = now()+15;
            [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:editor];
            [self waitFor:@"PERFIMAGE" completion:^{ [self waitForImageHeight:[height doubleValue]]; }];
        }];
    }];
}
- (void)waitForImageHeight:(double)previousHeight {
    require(now()<self.deadline,@"Delayed image geometry did not refresh");
    [self.preview evaluateJavaScript:@"({image:document.images[1]?.naturalHeight,height:document.documentElement.scrollHeight})"
        completionHandler:^(id result,NSError *error){
            double nativeHeight=[[self.document valueForKey:@"previewContentHeight"] doubleValue];
            if (!error && [result[@"image"] integerValue]==192 && [result[@"height"] doubleValue]>previousHeight
                    && fabs(nativeHeight-[result[@"height"] doubleValue])<1) {
                self.results[@"image_geometry_refresh"] = @YES; [self checkExplicitRefresh];
            } else [self after:0.02 run:^{ [self waitForImageHeight:previousHeight]; }];
        }];
}
- (void)checkExplicitRefresh {
    NSUInteger previous = navigations;
    [self.document render:nil];
    self.deadline = now()+15;
    [self waitForExplicitRefresh:previous];
}
- (void)waitForExplicitRefresh:(NSUInteger)previous {
    require(now()<self.deadline,@"Explicit refresh did not reload the page");
    if (navigations>previous && [[self.document valueForKey:@"isPreviewReady"] boolValue]
            && ![[self.document valueForKey:@"alreadyRenderingInWeb"] boolValue]) {
        self.results[@"explicit_refresh_navigation"] = @YES; [self finish];
    } else [self after:0.01 run:^{ [self waitForExplicitRefresh:previous]; }];
}
- (void)finish {
    NSError *error = nil;
    require([self.document printOperationWithSettings:@{} error:&error] != nil, @"Printing unavailable");
    self.results[@"print_operation"] = @YES;
    // Close with another parse queued, exercising generation cancellation.
    [[self.document valueForKey:@"renderer"] parseAndRenderLater];
    [self.document close]; self.preview = nil; self.document = nil;
    [self after:3 run:^{
        self.results[@"closed_app_mib"] = @(footprint());
        puts("BENCHMARK_MEMORY_CLOSED"); fflush(stdout);
        [self after:2 run:^{
            NSData *data = [NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:NULL];
            NSString *destination = NSProcessInfo.processInfo.environment[@"MACDOWN_BENCHMARK_OUTPUT"];
            require([data writeToFile:destination atomically:YES], @"Cannot write results");
            [isolatedDefaults removePersistentDomainForName:defaultsSuite];
            puts("BENCHMARK_PASSED"); fflush(stdout); exit(0);
        }];
    }];
}
@end

__attribute__((constructor)) static void startBenchmark(void) {
    // Redirect both regular defaults and the CLI's shared suite before AppKit
    // loads the application nib. The benchmark must not change user settings.
    defaultsSuite = [@"org.macdown.local-benchmark." stringByAppendingString:NSUUID.UUID.UUIDString];
    isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:defaultsSuite];
    [isolatedDefaults setVolatileDomain:@{
        @"htmlSyntaxHighlighting":@YES, @"htmlTaskList":@YES,
        @"htmlMermaid":@NO, @"htmlGraphviz":@NO, @"htmlMathJax":@NO,
        @"markdownManualRender":@NO, @"editorSyncScrolling":@YES,
        @"ApplePersistenceIgnoreState":@YES
    } forName:NSArgumentDomain];
    method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), (IMP)benchmarkDefaults);
    method_setImplementation(class_getInstanceMethod(NSUserDefaults.class, NSSelectorFromString(@"objectForKey:inSuiteNamed:")), (IMP)ignoreSharedRead);
    method_setImplementation(class_getInstanceMethod(NSUserDefaults.class, NSSelectorFromString(@"setObject:forKey:inSuiteNamed:")), (IMP)ignoreSharedWrite);
    Method method = class_getInstanceMethod(WKWebView.class, @selector(loadFileURL:allowingReadAccessToURL:));
    originalLoad = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)countLoad);
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),dispatch_get_main_queue(),^{
            static MPPreviewBenchmark *probe;
            probe = [[MPPreviewBenchmark alloc] init]; [probe start];
        });
    });
}
