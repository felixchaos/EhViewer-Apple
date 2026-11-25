import SwiftUI
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LocalAccountAvatar: View {
    let bytes: Data?
    var size: CGFloat

    private var image: Image? {
        #if os(macOS)
        bytes.flatMap { NSImage(data: $0) }.map { Image(nsImage: $0) }
        #else
        bytes.flatMap { UIImage(data: $0) }.map { Image(uiImage: $0) }
        #endif
    }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.43))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private nonisolated struct PickedAccountAvatar: Transferable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(png: try AccountAvatarFiles.importImage(from: received.file))
        }
    }
}

struct LocalAccountAvatarEditor: View {
    let memberID: String
    @State private var photo: PhotosPickerItem?
    @State private var showOptions = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var error: String?

    var body: some View {
        let profile = AccountProfileStore.shared
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showOptions.toggle()
            } label: {
                HStack {
                    Text("编辑头像")
                    Spacer()
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityValue(showOptions ? Text("已展开") : Text("已折叠"))
            .accessibilityIdentifier("account-avatar-edit")

            if showOptions {
                choice("从照片选取", id: "account-avatar-photo") { showPhotos = true }
                choice("从文件选取", id: "account-avatar-file") { showFiles = true }
                if profile.avatar != nil {
                    choice("移除头像", id: "account-avatar-remove", role: .destructive) {
                        do { try profile.resetAvatar(for: memberID) }
                        catch { self.error = "无法移除头像。" }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task { await importFile(url) }
            case .failure:
                error = "无法读取此文件。"
            }
        }
        .onChange(of: photo) { _, selection in
            guard let selection else { return }
            Task { await importPhoto(selection) }
        }
        .alert("头像", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func choice(_ title: LocalizedStringKey, id: String, role: ButtonRole? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }

    private func importFile(_ url: URL) async {
        do {
            let png = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try AccountAvatarFiles.importImage(from: url)
            }.value
            try AccountProfileStore.shared.setAvatar(png, for: memberID)
        } catch let error as AccountAvatarFiles.ImportError {
            self.error = error.errorDescription
        } catch {
            self.error = "无法设置头像。"
        }
    }

    private func importPhoto(_ selection: PhotosPickerItem) async {
        do {
            let picked = try await selection.loadTransferable(type: PickedAccountAvatar.self)
            guard photo == selection else { return }
            photo = nil
            guard let picked else {
                error = "无法读取此图片。"
                return
            }
            try AccountProfileStore.shared.setAvatar(picked.png, for: memberID)
        } catch {
            guard photo == selection else { return }
            photo = nil
            self.error = (error as? AccountAvatarFiles.ImportError)?.errorDescription ?? "无法设置头像。"
        }
    }
}
