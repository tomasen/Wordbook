//
//  WatchContentView.swift
//  Wordbook WatchKit Extension
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

struct WatchMasterView: View {
    @ObservedObject var icloud = iCloudState.shared
    @ObservedObject var iap = InAppPurchaseManager.shared
    @ObservedObject private var pushReceiver = PushNotificationReceiver.shared
    
    @StateObject private var viewModel = WatchWordListViewModel()
    
    @FocusState private var focusTab: Int?

    @State private var remoteChangeCount = 0
    @State private var searchKeyword: String = ""
    @State private var currentTab = 0
    
    private var didDataChange =  NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    private var didRemoteChange =  NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    
    var body: some View {
        NavigationView{
            WatchTabView(tabCount: 3,
                         currentTab: $currentTab,
                         onTabChanged: { tabIdx in focusTab = tabIdx; print("MSG: focus \(tabIdx)") }){
                pageOne()
                    .focused($focusTab, equals: 0)
                pageTwo()
                    .focused($focusTab, equals: 1)
                pageThree()
                    .focused($focusTab, equals: 2)
            }
                .navigationTitle(Text("Wordbook").font(.caption))
                .navigationBarTitleDisplayMode(.inline)
                .listStyle(.carousel)
                .onAppear{
                    viewModel.update()
                    focusTab = 0
                }
                .onReceive(didDataChange) { _ in
                    viewModel.update()
                }
                .onReceive(didRemoteChange) { _ in
                    viewModel.update()
                    remoteChangeCount += 1
                }
        }
    }
    
    @ViewBuilder func pageOne() -> some View {
        List{
            HStack{
                Spacer()
                VStack{
                    Spacer()
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 40))
                    Spacer()
                }
                if let w = pushReceiver.notificatedWord {
                    HiddenNavigationLink(destination: WatchCardView(w),
                                         isActive: $pushReceiver.notificatedWord.toBool())
                }
                Spacer()
            }
            .scenePadding()
            .onTapGesture {
                presentInputController()
            }
            .sheet(isPresented: $searchKeyword.toBool()){
                WatchCardView(searchKeyword, closeMyself: $searchKeyword.toBool())
            }
            .foregroundColor(Color("WatchListItemTitle"))
            .buttonStyle(.plain)
            .frame(height: 80)
            .background(LinearGradient(gradient: Gradient(colors: [Color("WatchTodayButton"), Color("WatchTodayButtonEnd")]), startPoint: .top, endPoint: .bottom))
            .mask(RoundedRectangle(cornerRadius: 24))
            .listRowBackground(Color.clear)
            .padding(.top, 10)
            
            Section(header:
                        HStack() {
                Spacer()
                Text("Learning")
                Spacer()
            }
                        .padding()
                        .listRowBackground(Color.clear),
                    footer:
                        HStack{
                Spacer()
                Image(systemName: icloud.enabled && iap.isProSubscriber ? "icloud" : "icloud.slash")
                    .imageScale(.medium)
                    .padding()
            }
                        .foregroundColor(Color("fontGray"))
                        .scenePadding()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .frame(maxWidth: .infinity, minHeight: 60)) {
                if viewModel.learnedRecently.count > 0 {
                    ForEach(viewModel.learnedRecently, id: \.self) { entry in
                        WordEntryItem(entry)
                    }
                } else {
                    Text("no word in wordbook")
                        .foregroundColor(Color("fontBody"))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        }
    }
    
    @ViewBuilder func pageTwo() -> some View {
        if viewModel.recentAdded.count > 0 {
            List {
                Section(header: HStack() {
                    Spacer()
                    Text("Newly Added")
                    Spacer()
                }.padding().listRowBackground(Color.clear)) {
                    ForEach(viewModel.recentAdded, id: \.self) { entry in
                        WordEntryItem(entry)
                    }
                }
            }
        } else {
            VStack{
                Spacer()
                Text("no word added yet")
                Spacer()
            }
            .focusable(true)
        }
    }
    
    @ViewBuilder func pageThree() -> some View {
        if viewModel.queueWords.count > 0 {
            List{
                Section(header: HStack() {
                    Spacer()
                    Text("Queue")
                    Spacer()
                }.padding().listRowBackground(Color.clear)) {
                    ForEach(viewModel.queueWords, id: \.self) { entry in
                        WordEntryItem(entry)
                    }
                }
            }
        } else {
            VStack{
                Spacer()
                Text("no word scheduled for review")
                Spacer()
            }
            .focusable(true)
        }
    }
    
    private func presentInputController() {
        WKExtension.shared()
            .visibleInterfaceController?
            .presentTextInputController(withSuggestions: [],
                                        allowedInputMode: .plain) { result in
                
                guard let result = result as? [String], let firstElement = result.first else {
                    return
                }
                
                print("MSG: \(firstElement)")
                searchKeyword = firstElement
            }
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

struct WatchTabView<Content: View>: View {
    @Binding var currentTabIndex: Int
    
    @State private var finalOffset: CGFloat = 0
    private let tabTotalCount: Int
    private let onTabChanged: (Int) -> Void
    private let content: Content
    
    init(tabCount: Int,
         currentTab: Binding<Int>,
         onTabChanged: @escaping (Int) -> Void,
         @ViewBuilder content: () -> Content) {
        self._currentTabIndex = currentTab
        self.content = content()
        self.onTabChanged = onTabChanged
        self.tabTotalCount = tabCount
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    self.content.frame(width: geometry.size.width)
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .offset(x: finalOffset)
                .gesture(
                    DragGesture().onChanged{  value in
                        finalOffset = -CGFloat(self.currentTabIndex) * geometry.size.width + value.translation.width
                    }.onEnded { value in
                        let offset = value.translation.width / geometry.size.width
                        let newIndex = (CGFloat(self.currentTabIndex) - offset).rounded()
                        self.currentTabIndex = min(max(Int(newIndex), 0), self.tabTotalCount - 1)
                        let newOffset = -CGFloat(self.currentTabIndex) * geometry.size.width
                        let duration = abs(finalOffset - newOffset)/geometry.size.width * 0.35
                        withAnimation(.easeOut(duration: duration)){
                            finalOffset = newOffset
                            onTabChanged(currentTabIndex)
                        }
                    }
                )
                .onAppear{
                    finalOffset = -CGFloat(self.currentTabIndex) * geometry.size.width
                }
            }
            VStack{
                Spacer()
                
                HStack{
                    ForEach(0..<tabTotalCount, id: \.self) { pageId in
                        Circle()
                            .foregroundColor(currentTabIndex==pageId ? Color.white:Color.gray)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5, alignment: .bottom)
                .padding(.bottom, 0.5)
            }
            .edgesIgnoringSafeArea(.bottom)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchMasterView()
    }
}
