//
//  DataManager.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation
import CoreData

enum CardCategory : Int16 {
    // there are also REVIEW, RELEARN, LEECH in ANKI, but that may not be necesary
    // the priority should be LEARNING > NEW > LEARN
    case NEW = 0, LEARN, LEARNING
    case SUSPEND = -2 // because leech, forgot more than serveral times
    case BURIED = -1
}

enum CardRating : Int16 {
    case NOIDEA = 0,    // forgotten, unrecognized
         VAGUE,              // unsure, vague
         WELLKNOWN           // well-known
}

class WordManager {
    // ManagedObjectContext of CoreData / CloudKit / iCloud
    private let moc = CoreDataManager.shared.container.viewContext
    private var preparedStudyWord: String?
    
    static let shared = WordManager()
    
    private var dailyWordsGoal: Int {
        UserPreferences.shared.dailyGoal
    }
    
    func nextWord() -> String {
        
        switch Int.random(in: 0...5) {
        case 0:
            if let w = addedRecentlyWordList(fetchLimit: 20).words.randomElement() {
                return w.text
            }
        case 1,2:
            // next vague or no idea Word of today
            if let w = nextNoGoodWord() {
                return w
            }
        default:
            break
        }
        // next due word, LEARNING > NEW > LEARN
        if let w = nextDueWord(before: now(), catagory: .LEARNING) {
            return w
        }
        
        if let w = nextDueWord(before: now(), catagory: .NEW) {
            return w
        }
        
        if let w = nextDueWord(before: now(), catagory: .LEARN) {
            return w
        }
        
        // next word that I shoud review before the end of today
        if let w = nextDueWord(before: EndOfTheDay(today), catagory: .LEARNING) {
            return w
        }
        
        // next in perfered vocalbulary (SAT, GRE)
        if UserPreferences.shared.testPrepBook != 0 {
            return CompactLexicalIndex.shared.randomWords(
                book: UserPreferences.shared.testPrepBooks[UserPreferences.shared.testPrepBook],
                num: 1
            ).first ?? ""
        }
        return ""
    }
    
    func nextRandomWord() -> String {
        CompactLexicalIndex.shared.randomWord()
    }

    /// Reserves the exact next study word so its local explanation can be
    /// generated while the start/share screen is still visible. Repeated calls
    /// return the same reservation until a CardViewModel consumes it.
    @MainActor
    func prepareNextStudyWord() -> String {
        if let preparedStudyWord {
            return preparedStudyWord
        }

        let scheduledWord = nextWord()
        let word = scheduledWord.isEmpty ? nextRandomWord() : scheduledWord
        guard !word.isEmpty else { return "" }
        preparedStudyWord = word
        return word
    }

    @MainActor
    func takePreparedStudyWord() -> String? {
        defer { preparedStudyWord = nil }
        return preparedStudyWord
    }

    @MainActor
    func replacePreparedStudyWord() -> String {
        preparedStudyWord = nil
        return prepareNextStudyWord()
    }
    
