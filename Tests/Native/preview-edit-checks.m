// Injected into an isolated development app, never the user's running document.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "MPRenderer.h"

static NSUserDefaults *defaults;
static NSString *suite;
static id getDefaults(id self, SEL cmd) { return defaults; }
static id ignoreRead(id self, SEL cmd, id key, id suiteName) { return nil; }
static void ignoreWrite(id self, SEL cmd, id value, id key, id suiteName) {}
static void require(BOOL condition, NSString *message) { if (!condition) { NSLog(@"PREVIEW EDIT FAILED: %@", message); exit(2); } }

@interface MPPreviewEditChecks : NSObject
@property NSDocument *document;
@property WKWebView *preview;
@property NSTextView *editor;
@property NSString *original;
@property NSString *edited;
@property NSArray *steps;
@property NSMutableArray *passed;
@property NSUInteger step;
@property double deadline;
@end
@implementation MPPreviewEditChecks
- (void)after:(double)delay run:(dispatch_block_t)block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), block);
}
- (void)js:(NSString *)script done:(void (^)(id))completion {
    [self.preview callAsyncJavaScript:script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld
        completionHandler:^(id result, NSError *error) { require(!error, error.description); completion(result); }];
}
- (void)ready:(dispatch_block_t)completion {
    require(NSProcessInfo.processInfo.systemUptime < self.deadline, @"Preview did not settle");
    MPRenderer *renderer = [self.document valueForKey:@"renderer"];
    if (![[self.document valueForKey:@"isPreviewReady"] boolValue] ||
            [[self.document valueForKey:@"alreadyRenderingInWeb"] boolValue] ||
            ![renderer.currentMarkdown isEqualToString:self.editor.string]) {
        [self after:0.02 run:^{ [self ready:completion]; }]; return;
    }
    [self js:@"return document.body.contentEditable === 'plaintext-only' && typeof window.__macdownPreviewSelection === 'function';" done:^(id result) {
        if ([result boolValue]) completion();
        else [self after:0.02 run:^{ [self ready:completion]; }];
    }];
}
- (void)pass:(NSString *)name {
    [self.passed addObject:name]; NSLog(@"PASSED %@", name);
    self.deadline = NSProcessInfo.processInfo.systemUptime + 15;
    [self ready:^{ [self next]; }];
}
- (void)waitForSelection:(NSRange)range completion:(dispatch_block_t)completion {
    require(NSProcessInfo.processInfo.systemUptime < self.deadline, @"Preview selection did not mirror in editor");
    if (NSEqualRanges(self.editor.selectedRange, range)) { completion(); return; }
    [self after:0.02 run:^{ [self waitForSelection:range completion:completion]; }];
}
- (void)next {
    if (self.step == self.steps.count) {
        [self.document close];
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"passed":self.passed} options:NSJSONWritingPrettyPrinted error:NULL];
        require([data writeToFile:NSProcessInfo.processInfo.environment[@"MACDOWN_EDIT_OUTPUT"] atomically:YES], @"Cannot save checks");
        [defaults removePersistentDomainForName:suite]; exit(0);
    }
    dispatch_block_t block = self.steps[self.step++]; block();
}
- (void)select:(NSString *)selector start:(NSUInteger)start length:(NSUInteger)length done:(void (^)(id))completion {
    NSString *argument = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[selector] options:0 error:NULL] encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"const n = document.querySelector(%@[0]).firstChild; const r = document.createRange(); r.setStart(n,%lu); r.setEnd(n,%lu); document.body.focus(); getSelection().removeAllRanges(); getSelection().addRange(r); const s = window.__macdownPreviewSelection(); return s && {start:s.start,end:s.end,text:s.text};",
        argument, start, start+length];
    [self js:script done:completion];
}
- (void)history:(NSString *)kind completion:(dispatch_block_t)completion {
    NSString *token = [self.document valueForKey:@"previewInteractionToken"];
    NSNumber *sequence = [self.document valueForKey:@"previewInteractionSequence"];
    [self.preview callAsyncJavaScript:@"window.webkit.messageHandlers.previewInteraction.postMessage({kind,token,sequence});"
        arguments:@{@"kind":kind,@"token":token,@"sequence":sequence} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld
        completionHandler:^(id result,NSError *error) { require(!error,error.description); [self after:0.3 run:completion]; }];
}
- (void)key:(NSString *)characters code:(unsigned short)code {
    [NSApp sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:self.preview.window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code]];
}
- (void)start {
    self.passed = [NSMutableArray array];
    NSString *path = NSProcessInfo.processInfo.environment[@"MACDOWN_EDIT_DOCUMENT"];
    self.original = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    for (NSDocument *doc in [NSDocumentController.sharedDocumentController.documents copy]) [doc close];
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:path] display:YES
        completionHandler:^(NSDocument *document, BOOL wasOpen, NSError *error) {
            require(document && !error, error.description ?: @"Cannot open fixture");
            self.document = document; self.preview = [document valueForKey:@"preview"]; self.editor = [document valueForKey:@"editor"];
            [NSApp activateIgnoringOtherApps:YES];
            [self.preview.window makeKeyAndOrderFront:nil];
            [self.preview.window makeFirstResponder:self.preview];
            self.steps = @[
                ^{
                    [self select:@"strong" start:0 length:4 done:^(id result) {
                        NSRange expected = [self.editor.string rangeOfString:@"bold"];
                        require(result && [result[@"start"] unsignedIntegerValue]==expected.location && [result[@"end"] unsignedIntegerValue]==NSMaxRange(expected), @"Incorrect bold source map");
                        [self waitForSelection:expected completion:^{
                            [self pass:@"precise_selection_and_inactive_editor_highlight"];
                        }];
                    }];
                },
                ^{
                    [self select:@"strong" start:0 length:4 done:^(id result) {
                        [NSApp activateIgnoringOtherApps:YES];
                        [self.preview.window makeKeyAndOrderFront:nil];
                        [self.preview.window makeFirstResponder:self.preview];
                        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:self.preview.window.windowNumber context:nil
                            characters:@"K" charactersIgnoringModifiers:@"k" isARepeat:NO keyCode:40];
                        [NSApp sendEvent:key];
                        [self after:0.4 run:^{
                            require([self.editor.string isEqualToString:[self.original stringByReplacingOccurrencesOfString:@"**bold**" withString:@"**K**"]], @"Native keyboard input did not edit Markdown");
                            require(self.document.isDocumentEdited, @"Preview edit did not mark document as modified");
                            NSString *saved = [[NSString alloc] initWithData:[self.document dataOfType:self.document.fileType error:NULL] encoding:NSUTF8StringEncoding];
                            require([saved isEqualToString:self.editor.string], @"Saved Markdown differs from preview edit");
                            [self history:@"historyUndo" completion:^{ require([self.editor.string isEqualToString:self.original], @"Keyboard edit undo failed"); [self pass:@"native_keyboard_input_and_document_save"]; }];
                        }];
                    }];
                },
                ^{
                    [self select:@"strong" start:0 length:4 done:^(id result) {
                        id<NSTextInputClient> client = ((NSView *)self.preview.window.firstResponder).inputContext.client;
                        require(client != nil, @"Preview has no native text input client");
                        [client setMarkedText:@"に" selectedRange:NSMakeRange(1,0) replacementRange:NSMakeRange(NSNotFound,0)];
                        [self after:0.08 run:^{
                            [client insertText:@"日本" replacementRange:NSMakeRange(NSNotFound,0)];
                            [self after:0.4 run:^{
                                require([self.editor.string isEqualToString:[self.original stringByReplacingOccurrencesOfString:@"**bold**" withString:@"**日本**"]], @"Composition lost or duplicated committed text");
                                [self history:@"historyUndo" completion:^{ require([self.editor.string isEqualToString:self.original], @"Composition undo failed"); [self pass:@"native_ime_composition"]; }];
                            }];
                        }];
                    }];
                },
                ^{
                    [self select:@"strong" start:0 length:4 done:^(id result) {
                        [self js:@"return window.__macdownPreviewReplace('BRAVE') && window.__macdownPreviewReplace('!');" done:^(id result) {
                            require([result boolValue], @"Optimistic typing was rejected");
                            self.edited = [self.original stringByReplacingOccurrencesOfString:@"**bold**" withString:@"**BRAVE\\!**"];
                            [self after:0.3 run:^{ require([self.editor.string isEqualToString:self.edited], @"Rapid edits lost text or formatting"); [self pass:@"rapid_preview_typing_preserves_markdown"]; }];
                        }];
                    }];
                },
                ^{
                    [self history:@"historyUndo" completion:^{
                        require(![self.editor.string isEqualToString:self.edited], @"Undo did not change source");
                        [self pass:@"native_undo"];
                    }];
                },
                ^{
                    [self history:@"historyRedo" completion:^{
                        require([self.editor.string isEqualToString:self.edited], @"Redo did not restore source");
                        [self pass:@"native_redo"];
                    }];
                },
                ^{
                    [self select:@"h1" start:5 length:2 done:^(id result) {
                        NSRange emoji = [self.editor.string rangeOfString:@"😀"];
                        require([result[@"start"] unsignedIntegerValue]==emoji.location && [result[@"end"] unsignedIntegerValue]==NSMaxRange(emoji), @"UTF-16 mapping split emoji");
                        [self js:@"return window.__macdownPreviewReplace('😎');" done:^(id result) {
                            require([result boolValue], @"Emoji replacement failed");
                            [self after:0.3 run:^{ require([self.editor.string containsString:@"Café 😎"], @"Emoji source corrupted"); [self pass:@"unicode_selection_and_edit"]; }];
                        }];
                    }];
                },
                ^{
                    [self select:@"a[href='https://example.com/link']" start:0 length:4 done:^(id result) {
                        NSRange link = [self.editor.string rangeOfString:@"[link]"];
                        require([result[@"start"] unsignedIntegerValue]==link.location+1, @"Label mapped to duplicate URL text");
                        [self js:@"return window.__macdownPreviewReplace('<b>&*');" done:^(id result) {
                            require([result boolValue], @"Literal paste failed");
                            [self after:0.3 run:^{ require([self.editor.string containsString:@"[\\<b\\>&amp;\\*](https://example.com/link)"], @"Paste changed link destination/HTML meaning"); [self pass:@"literal_paste_and_link_destination"]; }];
                        }];
                    }];
                },
                ^{
                    [self.preview evaluateJavaScript:@"({api:typeof window.__macdownPreviewReplace, bridge:typeof window.webkit.messageHandlers.previewInteraction})" completionHandler:^(id result,NSError *error) {
                        require(!error && [result[@"api"] isEqual:@"undefined"] && [result[@"bridge"] isEqual:@"undefined"], @"Document script can access mutation bridge");
                        [self pass:@"isolated_mutation_bridge"];
                    }];
                },
                ^{
                    [self select:@"strong" start:0 length:1 done:^(id result) {
                        [self.editor insertText:@"SOURCEEDIT " replacementRange:NSMakeRange(0,0)];
                        NSString *expected = [self.editor.string copy];
                        [self js:@"window.__macdownPreviewReplace('WRONG'); return true;" done:^(id result) {
                            [self after:0.35 run:^{ require([self.editor.string isEqualToString:expected], @"Stale preview overwrote newer editor text"); [self pass:@"stale_preview_mutation_rejected"]; }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = self.original;
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"h1" start:7 length:0 done:^(id result) {
                            [self key:@"\r" code:36];
                            [self after:0.3 run:^{
                                [self key:@"N" code:45];
                                [self after:0.3 run:^{ require([self.editor.string hasPrefix:@"# Café 😀\n\nN"], [@"Return lost the caret in an empty paragraph: " stringByAppendingString:self.editor.string]); [self pass:@"return_and_typing_in_new_paragraph"]; }];
                            }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = self.original;
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"li:nth-child(2)" start:4 length:0 done:^(id result) {
                            [self key:@"\r" code:36];
                            [self after:0.3 run:^{
                                [self key:@"N" code:45];
                                [self after:0.3 run:^{ require([self.editor.string containsString:@"- Next\n- N"], [@"Return lost the list marker or insertion caret: " stringByAppendingString:self.editor.string]); [self pass:@"return_continues_list_and_preserves_caret"]; }];
                            }];
                        }];
                    }];
                },
                ^{
                    [self select:@"strong" start:4 length:0 done:^(id result) {
                        [self key:@"\177" code:51];
                        [self after:0.3 run:^{ require([self.editor.string containsString:@"**bol**"], @"Backspace damaged formatting markers"); [self pass:@"native_backspace_preserves_formatting"]; }];
                    }];
                },
                ^{
                    self.editor.string = self.original;
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"strong" start:2 length:0 done:^(id result) {
                            [self key:@"\r" code:36];
                            [self after:0.04 run:^{ [self key:@"N" code:45]; }];
                            [self after:0.4 run:^{ require([self.editor.string containsString:@"**bo**\n\n**Nld**"], @"Paragraph split damaged bold formatting or lost rapid input"); [self pass:@"formatted_paragraph_split_and_rapid_input"]; }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = self.original;
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"code .token.keyword" start:0 length:5 done:^(id result) {
                            [self js:@"return window.__macdownPreviewReplace('let');" done:^(id result) {
                                require([result boolValue], @"Highlighted code is unmapped");
                                [self after:0.3 run:^{ require([self.editor.string containsString:@"```javascript\nlet x = 42;\n```"], @"Editing code damaged its fence"); [self pass:@"highlighted_code_edit_preserves_fence"]; }];
                            }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = [self.original stringByReplacingOccurrencesOfString:@"const x = 42;" withString:@"    A    B"];
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"code" start:4 length:0 done:^(id result) {
                            [self key:@"\177" code:51];
                            [self after:0.3 run:^{ require([self.editor.string containsString:@"```javascript\n   A    B\n```"], @"Code backspace removed an indentation run or fence"); [self pass:@"code_indentation_deletes_one_character"]; }];
                        }];
                    }];
                },
                ^{
                    [self select:@"th" start:0 length:4 done:^(id result) {
                        [self js:@"return window.__macdownPreviewReplace('Title|Name');" done:^(id result) {
                            require([result boolValue], @"Table cell is unmapped");
                            [self after:0.3 run:^{ require([self.editor.string containsString:@"Title\\|Name"], @"Table edit did not escape a literal separator"); [self pass:@"table_cell_edit_preserves_structure"]; }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = @"";
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self js:@"document.body.click();return true;" done:^(id result) {
                            [self key:@"N" code:45];
                            [self after:0.3 run:^{ require([self.editor.string isEqualToString:@"N"], @"Empty document could not be edited in preview"); [self pass:@"typing_in_empty_document"]; }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = self.original;
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    [self ready:^{
                        [self select:@"strong" start:0 length:4 done:^(id result) {
                            // Each gap straddles the 120 ms render debounce, so
                            // typing competes with native preview refreshes.
                            for (NSUInteger i=0; i<30; i++) [self after:i*0.125 run:^{ [self key:@"Q" code:12]; }];
                            [self after:4.2 run:^{
                                NSString *text = [@"" stringByPaddingToLength:30 withString:@"Q" startingAtIndex:0];
                                NSString *expected = [self.original stringByReplacingOccurrencesOfString:@"bold" withString:text];
                                require([self.editor.string isEqualToString:expected], @"Typing across render refreshes lost or duplicated keystrokes");
                                [self pass:@"typing_across_render_refreshes"];
                            }];
                        }];
                    }];
                },
                ^{
                    self.editor.string = [self.original stringByAppendingString:@"\n<div>Generated HTML</div>\n"];
                    [NSNotificationCenter.defaultCenter postNotificationName:NSTextDidChangeNotification object:self.editor];
                    self.deadline = NSProcessInfo.processInfo.systemUptime+15;
                    [self ready:^{
                        [self select:@"strong" start:0 length:4 done:^(id result) {
                            require(result && [result[@"start"] unsignedIntegerValue]==[self.editor.string rangeOfString:@"bold"].location, @"Safe block mapping lost around HTML");
                            [self js:@"const n=Array.from(document.querySelectorAll('div')).find(n=>n.textContent==='Generated HTML').firstChild;const r=document.createRange();r.selectNodeContents(n);getSelection().removeAllRanges();getSelection().addRange(r);return window.__macdownPreviewSelection()===null;" done:^(id result) {
                                require([result boolValue], @"Raw HTML mapped to guessed source"); [self pass:@"generated_html_fails_closed_safe_blocks_still_editable"];
                            }];
                        }];
                    }];
                },
                ^{
                    NSString *before = [self.editor.string copy];
                    NSString *token = [self.document valueForKey:@"previewInteractionToken"];
                    NSNumber *sequence = [self.document valueForKey:@"previewInteractionSequence"];
                    [self.preview callAsyncJavaScript:@"for(const start of [-1,0.5,1e20,[],null]) window.webkit.messageHandlers.previewInteraction.postMessage({kind:'replace',token,sequence,start,length:0,expected:'',replacement:'BAD'});"
                        arguments:@{@"token":token,@"sequence":sequence} inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id value,NSError *error) {
                            require(!error,error.description); [self after:0.1 run:^{ require([self.editor.string isEqualToString:before],@"Malformed bridge message mutated text"); [self pass:@"invalid_ranges_rejected"]; }];
                        }];
                }
            ];
            self.deadline = NSProcessInfo.processInfo.systemUptime+15;
            [self ready:^{ [self next]; }];
        }];
}
@end
__attribute__((constructor)) static void startChecks(void) {
    suite = [@"org.macdown.preview-edit-checks." stringByAppendingString:NSUUID.UUID.UUIDString];
    defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setVolatileDomain:@{@"htmlSyntaxHighlighting":@YES,@"htmlTaskList":@YES,@"htmlMermaid":@NO,@"htmlGraphviz":@NO,@"htmlMathJax":@NO,@"markdownManualRender":@NO,@"editorSyncScrolling":@YES,@"ApplePersistenceIgnoreState":@YES} forName:NSArgumentDomain];
    method_setImplementation(class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults)),(IMP)getDefaults);
    method_setImplementation(class_getInstanceMethod(NSUserDefaults.class,NSSelectorFromString(@"objectForKey:inSuiteNamed:")),(IMP)ignoreRead);
    method_setImplementation(class_getInstanceMethod(NSUserDefaults.class,NSSelectorFromString(@"setObject:forKey:inSuiteNamed:")),(IMP)ignoreWrite);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ static MPPreviewEditChecks *probe; probe=[MPPreviewEditChecks new];[probe start]; });
}
