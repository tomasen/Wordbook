//
//  WatchWordListViewModel.swift
//  WatchKit Extension
//
//  Created by SHEN SHENG on 1/9/22.
//

import SwiftUI

class WatchWordListViewModel: ObservableObject {
    @Published var learnedRecently = [String]()
    @Published var learnedRecentlyFetchLimit = 10
    
    @Published var recentAdded = [String]()
    @Published var recentAddedFetchLimit = 10
    
    @Published var queueWords = [String]()
    @Published var queueWordsFetchLimit = 10
    
    var pageCount: Int {
        return 3
    }
    
    func update() {
        learnedRecently = WordManager.shared.learnedRecentlyWordList(fetchLimit: learnedRecentlyFetchLimit).words.array()
        recentAdded = WordManager.shared.addedRecentlyWordList(fetchLimit: recentAddedFetchLimit).words.array()
        queueWords = WordManager.shared.queueWordList(fetchLimit: queueWordsFetchLimit).words.array()
    }
}
