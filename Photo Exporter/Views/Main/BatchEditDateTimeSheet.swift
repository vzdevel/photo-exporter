//
//  BatchEditDateTimeSheet.swift
//  Photo Exporter
//

import SwiftUI

struct BatchEditDateTimeSheet: View {
    let selectedCount: Int
    let initialDate: Date
    let initialTimeZone: TimeZone
    let onApply: (_ date: Date?, _ stepSeconds: Int, _ timeZone: TimeZone?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isUpdatingDateTime: Bool = false
    @State private var selectedDate: Date
    @State private var startingSecond: Int
    @State private var stepSeconds: Int = 0

    @State private var isUpdatingTimeZone: Bool = false
    @State private var selectedTimeZone: TimeZone

    @State private var isApplying: Bool = false

    init(
        selectedCount: Int,
        initialDate: Date = Date(),
        initialTimeZone: TimeZone = .current,
        onApply: @escaping (_ date: Date?, _ stepSeconds: Int, _ timeZone: TimeZone?) -> Void
    ) {
        self.selectedCount = selectedCount
        self.initialDate = initialDate
        self.initialTimeZone = initialTimeZone
        self.onApply = onApply
        _selectedDate = State(initialValue: initialDate)
        _selectedTimeZone = State(initialValue: initialTimeZone)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = initialTimeZone
        let initSec = cal.component(.second, from: initialDate)
        _startingSecond = State(initialValue: initSec)
    }

    private var canApply: Bool {
        (isUpdatingDateTime || isUpdatingTimeZone) && !isApplying
    }

    private func applyStartingSecondToSelectedDate(_ second: Int) {
        var cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: selectedDate)
        comps.second = min(59, max(0, second))
        if let newDate = cal.date(from: comps) {
            selectedDate = newDate
        }
    }

    private var previewStartingDate: Date {
        if isUpdatingTimeZone {
            let userCal = Calendar.current
            let comps = userCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: selectedDate)
            var targetCal = Calendar(identifier: .gregorian)
            targetCal.timeZone = selectedTimeZone
            return targetCal.date(from: comps) ?? selectedDate
        } else {
            return selectedDate
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Updating \(selectedCount) item\(selectedCount == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)

                            Text(summaryDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Date & Time") {
                    Toggle("Adjust Date & Time", isOn: $isUpdatingDateTime.animation())

                    if isUpdatingDateTime {
                        DatePicker(
                            "Starting Date & Time",
                            selection: $selectedDate
                        )
                        .datePickerStyle(.compact)

                        HStack {
                            Text("Starting Second")
                                .font(.body)

                            Spacer()

                            HStack(spacing: 8) {
                                TextField("0", value: $startingSecond, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 50)
                                    .textFieldStyle(.roundedBorder)

                                Stepper("", value: $startingSecond, in: 0...59)
                                    .labelsHidden()
                            }
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Increment Step")
                                    .font(.body)
                                Text("Seconds added per subsequent photo")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 8) {
                                TextField("0", value: $stepSeconds, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 54)
                                    .textFieldStyle(.roundedBorder)

                                Stepper("", value: $stepSeconds, in: 0...86400)
                                    .labelsHidden()
                            }
                        }

                        let tzForPreview = isUpdatingTimeZone ? selectedTimeZone : initialTimeZone
                        let firstStr = DateFormatters.dateTimeString(for: previewStartingDate, in: tzForPreview)

                        if stepSeconds == 0 {
                            Text("All selected photos will be set to \(firstStr).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("1st: \(firstStr) • 2nd: +\(stepSeconds)s • \(selectedCount)th: +\(stepSeconds * max(0, selectedCount - 1))s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Time Zone") {
                    Toggle("Adjust Time Zone", isOn: $isUpdatingTimeZone.animation())

                    if isUpdatingTimeZone {
                        NavigationLink {
                            TimeZoneSelectionListView(selectedTimeZone: $selectedTimeZone)
                        } label: {
                            HStack {
                                Text("Time Zone")
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(selectedTimeZone.identifier.replacingOccurrences(of: "_", with: " "))
                                        .font(.body)
                                        .foregroundColor(.primary)

                                    Text("\(DateFormatters.shortUTCOffsetString(for: selectedDate, in: selectedTimeZone)) • \(DateFormatters.friendlyTimezone(for: selectedDate, in: selectedTimeZone))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if !isUpdatingDateTime {
                            Text("Wall-clock date and time will remain unchanged; only the timezone offset will be updated.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Photos will be assigned the chosen date & time within this timezone.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isApplying = true
                        onApply(
                            isUpdatingDateTime ? selectedDate : nil,
                            isUpdatingDateTime ? max(0, stepSeconds) : 0,
                            isUpdatingTimeZone ? selectedTimeZone : nil
                        )
                        dismiss()
                    } label: {
                        if isApplying {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Apply")
                                .bold()
                        }
                    }
                    .disabled(!canApply)
                }
            }
            .onChange(of: selectedDate) { newDate in
                var cal = Calendar(identifier: .gregorian)
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: newDate)
                if comps.second != startingSecond {
                    comps.second = startingSecond
                    if let adjusted = cal.date(from: comps) {
                        selectedDate = adjusted
                    }
                }
            }
            .onChange(of: startingSecond) { newSecond in
                let clamped = min(59, max(0, newSecond))
                if clamped != newSecond {
                    startingSecond = clamped
                }
                applyStartingSecondToSelectedDate(clamped)
            }
        }
    }

    private var summaryDescription: String {
        if isUpdatingDateTime && isUpdatingTimeZone {
            return "Will update both date & time (with step) and time zone."
        } else if isUpdatingDateTime {
            return "Will update date & time with \(stepSeconds)s step; keeps existing time zone."
        } else if isUpdatingTimeZone {
            return "Will update time zone; keeps existing wall-clock time."
        } else {
            return "Select an option below to update."
        }
    }
}

struct TimeZoneSelectionListView: View {
    @Binding var selectedTimeZone: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery: String = ""

    private var filteredTimeZones: [TimeZone] {
        let known = TimeZone.knownTimeZoneIdentifiers
            .compactMap { TimeZone(identifier: $0) }
            .sorted { $0.identifier < $1.identifier }

        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return known
        } else {
            let query = searchQuery.lowercased()
            return known.filter {
                $0.identifier.lowercased().contains(query) ||
                ($0.abbreviation()?.lowercased().contains(query) ?? false)
            }
        }
    }

    var body: some View {
        List {
            ForEach(filteredTimeZones, id: \.identifier) { tz in
                Button {
                    selectedTimeZone = tz
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tz.identifier.replacingOccurrences(of: "_", with: " "))
                                .font(.body)
                                .foregroundColor(.primary)

                            Text("\(DateFormatters.shortUTCOffsetString(for: Date(), in: tz)) • \(DateFormatters.friendlyTimezone(for: Date(), in: tz))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if selectedTimeZone.identifier == tz.identifier {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $searchQuery, prompt: "Search city or timezone")
        .navigationTitle("Select Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

