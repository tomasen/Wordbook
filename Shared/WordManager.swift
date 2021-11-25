//
//  DataManager.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation

class WordManager {
    let persistentContainer = CoreDataManager.shared
    static let shared = WordManager()
    
    func NextWord() -> String {
        return WordDatabase.shared.RandomWord()
    }
}
