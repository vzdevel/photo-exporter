//
//  FolderPicker.swift
//  Photo Exporter
//

import SwiftUI
import UniformTypeIdentifiers

/// System document picker configured for folder selection
struct FolderPicker: UIViewControllerRepresentable {
    let onFolderPicked: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker

        init(_ parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let folderURL = urls.first else {
                parent.onCancel()
                return
            }
            parent.onFolderPicked(folderURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
