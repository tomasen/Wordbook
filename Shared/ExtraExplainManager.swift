//
//  WikiClient.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/28/21.
//

import Foundation
import WikipediaKit
import SwiftSoup

struct ExtraExplain: Identifiable {
    var id: Int = UUID().hashValue
    var title: String
    var source: ExtraExplainSource
    var expl: String
    var url: URL?
}

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

struct ExtraExplainManager {
    static let shared = ExtraExplainManager()
    
    public func queryWiki(_ word: String, _ completion: @escaping (_ result: ExtraExplain)->()) {
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
            let expl = article.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            if expl.count > 0 && !expl.lowercased().contains("may refer to") {
                let result = ExtraExplain(title: article.displayTitle,
                                          source: .WIKI,
                                          expl: expl,
                                          url: article.url)
                WordManager.shared.setCache(word: word, extraExplain: result)
                completion(result)
            }
        }
    }
    
    public func queryVocab(_ word: String, _ completion: @escaping (_ result: ExtraExplain)->()) {
        if var expl = WordManager.shared.getCache(word: word, source: .VOCAB) {
            if expl.url == nil {
                expl.url = expl.source.url(expl.title)
            }
            completion(expl)
            return
        }
        
        guard let compoment = word.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return
        }
        
        guard let url = URL(string: "https://www.vocabulary.com/dictionary/definition.ajax?search=\(compoment)") else {
            return
        }

        let task = URLSession.shared.dataTask(with: url) {(data, response, error) in
            guard let data = data else { return }
            do {
                let html = String(data: data, encoding: .utf8)!
                let doc: Document = try SwiftSoup.parseBodyFragment(html)
                
                var desc : String = ""
                if let long = try doc.select("p.long").first()?.text() {
                    desc = long
                } else if let short = try doc.select("p.short").first()?.text() {
                    desc = short
                }
                desc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                if desc.count > 0 {
                    let result = ExtraExplain(title: word,
                                              source: .VOCAB,
                                              expl: desc,
                                              url: ExtraExplainSource.VOCAB.url(word))
                    
                    WordManager.shared.setCache(word: word, extraExplain: result)
                    completion(result)
                }
            } catch Exception.Error(let type, let message) {
                print(type, message)
            } catch {
                print("error: fetching vocab, \(error)")
            }
        }

        task.resume()
    }
}