    func nextDueWord(before due: Date, catagory: CardCategory) -> String? {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        // earliest due for LEARN and then NEW word
        req.predicate = NSPredicate(format: "(duedate < %@ OR duedate = NULL) AND category == %d",
                                    due as NSDate,
                                    catagory.rawValue)
        if catagory == .LEARNING {
            req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.duedate, ascending: true)]
        } else {
            // randomlize it
            let totalresults = try! moc.count(for: req)
            switch totalresults {
            case 0:
                return nil
            default:
                req.fetchOffset = Int.random(in: 0..<totalresults)
            }
        }
        
        req.fetchLimit = 1
        
        let res = try! moc.fetch(req) as! [WordCard]
        return res.first?.word
    }
    
    func nextNoGoodWord() -> String? {
        let begin = BeginOfTheDay(today)
        let end = EndOfTheDay(today)
        
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "AnswerHistory")
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND word.category >= 0",
                                    begin as NSDate,
                                    end as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \AnswerHistory.date, ascending: true)]
        
        let res = try! moc.fetch(req) as! [AnswerHistory]
        
        var ret  = [String]()
        var nogood = [String]()
        var recent = [String]()
        
        for ans in res {
            if let w = ans.word?.word {
                if !ret.contains(w) {
                    ret.append(w)
                }
                if recent.count <= 3 {
                    if !recent.contains(w) {
                        recent.append(w)
                    }
                }
                if ans.answer != CardRating.WELLKNOWN.rawValue {
                    if !nogood.contains(w) {
                        nogood.append(w)
                    }
                }
            }
        }
        
        if nogood.count > 0 {
            // random nogood word
            if let w = nogood.randomElement() {
                if recent.contains(w) {
                    return nil
                }
                return w
            }
        }
        return nil
    }
    
    // ------- WordList -------
    func learnedRecentlyWordList(fetchLimit: Int) -> WordList {
        var recentLearned = WordList()
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "AnswerHistory")
        req.predicate = NSPredicate(format: "word.category >= 0")
        req.sortDescriptors = [NSSortDescriptor(keyPath: \AnswerHistory.date, ascending: false)]
        req.resultType = NSFetchRequestResultType.dictionaryResultType
        req.propertiesToFetch   = [#keyPath(AnswerHistory.word.word)]
        req.returnsDistinctResults = true;
        recentLearned.total = try! moc.count(for: req)
        if fetchLimit > 0 {
            req.fetchLimit = fetchLimit
        }
        let res = try! moc.fetch(req) as! [NSDictionary]
        if res.count > 0 {
            print("MSG: \(fetchLimit) \(recentLearned.total) \(res.count)")
            for key in res {
                if let w = key.allValues[0] as? String {
                    if let wordcard = WordManager.shared.fetchWordCard(w) {
                        if wordcard.category >= 0 {
                            recentLearned.words.append(WordListEntry(text: w, dueDate: nil))
                        }
                    }
                }
            }
        }
        if res.count < fetchLimit {
            recentLearned.total = recentLearned.words.count
        }
        
        return recentLearned
    }
    
    func addedRecentlyWordList(fetchLimit: Int) -> WordList {
        var recentAdded = WordList()
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "(createdAt < %@ OR createdAt = NULL) AND category >= 0",
                                    WordManager.shared.now() as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.createdAt, ascending: false)]
        recentAdded.total = try! moc.count(for: req)
        if fetchLimit > 0 {
            req.fetchLimit = fetchLimit
        }
        let res = try! moc.fetch(req) as! [WordCard]
        if res.count > 0 {
            for c in res {
                if let w = c.word {
                    recentAdded.words.append(WordListEntry(text: w, dueDate: c.duedate))
                }
            }
        }
        return recentAdded
    }
    
    func queueWordList(fetchLimit: Int) -> WordList {
        var queueWords = WordList()
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "(duedate < %@ OR duedate = NULL) AND category >= 0",
                                    WordManager.shared.now() as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \WordCard.duedate, ascending: true)]
        queueWords.total = try! moc.count(for: req)
        if fetchLimit > 0 {
            req.fetchLimit = fetchLimit
        }
        let res = try! moc.fetch(req) as! [WordCard]
        if res.count > 0 {
            for c in res {
                if let w = c.word {
                    queueWords.words.append(WordListEntry(text: w, dueDate: c.duedate))
                }
            }
        }
        return queueWords
    }
    
    // ------- Cache -------
    @MainActor
    func getCachedExplanation(word: String) -> VocabularyExplanation? {
        guard let reference = getCachedExplanationReference(word: word),
              reference.valid,
              let data = reference.desc?.data(using: .utf8),
              let cached = try? JSONDecoder().decode(
                  CachedVocabularyExplanation.self,
                  from: data
              ),
              cached.isCurrent else {
            return nil
        }
        return cached.explanation
    }

    @MainActor
    private func getCachedExplanationReference(word: String) -> Reference? {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Reference")
        req.predicate = NSPredicate(
            format: "word = %@ AND source = %d",
            LocalTutorConfiguration.normalizedCacheWord(word),
            LocalTutorConfiguration.cacheSource
        )
        req.fetchLimit = 1
        return (try? moc.fetch(req) as? [Reference])?.first
    }

    @MainActor
    func setCachedExplanation(word: String, explanation: VocabularyExplanation) {
        let reference = getCachedExplanationReference(word: word) ?? Reference(context: moc)
        let cached = CachedVocabularyExplanation(explanation: explanation)

        reference.valid = true
        reference.word = LocalTutorConfiguration.normalizedCacheWord(word)
        reference.source = LocalTutorConfiguration.cacheSource
        reference.desc = try? String(
            data: JSONEncoder().encode(cached),
            encoding: .utf8
        )
        saveExplanationCache()
    }

    @MainActor
    func removeCachedExplanation(word: String) {
        guard let reference = getCachedExplanationReference(word: word) else { return }
        moc.delete(reference)
        saveExplanationCache()
    }

    @MainActor
    private func saveExplanationCache() {
        guard moc.hasChanges else { return }
        do {
            try moc.save()
        } catch {
            print("Unable to save local explanation cache: \(error.localizedDescription)")
        }
    }
    
    // ------- Search ------
    func searchHints(_ input: String) -> [String]? {
        CompactLexicalIndex.shared.searchHints(input)
    }
    
    // ------- WordCard ------
    
    func addWordCard(_ word: String) -> WordCard? {
        if let wc = fetchWordCard(word) {
            // skip this already existed word
            wc.category = CardCategory.NEW.rawValue
            wc.createdAt = WordManager.shared.now()
            wc.duedate = WordManager.shared.now()
            return nil
        }
        
        let wc = WordCard.init(context: moc)
        wc.word = word
        wc.createdAt = WordManager.shared.now()
        return wc
    }
    
    func fetchWordCard(_ word: String) -> WordCard? {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "word LIKE %@", word)
        req.fetchLimit = 1
        
        let res = try! moc.fetch(req) as! [WordCard]
        return res.first
    }
    
    func ensureWordCard(_ word: String) -> WordCard? {
        if let card = fetchWordCard(word) {
            return card
        }
        return addWordCard(word)
    }
    
    func IsWordCardExist(_ word: String) -> Bool {
        // check is the word is in the wordbook
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "word LIKE %@", word)
        req.fetchLimit = 1
        do {
            return try moc.count(for: req) > 0
        } catch let error {
            print("count error \(error.localizedDescription)")
        }
        return false
    }
    
    func buryWordCard(_ word: String) {
        if let wc = fetchWordCard(word) {
            wc.category = CardCategory.BURIED.rawValue
            WordManager.shared.fetchEngagement().buried += 1
        }
    }
    
    func unburyWordCard(_ word: String) {
        if let wc = fetchWordCard(word) {
            wc.category = CardCategory.NEW.rawValue
            wc.duedate = nil
            
            let e = WordManager.shared.fetchEngagement()
            if e.buried > 0 {
                e.buried -= 1
            }
        }
    }
    
    // ------- Answer -------
    func answer(_ word: String, _ rate: CardRating) {
        guard let card = ensureWordCard(word) else {
            fatalError()
        }
        
        print ("MSG: Answering \(word) -> \(rate)")
        
        AnswerHistory.add(rate, card: card, duration: PausableTimer.shared.end())
        
        if rate == .NOIDEA && card.category > CardCategory.NEW.rawValue {
            // if not a new card, and forgot, means it possiblly is a leech card
            card.leech+=1
        }
        
        // become LEARNING after answered amd priotize
        card.category = CardCategory.LEARNING.rawValue
        
        switch rate {
        case .WELLKNOWN:
            // step up
            card.step += 1
            card.extendDuedate(from:today)
            
        case .VAGUE:
            card.step = 0
            fallthrough
        case .NOIDEA:
            card.updateDueByMinute(1)
        }
        
        refreshTodayEngagement()
    }
    
    // ------ Engagement ------
    func fetchEngagement() -> Engagement {
        fetchEngagement(today)
    }
    
    func fetchEngagement(_ day: Int32) -> Engagement {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "Engagement")
        req.predicate = NSPredicate(format: "day = %d", day)
        req.fetchLimit = 1
        let res = try! moc.fetch(req) as! [Engagement]
        guard let ret = res.first else {
            let eg = Engagement.init(context: moc)
            eg.day = day
            eg.goal = Int16(dailyWordsGoal)
            return eg
        }
        return ret
    }

    /// Rebuilds today's cached statistics from AnswerHistory and persists any
    /// resulting changes. UI entry points share this path so an app upgrade can
    /// repair the current study day before displaying its totals.
    @discardableResult
    func refreshTodayEngagement() -> Engagement {
        let engagement = fetchEngagement()
        engagement.update()
        CoreDataManager.shared.save()
        return engagement
    }
    
    // ---------
    func wordsOfToday() -> [String] {
        var ret = [String]()
        
        // TODO: what about buried words
        let res = AnswerHistory.fetch(BeginOfTheDay(today), EndOfTheDay(today))
        for ans in res {
            if let w = ans.word?.word {
                if !ret.contains(w) {
                    ret.append(w)
                }
            }
        }
        
        return ret
    }
    
    // return dictionary of Word: RatingCount
    // RatingCount: GOOD = 0, VAGUE = 1, NOIDEA = 2
    func wordsOfTodayWithRatingCount() -> [String: Int] {
        var ret = [String: Int]()
        
        let res = AnswerHistory.fetch(BeginOfTheDay(today), EndOfTheDay(today))
        for ans in res {
            if let w = ans.word?.word {
                print("MSG: \(w) \(ans.answer)")
                switch ans.answer {
                case CardRating.VAGUE.rawValue:
                    ret[w] = 1 + (ret[w] ?? 0)
                case CardRating.NOIDEA.rawValue:
                    ret[w] = 2 + (ret[w] ?? 0)
                default: // case CardRating.WELLKNOWN.rawValue:
                    if ret[w] == nil {
                        ret[w] = 0
                    }
                }
            }
        }
        return ret
    }
    
    // ------- Date Functions -------
    let cutoffHour = 4
    var pseudoTime: Date?
    var today: Int32 {
        day(from: now())
    }
    
    /// Local civil-day anchor for the integer IDs stored in Engagement.
    /// Using the absolute Unix epoch directly made the ID roll over at the
    /// epoch's local clock time (16:00 in Los Angeles), not at the study cutoff.
    /// This mapping intentionally follows the device's current calendar and
    /// time zone; it is not a cross-time-zone identifier.
    private var dayAnchor: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 0))
    }

    // A study day begins at 4 AM local time. Dates before that cutoff belong
    // to the previous civil day, matching the review/reset behavior.
    func day(from date: Date) -> Int32 {
        let calendar = Calendar.current
        let civilDay = calendar.startOfDay(for: date)
        let cutoff = calendar.date(
            bySettingHour: cutoffHour,
            minute: 0,
            second: 0,
            of: civilDay
        )!
        let studyCivilDay = date < cutoff
            ? calendar.date(byAdding: .day, value: -1, to: civilDay)!
            : civilDay
        return Int32(
            calendar.dateComponents(
                [.day],
                from: dayAnchor,
                to: studyCivilDay
            ).day!
        )
    }
    
    func date(from day: Int32) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: Int(day),
            to: dayAnchor
        )!
    }
    
    func BeginOfTheDay(_ day: Int32) -> Date {
        Calendar.current.date(
            bySettingHour: cutoffHour,
            minute: 0,
            second: 0,
            of: date(from: day)
        )!
    }
    
    /// Exclusive end of the study day. Calendar arithmetic keeps the cutoff
    /// at 4 AM across 23- and 25-hour daylight-saving transitions.
    func EndOfTheDay(_ day: Int32) -> Date {
        BeginOfTheDay(day + 1)
    }
    
    func todayDateString() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: self.date(from: self.today))
    }
    
    func now() -> Date {
        if let now = self.pseudoTime {
            return now
        }
        return Date()
    }
}

