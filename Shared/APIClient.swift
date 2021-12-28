//
//  APIClient.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/23/21.
//

import Foundation

class APIClient {
    struct APILexico: Decodable {
        var Word: String
        var Phonetics: [APIPhonetic]?
        var Senses: [APISense]?
        var Etymologies: [String]?
        var Inflections: [String]?
        var Derivatives: [String]?
    }
    
    struct APIPhonetic: Decodable {
        var Text:      String
        var AudioURI:  String?
        var AudioData: Data?
    }
    
    struct APISense: Decodable {
        var LexicalCategory: String // noun, verb, etc.
        var Definition:      String
        var Examples:        [String]?
        var Synonyms:        [String]?
        var Antonyms:        [String]?
    }
    
    public func query(term: String, nest: Int = 0, completion: @escaping (_ result: WordDefinition?)->()) {
        guard let term = term.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            completion(nil)
            return
        }
        guard let url = URL(string: "https://api.wordbook.cool/v1/api/q/" + term) else { return }
        URLSession.shared.dataTask(with: url) { (data, _, e) in
            if e != nil {
                completion(nil)
                return
            }
            
            do {
                let ret = try JSONDecoder().decode(APILexico.self, from: data!)
                if ret.Senses != nil {
                    DispatchQueue.main.async {
                        var senses = [Sense]()
                        if let rs = ret.Senses {
                            for s0 in rs {
                                senses.append(Sense(id: Int64(UUID().hashValue),
                                                    pos: self.fixLexCat(s0.LexicalCategory),
                                                    gloss: s0.Definition,
                                                    examples: s0.Examples ?? [],
                                                    synonyms: s0.Synonyms ?? []))
                            }
                        }
                        var extras = [ExtraExplain]()
                        if let re = ret.Etymologies {
                            for s1 in re {
                                extras.append(ExtraExplain(title: ret.Word,
                                                           source: .ORIGIN,
                                                           expl: s1))
                            }
                        }
                        completion(WordDefinition(word: ret.Word, senses: senses, pronunc: nil, sound: nil, extras: extras))
                    }
                } else {
                    if let der = ret.Derivatives?.first {
                        if nest > 2 {
                            print("too many nested call \(der)")
                            completion(nil)
                            return
                        }
                        self.query(term: der, nest: nest+1, completion: completion)
                    } else {
                        completion(nil)
                        return
                    }
                }
            } catch {
                print("Unexpected error: \(error).")
                completion(nil)
            }
        }
        .resume()
    }
    
    private func fixLexCat(_ cat: String) -> String {
        switch cat {
        case "noun":
            return "n"
        case "verb":
            return "v"
        case "adjective":
            return "adj"
        case "abbreviation":
            return "ab"
        case "adverbs", "adverb":
            return "adv"
        case "symbol":
            return "s"
        case "pronoun":
            return "pro"
        case "predeterminer":
            return "pdt"
        case "determiner":
            return "det"
        case "interjection":
            return "int"
        default:
            return cat
        }
    }
}
