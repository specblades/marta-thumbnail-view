#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#include <math.h>
#include "lauxlib.h"

@class MartaThumbnailOverlayController;

static NSMapTable<NSWindow *, MartaThumbnailOverlayController *> *activeControllers;
static NSView *FindHeaderViewForScrollView(NSScrollView *scrollView);
static const CGFloat MartaThumbnailPercentBaseCellWidth = 156.0;
static const CGFloat MartaThumbnailMinPercent = 0.50;
static const CGFloat MartaThumbnailDefaultPercent = 0.80;
static const CGFloat MartaThumbnailMaxPercent = 1.50;
static const CGFloat MartaThumbnailDefaultCellWidth = MartaThumbnailPercentBaseCellWidth * MartaThumbnailDefaultPercent;
static const CGFloat MartaThumbnailContentPadding = 8.0;
static NSString * const MartaThumbnailCellWidthDefaultsKey = @"com.csaturnus.marta.thumbnailviewer.cellWidth.v2";
static NSString * const MartaThumbnailFolderModesDefaultsKey = @"com.csaturnus.marta.thumbnailviewer.folderModes.v1";
static CGFloat MartaThumbnailCurrentCellWidth = MartaThumbnailDefaultCellWidth;

static CGFloat ClampThumbnailCellWidth(CGFloat value) {
    return MIN(MAX(value, MartaThumbnailPercentBaseCellWidth * MartaThumbnailMinPercent), MartaThumbnailPercentBaseCellWidth * MartaThumbnailMaxPercent);
}

static CGFloat ThumbnailCellHeightForWidth(CGFloat width) {
    return MAX(114.0, floor(width + 36.0));
}

@interface MartaThumbItem : NSObject
@property(nonatomic) NSInteger modelIndex;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL isFolder;
@property(nonatomic) BOOL isFile;
@property(nonatomic) BOOL isPackage;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL current;
@property(nonatomic) unsigned long long fileSize;
@property(nonatomic) NSTimeInterval modifiedTime;
@property(nonatomic) BOOL metadataLoaded;
@end

@implementation MartaThumbItem
@end

@interface MartaQuickLookItem : NSObject <QLPreviewItem>
@property(nonatomic, strong) NSURL *previewItemURL;
@property(nonatomic, strong) NSString *previewItemTitle;
@end

@implementation MartaQuickLookItem
@end

@interface MartaQuickLookDataSource : NSObject <QLPreviewPanelDataSource, QLPreviewPanelDelegate>
@property(nonatomic, copy) NSArray<MartaQuickLookItem *> *items;
@end

@implementation MartaQuickLookDataSource

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(__unused QLPreviewPanel *)panel {
    return (NSInteger)self.items.count;
}

- (id<QLPreviewItem>)previewPanel:(__unused QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return nil;
    }

    return self.items[index];
}

@end

@interface MartaThumbCallbacks : NSObject
@property(nonatomic) lua_State *L;
@property(nonatomic) int selectRef;
@property(nonatomic) int openRef;
@property(nonatomic) int actionRef;
@property(nonatomic) int closeRef;
@property(nonatomic) int refreshRef;
- (void)callSelectIndex:(NSInteger)index mode:(NSString *)mode anchor:(NSInteger)anchor;
- (void)callOpenIndex:(NSInteger)index;
- (void)callAction:(NSString *)actionId;
- (void)callCloseReason:(NSString *)reason;
- (void)callRefresh;
- (void)invalidate;
@end

@implementation MartaThumbCallbacks

- (instancetype)init {
    self = [super init];
    if (self) {
        _selectRef = LUA_NOREF;
        _openRef = LUA_NOREF;
        _actionRef = LUA_NOREF;
        _closeRef = LUA_NOREF;
        _refreshRef = LUA_NOREF;
    }
    return self;
}

- (void)callRef:(int)ref args:(void (^)(lua_State *L))args {
    lua_State *state = self.L;
    if (state == NULL || ref == LUA_NOREF || ref == LUA_REFNIL) {
        return;
    }

    lua_rawgeti(state, LUA_REGISTRYINDEX, ref);
    int topBeforeArgs = lua_gettop(state);
    args(state);
    int argCount = lua_gettop(state) - topBeforeArgs;
    if (lua_pcall(state, argCount, 0, 0) != LUA_OK) {
        const char *error = lua_tostring(state, -1);
        NSLog(@"Marta Thumbnail Viewer Lua callback failed: %s", error ?: "(unknown)");
        lua_pop(state, 1);
    }
}

- (void)callSelectIndex:(NSInteger)index mode:(NSString *)mode anchor:(NSInteger)anchor {
    [self callRef:self.selectRef args:^(lua_State *L) {
        lua_pushinteger(L, index);
        lua_pushstring(L, mode.UTF8String);
        lua_pushinteger(L, anchor);
    }];
}

- (void)callOpenIndex:(NSInteger)index {
    [self callRef:self.openRef args:^(lua_State *L) {
        lua_pushinteger(L, index);
    }];
}

- (void)callAction:(NSString *)actionId {
    [self callRef:self.actionRef args:^(lua_State *L) {
        lua_pushstring(L, actionId.UTF8String);
    }];
}

- (void)callCloseReason:(NSString *)reason {
    [self callRef:self.closeRef args:^(lua_State *L) {
        lua_pushstring(L, reason.UTF8String);
    }];
}

- (void)callRefresh {
    [self callRef:self.refreshRef args:^(__unused lua_State *L) {}];
}

- (void)invalidate {
    if (self.L == NULL) {
        return;
    }

    if (self.selectRef != LUA_NOREF) {
        luaL_unref(self.L, LUA_REGISTRYINDEX, self.selectRef);
    }
    if (self.openRef != LUA_NOREF) {
        luaL_unref(self.L, LUA_REGISTRYINDEX, self.openRef);
    }
    if (self.actionRef != LUA_NOREF) {
        luaL_unref(self.L, LUA_REGISTRYINDEX, self.actionRef);
    }
    if (self.closeRef != LUA_NOREF) {
        luaL_unref(self.L, LUA_REGISTRYINDEX, self.closeRef);
    }
    if (self.refreshRef != LUA_NOREF) {
        luaL_unref(self.L, LUA_REGISTRYINDEX, self.refreshRef);
    }

    self.L = NULL;
    self.selectRef = LUA_NOREF;
    self.openRef = LUA_NOREF;
    self.actionRef = LUA_NOREF;
    self.closeRef = LUA_NOREF;
    self.refreshRef = LUA_NOREF;
}

- (void)dealloc {
    [self invalidate];
}

@end

@interface MartaThumbnailGridView : NSView <NSDraggingSource>
@property(nonatomic, copy) NSArray<MartaThumbItem *> *items;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *cache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *placeholderCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, QLThumbnailGenerationRequest *> *thumbnailRequests;
@property(nonatomic, strong) NSMutableSet<NSString *> *failedThumbnailKeys;
@property(nonatomic, weak) MartaThumbCallbacks *callbacks;
@property(nonatomic, weak) MartaThumbnailOverlayController *controller;
@property(nonatomic) CGFloat cellWidth;
@property(nonatomic) CGFloat cellHeight;
@property(nonatomic) CGFloat padding;
@property(nonatomic) NSInteger anchorVisualIndex;
@property(nonatomic) NSInteger mouseDownVisualIndex;
@property(nonatomic) NSPoint mouseDownPoint;
@property(nonatomic, copy) NSString *sortColumn;
@property(nonatomic) BOOL sortAscending;
- (void)applyCellWidth:(CGFloat)cellWidth;
- (void)replaceItems:(NSArray<MartaThumbItem *> *)items;
- (void)cancelThumbnailRequests;
- (void)sortByColumn:(NSString *)column;
- (void)togglePreview;
@end

