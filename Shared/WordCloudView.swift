//
//  WordCloudView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/20/21.
//

import SwiftUI

struct WordCloudView: View {
    @State private var canvasRect = CGRect()
    var words: [WordCloudItem]
    var colorPlate: [String]
    var fontPlate: [String]
    
    var body: some View {
        var pos = [CGPoint]()
        for (index,item) in words.enumerated() {
            if pos.count < index + 1 {
                pos.append(CGPoint(x: canvasRect.width * (0.5 + CGFloat.random * 0.5 - 0.25),
                                   y: canvasRect.height * (0.5 + CGFloat.random * 0.5 - 0.25)))
            }
            
            if item.rect.isEmpty {
                continue
            }
            
            if index > 1 {
                // check if overlap with previous item
                let prev = words[index-1]
                if item.rect.intersects(prev.rect) {
                    // move current rect to next avalible position
                    
                }
            }
        }
        
        // https://github.com/jasondavies/d3-cloud/blob/master/index.js
        return ZStack{
            ForEach(Array(words.enumerated()), id: \.offset) {idx, item in
                NavigationLink(destination: CardView(item.word)) {
                    Text("\(item.word)")
                        .foregroundColor(Color(item.color))
                        .font(Font.custom(
                            item.font,
                            size: item.fontSize *
                            min(canvasRect.width, canvasRect.height) / 5))
                }
                .position(x: pos[idx].x, y: pos[idx].y)
                .background(RectGetter(item.$rect))
            }
        }
        .background(RectGetter($canvasRect))
    }
}

struct WordCloudItem: Hashable {
    var word: String
    var weight: Float
    
    var color: String
    var font: String
    var fontSize: CGFloat
    @State var rect = CGRect()
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(word)
    }
    
    static func == (lhs: WordCloudItem, rhs: WordCloudItem) -> Bool {
        return lhs.word == rhs.word &&
            lhs.rect == rhs.rect
        // TODO: finish this
    }
}

struct WordCloudView_Previews: PreviewProvider {
    static var previews: some View {
        let colorPlate = ["shareFont1", "shareFont2", "shareFont3",
                          "shareFont1", "shareFont5"]
        let fontPlate = [ "SFProText-Bold",
                          "SFProText-Medium", "SFProText-Regular", "SFProText-Semibold"]
            
        var words = [WordCloudItem]()
        for _ in 1...15 {
            words.append(WordCloudItem(word: WordManager.shared.nextWord(),
                                       weight: Float(CGFloat.random),
                                       color: colorPlate.randomElement()!,
                                       font: fontPlate.randomElement()!,
                                       fontSize: 0.2 + CGFloat.random * 0.5
                                      ))
                        
        }
        return WordCloudView(words: words, colorPlate: colorPlate, fontPlate: fontPlate)
    }
}
