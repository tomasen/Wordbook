//
//  DataManager.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation


enum CardCategory : Int16 {
    case NEW = 0, LEARN, LEARNING // there are also REVIEW, RELEARN, LEECH in ANKI, but that may not be necesary
    case SUSPEND = -2 // because leech, forgot more than serveral times
    case BURIED = -1
}

class WordManager {
    let persistentContainer = CoreDataManager.shared
    static let shared = WordManager()
    
    func NextWord() -> String {
        return WordDatabase.shared.RandomWord()
    }
    
    func ListWord() -> [String] {
        
        return []
    }
}