extension WordCard {
    func extendDuedate(from day: Int32) {
        // TODO: consider lastseen
        // TODO: add viration
        switch self.step {
        case 0:
            self.updateDueByMinute(1)
        case 1:
            self.updateDueByMinute(15)
        case 2:
            self.updateDueByDay(1)
        case 3:
            self.updateDueByDay(7)
        case 4:
            self.updateDueByDay(15)
        case 5:
            self.updateDueByDay(30)
        case 6: // ENDING
            self.updateDueByDay(75)
        case 7: // ENDED
            self.updateDueByDay(200)
        default:
            fatalError()
        }
    }
    
    func updateDueByMinute(_ num: Double) {
        self.duedate = WordManager.shared.now().addingTimeInterval(num*60+Double.random(in: 0..<(num*10)))
        print("updateDueByMinute \(String(describing: self.duedate))")
    }
    
    func updateDueByDay(_ num: Int32) {
        self.duedate = WordManager.shared.BeginOfTheDay(WordManager.shared.today + num
                                                        + (num >= 2 ? Int32.random(in: 0...num/2) : 0))
        // MAYBE: not reset category for learning cards?
        self.category = CardCategory.LEARN.rawValue
        print("updateDueByDay \(String(describing: self.duedate))")
    }
}


extension AnswerHistory {
    static let moc = CoreDataManager.shared.container.viewContext
    
