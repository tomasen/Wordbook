//
//  WatchSearchView.swift
//  WatchKit Extension
//
//  Created by SHEN SHENG on 1/8/22.
//

import SwiftUI

struct WatchSearchView: View {
    @FocusState var foucs: Bool
    @State var input: String = ""
    
    var body: some View {
        TextField("what", text: $input)
            .focused($foucs, equals: true)
            .onAppear{
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                foucs.toggle()
                }
            }
    }
}

struct WatchSearchView_Previews: PreviewProvider {
    static var previews: some View {
        WatchSearchView()
    }
}
