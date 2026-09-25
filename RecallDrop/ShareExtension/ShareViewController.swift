//
//  ShareViewController.swift
//  RecallDrop Share Extension
//
//  Principal class of the share extension. Opens the App Group store
//  through its own AppEnvironment and hosts the SwiftUI interface.
//

import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var environment: AppEnvironment?
    private var model: ShareExtensionModel?

    override func viewDidLoad() {
        super.viewDidLoad()

        let environment = AppEnvironment(role: .shareExtension)
        environment.start()
        self.environment = environment

        let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = ShareExtensionModel(
            environment: environment,
            extensionItems: extensionItems,
            onComplete: { [weak self] in self?.complete() },
            onCancel: { [weak self] in self?.cancel() }
        )
        self.model = model

        let root = ShareExtensionView(model: model)
            .environment(environment)
            .modelContainer(environment.container)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)

        Task { await model.load() }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
