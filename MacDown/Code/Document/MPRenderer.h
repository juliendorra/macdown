//
//  MPRenderer.h
//  MacDown
//
//  Created by Tzu-ping Chung  on 26/6.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>
@protocol MPRendererDataSource;
@protocol MPRendererDelegate;


typedef NS_ENUM(NSUInteger, MPCodeBlockAccessoryType)
{
    MPCodeBlockAccessoryNone = 0,
    MPCodeBlockAccessoryLanguageName,
    MPCodeBlockAccessoryCustom,
};


@interface MPRenderer : NSObject

@property (nonatomic) int rendererFlags;
@property (weak) id<MPRendererDataSource> dataSource;
@property (weak) id<MPRendererDelegate> delegate;

- (void)parseAndRenderNow;
- (void)parseAndRenderLater;
- (void)parseIfPreferencesChanged;
- (void)renderIfPreferencesChanged;
- (void)render;
- (void)cancelPendingRender;

- (NSString *)currentHtml;
// The exact source snapshot associated with currentHtml, never live editor text.
@property (nonatomic, copy, readonly) NSString *currentMarkdown;
@property (nonatomic, readonly) NSUInteger currentSourceOffset;
@property (nonatomic, readonly) BOOL currentRendersTOC;
- (NSString *)HTMLForExportWithStyles:(BOOL)withStyles
                         highlighting:(BOOL)withHighlighting;

@end


@protocol MPRendererDataSource <NSObject>

- (NSString *)rendererMarkdown:(MPRenderer *)renderer;
- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer;

@end

@protocol MPRendererDelegate <NSObject>

- (int)rendererExtensions:(MPRenderer *)renderer;
- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer;
- (BOOL)rendererRendersTOC:(MPRenderer *)renderer;
- (NSString *)rendererStyleName:(MPRenderer *)renderer;
- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)renderer;
- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer;
- (BOOL)rendererHasMermaid:(MPRenderer *)renderer;
- (BOOL)rendererHasGraphviz:(MPRenderer *)renderer;
- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)renderer;
- (BOOL)rendererHasMathJax:(MPRenderer *)renderer;
- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer;
- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html;

@end
