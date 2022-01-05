//
//  SharingViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/19/21.
//

import Foundation
import SwiftUI

class SharingViewModel: ObservableObject {
    static let shared = SharingViewModel()
    
    var shareViewRect: CGRect = CGRect.zero
    var systemSharingImage: UIImage?
    
    private let colorPlate = ["shareFont1", "shareFont2", "shareFont3",
                      "shareFont1", "shareFont5"]
    private let fontPlate = [ "SFProText-Bold",
                      "SFProText-Medium", "SFProText-Regular", "SFProText-Semibold"]
    
    
    var wordsOfToday: [WordElement] {
        var words = [WordElement]()
        for word in WordManager.shared.wordsOfToday() {
            words.append(
                WordElement(text: word,
                            color: Color(colorPlate.randomElement()!),
                            fontName: fontPlate.randomElement()!,
                            fontSize: CGFloat.random(in:20...50))
            )
        }
#if targetEnvironment(simulator)
        if words.count == 0 {
            words = [WordElement].generate(50)
        }
#endif
        return words
    }
    
    var todayDate: Date {
        WordManager.shared.date(from: WordManager.shared.today)
    }
    
    var minCanvasHeight: CGFloat? {
        if UIScreen.main.bounds.width < UIScreen.main.bounds.height {
            return UIScreen.main.bounds.width
        }
        return nil
    }
    
    var todayWordsTotal: Int16 {
        let e = WordManager.shared.fetchEngagement()
        return e.working + e.good
    }
    
    var todayStudyTimeInSeconds: TimeInterval {
        return WordManager.shared.fetchEngagement().duration
    }
}


