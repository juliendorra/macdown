//
//  DOMNode+Text.h
//  MacDown
//
//  Created by Tzu-ping Chung on 18/1.
//  Copyright (c) 2015 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSString (WordCount)
- (NSUInteger)numberOfWords;
- (NSUInteger)lengthWithoutNewlines;
- (NSUInteger)lengthWithoutWhitespacesAndNewlines;
@end
