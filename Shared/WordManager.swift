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
    
    static let shared = WordManager()
    
    func nextWord() -> String {
        if iCloudState.shared.enabled {
            // next vague or no idea Word of today
            if let w = nextNoGoodWord() {
                return w
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
            
            // TODO: next in perfered vocalbulary (SAT, GRE)
            
            // TODO: Engagement.checkin(day: scheduler.today)
            
            return ""
        } else {
            return WordDatabaseLocal.shared.randomWord()
        }
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
        req.predicate = NSPredicate(format: "date > %@ AND date < %@",
                                    begin as NSDate,
                                    end as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \AnswerHistory.date, ascending: true)]
        
        let res = try! moc.fetch(req) as! [AnswerHistory]
        
        var ret  = [String]()
        var good = [String]()
        
        for ans in res {
            if let w = ans.word?.word {
                if !ret.contains(w) {
                    ret.append(w)
                }
                if ans.answer == CardRating.WELLKNOWN.rawValue {
                    if !good.contains(w) {
                        good.append(w)
                    }
                }
            }
        }
        
        if (ret.count-good.count) >= 3 || ret.count > 15 {
            // remove good word from ret
            for w in good {
                if let index = ret.firstIndex(of: w) {
                    ret.remove(at: index)
                }
            }
            return ret.randomElement()
        }
        return nil
    }
    
    // ------- Answer -------
    func answer(_ word: String, _ rate: CardRating) {
        guard let card = WordCard.ensure(word) else {
            fatalError()
        }
        defer {
            try! moc.save()
        }
        print ("Answering \(word) -> \(rate)")
        // TODO: add timer to record the time spent on
        // pausing and hesitation before answering
        AnswerHistory.add(rate, card: card, duration: PausableTimer.shared.end())
        
        if rate == .NOIDEA && card.category > CardCategory.NEW.rawValue {
            // if not a new card, and forgot, means it possiblly is a leech card
            card.leech+=1
        }
        //        if card.category == CardCategory.NEW.rawValue {
        //            // update NEW counter in engagement record
        //            Engagement.fetch(today).new += 1
        //        }
        
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
        
        //
        //        DispatchQueue.global(qos: .background).async {
        //            self.updateEngagement()
        //        }
    }
    
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
        
        print(ret)
        
        return ret
    }
    
    
    // ------- Date Functions -------
    let cutoffHour = 4
    var pseudoTime: Date?
    lazy var today: Int32 = day(from: Date())
    
    // day of today, how many days since 2000-01-01
    // 4AM is the beginning of reset cycle
    func day(from date: Date) -> Int32 {
        return Int32(Calendar.current.dateComponents([.day],
                                                     from: Date(timeIntervalSince1970: 0),
                                                     to: date).day!)
    }
    
    func date(from day: Int32) -> Date {
        return Calendar.current.date(byAdding: .day, value: Int(day), to: Date.init(timeIntervalSince1970: 0))!
    }
    
    func BeginOfTheDay(_ day: Int32) -> Date {
        return Calendar.current.date(bySettingHour: cutoffHour, minute: 0, second: 0, of: date(from: day))!
    }
    
    func EndOfTheDay(_ day: Int32) -> Date {
        return Date(timeInterval: 24*3600-1, since: BeginOfTheDay(day))
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
    static let moc = CoreDataManager.shared.container.viewContext
    
    static func add(_ word: String) -> WordCard? {
        defer {
            try! moc.save()
        }
        
        if let wc = WordCard.fetch(word) {
            // skip this already existed word
            wc.category = CardCategory.NEW.rawValue
            wc.duedate = WordManager.shared.now()
            return nil
        }
        
        let wc = WordCard.init(context: moc)
        wc.word = word
        wc.createdAt = WordManager.shared.now()
        return wc
    }
    
    static func fetch(_ word: String) -> WordCard? {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "word LIKE %@", word)
        req.fetchLimit = 1
        
        let res = try! moc.fetch(req) as! [WordCard]
        return res.first
    }
    
    static func ensure(_ word: String) -> WordCard? {
        if let card = WordCard.fetch(word) {
            return card
        }
        return WordCard.add(word)
    }
    
    static func IsExist(_ word: String) -> Bool {
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
    
    static func bury(_ word: String) {
        if let wc = WordCard.fetch(word) {
            wc.category = CardCategory.BURIED.rawValue
            // scheduler.updateEngagement()
            // Engagement.fetch(scheduler.today).buried += 1
        }
    }
    
    static func unbury(_ word: String) {
        if let wc = WordCard.fetch(word) {
            wc.category = CardCategory.NEW.rawValue
            wc.duedate = nil
            // scheduler.updateEngagement()
            // let e = Engagement.fetch(scheduler.today)
            //            if e.buried > 0 {
            //                e.buried -= 1
            //            }
        }
    }
    
    
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
        
        try! moc.save()
    }
    
    static func fetch(_ begin: Date, _ end: Date) -> [AnswerHistory] {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "AnswerHistory")
        req.predicate = NSPredicate(format: "date > %@ AND date < %@", begin as NSDate, end as NSDate)
        
        return try! moc.fetch(req) as! [AnswerHistory]
    }
}

