//
//  ShareViewController.swift
//  words
//
//  Created by tomasen on 1/29/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import UIKit
import Social
import SwiftUI
import MobileCoreServices
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    lazy var viewModel = SharedExtensionViewModel()
    lazy var sharedExtensionView = SharedExtensionView(viewModel: viewModel)
    lazy var childView = UIHostingController(rootView: sharedExtensionView)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        getShareExtensionText{ text in
            DispatchQueue.main.async {
                self.viewModel.setContent(text)
            }
        }
        
        addChild(childView)
        childView.view.frame = self.view.frame
        view.addSubview(childView.view)
        childView.didMove(toParent: self)
    }
    
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        childView.view.frame = self.view.frame
    }
    
    @IBAction func onCancel(_ sender: Any) {
        self.extensionContext!.cancelRequest(withError: NSError(domain: "wordbook.cool", code: 0, userInfo: nil))
    }
    
    @IBAction func didSelectPost(_ sender: Any) {
        print("post: \(self.viewModel.contentText)")
        
        if !isContentValid() {
            // TODO: show error
            return
        }
        
        print(self.viewModel.words)
        
        self.viewModel.words.forEach { w in
            UserPreferences.shared.addToWordbook(w)
        }
        
        self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func getShareExtensionText(completion: @escaping (_ result: String)->()) {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return
        }

        for extensionItem in extensionItems {
            if let itemProviders = extensionItem.attachments {
                for itemProvider in itemProviders {
                    if itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier as String) {
                        itemProvider.loadItem(forTypeIdentifier: UTType.text.identifier as String, options: nil, completionHandler: { text, error in
                            if let t = text as? String {
                                completion(t)
                            }
                        })
                    }
                }
            }
        }
        return
    }
    
    private func isContentValid() -> Bool {
        // Do validation of contentText and/or NSExtensionContext attachments here
        return self.viewModel.words.count > 0
    }
}
