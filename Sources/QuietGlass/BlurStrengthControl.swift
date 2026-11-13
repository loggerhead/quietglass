//  Created by Clinton Imaro on 20/09/2026.

import AppKit
import SwiftUI

struct BlurStrengthControl: View {
    @Binding var strength: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let accent: Color
    private static let previewImage = Bundle.main.url(forResource: "BlurPreview", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private static let previewVideo = Bundle.main.url(forResource: "BlurPreview", withExtension: "mp4")

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Default blur strength").font(.system(size: 13, weight: .medium))
                Text("Choose how much detail stays visible.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 128, alignment: .leading)
            .padding(.top, 4)

            VStack(spacing: 14) {
                preview
                PrivacyLevelSlider(value: $strength, accent: accent,
                                   label: "Privacy blur strength", valueLabel: "\(Int(strength))")
                Text("Applies to full-screen, window, and detected-text blur.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 390)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var preview: some View {
        ZStack(alignment: .top) {
            sampleScene
                .accessibilityHidden(true)
            glassControls
                .padding(14)
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample blur preview")
        .accessibilityValue(QG("Blur strength %ld", Int(strength)))
    }

    @ViewBuilder private var sampleScene: some View {
        if !reduceMotion, let url = Self.previewVideo {
            BlurPreviewVideo(url: url, strength: strength)
        } else {
            stillScene
                .blur(radius: strength / 6)
                .padding(-16)
                .clipped()
        }
    }

    private var stillScene: some View {
        GeometryReader { geometry in
            if let image = Self.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Color(white: 0.14)
            }
        }
    }

    private var glassControls: some View {
        HStack(spacing: 12) {
            previewLabel.background(Color.black.opacity(0.68), in: Capsule())
            Spacer(minLength: 8)
            strengthLabel.background(Color.black.opacity(0.68), in: Capsule())
        }
    }

    private var previewLabel: some View {
        HStack(spacing: 7) {
            AppIconView(icon: .viewOff, size: 16)
            Text("Sample preview").font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .foregroundStyle(.white)
    }

    private var strengthLabel: some View {
        Text("\(Int(strength))")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(width: 42, height: 34)
            .foregroundStyle(.white)
    }
}

struct PrivacyLevelSlider: View {
    @Binding var value: Double
    let accent: Color
    let label: String
    let valueLabel: String
    var range: ClosedRange<Double> = 10...70
    var minimumLabel = "Lowest blur strength"
    var maximumLabel = "Highest blur strength"
    var showsEndpoints = true

    var body: some View {
        HStack(spacing: 12) {
            if showsEndpoints { endpoint("capsule.on.rectangle", amount: range.lowerBound, label: minimumLabel) }
            VStack(spacing: 2) {
                Slider(value: $value, in: range, step: 1)
                    .tint(accent)
                    .controlSize(.large)
                    .accessibilityLabel(QG(label))
                    .accessibilityValue(QG(valueLabel))
                HStack {
                    Circle().frame(width: 3, height: 3)
                    Spacer()
                    Circle().frame(width: 3, height: 3)
                    Spacer()
                    Circle().frame(width: 3, height: 3)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
            }
            if showsEndpoints { endpoint("capsule.on.rectangle.fill", amount: range.upperBound, label: maximumLabel) }
        }
    }

    private func endpoint(_ symbol: String, amount: Double, label: String) -> some View {
        Button { value = amount } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 24, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(QG(label))
        .help(QG(label))
    }
}
