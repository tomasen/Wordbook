//
//  WatchContentView.swift
//  Wordbook WatchKit Extension
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

struct WatchMasterView: View {
    @ObservedObject var icloud = iCloudState.shared
    @StateObject private var viewModel = WordListViewModel()
    
    @State private var remoteChangeCount = 0
    
    private var didDataChange =  NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    private var didRemoteChange =  NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    
    var body: some View {
        VStack{
            List{
                NavigationLink(destination: WatchCardView()) {
                    HStack{
                        Spacer()
                        VStack{
                            Spacer()
                            Text("Hit Me")
                            Spacer()
                        }
                        Spacer()
                    }
                    .scenePadding()
                }
                .foregroundColor(Color("WatchListItemTitle"))
                .buttonStyle(.plain)
                .frame(height: 80)
                .background(LinearGradient(gradient: Gradient(colors: [Color("WatchTodayButton"), Color("WatchTodayButtonEnd")]), startPoint: .top, endPoint: .bottom))
                .mask(RoundedRectangle(cornerRadius: 24))
                .listRowBackground(Color.clear)
                .padding(.top, 10)
                
                Section(header: HStack() {
                    Spacer()
                    Text("Words")
                    Spacer()
                }.padding().listRowBackground(Color.clear)) {
                    ForEach(viewModel.recentLearned.words) { entry in
                        WordEntryItem(entry.text)
                    }
                    ForEach(viewModel.queueWords.words) { entry in
                        WordEntryItem(entry.text)
                    }
                }
                ZStack{
                    Image(systemName: "ellipsis")
                        .imageScale(.medium)
                        .padding()
                        .foregroundColor(Color("fontGray"))
                    HStack{
                        Text("\(viewModel.footnote).\(remoteChangeCount)")
                            .font(.footnote)
                        Spacer()
                        Image(systemName: icloud.enabled ? "icloud" : "icloud.slash")
                            .imageScale(.medium)
                            .padding()
                    }
                }
                .foregroundColor(Color("fontGray"))
                .scenePadding()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            .listStyle(.carousel)
            .onAppear{
                viewModel.update()
            }
            .onReceive(didDataChange) { _ in
                viewModel.update()
            }
            .onReceive(didRemoteChange) { _ in
                viewModel.update()
                remoteChangeCount += 1
            }
        }
        .navigationTitle(Text("Wordbook").font(.caption))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WordEntryItem: View {
    @StateObject var viewModel = CardViewModel()
    
    init(_ word: String) {
        _viewModel = StateObject(wrappedValue: CardViewModel(word))
    }
    
    var body: some View {
        NavigationLink(destination: WatchCardView(viewModel.word)) {
            VStack(alignment: .leading) {
                Text(viewModel.word)
                    .customFont(name: "AvenirNext-Bold", style: .caption1, weight: .semibold)
                    .foregroundColor(Color("WatchListItemTitle"))
                Text("\(viewModel.summaryExplain)")
                    .customFont(name: "AvenirNext-Bold", style: .caption2, weight: .regular)
                    .foregroundColor(Color("WatchListItemContent"))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(Color("WatchListItemBackground"))
        .mask(RoundedRectangle(cornerRadius: 18))
        .listRowBackground(Color.clear)
        .onAppear{
            viewModel.fetchExplainFromLocalDatabase()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchMasterView()
    }
}
