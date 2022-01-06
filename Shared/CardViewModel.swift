//
//  CardViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation

class CardViewModel: ObservableObject {
    @Published var word = ""
    @Published var alsoKnownAs: String? = nil
    @Published var sound: Data? = nil
    @Published var pronunciation: String? = ""
    @Published var mnemonic: String? = nil
    @Published var senses: [Sense] = [Sense(id: 0, pos: "▩.", gloss: "▩▩▩▩▩▩▩▩▩▩▩\n▩▩▩▩▩▩▩", examples: [], synonyms: []),
                                      Sense(id: 1, pos: "▩.", gloss: "▩▩▩▩▩▩▩\n▩▩▩▩▩▩▩▩▩▩▩▩▩", examples: ["▩▩▩▩▩▩, ▩▩▩▩▩▩"], synonyms: [String]()),
                                      Sense(id: 2, pos: "▩.", gloss: "▩▩▩▩▩▩▩▩▩▩▩▩▩▩▩▩▩\n▩▩▩▩▩▩▩▩▩▩▩▩▩", examples: [], synonyms: [])]
    @Published var extras = [ExtraExplainSource: ExtraExplain]()
    
    init(_ w: String = "") {
        word = w
    }
    
    var summaryExplain: String {
        if senses.count == 0 {
            return "▩▩▩▩▩\n▩▩▩▩▩▩▩▩▩\n▩▩▩"
        }
        var ret = [String]()
        for s in senses {
            ret.append(s.gloss)
        }
        return ret.joined(separator: "; ")
    }
    
    // fetch explanation of word
    func fetchExplain() {
        APIClient().query(term: word,
                          completion: self.handleAPIExplanation)
        
        // check wiki
        if extras[.WIKI] == nil {
            ExtraExplainManager.shared.queryWiki(word, handleExtraExplain)
        }
        
        if InAppPurchaseManager.shared.isSuperUser {
            // check vocab
            if extras[.VOCAB] == nil {
                ExtraExplainManager.shared.queryVocab(word, handleExtraExplain)
            }
        }
    }
    
    private func handleExtraExplain(_ result: ExtraExplain) {
        DispatchQueue.main.async {
            self.extras[result.source] = result
        }
    }
    
    private func handleAPIExplanation(_ result: WordDefinition?) {
        DispatchQueue.main.async {
            guard let expl = result else {
                self.fetchExplainFromLocalDatabase()
                return
            }
            if self.word != expl.word {
                self.alsoKnownAs = expl.word
            }
            
            self.senses = expl.senses
            for e in expl.extras {
                self.extras[e.source] = e
            }
        }
    }
    
    func fetchExplainFromLocalDatabase() {
        DispatchQueue.global(qos: .background).async {
            let result = WordDatabaseLocal.shared.explain(self.word)
            DispatchQueue.main.async {
                self.senses = result.senses
                self.pronunciation = result.pronunc
                self.sound = result.sound
            }
        }
    }
    
    // set next word if word is empty
    func validate() {
        if word.count == 0 {
            word = WordManager.shared.nextWord()
            if word.count == 0 {
                word = WordManager.shared.nextRandomWord()
            }
        }
    }
    
    func answer(_ rate: CardRating) {
        WordManager.shared.answer(word, rate)
    }
}

class APIRequest {
    let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    func perform<T: Decodable>(with completion: @escaping (T?) -> Void) {
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.dataTask(with: url) { (data, _, _) in
            guard let data = data else {
                completion(nil)
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            completion(try? decoder.decode(T.self, from: data))
        }
        task.resume()
    }
}

