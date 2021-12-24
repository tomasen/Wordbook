//
//  SharingViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/19/21.
//

import Foundation
import SwiftUI

class SharingViewModel: ObservableObject {
    let colorPlate = ["shareFont1", "shareFont2", "shareFont3",
                      "shareFont1", "shareFont5"]
    let fontPlate = [ "SFProText-Bold",
                      "SFProText-Medium", "SFProText-Regular", "SFProText-Semibold"]
    
    
    var wordsOfToday: [String] {
        WordManager.shared.wordsOfToday()
    }
}


