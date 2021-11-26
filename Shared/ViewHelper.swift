//
//  ViewHelper.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/26/21.
//

import SwiftUI

struct CustomFont: ViewModifier {
    @Environment(\.sizeCategory) var sizeCategory
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?

    var name: String
    var style: UIFont.TextStyle
    var weight: Font.Weight = .regular

    func body(content: Content) -> some View {
        return content.font(Font.custom(
            name,
            size: UIFont.preferredFont(forTextStyle: style).pointSize)
            .weight(weight))
    }
}

extension View {
    func customFont(
        name: String,
        style: UIFont.TextStyle,
        weight: Font.Weight = .regular) -> some View {
        return self.modifier(CustomFont(name: name, style: style, weight: weight))
    }
    
    func dynamicDeviceNavigationViewStyle(stack: Bool) -> AnyView {
        if stack {
            return AnyView(self.navigationViewStyle(StackNavigationViewStyle()))
        } else {
            return AnyView(self.navigationViewStyle(DefaultNavigationViewStyle()))
        }
    }
}

