//
//  RootSupport.swift
//  RecallDrop
//
//  Pieces shared by the iOS and macOS root views: the toast banner, the
//  first-launch welcome sheet and lifecycle handling.
//

import SwiftUI
import RecallDropKit

/// Shows `router.toastMessage` briefly at the bottom of the window.
struct ToastOverlay: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = environment.router.toastMessage {
                Text(message)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        withAnimation { environment.router.toastMessage = nil }
                    }
                    .onTapGesture {
                        withAnimation { environment.router.toastMessage = nil }
                    }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: environment.router.toastMessage)
    }
}

/// App lifecycle: start once, refresh on activation, open deep links.
/// (Views that list captures fetch again through `CapturedItemsReader` when
/// the share extension changed the store.)
struct LifecycleModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                environment.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { environment.didBecomeActive() }
            }
            .onOpenURL { url in
                environment.router.handle(url: url)
            }
    }
}

extension View {
    func appChrome() -> some View {
        modifier(LifecycleModifier())
            .modifier(ToastOverlay())
            .modifier(RouterAlertModifier())
            .modifier(WelcomeSheetModifier())
    }
}

/// Presents `router.alertMessage` until the user dismisses it.
struct RouterAlertModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let router = environment.router
        content.alert("RecallDrop Library", isPresented: Binding(
            get: { router.alertMessage != nil },
            set: { presented in if !presented { router.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.alertMessage ?? "")
        }
    }
}

/// First-launch introduction with the privacy model and the two ways to start.
struct WelcomeSheetModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        @Bindable var settings = environment.settings
        content.sheet(isPresented: Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { presented in if !presented { settings.hasCompletedOnboarding = true } }
        )) {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Welcome to RecallDrop")
                    .font(.title.weight(.bold))
                Text("Your visual second brain for screenshots, links and fleeting ideas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                feature("text.viewfinder", "Instant, private text recognition", "Every screenshot becomes searchable on this device.")
                feature("sparkles", "Specialized agents", "Idea Extractor, Action Planner, Visual & Tech Inspector and your own personas.")
                feature("key", "Bring your own key", "OpenRouter, OpenAI, Anthropic or a local model. Keys stay in the Keychain.")
                feature("bell.badge", "Resurface what matters", "Remind me in 2 hours, tonight or tomorrow.")
            }
            .frame(maxWidth: 440, alignment: .leading)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    finish()
                    environment.router.selectedTab = .settings
                    environment.router.sidebarSelection = .settings
                } label: {
                    Text("Set Up an AI Provider")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    environment.settings.offlineOnly = true
                    finish()
                } label: {
                    Text("Start Offline – Everything Stays on Device")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Continue") { finish() }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: 440)
        }
        .padding(28)
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
        .interactiveDismissDisabled(false)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        environment.settings.hasCompletedOnboarding = true
        dismiss()
    }
}