@interface MartaThumbnailOverlayController : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSResponder *previousResponder;
@property(nonatomic, weak) NSScrollView *targetScrollView;
@property(nonatomic, weak) NSTableView *targetTable;
@property(nonatomic, strong) NSView *containerView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) MartaThumbnailGridView *gridView;
@property(nonatomic, strong) NSView *sizeBar;
@property(nonatomic, strong) NSSlider *sizeSlider;
@property(nonatomic, strong) NSTextField *sizeLabel;
@property(nonatomic, strong) MartaThumbCallbacks *callbacks;
@property(nonatomic, strong) MartaQuickLookDataSource *quickLookDataSource;
@property(nonatomic, strong) id targetFrameObserver;
@property(nonatomic, strong) id windowResizeObserver;
@property(nonatomic, strong) id headerClickMonitor;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL suppressHeaderMouseUp;
- (void)closeWithReason:(NSString *)reason;
- (void)close;
- (void)syncFrame;
- (void)layoutOverlayContents;
- (void)installHeaderClickMonitor;
- (void)sizeSliderChanged:(NSSlider *)sender;
- (void)toggleQuickLookForItems:(NSArray<MartaThumbItem *> *)items currentItem:(MartaThumbItem *)currentItem;
@end

@implementation MartaThumbnailGridView

- (instancetype)initWithItems:(NSArray<MartaThumbItem *> *)items callbacks:(MartaThumbCallbacks *)callbacks {
    self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)];
    if (self) {
        _items = [items copy];
        _callbacks = callbacks;
        _cache = [NSMutableDictionary dictionary];
        _placeholderCache = [NSMutableDictionary dictionary];
        _thumbnailRequests = [NSMutableDictionary dictionary];
        _failedThumbnailKeys = [NSMutableSet set];
        _cellWidth = ClampThumbnailCellWidth(MartaThumbnailCurrentCellWidth);
        _cellHeight = ThumbnailCellHeightForWidth(_cellWidth);
        _padding = MartaThumbnailContentPadding;
        _anchorVisualIndex = [self initialCurrentVisualIndex];
        _mouseDownVisualIndex = -1;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (void)dealloc {
    [self cancelThumbnailRequests];
}

- (void)applyCellWidth:(CGFloat)cellWidth {
    CGFloat nextWidth = ClampThumbnailCellWidth(cellWidth);
    if (fabs(self.cellWidth - nextWidth) < 0.5) {
        return;
    }

    self.cellWidth = nextWidth;
    self.cellHeight = ThumbnailCellHeightForWidth(nextWidth);
    [self cancelThumbnailRequests];
    [self.cache removeAllObjects];
    [self.placeholderCache removeAllObjects];
    [self.failedThumbnailKeys removeAllObjects];
    [self updateDocumentHeightForWidth:self.bounds.size.width];
    self.needsDisplay = YES;
}

- (void)replaceItems:(NSArray<MartaThumbItem *> *)items {
    self.items = [items copy];
    self.anchorVisualIndex = [self initialCurrentVisualIndex];
    self.mouseDownVisualIndex = -1;
    [self updateDocumentHeightForWidth:self.bounds.size.width];
    self.needsDisplay = YES;

    NSInteger current = [self currentVisualIndex];
    if (current >= 0) {
        [self scrollRectToVisible:[self tileRectForVisualIndex:current]];
    }
}

- (void)loadMetadataForItem:(MartaThumbItem *)item {
    if (item.metadataLoaded) {
        return;
    }

    NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:item.path error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    NSDate *modifiedDate = attributes[NSFileModificationDate];
    item.fileSize = fileSize != nil ? fileSize.unsignedLongLongValue : 0;
    item.modifiedTime = modifiedDate != nil ? modifiedDate.timeIntervalSinceReferenceDate : 0;
    item.metadataLoaded = YES;
}

- (NSComparisonResult)compareItem:(MartaThumbItem *)left
                           toItem:(MartaThumbItem *)right
                           column:(NSString *)column
                        ascending:(BOOL)ascending {
    if (left.isFolder != right.isFolder) {
        return left.isFolder ? NSOrderedAscending : NSOrderedDescending;
    }

    NSComparisonResult result = NSOrderedSame;
    if ([column isEqualToString:@"extension"]) {
        NSString *leftExtension = left.path.pathExtension.lowercaseString ?: @"";
        NSString *rightExtension = right.path.pathExtension.lowercaseString ?: @"";
        result = [leftExtension localizedCaseInsensitiveCompare:rightExtension];
    } else if ([column isEqualToString:@"size"]) {
        [self loadMetadataForItem:left];
        [self loadMetadataForItem:right];
        if (left.fileSize < right.fileSize) {
            result = NSOrderedAscending;
        } else if (left.fileSize > right.fileSize) {
            result = NSOrderedDescending;
        }
    } else if ([column isEqualToString:@"modified"]) {
        [self loadMetadataForItem:left];
        [self loadMetadataForItem:right];
        if (left.modifiedTime < right.modifiedTime) {
            result = NSOrderedAscending;
        } else if (left.modifiedTime > right.modifiedTime) {
            result = NSOrderedDescending;
        }
    } else {
        result = [left.name localizedCaseInsensitiveCompare:right.name];
    }

    if (result == NSOrderedSame) {
        result = [left.name localizedCaseInsensitiveCompare:right.name];
    }
    if (result == NSOrderedSame) {
        result = [left.path localizedCaseInsensitiveCompare:right.path];
    }

    if (!ascending && left.isFolder == right.isFolder) {
        result = -result;
    }
    return result;
}

- (void)sortByColumn:(NSString *)column {
    if (column.length == 0) {
        column = @"name";
    }

    BOOL ascending;
    if ([self.sortColumn isEqualToString:column]) {
        ascending = !self.sortAscending;
    } else if ([column isEqualToString:@"modified"] || [column isEqualToString:@"size"]) {
        ascending = NO;
    } else {
        ascending = YES;
    }

    self.sortColumn = column;
    self.sortAscending = ascending;
    self.items = [self.items sortedArrayUsingComparator:^NSComparisonResult(MartaThumbItem *left, MartaThumbItem *right) {
        return [self compareItem:left toItem:right column:column ascending:ascending];
    }];

    NSInteger current = [self currentVisualIndex];
    self.anchorVisualIndex = current;
    self.mouseDownVisualIndex = -1;
    [self updateDocumentHeightForWidth:self.bounds.size.width];
    self.needsDisplay = YES;
    if (current >= 0) {
        [self scrollRectToVisible:[self tileRectForVisualIndex:current]];
    }
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    self.needsDisplay = YES;
    return YES;
}

- (BOOL)resignFirstResponder {
    self.needsDisplay = YES;
    return YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateDocumentHeightForWidth:newSize.width];
}

- (NSInteger)initialCurrentVisualIndex {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if (self.items[i].current) {
            return i;
        }
    }
    return self.items.count > 0 ? 0 : -1;
}

- (NSInteger)currentVisualIndex {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if (self.items[i].current) {
            return i;
        }
    }
    return self.items.count > 0 ? 0 : -1;
}

- (NSInteger)columnsForWidth:(CGFloat)width {
    return MAX(1, (NSInteger)floor(MAX(width, self.cellWidth) / self.cellWidth));
}

- (void)updateDocumentHeightForWidth:(CGFloat)width {
    NSInteger columns = [self columnsForWidth:width];
    NSInteger rows = ((NSInteger)self.items.count + columns - 1) / columns;
    CGFloat height = MAX(self.enclosingScrollView.contentSize.height, rows * self.cellHeight + self.padding);
    if (fabs(self.frame.size.height - height) > 1) {
        [super setFrameSize:NSMakeSize(width, height)];
    }
}

- (NSRect)tileRectForVisualIndex:(NSInteger)index {
    NSInteger columns = [self columnsForWidth:self.bounds.size.width];
    NSInteger row = index / columns;
    NSInteger column = index % columns;
    return NSMakeRect(column * self.cellWidth + 4, row * self.cellHeight + 4, self.cellWidth - 8, self.cellHeight - 8);
}

