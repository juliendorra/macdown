#import <Cocoa/Cocoa.h>
#import "MPToolbarController.h"
#include <assert.h>

@interface MPToolbarCheckTarget : NSObject
@property NSUInteger calls;
@property (strong) id sender;
- (void)unindent:(id)sender;
@end
@implementation MPToolbarCheckTarget
- (void)unindent:(id)sender { self.calls++; self.sender = sender; }
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        MPToolbarController *controller = [[MPToolbarController alloc] init];
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"LocalRegression"];
        NSArray *identifiers = [controller toolbarDefaultItemIdentifiers:toolbar];
        assert(identifiers.count == 15);
        assert([identifiers.firstObject isEqualToString:@"indent-group"]);
        assert([identifiers.lastObject isEqualToString:@"layout"]);
        NSUInteger spaces = 0;
        for (NSString *identifier in identifiers) {
            if ([identifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier]) spaces++;
            assert(![identifier isEqualToString:@"comment"]);
            assert(![identifier isEqualToString:@"highlight"]);
            assert(![identifier isEqualToString:@"strikethrough"]);
        }
        assert(spaces == 5);
        for (NSUInteger i = 0; i < 100; i++)
            assert([[controller toolbarDefaultItemIdentifiers:toolbar] isEqualToArray:identifiers]);
        MPToolbarCheckTarget *target = [[MPToolbarCheckTarget alloc] init];
        controller.document = (MPDocument *)target;
        NSSegmentedControl *control = [[NSSegmentedControl alloc] init];
        control.identifier = @"indent-group";
        control.segmentCount = 3;
        control.selectedSegment = 0;
        [controller performSelector:@selector(selectedToolbarItemGroupItem:) withObject:control];
        assert(target.calls == 1 && target.sender == control);
        control.selectedSegment = 2; // Not an item in the two-item toolbar group.
        [controller performSelector:@selector(selectedToolbarItemGroupItem:) withObject:control];
        assert(target.calls == 1);
        control.selectedSegment = -1;
        [controller performSelector:@selector(selectedToolbarItemGroupItem:) withObject:control];
        assert(target.calls == 1);
        puts("Local AppKit toolbar checks passed (101 constructions, action dispatch, bounds sanitizers).");
    }
    return 0;
}
