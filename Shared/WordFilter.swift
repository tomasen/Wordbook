//
//  WordParser.swift
//  Memorable
//
//  Created by tomasen on 2/4/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import Foundation

class WordFilter {
    static var shared = WordFilter()
    
    // remove words not worth the time
    // TODO: fill in more skip words: determiners, prepositions, pronouns, conjunctions, and particles
    let skipWords = ["of", "is", "he", "she", "on", "in", "into", "the", "to",
                     "this", "that", "or", "a", "and", "their", "us", "we", "what",
                     "which", "whether", "it", "its", "with", "at", "by", "onto",
                     "for", "when"]
    
    
    // remove english words put to array of .words, space seperated .plainText
    // TODO: and attributedText with definitions
    func filter(from text:String) -> [String] {
        var words: [String] = []
        
        let substrings = text.lowercased().split(whereSeparator: { !$0.isASCII || !$0.isLetter })
        var lexemes = [String]()
        substrings.forEach { word in
            lexemes.append(String(word))
        }

        // now start to find phrase
        while lexemes.count > 0 {
            let w = longestNextPhrase(words: &lexemes)
            // remove words not worth the time like of, is, he, she, I
            if !self.skipWords.contains(w) && w.count>1{
                words.append(w)
            }
        }
          
        return words
    }
    
    private func longestNextPhrase(words: inout [String]) -> String {
        if words.count <= 0 {
            return ""
        }
        
        for n in words.indices.reversed() {
            let q = words[0...n].joined(separator: " ")
            if self.skipWords.contains(q) {
                break
            }
            if let w = WordDatabaseLocal.shared.exist(q) {
                words.removeSubrange(0...n)
                return w
            }
        }
        
        // if not found, return the first one
        let w = words[0]
        words.remove(at: 0)
        return w
    }
}
