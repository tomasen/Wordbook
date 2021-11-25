//
//  CardViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation

class CardViewModel: ObservableObject {
    @Published var word = ""
 
    func UpdateWord(_ w: String) {
        if w == "" {
            word = WordManager.shared.NextWord()
        } else {
            if word != w {
                word = w
                // TODO: fetch explanation
            }
        }
    }
}
