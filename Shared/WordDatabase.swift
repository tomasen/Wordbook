
import Foundation
import SQLite

struct WordDatabase {
    private let db = ((Bundle.main.path(forResource: "wordnet", ofType: "sqlite") != nil) ?
        try! Connection(Bundle.main.path(forResource: "wordnet", ofType: "sqlite")!, readonly: true) :
        try! Connection(Bundle.main.path(forResource: "wordnet-lite", ofType: "sqlite")!, readonly: true))
    
    static let shared = WordDatabase()
    
    func GetSearchHints(input: String) -> [String]? {
        if (input.count < 2) {
            return nil
        }
        let stmt = try! db.prepare("""
        SELECT DISTINCT word
        FROM word WHERE word LIKE ? OR id = (SELECT wordid FROM alias WHERE alias LIKE ?)
        ORDER BY (CASE WHEN word = ? THEN -4
        WHEN id = (SELECT wordid FROM alias WHERE alias = ?) THEN -3
        WHEN word LIKE ? THEN -2
        WHEN id = (SELECT wordid FROM alias WHERE alias LIKE ?) THEN -1
        ELSE phrase END) ASC, RANDOM()
        LIMIT 30
        """)
        
        var ret = [String]()
        for row in try! stmt.run(input+"%", input+"%", input, input, input+"%", input+"%") {
            let word = row[0] as! String
            ret.append(word)
        }
        return ret
    }
    
    func find(_ lex: String) -> String? {
        var stmt = try! db.prepare("""
        SELECT word
        FROM word WHERE word = ?
        LIMIT 1
        """)
        for row in try! stmt.run(lex) {
            return row[0] as? String
        }
        
        stmt = try! db.prepare("""
        SELECT word.word
        FROM word, alias WHERE alias.alias LIKE ?
        AND word.id = alias.wordid
        LIMIT 1
        """)
        for row in try! stmt.run(lex) {
            return row[0] as? String
        }
        return nil
    }
    
    func RandomWords(book tag: String, num: Int) -> [String] {
        let stmt = try! db.prepare("""
        SELECT word
        FROM word, bookref, book
        WHERE word.id = bookref.wordid AND
        bookref.bookid = book.id AND
        book.tag = ?
        ORDER BY RANDOM()
        LIMIT ?
        """)
        
        var ret = [String]()
        for row in try! stmt.run(tag, num) {
            ret.append(row[0] as! String)
        }
        return ret
    }
    
     // RandomWord fetch one random word from wordnet
    func RandomWord() -> String {
        // only show word instead of pharse
        let stmt = try! db.prepare("""
        SELECT word
        FROM word
        WHERE phrase = 0
        ORDER BY RANDOM()
        LIMIT 1
        """)
        
        for row in try! stmt.run() {
            let word = row[0] as! String
            return word
        }
        
        fatalError("error: out of random word impossibly")
    }
}