- (NSInteger)visualIndexAtPoint:(NSPoint)point {
    if (point.x < 0 || point.y < 0) {
        return -1;
    }

    NSInteger columns = [self columnsForWidth:self.bounds.size.width];
    NSInteger column = point.x / self.cellWidth;
    NSInteger row = point.y / self.cellHeight;
    NSInteger index = row * columns + column;
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return -1;
    }

    return index;
}

- (NSString *)thumbnailCacheKeyForPath:(NSString *)path maxSize:(CGFloat)maxSize {
    return [NSString stringWithFormat:@"%@|%ld", path ?: @"", (long)llround(maxSize)];
}

- (NSRect)tileRectForPath:(NSString *)path {
    for (NSInteger index = 0; index < (NSInteger)self.items.count; index++) {
        if ([self.items[index].path isEqualToString:path]) {
            return [self tileRectForVisualIndex:index];
        }
    }

    return NSZeroRect;
}

- (BOOL)containsItemPath:(NSString *)path {
    for (MartaThumbItem *item in self.items) {
        if ([item.path isEqualToString:path]) {
            return YES;
        }
    }

    return NO;
}

- (void)cancelThumbnailRequests {
    for (QLThumbnailGenerationRequest *request in self.thumbnailRequests.allValues) {
        [QLThumbnailGenerator.sharedGenerator cancelRequest:request];
    }
    [self.thumbnailRequests removeAllObjects];
}

- (NSImage *)scaledThumbnailFromImage:(NSImage *)source maxSize:(CGFloat)maxSize {
    if (source == nil) {
        return nil;
    }

    NSSize sourceSize = source.size;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
        sourceSize = NSMakeSize(maxSize, maxSize);
    }

    CGFloat scale = MIN(maxSize / sourceSize.width, maxSize / sourceSize.height);
    NSSize targetSize = NSMakeSize(MAX(1, floor(sourceSize.width * scale)),
                                   MAX(1, floor(sourceSize.height * scale)));

    NSImage *thumb = [[NSImage alloc] initWithSize:targetSize];
    [thumb lockFocus];
    [source drawInRect:NSMakeRect(0, 0, targetSize.width, targetSize.height)
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:YES
                 hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    [thumb unlockFocus];

    return thumb;
}

- (NSImage *)placeholderThumbnailForItem:(MartaThumbItem *)item maxSize:(CGFloat)maxSize {
    NSString *key = [@"icon|" stringByAppendingString:[self thumbnailCacheKeyForPath:item.path maxSize:maxSize]];
    NSImage *cached = self.placeholderCache[key];
    if (cached != nil) {
        return cached;
    }

    NSImage *thumb = [self scaledThumbnailFromImage:[NSWorkspace.sharedWorkspace iconForFile:item.path] maxSize:maxSize];
    if (thumb != nil) {
        self.placeholderCache[key] = thumb;
    }
    return thumb;
}

- (void)requestQuickLookThumbnailForItem:(MartaThumbItem *)item maxSize:(CGFloat)maxSize key:(NSString *)key {
    if (!item.isFile || item.path.length == 0 || self.thumbnailRequests[key] != nil || [self.failedThumbnailKeys containsObject:key]) {
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:item.path];
    NSScreen *screen = NSScreen.mainScreen;
    CGFloat backingScale = screen != nil ? screen.backingScaleFactor : 2.0;
    CGFloat requestDimension = MAX(1.0, ceil(maxSize));
    CGSize requestSize = CGSizeMake(requestDimension, requestDimension);
    QLThumbnailGenerationRequestRepresentationTypes types =
        QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail |
        QLThumbnailGenerationRequestRepresentationTypeThumbnail;

    QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url
                                                                                                size:requestSize
                                                                                               scale:backingScale
                                                                                 representationTypes:types];
    request.iconMode = NO;
    self.thumbnailRequests[key] = request;

    NSString *path = [item.path copy];
    __weak MartaThumbnailGridView *weakSelf = self;
    [QLThumbnailGenerator.sharedGenerator generateRepresentationsForRequest:request
                                                              updateHandler:^(QLThumbnailRepresentation * _Nullable thumbnail,
                                                                              QLThumbnailRepresentationType type,
                                                                              __unused NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MartaThumbnailGridView *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.thumbnailRequests[key] != request || ![strongSelf containsItemPath:path]) {
                return;
            }

            NSImage *source = thumbnail.NSImage;
            if (source != nil) {
                NSImage *scaled = [strongSelf scaledThumbnailFromImage:source maxSize:maxSize];
                if (scaled != nil) {
                    strongSelf.cache[key] = scaled;
                    NSRect dirtyRect = [strongSelf tileRectForPath:path];
                    if (!NSEqualRects(dirtyRect, NSZeroRect)) {
                        [strongSelf setNeedsDisplayInRect:dirtyRect];
                    }
                }
            }

            if (type == QLThumbnailRepresentationTypeThumbnail) {
                if (thumbnail == nil) {
                    [strongSelf.failedThumbnailKeys addObject:key];
                }
                [strongSelf.thumbnailRequests removeObjectForKey:key];
            }
        });
    }];
}

- (NSImage *)thumbnailForItem:(MartaThumbItem *)item maxSize:(CGFloat)maxSize {
    NSString *key = [self thumbnailCacheKeyForPath:item.path maxSize:maxSize];
    NSImage *cached = self.cache[key];
    if (cached != nil) {
        return cached;
    }

    [self requestQuickLookThumbnailForItem:item maxSize:maxSize key:key];
    return [self placeholderThumbnailForItem:item maxSize:maxSize];
}

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirtyRect);

    if (self.items.count == 0) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        [@"No items" drawAtPoint:NSMakePoint(20, 20) withAttributes:attrs];
        return;
    }

    CGFloat thumbMax = self.cellWidth - self.padding * 2;
    NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
    center.alignment = NSTextAlignmentCenter;
    center.lineBreakMode = NSLineBreakByTruncatingMiddle;

    for (NSInteger index = 0; index < (NSInteger)self.items.count; index++) {
        if (!NSIntersectsRect(dirtyRect, [self tileRectForVisualIndex:index])) {
            continue;
        }

        MartaThumbItem *item = self.items[index];
        NSRect tileRect = [self tileRectForVisualIndex:index];

        if (item.selected) {
            NSBezierPath *selected = [NSBezierPath bezierPathWithRoundedRect:tileRect xRadius:7 yRadius:7];
            [NSColor.selectedContentBackgroundColor setFill];
            [selected fill];
        } else if (item.current && self.window.firstResponder == self) {
            NSBezierPath *current = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tileRect, 1.5, 1.5) xRadius:7 yRadius:7];
            [NSColor.keyboardFocusIndicatorColor setStroke];
            current.lineWidth = 2;
            [current stroke];
        }

        NSImage *thumb = [self thumbnailForItem:item maxSize:thumbMax];
        if (thumb != nil) {
            CGFloat imageX = NSMidX(tileRect) - thumb.size.width / 2;
            CGFloat imageY = tileRect.origin.y + 8 + (thumbMax - thumb.size.height) / 2;
            [thumb drawInRect:NSMakeRect(imageX, imageY, thumb.size.width, thumb.size.height)];
        }

        NSDictionary *textAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: item.selected ? NSColor.selectedControlTextColor : NSColor.labelColor,
            NSParagraphStyleAttributeName: center
        };
        NSRect textRect = NSMakeRect(tileRect.origin.x + 5,
                                     tileRect.origin.y + thumbMax + 16,
                                     tileRect.size.width - 10,
                                     34);
        [item.name drawInRect:textRect withAttributes:textAttributes];
    }
}

