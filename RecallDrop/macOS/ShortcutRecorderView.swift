//
//  ShortcutRecorderView.swift
//  RecallDrop (macOS)
//
//  Records a global shortcut: click, then press the key combination
//  (⌘, ⌥ or ⌃ required). Escape cancels, Delete clears.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorderView: View {
    let combo: HotKeyCombo?
    let onChange: (HotKeyCombo?) -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isRecording {
                    ShortcutCaptureField { result in
                        isRecording = false
                        switch result {
                        case .recorded(let combo): onChange(combo)
                        case .cleared: onChange(nil)
                        case .cancelled: break
                        }
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    Text("Type shortcut…")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(combo?.displayString ?? "Off")
                        .monospaced()
                        .foregroundStyle(combo == nil ? .secondary : .primary)
                }
            }
            .frame(minWidth: 120)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .onTapGesture { isRecording.toggle() }

            if combo != nil, !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn this shortcut off")
            }
        }
    }
}

enum ShortcutCaptureResult {
    case recorded(HotKeyCombo)
    case cleared
    case cancelled
}

/// An invisible first responder that receives the next key combination.
private struct ShortcutCaptureField: NSViewRepresentable {
    let onFinish: (ShortcutCaptureResult) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onFinish = onFinish
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onFinish = onFinish
    }

    final class CaptureView: NSView {
        var onFinish: ((ShortcutCaptureResult) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            handle(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            handle(event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onFinish?(.cancelled)
            onFinish = nil
            return super.resignFirstResponder()
        }

        private func handle(_ event: NSEvent) {
            let callback = onFinish
            onFinish = nil
            switch Int(event.keyCode) {
            case kVK_Escape:
                callback?(.cancelled)
            case kVK_Delete, kVK_ForwardDelete:
                callback?(.cleared)
            default:
                if let combo = HotKeyCombo(event: event) {
                    callback?(.recorded(combo))
                } else {
                    NSSound.beep()
                    onFinish = callback
                }
            }
        }
    }
}
