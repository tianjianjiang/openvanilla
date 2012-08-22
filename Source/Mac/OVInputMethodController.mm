//
// OVInputMethodController.m
//
// Copyright (c) 2004-2012 Lukhnos Liu (lukhnos at openvanilla dot org)
// 
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//

#import "OVInputMethodController.h"
#import "OpenVanilla.h"
#import "OVLoaderServiceImpl.h"
#import "OVCandidateServiceImpl.h"
#import "OVTextBufferImpl.h"
#import "OVPlistBackedKeyValueMapImpl.h"
#import "OVTextBufferCombinator.h"

using namespace OpenVanilla;

#if DEBUG
    #define IMEDebug NSLog
#else
    #define IMEDebug(...)
#endif

OVCINDatabaseService* g_dbService = 0;
OVLoaderServiceImpl* g_loaderService = 0;
OVCandidateServiceImpl* g_candidateService = 0;
OVInputMethod* g_inputMethod = 0;

@interface OVInputMethodController ()
{
@protected
    OVTextBufferImpl *_composingText;
    OVTextBufferImpl *_readingText;
    OVEventHandlingContext *_inputMethodContext;
}
@end

@implementation OVInputMethodController
- (void)dealloc
{
    if (_composingText) {
        delete _composingText;
    }

    if (_readingText) {
        delete _readingText;
    }

    if (_inputMethodContext) {
        delete _inputMethodContext;
    }

    [super dealloc];
}

+ (void)load
{
}

- (id)initWithServer:(IMKServer *)server delegate:(id)aDelegate client:(id)client
{
    IMEDebug(@"%s", __PRETTY_FUNCTION__);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_loaderService = new OVLoaderServiceImpl;
        g_candidateService = new OVCandidateServiceImpl(g_loaderService);
    });

    self = [super initWithServer:server delegate:aDelegate client:client];
	if (self) {
        _composingText = new OVTextBufferImpl;
        _readingText = new OVTextBufferImpl;
	}
	
	return self;
}

- (NSMenu *)menu
{
    IMEDebug(@"%s", __PRETTY_FUNCTION__);
    return nil;
}

#pragma mark IMKStateSetting protocol methods

- (void)activateServer:(id)client
{
    IMEDebug(@"%s", __PRETTY_FUNCTION__);
    [client overrideKeyboardWithKeyboardNamed:@"com.apple.keylayout.US"];

    _composingText->clear();
    _readingText->clear();

    if (_inputMethodContext) {
        delete _inputMethodContext;
        _inputMethodContext = 0;
    }

    if (g_inputMethod) {
        _inputMethodContext = g_inputMethod->createContext();
    }

    if (_inputMethodContext) {
        _inputMethodContext->startSession(g_loaderService);
    }
}

- (void)deactivateServer:(id)client
{
    IMEDebug(@"%s", __PRETTY_FUNCTION__);
    if (_inputMethodContext) {
        _inputMethodContext->stopSession(g_loaderService);
        delete _inputMethodContext;
        _inputMethodContext = 0;
    }
}

- (void)commitComposition:(id)sender
{
    if (_composingText->isCommitted()) {
        NSString *combinedText = [NSString stringWithUTF8String:_composingText->composedCommittedText().c_str()];

        [sender insertText:combinedText replacementRange:NSMakeRange(NSNotFound, NSNotFound)];
    }
}