- (void)notifySelectionForVisualIndex:(NSInteger)visualIndex mode:(NSString *)mode {
    if (visualIndex < 0 || visualIndex >= (NSInteger)self.items.count) {
        return;
    }

    NSInteger anchorModelIndex = self.items[MAX(0, self.anchorVisualIndex)].modelIndex;
    MartaThumbItem *item = self.items[visualIndex];
    [self.callbacks callSelectIndex:item.modelIndex mode:mode anchor:anchorModelIndex];
}

- (void)setSelectionToVisualIndex:(NSInteger)visualIndex mode:(NSString *)mode notify:(BOOL)notify {
    if (visualIndex < 0 || visualIndex >= (NSInteger)self.items.count) {
        return;
    }

    if ([mode isEqualToString:@"extend"] && self.anchorVisualIndex >= 0) {
        NSInteger from = MIN(self.anchorVisualIndex, visualIndex);
        NSInteger to = MAX(self.anchorVisualIndex, visualIndex);
        for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
            self.items[i].selected = (i >= from && i <= to);
            self.items[i].current = (i == visualIndex);
        }
    } else if ([mode isEqualToString:@"toggle"]) {
        for (MartaThumbItem *item in self.items) {
            item.current = NO;
        }
        self.items[visualIndex].selected = !self.items[visualIndex].selected;
        self.items[visualIndex].current = YES;
        self.anchorVisualIndex = visualIndex;
    } else {
        for (MartaThumbItem *item in self.items) {
            item.selected = NO;
            item.current = NO;
        }
        self.items[visualIndex].selected = YES;
        self.items[visualIndex].current = YES;
        self.anchorVisualIndex = visualIndex;
        mode = @"single";
    }

    [self scrollRectToVisible:[self tileRectForVisualIndex:visualIndex]];
    self.needsDisplay = YES;

    if (notify) {
        [self notifySelectionForVisualIndex:visualIndex mode:mode];
    }
}

- (NSArray<NSNumber *> *)selectedVisualIndices {
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if (self.items[i].selected) {
            [indices addObject:@(i)];
        }
    }

    if (indices.count == 0) {
        NSInteger current = [self currentVisualIndex];
        if (current >= 0) {
            [indices addObject:@(current)];
        }
    }

    return indices;
}

- (void)togglePreview {
    NSArray<NSNumber *> *selectedIndices = [self selectedVisualIndices];
    if (selectedIndices.count == 0) {
        return;
    }

    NSMutableArray<MartaThumbItem *> *previewItems = [NSMutableArray array];
    NSInteger currentVisualIndex = [self currentVisualIndex];
    MartaThumbItem *currentItem = nil;

    for (NSNumber *number in selectedIndices) {
        NSInteger visualIndex = number.integerValue;
        if (visualIndex < 0 || visualIndex >= (NSInteger)self.items.count) {
            continue;
        }

        MartaThumbItem *item = self.items[visualIndex];
        [previewItems addObject:item];
        if (visualIndex == currentVisualIndex) {
            currentItem = item;
        }
    }

    if (currentItem == nil && previewItems.count > 0) {
        currentItem = previewItems.firstObject;
    }

    if (currentVisualIndex >= 0 && currentVisualIndex < (NSInteger)self.items.count) {
        [self notifySelectionForVisualIndex:currentVisualIndex mode:@"single"];
    }

    [self.controller toggleQuickLookForItems:previewItems currentItem:currentItem];
}

- (void)mouseDown:(NSEvent *)event {
    [[self window] makeFirstResponder:self];

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger visualIndex = [self visualIndexAtPoint:point];
    self.mouseDownPoint = point;
    self.mouseDownVisualIndex = visualIndex;

    if (visualIndex < 0) {
        return;
    }

    BOOL extend = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    BOOL toggle = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    NSString *mode = toggle ? @"toggle" : (extend ? @"extend" : @"single");
    [self setSelectionToVisualIndex:visualIndex mode:mode notify:YES];

    if (event.clickCount >= 2) {
        [self.callbacks callOpenIndex:self.items[visualIndex].modelIndex];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    [[self window] makeFirstResponder:self];

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger visualIndex = [self visualIndexAtPoint:point];
    if (visualIndex >= 0) {
        [self setSelectionToVisualIndex:visualIndex mode:@"single" notify:YES];
    }

    [self.callbacks callAction:@"core.context.menu"];
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.mouseDownVisualIndex < 0 || self.mouseDownVisualIndex >= (NSInteger)self.items.count) {
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - self.mouseDownPoint.x;
    CGFloat dy = point.y - self.mouseDownPoint.y;
    if (sqrt(dx * dx + dy * dy) < 4) {
        return;
    }

    NSMutableArray<NSDraggingItem *> *dragItems = [NSMutableArray array];
    for (NSNumber *number in [self selectedVisualIndices]) {
        NSInteger visualIndex = number.integerValue;
        MartaThumbItem *item = self.items[visualIndex];
        NSURL *url = [NSURL fileURLWithPath:item.path];
        NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
        NSRect dragFrame = NSInsetRect([self tileRectForVisualIndex:visualIndex], 26, 36);
        NSImage *image = [self thumbnailForItem:item maxSize:72] ?: [NSWorkspace.sharedWorkspace iconForFile:item.path];
        [dragItem setDraggingFrame:dragFrame contents:image];
        [dragItems addObject:dragItem];
    }

    if (dragItems.count > 0) {
        [self beginDraggingSessionWithItems:dragItems event:event source:self];
    }
    self.mouseDownVisualIndex = -1;
}

- (NSDragOperation)draggingSession:(__unused NSDraggingSession *)session
 sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextOutsideApplication ? NSDragOperationCopy : (NSDragOperationCopy | NSDragOperationMove);
}

- (void)moveCurrentBy:(NSInteger)delta extending:(BOOL)extending {
    NSInteger current = [self currentVisualIndex];
    if (current < 0) {
        return;
    }

    NSInteger target = MIN(MAX(current + delta, 0), (NSInteger)self.items.count - 1);
    if (target == current) {
        return;
    }

    [self setSelectionToVisualIndex:target mode:(extending ? @"extend" : @"single") notify:YES];
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers ?: @"";
    unichar ch = chars.length > 0 ? [chars characterAtIndex:0] : 0;
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    NSInteger columns = [self columnsForWidth:self.bounds.size.width];

    if (command && ch == '2') {
        [self.controller closeWithReason:@"keyboard"];
        return;
    }

    switch (ch) {
        case ' ':
            [self togglePreview];
            return;
        case NSLeftArrowFunctionKey:
            [self moveCurrentBy:-1 extending:shift];
            return;
        case NSRightArrowFunctionKey:
            [self moveCurrentBy:1 extending:shift];
            return;
        case NSUpArrowFunctionKey:
            [self moveCurrentBy:-columns extending:shift];
            return;
        case NSDownArrowFunctionKey:
            [self moveCurrentBy:columns extending:shift];
            return;
        case NSHomeFunctionKey:
            [self setSelectionToVisualIndex:0 mode:(shift ? @"extend" : @"single") notify:YES];
            return;
        case NSEndFunctionKey:
            [self setSelectionToVisualIndex:(NSInteger)self.items.count - 1 mode:(shift ? @"extend" : @"single") notify:YES];
            return;
        case NSPageUpFunctionKey:
            [self moveCurrentBy:-(columns * 3) extending:shift];
            return;
        case NSPageDownFunctionKey:
            [self moveCurrentBy:(columns * 3) extending:shift];
            return;
        case NSCarriageReturnCharacter:
        case NSNewlineCharacter: {
            NSInteger current = [self currentVisualIndex];
            if (current >= 0) {
                [self.callbacks callOpenIndex:self.items[current].modelIndex];
            }
            return;
        }
        case NSDeleteCharacter:
        case NSBackspaceCharacter:
        case NSDeleteFunctionKey:
            [self.callbacks callAction:@"core.delete"];
            return;
        case NSF3FunctionKey:
            [self.controller closeWithReason:@"keyboard"];
            return;
        case 0x1B:
            for (MartaThumbItem *item in self.items) {
                item.selected = NO;
            }
            self.needsDisplay = YES;
            [self.callbacks callAction:@"core.deselect.all"];
            return;
        default:
            break;
    }

    if (event.keyCode == 96) {
        [self.callbacks callAction:@"core.copy"];
    } else if (event.keyCode == 97) {
        [self.callbacks callAction:@"core.move"];
    } else if (event.keyCode == 98) {
        [self.callbacks callAction:@"core.new.directory"];
    } else if (event.keyCode == 100) {
        [self.callbacks callAction:@"core.delete"];
    } else {
        [super keyDown:event];
    }
}