    static func add(_ rating: CardRating, card: WordCard, duration: Double) {
        let log = AnswerHistory.init(context: moc)
        log.word = card
        log.date = WordManager.shared.now()
        log.answer = rating.rawValue
        log.duration = duration
    }
    
    static func fetch(_ begin: Date, _ end: Date) -> [AnswerHistory] {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "AnswerHistory")
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND word.category >= 0", begin as NSDate, end as NSDate)
        
        return try! moc.fetch(req) as! [AnswerHistory]
    }
}

extension Engagement {
    // update every part of engagement record
    func update() {
        var timespend = Double(0)
        let begin = WordManager.shared.BeginOfTheDay(day)
        let end = WordManager.shared.EndOfTheDay(day)
        
        let res = AnswerHistory.fetch(begin, end)
        
        var worstAnswer = [String: Int16]()
        var bestAnswer = [String: Int16]()
        for rec in res {
            timespend += rec.duration
            if let word = rec.word?.word {
                if let ans = worstAnswer[word] {
                    worstAnswer[word] = min(ans, rec.answer)
                } else {
                    worstAnswer[word] = rec.answer
                }
                
                if let ans = bestAnswer[word] {
                    bestAnswer[word] = max(ans, rec.answer)
                } else {
                    bestAnswer[word] = rec.answer
                }
            }
        }
        
        var goodAnswerCount: Int16 = 0
        var vagueAnswerCount: Int16 = 0
        var noideaAnswerCount: Int16 = 0
        var noGoodAnswerCount: Int16 = 0
        for ans in bestAnswer {
            switch ans.value {
            case CardRating.WELLKNOWN.rawValue:
                goodAnswerCount += 1
            case CardRating.NOIDEA.rawValue:
                noGoodAnswerCount += 1
                noideaAnswerCount += 1
            case CardRating.VAGUE.rawValue:
                noGoodAnswerCount += 1
                vagueAnswerCount += 1
            default:
                print("should not happening")
            }
        }
        
        if self.noidea != noideaAnswerCount {
            self.noidea = noideaAnswerCount
        }
        if self.vague != vagueAnswerCount {
            self.vague = vagueAnswerCount
        }
        if self.good != goodAnswerCount {
            self.good = goodAnswerCount
        }
        
        // how many answered today but due day is tommorow
        if self.finished != goodAnswerCount {
            self.finished = goodAnswerCount
        }
        if self.working != noGoodAnswerCount {
            self.working = noGoodAnswerCount
        }
        
        // update time spend
        if abs(self.duration - timespend) > 0.000_001 {
            self.duration = timespend
        }
    }
}

struct WordList {
    var words: [WordListEntry] = []
    var total: Int = -1
    var count: Int {
        words.count
    }
}

struct WordListEntry: Identifiable {
    var id: String { text }
    
    var text: String
    var dueDate : Date?
}

extension Array where Element == WordListEntry {
    func array() -> [String] {
        var out = [String]()
        for e in self {
            out.append(e.text)
        }
        return out
    }
}
