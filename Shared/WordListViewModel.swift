//
//  WordListViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/26/21.
//

import Foundation

class WordListViewModel: ObservableObject {
    @Published var Learned: [String] = []
    @Published var RecentAdded: [EntryInfo] = []
    @Published var NewWords: [String] = []
    @Published var QueueWords: [String] = []
    
    init() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true, block: { _ in
            self.Learned.append(WordManager.shared.NextWord())
        })
    }
    
    func Update() {
        
    }
}

struct EntryInfo: Hashable {
    var Word : String
    var Date : Date?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(Word)
        hasher.combine(Date)
    }
    
    static func == (lhs: EntryInfo, rhs: EntryInfo) -> Bool {
        return lhs.Word == rhs.Word && lhs.Date == rhs.Date
    }
}