@end

@implementation MartaThumbnailOverlayController

- (void)installHeaderClickMonitor {
    if (self.headerClickMonitor != nil || self.window == nil || self.targetScrollView == nil) {
        return;
    }

    __weak MartaThumbnailOverlayController *weakController = self;
    self.headerClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp)
                                                                     handler:^NSEvent *(NSEvent *event) {
        MartaThumbnailOverlayController *controller = weakController;
        if (controller == nil || controller.closed || event.window != controller.window) {
            return event;
        }

        BOOL clickedHeader = NO;
        NSString *sortColumn = nil;
        NSString *(^sortColumnFromTableColumn)(NSTableColumn *) = ^NSString *(NSTableColumn *column) {
            NSString *identifier = column.identifier.description ?: @"";
            NSString *title = column.headerCell.stringValue ?: @"";
            NSString *text = [NSString stringWithFormat:@"%@ %@", identifier, title].lowercaseString;
            if ([text containsString:@"modified"]) {
                return @"modified";
            }
            if ([text containsString:@"size"]) {
                return @"size";
            }
            if ([text containsString:@"extension"]) {
                return @"extension";
            }
            return @"name";
        };
        NSString *(^sortColumnFromRatio)(CGFloat) = ^NSString *(CGFloat ratio) {
            ratio = MAX(0.0, MIN(1.0, ratio));
            if (ratio >= 0.80) {
                return @"modified";
            }
            if (ratio >= 0.68) {
                return @"size";
            }
            if (ratio >= 0.58) {
                return @"extension";
            }
            return @"name";
        };

        NSTableHeaderView *headerView = controller.targetTable.headerView;
        if (headerView != nil) {
            NSPoint headerPoint = [headerView convertPoint:event.locationInWindow fromView:nil];
            clickedHeader = NSPointInRect(headerPoint, headerView.bounds);
            NSInteger columnIndex = clickedHeader ? [headerView columnAtPoint:headerPoint] : -1;
            if (columnIndex >= 0 && columnIndex < (NSInteger)controller.targetTable.tableColumns.count) {
                sortColumn = sortColumnFromTableColumn(controller.targetTable.tableColumns[columnIndex]);
            }
        }
        if (!clickedHeader && controller.targetScrollView != nil) {
            NSView *martaHeaderView = FindHeaderViewForScrollView(controller.targetScrollView);
            if (martaHeaderView != nil) {
                NSPoint headerPoint = [martaHeaderView convertPoint:event.locationInWindow fromView:nil];
                clickedHeader = NSPointInRect(headerPoint, martaHeaderView.bounds);
                if (clickedHeader && NSWidth(martaHeaderView.bounds) > 0) {
                    sortColumn = sortColumnFromRatio(headerPoint.x / NSWidth(martaHeaderView.bounds));
                }
            } else {
                NSRect bodyRect = [controller.targetScrollView convertRect:controller.targetScrollView.bounds toView:nil];
                NSRect headerBand = NSMakeRect(NSMinX(bodyRect), NSMaxY(bodyRect), NSWidth(bodyRect), 30.0);
                clickedHeader = NSPointInRect(event.locationInWindow, headerBand);
                if (clickedHeader) {
                    CGFloat x = event.locationInWindow.x - NSMinX(bodyRect);
                    CGFloat columnX = 0;
                    for (NSTableColumn *column in controller.targetTable.tableColumns) {
                        columnX += column.width;
                        if (x <= columnX) {
                            sortColumn = sortColumnFromTableColumn(column);
                            break;
                        }
                    }
                    if (sortColumn == nil && NSWidth(bodyRect) > 0) {
                        sortColumn = sortColumnFromRatio(x / NSWidth(bodyRect));
                    }
                }
            }
        }
        if (!clickedHeader) {
            return event;
        }
        if (sortColumn == nil) {
            sortColumn = @"name";
        }

        if (event.type == NSEventTypeLeftMouseUp && controller.suppressHeaderMouseUp) {
            controller.suppressHeaderMouseUp = NO;
            return nil;
        }
        if (event.type == NSEventTypeLeftMouseDown) {
            controller.suppressHeaderMouseUp = YES;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MartaThumbnailOverlayController *delayedController = weakController;
            if (delayedController != nil && !delayedController.closed) {
                [delayedController.gridView sortByColumn:sortColumn];
            }
        });

        return nil;
    }];
}

- (void)toggleQuickLookForItems:(NSArray<MartaThumbItem *> *)items currentItem:(MartaThumbItem *)currentItem {
    if (items.count == 0) {
        return;
    }

    if ([QLPreviewPanel sharedPreviewPanelExists]) {
        QLPreviewPanel *existingPanel = [QLPreviewPanel sharedPreviewPanel];
        if (existingPanel.isVisible && existingPanel.dataSource == self.quickLookDataSource) {
            [existingPanel orderOut:nil];
            return;
        }
    }

    NSMutableArray<MartaQuickLookItem *> *quickLookItems = [NSMutableArray array];
    NSInteger currentPreviewIndex = 0;
    for (MartaThumbItem *item in items) {
        if (item.path.length == 0) {
            continue;
        }

        MartaQuickLookItem *quickLookItem = [[MartaQuickLookItem alloc] init];
        quickLookItem.previewItemURL = [NSURL fileURLWithPath:item.path];
        quickLookItem.previewItemTitle = item.name.length > 0 ? item.name : item.path.lastPathComponent;

        if (item == currentItem) {
            currentPreviewIndex = (NSInteger)quickLookItems.count;
        }
        [quickLookItems addObject:quickLookItem];
    }

    if (quickLookItems.count == 0) {
        return;
    }

    MartaQuickLookDataSource *dataSource = [[MartaQuickLookDataSource alloc] init];
    dataSource.items = quickLookItems;
    self.quickLookDataSource = dataSource;

    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    panel.dataSource = dataSource;
    panel.delegate = dataSource;
    [panel reloadData];
    [panel setCurrentPreviewItemIndex:currentPreviewIndex];
    [panel makeKeyAndOrderFront:self.window];
}

- (void)closeWithReason:(NSString *)reason {
    if (self.closed) {
        return;
    }

    self.closed = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.targetFrameObserver != nil) {
        [center removeObserver:self.targetFrameObserver];
        self.targetFrameObserver = nil;
    }
    if (self.windowResizeObserver != nil) {
        [center removeObserver:self.windowResizeObserver];
        self.windowResizeObserver = nil;
    }
    if (self.headerClickMonitor != nil) {
        [NSEvent removeMonitor:self.headerClickMonitor];
        self.headerClickMonitor = nil;
    }
    if ([QLPreviewPanel sharedPreviewPanelExists]) {
        QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
        if (panel.dataSource == self.quickLookDataSource) {
            [panel orderOut:nil];
            panel.dataSource = nil;
            panel.delegate = nil;
        }
    }
    self.quickLookDataSource = nil;
    [self.callbacks callCloseReason:reason ?: @"closed"];
    [self.sizeBar removeFromSuperview];
    [self.containerView removeFromSuperview];
    if (self.window != nil && self.previousResponder != nil) {
        [self.window makeFirstResponder:self.previousResponder];
    }
    [self.callbacks invalidate];

    NSWindow *window = self.window;
    if (window != nil && activeControllers != nil && [activeControllers objectForKey:window] == self) {
        [activeControllers removeObjectForKey:window];
    }
}

