//
//  WikiClient.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/28/21.
//

import Foundation
import WikipediaKit

enum ExtraExplainSource : Int16 {
    case NONE
    case WIKI
    case VOCAB
    case ORIGIN
    
    var desc : String {
        switch self {
        case .WIKI: return "Wikipedia"
        case .VOCAB: return "Vocabulary.com"
        case .NONE: return "Untitled"
        case .ORIGIN: return "Origin"
        }
    }
    
    func url(_ title: String) -> URL? {
        switch self {
        case .WIKI:
            return URL(string: "https://en.wikipedia.org/wiki/\(title.urlencode())")
        case .VOCAB:
            return URL(string: "https://www.vocabulary.com/dictionary/\(title.urlencode())")
        default:
            return nil
        }
    }
}

struct WikiExplainClient {
    static let shared = WikiExplainClient()
    
    public func query(_ word: String, _ completion: @escaping (_ result: ExtraExplain)->()) {
        if var expl = WordManager.shared.getCache(word: word, source: .WIKI) {
            if expl.url == nil {
                expl.url = expl.source.url(expl.title)
            }
            completion(expl)
            return
        }
        
        // TODO: set by perference
        let language = WikipediaLanguage("en")
        
        // You need to pass in the maximum width
        // in pixels for the returned thumbnail URL,
        // for example the screen width:
        let _ = Wikipedia.shared.requestArticleSummary(language: language,
                                                       title: word)
        { (article, error) in
            guard error == nil else {
                print(error as Any)
                return
            }
            guard let article = article else {
                print("invalid wiki article")
                return
            }
            let trimed = article.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimed.count > 0 && !trimed.lowercased().contains("may refer to") {
                let result = ExtraExplain(title: article.displayTitle,
                                          source: .WIKI,
                                          expl: article.displayText,
                                          url: article.url)
                WordManager.shared.setCache(word: word, extraExplain: result)
                completion(result)
            }
        }
    }
}
