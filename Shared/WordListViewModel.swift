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
    @Published var recentLearned = WordEntryList()
    @Published var recentAdded = WordEntryList()
    @Published var queueWords = WordEntryList()
    @Published var updateCounter = 0
    
    var footnote: String {
        "\(updateCounter)"
    }
    
    
    private let moc = CoreDataManager.shared.container.viewContext
    
    func delete(word: String) {
        // TODO:
    }
    
    func updateRecentLearned() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "AnswerHistory")
        req.predicate = NSPredicate(format: "word.category >= 0")
        req.sortDescriptors = [NSSortDescriptor(keyPath: \AnswerHistory.date, ascending: false)]
        req.resultType = NSFetchRequestResultType.dictionaryResultType
        req.propertiesToFetch   = [#keyPath(AnswerHistory.word.word)]
        req.returnsDistinctResults = true;
        recentLearned.total = try! moc.count(for: req)
        if recentLearned.fetchLimit > 0 {
            req.fetchLimit = recentLearned.fetchLimit
        }
        let res = try! moc.fetch(req) as! [NSDictionary]
        if res.count > 0 {
            recentLearned.words.removeAll()
            for key in res {
                if let w = key.allValues[0] as? String {
                    recentLearned.words.append(WordEntry(text: w, dueDate: nil))
                }
            }
        }
    }
    
    func updateQueueWords() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "(duedate < %@ OR duedate = NULL) AND category >= 0",
                                    WordManager.shared.now() as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.duedate, ascending: true)]
        queueWords.total = try! moc.count(for: req)
        if queueWords.fetchLimit > 0 {
            req.fetchLimit = queueWords.fetchLimit
        }
        let res = try! moc.fetch(req) as! [WordCard]
        if res.count > 0 {
            queueWords.words.removeAll()
            for c in res {
                if let w = c.word {
                    queueWords.words.append(WordEntry(text: w, dueDate: c.duedate))
                }
            }
        }
    }
    
    func updateRecentAdded() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "(duedate < %@ OR duedate = NULL) AND category >= 0",
                                    WordManager.shared.now() as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.createdAt, ascending: false)]
        recentAdded.total = try! moc.count(for: req)
        if recentAdded.fetchLimit > 0 {
            req.fetchLimit = recentAdded.fetchLimit
        }
        let res = try! moc.fetch(req) as! [WordCard]
        if res.count > 0 {
            recentAdded.words.removeAll()
            for c in res {
                if let w = c.word {
                    recentAdded.words.append(WordEntry(text: w, dueDate: c.duedate))
                }
            }
        }
    }
    
    func update() {
        updateQueueWords()
        updateRecentAdded()
        updateRecentLearned()
        
        #if DEBUG
        if recentLearned.words.count == 0 {
            recentLearned.total = 10
            for _ in 0...recentLearned.total {
                recentLearned.words.append(WordEntry(text: WordManager.shared.nextRandomWord()))
            }
        }
        #endif
        updateCounter += 1
    }
}

struct WordEntryList {
    var words: [WordEntry] = []
    var fetchLimit: Int = 10
    var total: Int = -1
    var count: Int {
        words.count
    }
    
    mutating func increaseLimit() {
        fetchLimit = fetchLimit + 10
        if total > 0 && fetchLimit > total + 10{
            fetchLimit = total
        }
    }
}

struct WordEntry: Identifiable {
    var id: String { text }
    
    var text: String
    var dueDate : Date?
}

extension Array where Element == WordEntry {
    func array() -> [String] {
        var out = [String]()
        for e in self {
            out.append(e.text)
        }
        return out
    }
}