- (void)syncFrame {
    if (self.closed || self.targetScrollView == nil || self.containerView == nil) {
        return;
    }

    self.containerView.frame = self.targetScrollView.frame;
    [self layoutOverlayContents];
}

- (void)layoutOverlayContents {
    if (self.containerView == nil || self.scrollView == nil) {
        return;
    }

    NSRect bounds = self.containerView.bounds;
    self.scrollView.frame = bounds;

    if (self.sizeBar != nil && self.targetScrollView != nil) {
        NSView *host = self.sizeBar.superview;
        NSView *targetHost = self.targetScrollView.superview;
        if (host != nil && targetHost != nil) {
            NSRect targetFrame = [targetHost convertRect:self.targetScrollView.frame toView:host];
            CGFloat statusHeight = 24.0;
            CGFloat controlHeight = 20.0;
            CGFloat controlWidth = MAX(150.0, MIN(190.0, floor(NSWidth(targetFrame) * 0.10)));
            CGFloat rightInset = 14.0;
            CGFloat x = NSMaxX(targetFrame) - controlWidth - rightInset;
            CGFloat y = host.isFlipped
                ? NSMaxY(targetFrame) + floor((statusHeight - controlHeight) / 2.0)
                : NSMinY(targetFrame) - statusHeight + floor((statusHeight - controlHeight) / 2.0);

            x = MAX(NSMinX(targetFrame) + rightInset, x);
            if (y < 0 || y + controlHeight > NSHeight(host.bounds)) {
                y = host.isFlipped
                    ? MAX(0.0, NSHeight(host.bounds) - statusHeight)
                    : 2.0;
            }

            self.sizeBar.frame = NSMakeRect(x, y, controlWidth, controlHeight);

            CGFloat labelWidth = 40.0;
            CGFloat sliderWidth = MAX(64.0, controlWidth - labelWidth - 8.0);
            self.sizeSlider.frame = NSMakeRect(0, 0, sliderWidth, controlHeight);
            self.sizeLabel.frame = NSMakeRect(NSMaxX(self.sizeSlider.frame) + 8, 1, labelWidth, controlHeight - 2);
        }
    }

    CGFloat contentWidth = NSWidth(self.scrollView.contentView.bounds);
    if (contentWidth > 0) {
        [self.gridView setFrameSize:NSMakeSize(contentWidth, self.gridView.frame.size.height)];
        [self.gridView updateDocumentHeightForWidth:contentWidth];
    }
}

- (void)sizeSliderChanged:(NSSlider *)sender {
    NSInteger percent = (NSInteger)llround(sender.doubleValue / 10.0) * 10;
    percent = MAX(50, MIN(150, percent));
    sender.doubleValue = percent;

    MartaThumbnailCurrentCellWidth = ClampThumbnailCellWidth(MartaThumbnailPercentBaseCellWidth * ((CGFloat)percent / 100.0));
    [NSUserDefaults.standardUserDefaults setDouble:MartaThumbnailCurrentCellWidth forKey:MartaThumbnailCellWidthDefaultsKey];
    [self.gridView applyCellWidth:MartaThumbnailCurrentCellWidth];

    self.sizeLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)percent];
    [self layoutOverlayContents];
}

- (void)close {
    [self closeWithReason:@"programmatic"];
}

- (void)dealloc {
    [self close];
}

@end

static void EnsureActiveControllers(void) {
    if (activeControllers == nil) {
        activeControllers = [NSMapTable weakToStrongObjectsMapTable];
    }
}

static void CollectHeaderViews(NSView *view, NSMutableArray<NSView *> *headers) {
    NSString *className = NSStringFromClass(view.class);
    if ([className containsString:@"TableHeaderView"]) {
        [headers addObject:view];
    }
    for (NSView *subview in view.subviews) {
        CollectHeaderViews(subview, headers);
    }
}

static CGFloat RectHorizontalOverlap(NSRect left, NSRect right) {
    return MAX(0.0, MIN(NSMaxX(left), NSMaxX(right)) - MAX(NSMinX(left), NSMinX(right)));
}

static NSView *FindHeaderViewForScrollView(NSScrollView *scrollView) {
    if (scrollView == nil) {
        return nil;
    }

    NSView *root = scrollView.superview ?: scrollView.window.contentView;
    if (root == nil) {
        return nil;
    }

    NSMutableArray<NSView *> *headers = [NSMutableArray array];
    CollectHeaderViews(root, headers);
    if (headers.count == 0) {
        return nil;
    }

    NSRect scrollRect = [scrollView convertRect:scrollView.bounds toView:nil];
    NSView *bestHeader = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (NSView *header in headers) {
        NSRect headerRect = [header convertRect:header.bounds toView:nil];
        if (NSWidth(headerRect) < 120.0 || NSHeight(headerRect) < 12.0 || NSHeight(headerRect) > 60.0) {
            continue;
        }

        CGFloat overlap = RectHorizontalOverlap(headerRect, scrollRect);
        CGFloat requiredOverlap = MIN(NSWidth(headerRect), NSWidth(scrollRect)) * 0.5;
        if (overlap < requiredOverlap) {
            continue;
        }

        CGFloat verticalGap = fabs(NSMinY(headerRect) - NSMaxY(scrollRect));
        if (verticalGap > 8.0) {
            continue;
        }

        CGFloat score = verticalGap
            + fabs(NSMinX(headerRect) - NSMinX(scrollRect)) * 0.1
            + fabs(NSWidth(headerRect) - NSWidth(scrollRect)) * 0.01;
        if (score < bestScore) {
            bestScore = score;
            bestHeader = header;
        }
    }

    return bestHeader;
}

static void CollectTableViews(NSView *view, NSMutableArray<NSTableView *> *tables) {
    if ([view isKindOfClass:NSTableView.class]) {
        [tables addObject:(NSTableView *)view];
    }
    for (NSView *subview in view.subviews) {
        CollectTableViews(subview, tables);
    }
}

static void CollectScrollViews(NSView *view, NSMutableArray<NSScrollView *> *scrollViews) {
    if ([view isKindOfClass:NSScrollView.class]) {
        NSScrollView *scrollView = (NSScrollView *)view;
        CGFloat area = NSWidth(scrollView.bounds) * NSHeight(scrollView.bounds);
        if (area > 20000 && NSWidth(scrollView.bounds) > 160 && NSHeight(scrollView.bounds) > 120) {
            [scrollViews addObject:scrollView];
        }
    }
    for (NSView *subview in view.subviews) {
        CollectScrollViews(subview, scrollViews);
    }
}

static NSTableView *TableFromResponder(NSResponder *responder) {
    if ([responder isKindOfClass:NSTableView.class]) {
        return (NSTableView *)responder;
    }
    if (![responder isKindOfClass:NSView.class]) {
        return nil;
    }

    NSView *view = (NSView *)responder;
    while (view != nil) {
        if ([view isKindOfClass:NSTableView.class]) {
            return (NSTableView *)view;
        }
        view = view.superview;
    }
    return nil;
}

static NSScrollView *ScrollViewFromResponder(NSResponder *responder) {
    if ([responder isKindOfClass:NSScrollView.class]) {
        return (NSScrollView *)responder;
    }
    if (![responder isKindOfClass:NSView.class]) {
        return nil;
    }

    NSView *view = (NSView *)responder;
    while (view != nil) {
        if ([view isKindOfClass:NSScrollView.class]) {
            return (NSScrollView *)view;
        }
        view = view.superview;
    }
    return nil;
}