- (BOOL)handleOVKey:(OVKey &)key client:(id)client
{
    if (!_inputMethodContext) {
        return NO;
    }

    bool handled = false;
    bool candidatePanelFallThrough = false;

    OVOneDimensionalCandidatePanelImpl* panel = dynamic_cast<OVOneDimensionalCandidatePanelImpl*>(g_candidateService->useVerticalCandidatePanel());
    if (panel && panel->isInControl()) {
        OVOneDimensionalCandidatePanelImpl::KeyHandlerResult result = panel->handleKey(&key);
        switch (result) {
            case OVOneDimensionalCandidatePanelImpl::Handled:
            {
                return YES;
            }

            case OVOneDimensionalCandidatePanelImpl::CandidateSelected:
            {
                size_t index = panel->currentHightlightIndexInCandidateList();
                string candidate = panel->candidateList()->candidateAtIndex(index);
                handled = _inputMethodContext->candidateSelected(g_candidateService, candidate, index, _readingText, _composingText, g_loaderService);
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::Canceled:
            {
                _inputMethodContext->candidateCanceled(g_candidateService, _readingText, _composingText, g_loaderService);
                handled = true;
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::NonCandidatePanelKeyReceived:
            {
                handled = _inputMethodContext->candidateNonPanelKeyReceived(g_candidateService, &key, _readingText, _composingText, g_loaderService);
                candidatePanelFallThrough = true;
                break;
            }

            case OVOneDimensionalCandidatePanelImpl::Invalid:
            {
                g_loaderService->beep();
                return YES;
            }

        }
    }

    if (!candidatePanelFallThrough) {
        handled = _inputMethodContext->handleKey(&key, _readingText, _composingText, g_candidateService, g_loaderService);
    }

    if (_composingText->isCommitted()) {
        [self commitComposition:client];
        _composingText->finishCommit();
    }

    OVTextBufferCombinator combinedText(_composingText, _readingText);
    NSAttributedString *attrString = combinedText.combinedAttributedString();
    NSRange selectionRange = combinedText.selectionRange();

    if (_composingText->shouldUpdate() || _readingText->shouldUpdate()) {

        [client setMarkedText:attrString selectionRange:selectionRange replacementRange:NSMakeRange(NSNotFound, NSNotFound)];

        _composingText->finishUpdate();
        _readingText->finishUpdate();
    }

    NSUInteger cursorIndex = selectionRange.location;
    if (cursorIndex == [attrString length] && cursorIndex) {
        cursorIndex--;
    }

    NSRect lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0);
    @try {
        [client attributesForCharacterIndex:cursorIndex lineHeightRectangle:&lineHeightRect];
    }
    @catch (NSException *exception) {
    }

    g_candidateService->currentCandidatePanel()->setPanelOrigin(lineHeightRect.origin);
    g_candidateService->currentCandidatePanel()->updateVisibility();
    
    return handled;
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)client
{
    IMEDebug(@"%s", __PRETTY_FUNCTION__);
    if ([event type] != NSKeyDown) {
        return NO;
    }

    NSString *chars = [event characters];
    NSUInteger cocoaModifiers = [event modifierFlags];
    unsigned short virtualKeyCode = [event keyCode];

    bool capsLock = !!(cocoaModifiers & NSAlphaShiftKeyMask);
	bool shift = !!(cocoaModifiers & NSShiftKeyMask);
	bool ctrl = !!(cocoaModifiers & NSControlKeyMask);
    bool opt = !!(cocoaModifiers & NSAlternateKeyMask);
	bool cmd = !!(cocoaModifiers & NSCommandKeyMask);
    bool numLock = false;

    UInt32 numKeys[16] = {
        // 0,1,2,3,4,5, 6,7,8,9,.,+,-,*,/,=
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5b, 0x5c, 0x41, 0x45, 0x4e, 0x43, 0x4b, 0x51
    };

    for (size_t i = 0; i < 16; i++) {
        if (virtualKeyCode == numKeys[i]) {
            numLock = true;
            break;
        }
    }

    OVKey key;
    UniChar unicharCode = 0;
    if ([chars length] > 0) {
        unicharCode = [chars characterAtIndex:0];

        // map Ctrl-[A-Z] to a char code
        if (cocoaModifiers & NSControlKeyMask) {
            if (unicharCode < 27) {
                unicharCode += ('a' - 1);
            }
            else {
                switch (unicharCode) {
                    case 27:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '{' : '[';
                        break;
                    case 28:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '|' : '\\';
                        break;
                    case 29:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '}': ']';
                        break;
                    case 31:
                        unicharCode = (cocoaModifiers & NSShiftKeyMask) ? '_' : '-';
                        break;
                }
            }
        }

        UniChar remappedKeyCode = unicharCode;

        // remap function key codes
        switch(unicharCode) {
            case NSUpArrowFunctionKey:      remappedKeyCode = (UniChar)OVKeyCode::Up; break;
            case NSDownArrowFunctionKey:    remappedKeyCode = (UniChar)OVKeyCode::Down; break;
            case NSLeftArrowFunctionKey:    remappedKeyCode = (UniChar)OVKeyCode::Left; break;
            case NSRightArrowFunctionKey:   remappedKeyCode = (UniChar)OVKeyCode::Right; break;
            case NSDeleteFunctionKey:       remappedKeyCode = (UniChar)OVKeyCode::Delete; break;
            case NSHomeFunctionKey:         remappedKeyCode = (UniChar)OVKeyCode::Home; break;
            case NSEndFunctionKey:          remappedKeyCode = (UniChar)OVKeyCode::End; break;
            case NSPageUpFunctionKey:       remappedKeyCode = (UniChar)OVKeyCode::PageUp; break;
            case NSPageDownFunctionKey:     remappedKeyCode = (UniChar)OVKeyCode::PageDown; break;
            case NSF1FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F1; break;
            case NSF2FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F2; break;
            case NSF3FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F3; break;
            case NSF4FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F4; break;
            case NSF5FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F5; break;
            case NSF6FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F6; break;
            case NSF7FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F7; break;
            case NSF8FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F8; break;
            case NSF9FunctionKey:           remappedKeyCode = (UniChar)OVKeyCode::F9; break;
            case NSF10FunctionKey:          remappedKeyCode = (UniChar)OVKeyCode::F10; break;
        }

        unicharCode = remappedKeyCode;
    }

    if (unicharCode < 128) {
        key = g_loaderService->makeOVKey(unicharCode, opt, opt, ctrl, shift, cmd, capsLock, numLock);
    }
    else {
        key = g_loaderService->makeOVKey(string([chars UTF8String]), opt, opt, ctrl, shift, cmd, capsLock, numLock);
    }

    return [self handleOVKey:key client:client];
}

@end