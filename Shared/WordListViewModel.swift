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
    @Published var Learned: [String] = []
    
    func Update() {
        self.Learned.append(WordManager.shared.nextWord())
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