static NSTableView *FindTargetTable(NSWindow *window, NSString *paneId) {
    NSTableView *responderTable = TableFromResponder(window.firstResponder);
    if (responderTable != nil) {
        return responderTable;
    }

    NSMutableArray<NSTableView *> *tables = [NSMutableArray array];
    CollectTableViews(window.contentView, tables);
    if (tables.count == 0) {
        return nil;
    }
    if (tables.count == 1) {
        return tables.firstObject;
    }

    NSArray<NSTableView *> *sorted = [tables sortedArrayUsingComparator:^NSComparisonResult(NSTableView *left, NSTableView *right) {
        NSRect leftFrame = [left.enclosingScrollView convertRect:left.enclosingScrollView.bounds toView:nil];
        NSRect rightFrame = [right.enclosingScrollView convertRect:right.enclosingScrollView.bounds toView:nil];
        CGFloat leftMid = NSMidX(leftFrame);
        CGFloat rightMid = NSMidX(rightFrame);
        if (leftMid < rightMid) {
            return NSOrderedAscending;
        }
        if (leftMid > rightMid) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSString *lowerPaneId = paneId.lowercaseString;
    if ([lowerPaneId containsString:@"right"] || [lowerPaneId hasSuffix:@"1"]) {
        return sorted.lastObject;
    }
    return sorted.firstObject;
}

static NSScrollView *FindTargetScrollView(NSWindow *window, NSString *paneId) {
    NSTableView *targetTable = FindTargetTable(window, paneId);
    if (targetTable.enclosingScrollView != nil) {
        return targetTable.enclosingScrollView;
    }

    NSScrollView *responderScrollView = ScrollViewFromResponder(window.firstResponder);
    if (responderScrollView != nil) {
        return responderScrollView;
    }

    NSMutableArray<NSScrollView *> *scrollViews = [NSMutableArray array];
    CollectScrollViews(window.contentView, scrollViews);
    if (scrollViews.count == 0) {
        return nil;
    }
    if (scrollViews.count == 1) {
        return scrollViews.firstObject;
    }

    NSArray<NSScrollView *> *sortedByX = [scrollViews sortedArrayUsingComparator:^NSComparisonResult(NSScrollView *left, NSScrollView *right) {
        NSRect leftFrame = [left convertRect:left.bounds toView:nil];
        NSRect rightFrame = [right convertRect:right.bounds toView:nil];
        CGFloat leftMid = NSMidX(leftFrame);
        CGFloat rightMid = NSMidX(rightFrame);
        if (leftMid < rightMid) {
            return NSOrderedAscending;
        }
        if (leftMid > rightMid) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSString *lowerPaneId = paneId.lowercaseString;
    if ([lowerPaneId containsString:@"right"] || [lowerPaneId hasSuffix:@"1"]) {
        return sortedByX.lastObject;
    }
    if ([lowerPaneId containsString:@"left"] || [lowerPaneId hasSuffix:@"0"]) {
        return sortedByX.firstObject;
    }

    return [scrollViews sortedArrayUsingComparator:^NSComparisonResult(NSScrollView *left, NSScrollView *right) {
        CGFloat leftArea = NSWidth(left.bounds) * NSHeight(left.bounds);
        CGFloat rightArea = NSWidth(right.bounds) * NSHeight(right.bounds);
        if (leftArea > rightArea) {
            return NSOrderedAscending;
        }
        if (leftArea < rightArea) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }].firstObject;
}

static NSString *LuaStringField(lua_State *L, int tableIndex, const char *name) {
    lua_getfield(L, tableIndex, name);
    const char *value = lua_tostring(L, -1);
    NSString *result = value != NULL ? [NSString stringWithUTF8String:value] : @"";
    lua_pop(L, 1);
    return result;
}

static BOOL LuaBoolField(lua_State *L, int tableIndex, const char *name) {
    lua_getfield(L, tableIndex, name);
    BOOL value = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return value;
}

static NSInteger LuaIntegerField(lua_State *L, int tableIndex, const char *name) {
    lua_getfield(L, tableIndex, name);
    NSInteger value = (NSInteger)lua_tointeger(L, -1);
    lua_pop(L, 1);
    return value;
}

static NSArray<MartaThumbItem *> *ReadItems(lua_State *L, int tableIndex) {
    luaL_checktype(L, tableIndex, LUA_TTABLE);
    NSMutableArray<MartaThumbItem *> *items = [NSMutableArray array];
    NSUInteger count = lua_rawlen(L, tableIndex);

    for (NSUInteger i = 1; i <= count; i++) {
        lua_rawgeti(L, tableIndex, (lua_Integer)i);
        if (lua_istable(L, -1)) {
            int itemTable = lua_gettop(L);
            MartaThumbItem *item = [[MartaThumbItem alloc] init];
            item.modelIndex = LuaIntegerField(L, itemTable, "index");
            item.path = LuaStringField(L, itemTable, "path");
            item.name = LuaStringField(L, itemTable, "name");
            item.isFolder = LuaBoolField(L, itemTable, "isFolder");
            item.isFile = LuaBoolField(L, itemTable, "isFile");
            item.isPackage = LuaBoolField(L, itemTable, "isPackage");
            item.selected = LuaBoolField(L, itemTable, "selected");
            item.current = LuaBoolField(L, itemTable, "current");
            if (item.name.length == 0) {
                item.name = item.path.lastPathComponent;
            }
            if (item.path.length > 0) {
                [items addObject:item];
            }
        }
        lua_pop(L, 1);
    }

    return items;
}

static int RefCallback(lua_State *L, int callbacksIndex, const char *name) {
    lua_getfield(L, callbacksIndex, name);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return LUA_NOREF;
    }
    return luaL_ref(L, LUA_REGISTRYINDEX);
}

static MartaThumbCallbacks *ReadCallbacks(lua_State *L, int callbacksIndex) {
    luaL_checktype(L, callbacksIndex, LUA_TTABLE);
    MartaThumbCallbacks *callbacks = [[MartaThumbCallbacks alloc] init];
    callbacks.L = L;
    callbacks.selectRef = RefCallback(L, callbacksIndex, "select");
    callbacks.openRef = RefCallback(L, callbacksIndex, "open");
    callbacks.actionRef = RefCallback(L, callbacksIndex, "action");
    callbacks.closeRef = RefCallback(L, callbacksIndex, "close");
    callbacks.refreshRef = RefCallback(L, callbacksIndex, "refresh");
    return callbacks;
}

static void CloseOverlayForWindow(NSWindow *window, NSString *reason) {
    if (window == nil) {
        return;
    }

    EnsureActiveControllers();
    MartaThumbnailOverlayController *controller = [activeControllers objectForKey:window];
    if (controller != nil) {
        [controller closeWithReason:reason ?: @"programmatic"];
        [activeControllers removeObjectForKey:window];
    }
}

static int showOverlay(lua_State *L) {
    if (lua_type(L, 1) != LUA_TLIGHTUSERDATA) {
        return luaL_argerror(L, 1, "First argument should be a NSWindow reference");
    }

    NSWindow *window = (__bridge NSWindow *)lua_touserdata(L, 1);
    NSArray<MartaThumbItem *> *items = ReadItems(L, 2);
    NSString *paneId = lua_isstring(L, 3) ? [NSString stringWithUTF8String:lua_tostring(L, 3)] : @"";
    MartaThumbCallbacks *callbacks = ReadCallbacks(L, 5);
    BOOL shouldToggleExistingOverlay = lua_gettop(L) < 6 || lua_toboolean(L, 6);
    CGFloat storedCellWidth = [NSUserDefaults.standardUserDefaults doubleForKey:MartaThumbnailCellWidthDefaultsKey];
    if (storedCellWidth > 0) {
        MartaThumbnailCurrentCellWidth = ClampThumbnailCellWidth(storedCellWidth);
    }

    EnsureActiveControllers();
    MartaThumbnailOverlayController *existingController = [activeControllers objectForKey:window];
    if (existingController != nil && existingController.closed) {
        [activeControllers removeObjectForKey:window];
        existingController = nil;
    }
    if (existingController != nil) {
        CloseOverlayForWindow(window, shouldToggleExistingOverlay ? @"toggle" : @"replace");
        if (shouldToggleExistingOverlay) {
            [callbacks invalidate];
            lua_pushboolean(L, 1);
            lua_pushstring(L, "closed");
            return 2;
        }
    }

    NSScrollView *targetScrollView = FindTargetScrollView(window, paneId);
    NSView *targetSuperview = targetScrollView.superview;
    if (targetScrollView == nil || targetSuperview == nil) {
        NSLog(@"Marta Thumbnail Viewer: could not find a Marta scroll view to overlay");
        [callbacks invalidate];
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Could not find a Marta scroll view to overlay");
        return 2;
    }

    MartaThumbnailOverlayController *controller = [[MartaThumbnailOverlayController alloc] init];
    controller.window = window;
    controller.previousResponder = window.firstResponder;
    controller.callbacks = callbacks;
    controller.targetScrollView = targetScrollView;
    controller.targetTable = [targetScrollView.documentView isKindOfClass:NSTableView.class]
        ? (NSTableView *)targetScrollView.documentView
        : FindTargetTable(window, paneId);

    MartaThumbnailGridView *grid = [[MartaThumbnailGridView alloc] initWithItems:items callbacks:callbacks];
    grid.controller = controller;
    grid.autoresizingMask = NSViewWidthSizable;

    NSView *containerView = [[NSView alloc] initWithFrame:targetScrollView.frame];
    containerView.autoresizingMask = targetScrollView.autoresizingMask;
    containerView.wantsLayer = YES;
    containerView.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = NSColor.windowBackgroundColor;
    scrollView.borderType = NSNoBorder;
    scrollView.documentView = grid;

    NSView *sizeBar = [[NSView alloc] initWithFrame:NSZeroRect];
    sizeBar.wantsLayer = YES;
    sizeBar.layer.backgroundColor = NSColor.clearColor.CGColor;

    NSSlider *sizeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    sizeSlider.minValue = 50.0;
    sizeSlider.maxValue = 150.0;
    sizeSlider.doubleValue = llround((MartaThumbnailCurrentCellWidth / MartaThumbnailPercentBaseCellWidth) * 100.0 / 10.0) * 10.0;
    sizeSlider.numberOfTickMarks = 11;
    sizeSlider.allowsTickMarkValuesOnly = YES;
    sizeSlider.continuous = YES;
    sizeSlider.target = controller;
    sizeSlider.action = @selector(sizeSliderChanged:);

    NSTextField *sizeLabel = [NSTextField labelWithString:@""];
    sizeLabel.alignment = NSTextAlignmentRight;
    sizeLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    sizeLabel.textColor = NSColor.secondaryLabelColor;
    sizeLabel.translatesAutoresizingMaskIntoConstraints = YES;

    [sizeBar addSubview:sizeSlider];
    [sizeBar addSubview:sizeLabel];
    [containerView addSubview:scrollView];

    [targetSuperview addSubview:containerView positioned:NSWindowAbove relativeTo:targetScrollView];
    NSView *overlayHost = window.contentView ?: targetSuperview;
    [overlayHost addSubview:sizeBar positioned:NSWindowAbove relativeTo:nil];
    controller.containerView = containerView;
    controller.scrollView = scrollView;
    controller.gridView = grid;
    controller.sizeBar = sizeBar;
    controller.sizeSlider = sizeSlider;
    controller.sizeLabel = sizeLabel;
    [controller sizeSliderChanged:sizeSlider];
    [controller syncFrame];
    [controller installHeaderClickMonitor];

    targetScrollView.postsFrameChangedNotifications = YES;
    __weak MartaThumbnailOverlayController *weakController = controller;
    controller.targetFrameObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification
                                                                                     object:targetScrollView
                                                                                      queue:NSOperationQueue.mainQueue
                                                                                 usingBlock:^(__unused NSNotification *notification) {
        [weakController syncFrame];
    }];
    controller.windowResizeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
                                                                                      object:window
                                                                                       queue:NSOperationQueue.mainQueue
                                                                                  usingBlock:^(__unused NSNotification *notification) {
        [weakController syncFrame];
    }];

    EnsureActiveControllers();
    [activeControllers setObject:controller forKey:window];

    [window makeFirstResponder:grid];
    NSInteger current = [grid currentVisualIndex];
    if (current >= 0) {
        [grid scrollRectToVisible:[grid tileRectForVisualIndex:current]];
    }

    lua_pushboolean(L, 1);
    lua_pushstring(L, "shown");
    return 2;
}

static int closeOverlay(lua_State *L) {
    if (lua_type(L, 1) != LUA_TLIGHTUSERDATA) {
        return luaL_argerror(L, 1, "First argument should be a NSWindow reference");
    }

    NSWindow *window = (__bridge NSWindow *)lua_touserdata(L, 1);
    CloseOverlayForWindow(window, @"programmatic");
    return 0;
}

static int updateOverlay(lua_State *L) {
    if (lua_type(L, 1) != LUA_TLIGHTUSERDATA) {
        return luaL_argerror(L, 1, "First argument should be a NSWindow reference");
    }

    NSWindow *window = (__bridge NSWindow *)lua_touserdata(L, 1);
    NSArray<MartaThumbItem *> *items = ReadItems(L, 2);

    EnsureActiveControllers();
    MartaThumbnailOverlayController *controller = [activeControllers objectForKey:window];
    if (controller == nil || controller.closed || controller.gridView == nil) {
        lua_pushboolean(L, 0);
        return 1;
    }

    [controller.gridView replaceItems:items];
    [controller syncFrame];
    if (controller.window != nil) {
        [controller.window makeFirstResponder:controller.gridView];
    }

    lua_pushboolean(L, 1);
    return 1;
}

static NSMutableDictionary<NSString *, NSString *> *ReadMutableFolderModes(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:MartaThumbnailFolderModesDefaultsKey];
    if ([stored isKindOfClass:NSDictionary.class]) {
        return [stored mutableCopy];
    }

    return [NSMutableDictionary dictionary];
}

