//
//  WordListViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/26/21.
//

import Foundation
import SwiftUI
import CoreData

class WordListViewModel: ObservableObject {
    @Published var learnedRecently = WordList()
    var learnedRecentlyFetchLimit = 10
    
    @Published var recentAdded = WordList()
    var recentAddedFetchLimit = 10
    
    @Published var queueWords = WordList()
    var queueWordsFetchLimit = 10
    
    @Published var updateCounter = 0
    
    static var shared = WordListViewModel()
    
    var footnote: String {
        "\(updateCounter)"
    }
    
    private let moc = CoreDataManager.shared.container.viewContext
    
    func delete(word: String) {
        // TODO:
    }
    
    func updateRecentLearned() {
        learnedRecently = WordManager.shared.learnedRecentlyWordList(fetchLimit: learnedRecentlyFetchLimit)
    }
    
    func updateRecentAdded() {
        recentAdded = WordManager.shared.addedRecentlyWordList(fetchLimit: recentAddedFetchLimit)
    }
    
    func updateQueueWords() {
        queueWords = WordManager.shared.queueWordList(fetchLimit: queueWordsFetchLimit)
    }
    
    func update() {
        updateQueueWords()
        updateRecentAdded()
        updateRecentLearned()
        
        #if DEBUG
        if learnedRecently.words.count == 0 {
            learnedRecently.total = 10
            recentAdded.total = 10
            for _ in 0...learnedRecently.total {
                learnedRecently.words.append(WordListEntry(text: WordManager.shared.nextRandomWord()))
                recentAdded.words.append(WordListEntry(text: WordManager.shared.nextRandomWord()))
            }
        }
        #endif
        updateCounter += 1
    }
}

