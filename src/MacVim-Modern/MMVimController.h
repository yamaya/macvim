/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MacVim.h"

@class MMWindowController;

/**
 */
@interface MMVimController : NSObject<NSToolbarDelegate, NSOpenSavePanelDelegate>

@property (nonatomic, readonly) MMWindowController *windowController;
@property (nonatomic, readonly) id backendProxy;
@property (nonatomic, readonly) NSMenu *mainMenu;
@property (nonatomic, readonly) int pid;
@property (nonatomic, copy) NSString *serverName;
@property (nonatomic, readonly) NSDictionary *vimState;
@property (nonatomic, assign) BOOL isPreloading;
@property (nonatomic, readonly) NSDate *creationDate;
@property (nonatomic, readonly) BOOL hasModifiedBuffer;
@property (nonatomic, readonly) unsigned vimControllerId;

- (instancetype)initWithBackend:(id)backend pid:(int)processIdentifier;

- (id)objectForVimStateKey:(NSString *)key;

- (void)cleanup;
- (void)dropFiles:(NSArray *)filenames forceOpen:(BOOL)force;
- (void)file:(NSString *)filename draggedToTabAtIndex:(NSUInteger)index;
- (void)filesDraggedToTabBar:(NSArray *)filenames;
- (void)dropString:(NSString *)string;
- (void)passArguments:(NSDictionary *)args;
- (void)sendMessage:(int)msgid data:(NSData *)data;
- (BOOL)sendMessageNow:(int)msgid data:(NSData *)data timeout:(NSTimeInterval)timeout;
- (void)addVimInput:(NSString *)string;
- (NSString *)evaluateVimExpression:(NSString *)expression;
- (id)evaluateVimExpressionCocoa:(NSString *)expression errorString:(NSString **)outErrorString;
- (void)processInputQueue:(NSArray *)queue;
@end
