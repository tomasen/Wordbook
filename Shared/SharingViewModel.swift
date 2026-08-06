//
//  SharingViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/19/21.
//

import Foundation
import SwiftUI

@MainActor
class SharingViewModel: ObservableObject {
    static let shared = SharingViewModel()

    @Published private(set) var todayWordsTotal: Int16 = 0
    @Published private(set) var todayStudyTimeInSeconds: TimeInterval = 0
    
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
        
        let maxRating = sortedOne.last!.value
        let minRating = sortedOne.first!.value
        let ratingRange = maxRating - minRating
        for (step, word) in sortedOne.reversed().enumerated() {
            let normalizedRating: CGFloat
            if ratingRange == 0 {
                normalizedRating = 0.5
            } else {
                normalizedRating = CGFloat(word.value - minRating) / CGFloat(ratingRange)
            }
            // A square-root curve preserves the emphasis on difficult words
            // without making the middle of the cloud look under-filled.
            let fontSize = 20 + 40 * sqrt(normalizedRating)
            words.append(
                WordElement(text: word.key,
                            color: Color(colorPlate[step % colorPlate.count]),
                            fontName: fontPlate[step % fontPlate.count],
                            fontSize: fontSize)
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
    
    func refresh() {
        let engagement = WordManager.shared.refreshTodayEngagement()
        todayWordsTotal = engagement.working + engagement.good
        todayStudyTimeInSeconds = engagement.duration
    }
}
