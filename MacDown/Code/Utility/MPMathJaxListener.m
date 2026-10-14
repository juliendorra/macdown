#import "MPMathJaxListener.h"

@implementation MPMathJaxListener
- (void)userContentController:(WKUserContentController *)controller
     didReceiveScriptMessage:(WKScriptMessage *)message
{
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end
