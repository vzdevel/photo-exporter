//
//  AdjustDateTimeSheet.swift
//  Photo Exporter
//

import SwiftUI

struct AdjustDateTimeSheet: View {
    let initialDate: Date
    let originalEmbeddedDate: Date?
    let initialTimeZone: TimeZone
    let isPreviouslyAdjusted: Bool
    let onSave: (Date, TimeZone) -> Void
    let onRevert: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var selectedSecond: Int
    @State private var selectedTimeZone: TimeZone
    @State private var searchQuery: String = ""
    @State private var isShowingTimeZonePicker: Bool = false

    init(
        initialDate: Date?,
        originalEmbeddedDate: Date?,
        initialTimeZone: TimeZone,
        isPreviouslyAdjusted: Bool = false,
        onSave: @escaping (Date, TimeZone) -> Void,
        onRevert: @escaping () -> Void = {}
    ) {
        let baseDate = initialDate ?? Date()
        self.initialDate = baseDate
        self.originalEmbeddedDate = originalEmbeddedDate
        self.initialTimeZone = initialTimeZone
        self.isPreviouslyAdjusted = isPreviouslyAdjusted
        self.onSave = onSave
        self.onRevert = onRevert
        _selectedDate = State(initialValue: baseDate)
        _selectedTimeZone = State(initialValue: initialTimeZone)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = initialTimeZone
        let initSec = cal.component(.second, from: baseDate)
        _selectedSecond = State(initialValue: initSec)
    }

    private var hasUserModified: Bool {
        var calInit = Calendar(identifier: .gregorian)
        calInit.timeZone = initialTimeZone
        let compsInit = calInit.dateComponents([.year, .month, .day, .hour, .minute, .second], from: initialDate)

        var calCur = Calendar(identifier: .gregorian)
        calCur.timeZone = selectedTimeZone
        let compsCur = calCur.dateComponents([.year, .month, .day, .hour, .minute, .second], from: selectedDate)

        let isDateDifferent = (compsInit.year != compsCur.year ||
                               compsInit.month != compsCur.month ||
                               compsInit.day != compsCur.day ||
                               compsInit.hour != compsCur.hour ||
                               compsInit.minute != compsCur.minute ||
                               compsInit.second != compsCur.second)
        return isDateDifferent || (selectedTimeZone.identifier != initialTimeZone.identifier)
    }

    private func applySecondToSelectedDate(_ second: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = selectedTimeZone
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: selectedDate)
        comps.second = min(59, max(0, second))
        if let newDate = cal.date(from: comps) {
            selectedDate = newDate
        }
    }

    private func updateSelectedTimeZone(to newTimeZone: TimeZone) {
        let oldTimeZone = selectedTimeZone
        guard oldTimeZone != newTimeZone else { return }

        var sourceCal = Calendar(identifier: .gregorian)
        sourceCal.timeZone = oldTimeZone
        let comps = sourceCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: selectedDate)

        var targetCal = Calendar(identifier: .gregorian)
        targetCal.timeZone = newTimeZone
        if let newDate = targetCal.date(from: comps) {
            selectedDate = newDate
        }
        selectedTimeZone = newTimeZone
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Date
                Section("Date") {
                    DatePicker(
                        "Date",
                        selection: $selectedDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, selectedTimeZone)
                }

                // Section 2: Time & Second
                Section {
                    DatePicker(
                        "Time",
                        selection: $selectedDate,
                        displayedComponents: [.hourAndMinute]
                    )
                    .environment(\.timeZone, selectedTimeZone)

                    HStack {
                        Text("Second")
                            .font(.body)

                        Spacer()

                        HStack(spacing: 8) {
                            TextField("0", value: $selectedSecond, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                                .textFieldStyle(.roundedBorder)

                            Stepper("", value: $selectedSecond, in: 0...59)
                                .labelsHidden()
                        }
                    }
                } header: {
                    Text("Time")
                } footer: {
                    Text("Selected: \(DateFormatters.dateTimeString(for: selectedDate, in: selectedTimeZone))")
                }

                // Section 2: Time Zone Selection
                Section {
                    Button {
                        isShowingTimeZonePicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Time Zone")
                                    .foregroundColor(.primary)
                                Text(selectedTimeZone.identifier.replacingOccurrences(of: "_", with: " "))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(DateFormatters.friendlyTimezone(for: selectedDate, in: selectedTimeZone))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.blue)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }
                } header: {
                    Text("Time Zone")
                } footer: {
                    Text("The selected date, time, and timezone offset will be embedded directly into the photo's EXIF data upon export.")
                }
            }
            .navigationTitle("Adjust Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isPreviouslyAdjusted && !hasUserModified {
                        Button(role: .destructive) {
                            onRevert()
                            dismiss()
                        } label: {
                            Text("Revert")
                                .font(.headline)
                                .foregroundColor(.red)
                        }
                    } else {
                        Button("Adjust") {
                            onSave(selectedDate, selectedTimeZone)
                            dismiss()
                        }
                        .font(.headline)
                    }
                }
            }
            .sheet(isPresented: $isShowingTimeZonePicker) {
                timeZonePickerSheet
            }
            .onChange(of: selectedDate) { newDate in
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = selectedTimeZone
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: newDate)
                if comps.second != selectedSecond {
                    comps.second = selectedSecond
                    if let adjusted = cal.date(from: comps) {
                        selectedDate = adjusted
                    }
                }
            }
            .onChange(of: selectedSecond) { newSecond in
                let clamped = min(59, max(0, newSecond))
                if clamped != newSecond {
                    selectedSecond = clamped
                }
                applySecondToSelectedDate(clamped)
            }
        }
    }

    // MARK: - Timezone Picker Sheet

    private var filteredTimeZones: [TimeZone] {
        let known = TimeZone.knownTimeZoneIdentifiers
            .compactMap { TimeZone(identifier: $0) }

        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return known.sorted {
                $0.secondsFromGMT(for: selectedDate) < $1.secondsFromGMT(for: selectedDate)
            }
        } else {
            let query = searchQuery.lowercased()
            return known.filter {
                $0.identifier.lowercased().contains(query) ||
                ($0.abbreviation(for: selectedDate)?.lowercased().contains(query) ?? false)
            }
        }
    }

    private var timeZonePickerSheet: some View {
        NavigationStack {
            List(filteredTimeZones, id: \.identifier) { tz in
                Button {
                    updateSelectedTimeZone(to: tz)
                    isShowingTimeZonePicker = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tz.identifier.replacingOccurrences(of: "_", with: " "))
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(DateFormatters.friendlyTimezone(for: selectedDate, in: tz))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if tz == selectedTimeZone {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                                .font(.headline)
                        }
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "Search city or timezone")
            .navigationTitle("Select Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isShowingTimeZonePicker = false
                    }
                }
            }
        }
    }
}
