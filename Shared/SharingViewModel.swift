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
        
        let maximumDifficulty = max(sortedOne.last!.value, 0)
        for word in sortedOne.reversed() {
            let normalizedDifficulty = WordCloudDifficultyScale.normalizedDifficulty(
                for: word.value,
                maximumDifficultyScore: maximumDifficulty
            )
            let fontSize = WordCloudDifficultyScale.fontSize(
                for: word.value,
                maximumDifficultyScore: maximumDifficulty
            )
            let visualStyle = WordCloudVisualStyle(
                normalizedDifficulty: normalizedDifficulty
            )
            words.append(
                WordElement(text: word.key,
                            color: Color(visualStyle.colorName),
                            fontName: visualStyle.fontName,
                            fontSize: fontSize,
                            difficultyScore: word.value)
            )
        }
#if targetEnvironment(simulator)
        if words.count == 0 {
            words = [WordElement].generate(50)
        }
#endif
        return words
    }

    /// Reinforces the confidence hierarchy without introducing a second,
    /// unrelated rank-based visual order. Difficult words are brighter and
    /// heavier; familiar words remain quieter.
    private struct WordCloudVisualStyle {
        let colorName: String
        let fontName: String

        init(normalizedDifficulty: CGFloat) {
            switch normalizedDifficulty {
            case 0.67...:
                colorName = "shareFont5"
                fontName = "SFProText-Bold"
            case 0.25...:
                colorName = "shareFont1"
                fontName = "SFProText-Medium"
            default:
                colorName = "shareFont2"
                fontName = "SFProText-Regular"
            }
        }
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
