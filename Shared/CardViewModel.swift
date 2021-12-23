//
//  CardViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation

class CardViewModel: ObservableObject {
    @Published var word = ""
    @Published var sound: Data? = nil
    @Published var pronunciation: String? = ""
    @Published var mnemonic: String? = nil
    @Published var senses = [Sense]()
    @Published var extras = [SimpleExplanation]()
    
    // fetch explanation of word
    func fetchExplain() {
        if AppStoreManager.shared.isProUser{
            APIClient().query(term: word,
                              completion: self.handleAPIExplanation)
        } else {
            fetchExplainFromLocalDatabase()
        }
    }
    
    private func handleAPIExplanation(_ result: WordExplanation?) {
        guard let expl = result else {
            fetchExplainFromLocalDatabase()
            return
        }
        word = expl.word
        senses = expl.senses
        extras = expl.extras
    }
    
    private func fetchExplainFromLocalDatabase() {
        let result = WordDatabaseLocal.shared.explain(word)
        senses = result.senses
        pronunciation = result.pronunc
        sound = result.sound
    }
    
    // set next word if word is empty
    func validate() {
        if word == "" {
            word = WordManager.shared.nextWord()
        }
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