static int setFolderMode(lua_State *L) {
    const char *pathCString = luaL_checkstring(L, 1);
    NSString *path = [NSString stringWithUTF8String:pathCString ?: ""];
    if (path.length == 0) {
        return 0;
    }

    NSMutableDictionary<NSString *, NSString *> *modes = ReadMutableFolderModes();
    if (lua_isnoneornil(L, 2)) {
        [modes removeObjectForKey:path];
    } else {
        const char *modeCString = luaL_checkstring(L, 2);
        NSString *mode = [NSString stringWithUTF8String:modeCString ?: ""];
        if (![mode isEqualToString:@"tiles"] && ![mode isEqualToString:@"list"]) {
            return luaL_argerror(L, 2, "Expected 'tiles' or 'list'");
        }
        modes[path] = mode;
    }

    [NSUserDefaults.standardUserDefaults setObject:modes forKey:MartaThumbnailFolderModesDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    return 0;
}

static int getFolderMode(lua_State *L) {
    const char *pathCString = luaL_checkstring(L, 1);
    NSString *path = [NSString stringWithUTF8String:pathCString ?: ""];
    NSDictionary *modes = [NSUserDefaults.standardUserDefaults dictionaryForKey:MartaThumbnailFolderModesDefaultsKey];
    NSString *mode = [modes isKindOfClass:NSDictionary.class] ? modes[path] : nil;
    if ([mode isKindOfClass:NSString.class] && mode.length > 0) {
        lua_pushstring(L, mode.UTF8String);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static const struct luaL_Reg martathumbs[] = {
    {"showOverlay", showOverlay},
    {"closeOverlay", closeOverlay},
    {"updateOverlay", updateOverlay},
    {"setFolderMode", setFolderMode},
    {"getFolderMode", getFolderMode},
    {NULL, NULL}
};

int luaopen_libmartathumbs(lua_State *L) {
    luaL_newlib(L, martathumbs);
    return 1;
}
