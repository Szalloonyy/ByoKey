//
//  ImageViewerView.swift
//  RecallDrop
//
//  Full-screen image viewer with pinch/scroll zoom, pan and double-tap.
//

import SwiftUI

struct ImageViewerView: View {
    let item: CapturedItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: DecodedImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle(item.displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard let data = item.imageData else { return }
            image = await Task.detached(priority: .userInitiated) {
                ImageProcessor.decodedImage(from: data, maxPixelSize: 4096)
            }.value
        }
    }
}

private struct ZoomableImage: View {
    let image: DecodedImage

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(pan(in: proxy.size))
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if scale > 1 {
                            reset()
                        } else {
                            scale = 2.5
                            committedScale = 2.5
                        }
                    }
                }
                .accessibilityLabel("Captured image")
                .accessibilityHint("Double-tap to zoom")
        }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), maxScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { reset() }
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(CGSize(width: committedOffset.width + value.translation.width,
                                        height: committedOffset.height + value.translation.height), in: size)
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    /// Keeps the image from being dragged completely off screen.
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -limitX), limitX),
                      height: min(max(proposed.height, -limitY), limitY))
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}
