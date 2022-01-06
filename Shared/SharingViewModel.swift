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
        
        let answersToday = WordManager.shared.wordsOfTodayWithRatingCount()
        if answersToday.count == 0 {
            return words
        }
        
        let sortedOne = answersToday.sorted { (first, second) -> Bool in
            if first.value == second.value {
                return first.key < second.key
            }
            return first.value < second.value
        }
        
        let maxRating = max(sortedOne.last!.value, 1)
        let minRating = sortedOne.first!.value
        var step = 0
        for idx in 0...sortedOne.count-1 {
            let word = sortedOne[idx % 2 == 0 ? sortedOne.count - 1 - idx/2 : idx / 2 ]
            words.append(
                WordElement(text: word.key,
                            color: Color(colorPlate[step % colorPlate.count]),
                            fontName: fontPlate[step % fontPlate.count],
                            fontSize: CGFloat(40 * (word.value - minRating) / maxRating + 20))
            )
            step += 1
        }
        print("MSG: \(words) \(sortedOne)")
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
        return WordManager.shared.fetchEngagement().duration//
        
    }
}


