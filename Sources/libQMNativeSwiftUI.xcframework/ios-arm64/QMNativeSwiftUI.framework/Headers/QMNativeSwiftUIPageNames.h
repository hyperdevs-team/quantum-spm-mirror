//
//  QMNativeSwiftUIPageNames.h
//  QMNativeSwiftUI
//
//  Copyright © 2026 Quantum Metric. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C declaration of the Swift class of the same name. Call +enable once at
/// launch so the linker keeps SwiftUI page-name recovery (SPM and CocoaPods). Idempotent;
/// page names still need the swiftui_page_names config flag. QP-27110.
@interface QMNativeSwiftUIPageNames : NSObject
+ (void)enable;
@end

NS_ASSUME_NONNULL_END
