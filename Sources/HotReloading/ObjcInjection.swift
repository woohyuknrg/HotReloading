//
//  ObjcInjection.swift
//
//  Created by John Holdsworth on 17/03/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/ObjcInjection.swift#7 $
//
//  Code specific to "classic" Objective-C method swizzling.
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

extension SwiftInjection {

    /// New method of swizzling based on symbol names
    /// - Parameters:
    ///   - oldClass: original class to be swizzled
    ///   - tmpfile: no longer used
    /// - Returns: # methods swizzled
    open class func injection(swizzle oldClass: AnyClass, tmpfile: String) -> Int {
        var methodCount: UInt32 = 0, swizzled = 0
        if let methods = class_copyMethodList(oldClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                swizzled += swizzle(oldClass: oldClass,
                    selector: method_getName(methods[i]), tmpfile)
            }
            free(methods)
        }
        return swizzled
    }

    /// Swizzle the newly loaded implementation of a selector onto oldClass
    /// - Parameters:
    ///   - oldClass: orignal class to be swizzled
    ///   - selector: method selector to be swizzled
    ///   - tmpfile: no longer used
    /// - Returns: # methods swizzled
    open class func swizzle(oldClass: AnyClass, selector: Selector,
                            _ tmpfile: String) -> Int {
        var swizzled = 0
        if let method = class_getInstanceMethod(oldClass, selector),
            let existing = unsafeBitCast(method_getImplementation(method),
                                         to: UnsafeMutableRawPointer?.self),
            let selsym = originalSym(for: existing) {
            if let replacement = fast_dlsym(lastLoadedImage(), selsym) {
                traceAndReplace(existing, replacement: replacement,
                                objcMethod: method, objcClass: oldClass) {
                    (replacement: IMP) -> String? in
                    if class_replaceMethod(oldClass, selector, replacement,
                                           method_getTypeEncoding(method)) != nil {
                        swizzled += 1
                        return "Swizzled "+describeImageSymbol(selsym)
                    }
                    return nil
                }
            } else {
                detail("⚠️ Swizzle failed "+describeImageSymbol(selsym))
            }
        }
        return swizzled
    }

    /// Fallback to make sure at least the @objc func injected() and viewDidLoad() methods are swizzled
    open class func swizzleBasics(oldClass: AnyClass, tmpfile: String) -> Int {
        var swizzled = swizzle(oldClass: oldClass, selector: injectedSEL, tmpfile)
        #if os(iOS) || os(tvOS)
        swizzled += swizzle(oldClass: oldClass, selector: viewDidLoadSEL, tmpfile)
        #endif
        return swizzled
    }

    /// Original Objective-C swizzling
    /// - Parameters:
    ///   - newClass: Newly loaded class
    ///   - oldClass: Original class to be swizzle
    /// - Returns: # of methods swizzled
    open class func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) -> Int {
        var methodCount: UInt32 = 0, swizzled = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                let selector = method_getName(methods[i])
                let replacement = method_getImplementation(methods[i])
                guard let method = class_getInstanceMethod(oldClass, selector),
                      let existing = i < 0 ? nil : method_getImplementation(method),
                   replacement != existing else {
                    continue
                }
                traceAndReplace(existing, replacement: autoBitCast(replacement),
                                objcMethod: methods[i], objcClass: newClass) {
                    (replacement: IMP) -> String? in
                    if class_replaceMethod(oldClass, selector, replacement,
                        method_getTypeEncoding(methods[i])) != nil {
                        swizzled += 1
                        let which = class_isMetaClass(oldClass) ? "+" : "-"
                        return "Sizzled \(which)[\(_typeName(oldClass!)) \(selector)]"
                    }
                    return nil
                }
            }
            free(methods)
        }
        return swizzled
    }
}
