//
//  WordCloudView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/20/21.
//

import SwiftUI

    
struct WordCloudView: View {
    
    @State private var canvasRect = CGRect()
    @State private var sizeArray: [CGSize]
    
    private var cloudItems: [WordCloudItem]
    private var stateCache = WordCloudStateCache()
    
    init(words: [String]) {
        self._sizeArray = State(initialValue:[CGSize](repeating: CGSize.zero, count: words.count))
        
        self.cloudItems = [WordCloudItem]()
        
        let colorPlate =  ["shareFont1", "shareFont2", "shareFont3",
                           "shareFont1", "shareFont5"]
        let fontPlate = [ "SFProText-Bold",
                          "SFProText-Medium", "SFProText-Regular", "SFProText-Semibold"]
        
        for w in words {
            self.cloudItems.append(
                WordCloudItem(word: w,
                              weight: CGFloat.random * 0.6 + 0.4,
                              color: colorPlate.randomElement()!,
                              font: fontPlate.randomElement()!)
            )
        }
    }
    
    init() {
        var words = [String]()
        let n = Int.random(in: 5...50)
        for _ in 1...n {
            words.append(WordManager.shared.nextWord())
        }
        self.init(words: words)
    }
    
    
    var body: some View {
        let pos = calcPositions(canvasSize: canvasRect.size, itemSizes: sizeArray)
        // https://github.com/jasondavies/d3-cloud/blob/master/index.js
        return ZStack{
            ForEach(Array(cloudItems.enumerated()), id: \.offset) {idx, item in
                NavigationLink(destination: CardView(item.word)) {
                    Text("\(item.word)")
                        .foregroundColor(Color(item.color))
                        .font(Font.custom(
                            item.font,
                            size: item.weight *
                            (canvasRect.width + canvasRect.height) / (6*log(CGFloat(cloudItems.count)))))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(3)
                        .background(SizeArrayGetter($sizeArray, idx))
                }
                .position(x: canvasRect.width/2 + pos[idx].x,
                          y: canvasRect.height/2 + pos[idx].y)
                
            }
        }
        .frame(idealHeight: self.canvasRect.width)
        .background(RectGetter($canvasRect))
    }
    
    func checkIntersects(rect: CGRect, rects: [CGRect]) -> Bool {
        for r in rects {
            if rect.intersects(r) {
                return true
            }
        }
        return false
    }
    
    func simularSizeArray(a: [CGSize], b: [CGSize]) -> Bool {
        if a == b {
            return true
        }
        
        if a.count != b.count {
            return false
        }
        var diff : CGFloat = 0
        for i in 0...(a.count-1) {
            diff += abs(a[i].width - b[i].width) +
            abs(a[i].height - b[i].height)
        }
        
        return diff < 0.01
    }
    
    func checkOutsideBoundry(canvasSize: CGSize, rect: CGRect) -> Bool {
        if rect.maxY > canvasRect.height/2 {
            return true
        }
        if rect.minY < -canvasRect.height/2 {
            return true
        }
        return false
    }
    
    func calcPositions(canvasSize: CGSize, itemSizes: [CGSize]) -> [CGPoint] {
        var pos = [CGPoint](repeating: CGPoint.zero, count: itemSizes.count)
        if canvasSize.height == 0 {
            return pos
        }
        if stateCache.lastCanvasSize == canvasSize
            && simularSizeArray(a: stateCache.lastSizeArray, b: sizeArray) {
            return stateCache.lastPositions
        }
        
        defer {
            stateCache.lastCanvasSize = canvasSize
            stateCache.lastSizeArray = sizeArray
            stateCache.lastPositions = pos
        }
        var rects = [CGRect]()
        
        var step : CGFloat = 0
        let ratio = canvasSize.width * 1.5 / canvasSize.height
        
        let startPos = CGPoint(x: CGFloat.random * canvasSize.width * 0.1,
                               y: CGFloat.random * canvasSize.height * 0.1)
        
        for (index, itemSize) in itemSizes.enumerated() {
            var nextRect = CGRect(origin: CGPoint(x: startPos.x - itemSize.width/2,
                                                  y: startPos.y - itemSize.height/2),
                                  size: itemSize)
            if index > 0 {
                while checkOutsideBoundry(canvasSize: canvasSize,
                                          rect: nextRect)
                        || checkIntersects(rect: nextRect, rects: rects) {
                    nextRect.origin.x = startPos.x + ratio * step * cos(step) + startPos.x - itemSize.width/2
                    nextRect.origin.y = startPos.y + step * sin(step) + startPos.y - itemSize.height/2
                    step = step + 0.01
                }
            }
            pos[index] = nextRect.center
            rects.append(nextRect)
        }
        return pos
    }
}

class WordCloudStateCache {
    var lastCanvasSize = CGSize.zero
    var lastSizeArray = [CGSize]()
    var lastPositions = [CGPoint]()
}

extension CGRect {
    var center : CGPoint {
        return CGPoint(x: self.origin.x + self.size.width/2,
                       y: self.origin.y + self.size.height/2)
    }
}

struct SizeArrayGetter: View {
    @Binding var sizeArray: [CGSize]
    private var index: Int
    
    init(_ sizeArray: Binding<[CGSize]>, _ index: Int) {
        _sizeArray = sizeArray
        self.index = index
    }
    
    var body: some View {
        GeometryReader { proxy in
            self.createView(proxy: proxy)
        }
    }
    
    func createView(proxy: GeometryProxy) -> some View {
        DispatchQueue.main.async {
            self.sizeArray[index] = proxy.frame(in: .global).size
        }
        
        return Rectangle().fill(Color.clear)
    }
}



struct WordCloudItem: Hashable {
    var word: String
    var weight: CGFloat
    var color: String
    var font: String
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(word)
    }
    
    static func == (lhs: WordCloudItem, rhs: WordCloudItem) -> Bool {
        return lhs.word == rhs.word
        // TODO: finish this
    }
}

struct WordCloudView_Previews: PreviewProvider {
    static var previews: some View {
        VStack{
            Spacer()
            WordCloudView()
            Spacer().padding()
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }
}
