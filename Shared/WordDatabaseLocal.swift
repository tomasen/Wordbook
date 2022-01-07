
import Foundation
import SQLite

struct Sense: Identifiable {
    var id: Int64
    
    // part-of-speech
    var pos: String
    var gloss: String
    var examples: [String]
    var synonyms: [String]
}

struct WordDefinition {
    var word: String
    var senses: [Sense]
    var pronunc: String?
    var sound: Data?
    var extras: [ExtraExplain]
}

struct WordDatabaseLocal {
    private let db = ((Bundle.main.path(forResource: "wordnet", ofType: "sqlite") != nil) ?
                      try! Connection(Bundle.main.path(forResource: "wordnet", ofType: "sqlite")!, readonly: true) :
                        try! Connection(Bundle.main.path(forResource: "wordnet-lite", ofType: "sqlite")!, readonly: true))
    
    static let shared = WordDatabaseLocal()
    
    func searchHints(_ input: String) -> [String]? {
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
    
    func explain(_ lex: String) -> (word: String, senses: [Sense], pronunc: String?, sound: Data?) {
        var pronunc: String? = nil
        var senses = [Sense]()
        var sound: Data? = nil
        
        var stmt = try! db.prepare("""
        SELECT word, pronunc, id
        FROM word WHERE word = ?
        LIMIT 1
        """)
        var word: String = ""
        var wordid: Int64 = 0
        for row in try! stmt.run(lex) {
            word = row[0] as! String
            pronunc = row[1] as! String?
            wordid = row[2] as! Int64
        }
        
        if wordid <= 0 {
            // word not found
            return (lex, [], nil, nil)
        }
        
        stmt = try! db.prepare("""
        SELECT lexid, sstype, glossid,
        (SELECT gloss FROM gloss
        WHERE gloss.id = sense.glossid) AS gloss
        FROM sense WHERE sense.wordid = ?
        ORDER BY lexid ASC
        """)
        
        for row in try! stmt.run(wordid) {
            //let lexid = Int(row[0] as! Int64)
            let ssType = row[1] as! String
            let glossid = row[2] as! Int64
            let gloss = row[3] as! String
            
            let examples = findExample(glossid: glossid, mustInclude: word)
            let synonyms = findSynonym(glossid: glossid, except: word)
            
            senses.append(Sense(id: glossid,
                                pos: ssType, gloss: gloss,
                                examples: examples, synonyms: synonyms))
        }
        
        stmt = try! db.prepare("""
        SELECT sound FROM sound WHERE wordid = ? LIMIT 1
        """)
        
        for row in try! stmt.run(wordid) {
            if let blob = row[0] as! SQLite.Blob? {
                sound = Data(bytes: blob.bytes, count: blob.bytes.count)
            }
        }
        return (word, senses, pronunc, sound)
    }
    
    
    private func findSynonym(glossid: Int64, except: String) -> [String] {
        let stmt = try! db.prepare("""
        SELECT word
        FROM word, sense
        WHERE word.id = sense.wordid AND glossid = ?
        """)
        
        var synonyms = [String]()
        for row in try! stmt.run(glossid) {
            let w = row[0] as! String
            if w != except {
                synonyms.append(w)
            }
        }
        
        return synonyms.filter {
            !$0.contains(" ") && !$0.contains("-") 
        }
    }
    
    private func findExample(glossid: Int64, mustInclude: String) -> [String] {
        // find examples
        let exmpStmt = try! db.prepare("""
        SELECT example
        FROM example WHERE glossid = ? AND example LIKE ?
        """)
        var examples = [String]()
        for row in try! exmpStmt.run(glossid, "%"+mustInclude+"%") {
            examples.append(row[0] as! String)
        }
        return examples
    }
    
    func exist(_ lex: String) -> String? {
        var stmt = try! db.prepare("""
        SELECT word
        FROM word WHERE word = ?
        LIMIT 1
        """)
        for row in try! stmt.run(lex) {
            return row[0] as? String
        }
        
        stmt = try! db.prepare("""
        SELECT word
        FROM word WHERE word LIKE ?
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
    
    func randomWords(book tag: String, num: Int) -> [String] {
        let stmt = try! db.prepare("""
        SELECT word
        FROM word, bookref, book
        WHERE word.id = bookref.wordid AND
        bookref.bookid = book.id AND
        book.tag LIKE ?
        ORDER BY RANDOM()
        LIMIT ?
        """)
        
        var ret = [String]()
        for row in try! stmt.run(tag+"%", num) {
            ret.append(row[0] as! String)
        }
        return ret
    }
    
    // RandomWord fetch one random word from wordnet
    func randomWord() -> String {
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
    
    func explainAlias(_ word: String) -> [String] {
        let stmt = try! db.prepare("""
        SELECT word.word, alias.reason
        FROM word, alias WHERE alias.alias LIKE ?
        AND word.id = alias.wordid
        LIMIT 1
        """)
        for row in try! stmt.run(word) {
            let originWord = row[0] as! String
            return explainExact(originWord)
        }
        return [String]()
    }
    
    func explainExact(_ word: String) -> [String] {
        var ret = [String]()
        
        let stmt = try! db.prepare("""
        SELECT sense.sstype, gloss.gloss
        FROM word, sense, gloss WHERE word.word LIKE ?
        AND sense.wordid = word.id
        AND gloss.id = sense.glossid
        """)
        
        for row in try! stmt.run(word) {
            // let ssType = row[0] as! String
            let gloss = row[1] as! String
            
            ret.append(gloss)
        }
        return ret
    }
}
