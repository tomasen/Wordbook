//
//  WordCloudView2.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/23/21.
//

import SwiftUI

struct WordCloudView2<ItemView: View>: View {
    
    @State private var canvasRect = CGRect()
    @State private var sizeArray: [CGSize]
    
    let itemViews: [ItemView]
    
    init(itemViews: [ItemView]) {
        self.itemViews = itemViews
        self.sizeArray = [CGSize](repeating: CGSize.zero, count: itemViews.count)
    }
    
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

struct MyItemView: View {
    let s: String

    var body: some View {
        NavigationLink(destination: CardView(s)) {
            Text("\(s)")
                .foregroundColor(Color.white)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(3)
        }
    }
}

struct WordCloudView2_Previews: PreviewProvider {
    static var previews: some View {
        var vs = [MyItemView]()
        vs.append(MyItemView(s: "1"))
        vs.append(MyItemView(s: "2"))
        return WordCloudView2(itemViews: vs)
    }
}
