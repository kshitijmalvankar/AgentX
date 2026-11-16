import MarkdownUI
import SwiftUI

extension Theme {
    /// Claude's replies: system font, comfortable line spacing, modest
    /// headings, quiet tables and code blocks that scroll instead of wrapping.
    @MainActor static let agentX = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.secondary.opacity(0.12))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(.accentColor) }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.3))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 16, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.15))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.0))
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.3))
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.3))
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: 10)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.86))
                    }
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Radius.inset))
            .markdownMargin(top: 2, bottom: 12)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.horizontalBorders, color: Color.secondary.opacity(0.22), width: 0.5))
                .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Color.secondary.opacity(0.05), header: Color.secondary.opacity(0.08)))
                .markdownMargin(top: 2, bottom: 12)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    FontSize(.em(0.95))
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
        }
        .thematicBreak {
            Divider().markdownMargin(top: 10, bottom: 10)
        }
}

/// Keeps chat content to a comfortable reading width, centered in wide windows.
struct ReadingColumn: ViewModifier {
    var maxWidth: CGFloat = 760

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func readingColumn(_ maxWidth: CGFloat = 760) -> some View { modifier(ReadingColumn(maxWidth: maxWidth)) }
}
