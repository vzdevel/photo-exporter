//
//  FilterBarView.swift
//  Photo Exporter
//

import SwiftUI

struct FilterBarView: View {
    @Binding var selectedFilter: PhotoFilter
    @Binding var selectedMediaType: MediaTypeFilter
    let counts: [PhotoFilter: Int]
    @Binding var isSearchActive: Bool
    var matchedCount: Int = 0
    var currentMatchIndex: Int = 0
    var onSearchQueryChanged: (String) -> Void
    var onNextMatch: (() -> Void)? = nil
    var onPreviousMatch: (() -> Void)? = nil

    @State private var queryText: String = ""
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var isSearchFocused: Bool

    var visibleFilters: [PhotoFilter] {
        PhotoFilter.allCases.filter { filter in
            filter == .all || (counts[filter] ?? 0) > 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleFilters) { filter in
                            if filter == .all {
                                mediaTypeChip()
                            } else {
                                standardFilterChip(for: filter)
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 46)
                    .padding(.vertical, 5)
                }
                .frame(height: 44)

                // Trailing pinned search button with smooth gradient fade
                HStack(spacing: 0) {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(.systemBackground).opacity(0),
                            Color(.systemBackground)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 14, height: 44)
                    .allowsHitTesting(false)

                    ZStack {
                        Color(.systemBackground)

                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                isSearchActive.toggle()
                                if isSearchActive {
                                    isSearchFocused = true
                                } else {
                                    debounceTask?.cancel()
                                    queryText = ""
                                    isSearchFocused = false
                                    onSearchQueryChanged("")
                                }
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isSearchActive ? .white : .primary)
                                .frame(width: 32, height: 32)
                                .background(isSearchActive ? Color.blue : Color(.secondarySystemFill))
                                .clipShape(Circle())
                                .shadow(color: isSearchActive ? Color.blue.opacity(0.3) : .clear, radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSearchActive ? "Close Search" : "Search Photos")
                    }
                    .frame(width: 40, height: 44)
                }
                .frame(height: 44)
            }
            .frame(height: 44)

            if isSearchActive {
                searchBarView
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: isSearchActive) { active in
            if !active {
                debounceTask?.cancel()
                queryText = ""
                onSearchQueryChanged("")
            }
        }
    }

    private var searchBarView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))

                TextField("Search filename or date (yyyy-M-d, M/d/yyyy)", text: $queryText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFocused)
                    .onChange(of: queryText) { newText in
                        debounceTask?.cancel()
                        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if clean.isEmpty {
                            onSearchQueryChanged("")
                        } else {
                            debounceTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                guard !Task.isCancelled else { return }
                                onSearchQueryChanged(newText)
                            }
                        }
                    }

                if !queryText.isEmpty {
                    Button {
                        debounceTask?.cancel()
                        queryText = ""
                        onSearchQueryChanged("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemFill))
            .cornerRadius(10)

            let cleanQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanQuery.isEmpty {
                if matchedCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(currentMatchIndex + 1)/\(matchedCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        if matchedCount > 1 {
                            Button {
                                onPreviousMatch?()
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(width: 24, height: 24)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(currentMatchIndex <= 0)
                            .opacity(currentMatchIndex <= 0 ? 0.4 : 1.0)

                            Button {
                                onNextMatch?()
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(width: 24, height: 24)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(currentMatchIndex >= matchedCount - 1)
                            .opacity(currentMatchIndex >= matchedCount - 1 ? 0.4 : 1.0)
                        }
                    }
                } else {
                    Text("0 found")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func mediaTypeChip() -> some View {
        let isSelected = selectedFilter == .all
        let count = counts[.all] ?? 0

        let chipLabel = HStack(spacing: 6) {
            Image(systemName: selectedMediaType.iconName)
                .font(.system(size: 13, weight: .semibold))

            Text(selectedMediaType.title)
                .font(.system(size: 13, weight: .semibold))

            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isSelected ? Color.white.opacity(0.25) : Color(.tertiarySystemFill)
                )
                .clipShape(Capsule())

            if isSelected {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.blue : Color(.secondarySystemFill)
        )
        .foregroundColor(isSelected ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: isSelected ? Color.blue.opacity(0.3) : .clear, radius: 4, y: 2)

        return Group {
            if isSelected {
                Menu {
                    ForEach(MediaTypeFilter.allCases.filter { $0 != selectedMediaType }) { type in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMediaType = type
                            }
                        } label: {
                            Label(type.title, systemImage: type.iconName)
                        }
                    }
                } label: {
                    chipLabel
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = .all
                    }
                } label: {
                    chipLabel
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func standardFilterChip(for filter: PhotoFilter) -> some View {
        let isSelected = selectedFilter == filter
        let count = counts[filter] ?? 0

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedFilter = filter
            }
        } label: {
            HStack(spacing: 6) {
                if let icon = filter.iconName, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(filter.shortTitle)
                    .font(.system(size: 13, weight: .semibold))

                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected ? Color.white.opacity(0.25) : Color(.tertiarySystemFill)
                    )
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? filter.color : Color(.secondarySystemFill)
            )
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: isSelected ? filter.color.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}
