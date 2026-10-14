#import <WebKit/WebKit.h>

// WKUserContentController retains its handlers. Forward weakly so closing a
// document tears down its WebKit process and pending callbacks.
@interface MPMathJaxListener : NSObject <WKScriptMessageHandler>
@property (weak) id<WKScriptMessageHandler> target;
@end
