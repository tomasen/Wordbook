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
}

extension Binding where Value == Bool {
    static func ||(_ lhs: Binding<Bool>, _ rhs: Binding<Bool>) -> Binding<Bool> {
        return Binding<Bool>( get: { lhs.wrappedValue || rhs.wrappedValue },
                              set: { v in
                                lhs.wrappedValue = v
                                rhs.wrappedValue = v
                                })
    }
}

struct FootViewStyle: ViewModifier {
    func body(content: Content) -> some View {
        return content
            .frame(height: 20)
            .customFont(name: "AvenirNext-Medium", style: .title3, weight: .medium)
            .buttonStyle(ChoiceButtonStyle())
    }
}

struct ChoiceButtonStyle: ButtonStyle {
    private let isEnabled: Bool
    init(_ isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
    
    public func makeBody(configuration: ChoiceButtonStyle.Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? Color("fontLink") : Color.gray)
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

struct RectGetter: View {
    @Binding var rect: CGRect

    init(_ rect: Binding<CGRect>) {
        _rect = rect
    }
    
    var body: some View {
        GeometryReader { proxy in
            self.createView(proxy: proxy)
        }
    }

    func createView(proxy: GeometryProxy) -> some View {
        DispatchQueue.main.async {
            self.rect = proxy.frame(in: .global)
        }

        return Rectangle().fill(Color.clear)
    }
}
