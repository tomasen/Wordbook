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
    
    @State private var remoteChangeCount = 0
    @State private var searchKeyword: String = ""
    @State private var currentPage = 0
    
    @FocusState private var focusPage: Int?
    
    private var didDataChange =  NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    private var didRemoteChange =  NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    
    var body: some View {
        NavigationView{
            WatchTabView(currentPage: $currentPage,
                         AnyView(pageOne()),
                         AnyView(pageTwo()),
                         AnyView(pageThree())
            )
                .navigationTitle(Text("Wordbook").font(.caption))
                .navigationBarTitleDisplayMode(.inline)
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
    @Binding var currentPageIndex: Int
    private let childViews: [Content]
    
    @FocusState private var focusPage: Int?
    @State private var finalOffset: CGFloat = 0
    private let pageCount: Int
    
    init(currentPage: Binding<Int>, _ views: Content...) {
        self.childViews = views
        self.pageCount = views.count
        self._currentPageIndex = currentPage
    }
    
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    self.content().frame(width: geometry.size.width)
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .offset(x: finalOffset)
                .gesture(
                    DragGesture().onChanged{  value in
                        finalOffset = -CGFloat(self.currentPageIndex) * geometry.size.width + value.translation.width
                    }.onEnded { value in
                        let offset = value.translation.width / geometry.size.width
                        let newIndex = (CGFloat(self.currentPageIndex) - offset).rounded()
                        self.currentPageIndex = min(max(Int(newIndex), 0), self.pageCount - 1)
                        let newOffset = -CGFloat(self.currentPageIndex) * geometry.size.width
                        let duration = abs(finalOffset - newOffset)/geometry.size.width * 0.35
                        withAnimation(.easeOut(duration: duration)){
                            finalOffset = newOffset
                            focusPage = currentPageIndex
                        }
                    }
                )
                .onAppear{
                    finalOffset = -CGFloat(self.currentPageIndex) * geometry.size.width
                }
            }
            VStack{
                Spacer()
                
                HStack{
                    ForEach(0..<pageCount, id: \.self) { pageId in
                        Circle()
                            .foregroundColor(currentPageIndex==pageId ? Color.white:Color.gray)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5, alignment: .bottom)
                .padding(.bottom, 0.5)
            }
            .edgesIgnoringSafeArea(.bottom)
        }
    }
    
    @ViewBuilder func content() -> some View {
        ForEach(0..<childViews.count, id: \.self) { index in
            childViews[index]
                .focusable(true)
                .focused($focusPage, equals: index)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchMasterView()
    }
}
