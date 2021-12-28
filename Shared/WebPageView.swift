//
//  WebPageView.swift
//  Memorable
//
//  Created by tomasen on 3/8/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import SwiftUI
import WebView
import WebKit

class WKWebViewController: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)")
        // ページの読み込み準備開始
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        print("webView(_ webView: WKWebView, didCommit navigation: WKNavigation!)")
        // ページが見つかり、読み込み開始
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)")
        // ページ読み込み完了
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)")
        // ページ読み込み失敗
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        print("webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy)")
        decisionHandler(.allow)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("webViewWebContentProcessDidTerminate")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        print("webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)")
        
        decisionHandler(.allow)
    }
}

struct WebPageView: View {
    @ObservedObject var webViewStore = WebViewStore()
    @Environment(\.presentationMode) var mode: Binding<PresentationMode>
    var url: URL
    var delegate = WKWebViewController()
    
    init(url: URL) {
        self.url = url
        webViewStore.webView.navigationDelegate = delegate
        self.load()
    }
    
    var body: some View {
        NavigationView {
            WebView(webView: webViewStore.webView)
//            .onAppear {
//                    // TODO: use rss as data source
//                    // https://news.google.com/rss/search?q=concession&hl=en-US&gl=US&ceid=US:en
//                    // "https://news.google.com/search?q=\(self.state.word)&hl=en-US&gl=US&ceid=US:en"
//                    // self.load()
//            }
            .navigationBarTitle(Text("\(webViewStore.webView.title ?? "Wordbook")"), displayMode: .inline)
            .navigationBarItems(leading:
                HStack {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .imageScale(.large)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(!webViewStore.webView.canGoBack)
                    
                    Button(action: goForward) {
                        Image(systemName: "chevron.right")
                            .imageScale(.large)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(!webViewStore.webView.canGoForward)
                    
                    if webViewStore.webView.isLoading {
                        Button(action: stop) {
                            Image(systemName: "xmark")
                                .imageScale(.large)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                        }
                    } else {
                        Button(action: load) {
                            Image(systemName: "goforward")
                                .imageScale(.large)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                        }
                    }
                }, trailing:
                HStack {
                    Button(action: {
                        UIApplication.shared.open(self.url)
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .imageScale(.large)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    }
                    
                    Button(action: {
                        self.mode.wrappedValue.dismiss()
                    }) {
                        Text("Close")
                    }
                }
            )
        }
    }
    
    func load() {
        self.webViewStore.webView.load(URLRequest(url:self.url))
    }
    
    func stop() {
        webViewStore.webView.stopLoading()
    }
    
    func reload() {
        webViewStore.webView.reload()
    }
    
    func goBack() {
        webViewStore.webView.goBack()
    }
    
    func goForward() {
        webViewStore.webView.goForward()
    }
}

struct WebPageView_Previews: PreviewProvider {
    static var previews: some View {
        WebPageView(url: URL(string: "https://www.google.com/search?q=happy&hl=en-us&tbm=nws")!)
    }
}
