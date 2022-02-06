//
//  WatchWordListViewModel.swift
//  WatchKit Extension
//
//  Created by SHEN SHENG on 1/9/22.
//

import SwiftUI

class WatchWordListViewModel: ObservableObject {
    @Published var learnedRecently = [String]()
    @Published var learnedRecentlyFetchLimit = 20
    
    @Published var recentAdded = [String]()
    @Published var recentAddedFetchLimit = 20
    
    @Published var queueWords = [String]()
    @Published var queueWordsFetchLimit = 20
    
    var pageCount: Int {
        return 3
    }
    
    func update() {
        learnedRecently = WordManager.shared.learnedRecentlyWordList(fetchLimit: learnedRecentlyFetchLimit).words.array()
        recentAdded = WordManager.shared.addedRecentlyWordList(fetchLimit: recentAddedFetchLimit).words.array()
        queueWords = WordManager.shared.queueWordList(fetchLimit: queueWordsFetchLimit).words.array()
        
        #if DEBUG
        if learnedRecently.count == 0 && false {
            for _ in 0...15 {
                learnedRecently.append(WordManager.shared.nextRandomWord())
            }
            for _ in 0...15 {
                recentAdded.append(WordManager.shared.nextRandomWord())
            }
            for _ in 0...15 {
                queueWords.append(WordManager.shared.nextRandomWord())
            }
        }
        #endif
    }
}
