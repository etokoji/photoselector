//
//  ContentView.swift
//  photoSelector
//
//  Created by 江藤公二 on 2025/12/01.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PhotoSorterViewModel()
    
    var columns: [GridItem] {
        [
            GridItem(.adaptive(minimum: viewModel.thumbnailSize, maximum: viewModel.thumbnailSize * 2), spacing: 10)
        ]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar Area
            HStack {
                Button(action: selectFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
                
                Spacer()
                
                // Thumbnail Size Slider
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $viewModel.thumbnailSize, in: 100...400, step: 10)
                        .frame(width: 120)
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    
                    // Clear All Selections Button (right side of slider)
                    Button(action: {
                        viewModel.clearAllSelections()
                    }) {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .disabled(viewModel.photos.isEmpty)
                }
                
                Spacer()
                
                Text("\(viewModel.photos.count) Photos")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: {
                    viewModel.executeMoves()
                }) {
                    Label("Move Discarded (没)", systemImage: "trash")
                }
                .disabled(viewModel.photos.filter { $0.status == .groupB }.isEmpty || viewModel.isProcessing)
                .tint(.red)
            }
            .padding()
            .background(Material.bar)
            
            // Main Content with Side Panel (use native NSSplitView via representable on macOS)
#if os(macOS)
            SplitViewRepresentable(
                left:
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(viewModel.photos) { photo in
                                PhotoGridItem(photo: photo, thumbnailSize: viewModel.thumbnailSize)
                                    .onTapGesture {
                                        viewModel.toggleStatus(for: photo)
                                    }
                            }
                        }
                        .padding()
                    },
                right: GroupBSidePanel(photos: viewModel.photos.filter { $0.status == .groupB }),
                minLeft: 400,
                minRight: 200
            )
            .frame(minWidth: 400)
#else
            HSplitView {
                // Main Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(viewModel.photos) { photo in
                            PhotoGridItem(photo: photo, thumbnailSize: viewModel.thumbnailSize)
                                .onTapGesture {
                                    viewModel.toggleStatus(for: photo)
                                }
                        }
                    }
                    .padding()
                }
                .frame(minWidth: 400)

                // Side Panel for Group B
                if isSidePanelVisible {
                    GroupBSidePanel(photos: viewModel.photos.filter { $0.status == .groupB })
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: 400)
                }
            }
#endif
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                viewModel.loadPhotos(from: url)
            }
        }
    }
}

struct PhotoGridItem: View {
    let photo: PhotoItem
    let thumbnailSize: Double
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: photo.url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .overlay(Image(systemName: "exclamationmark.triangle"))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(height: thumbnailSize)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 4)
            )
            
            // Status Indicator Icon
            if photo.status != .unknown {
                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundStyle(statusColor)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
            }
        }
        .opacity(photo.status == .groupB ? 0.5 : 1.0)
    }
    
    var borderColor: Color {
        switch photo.status {
        case .groupA: return .green
        case .groupB: return .red
        case .unknown: return .clear
        }
    }
    
    var statusIcon: String {
        switch photo.status {
        case .groupA: return "checkmark.circle.fill"
        case .groupB: return "xmark.circle.fill"
        case .unknown: return ""
        }
    }
    
    var statusColor: Color {
        switch photo.status {
        case .groupA: return .green
        case .groupB: return .red
        case .unknown: return .clear
        }
    }
}

struct GroupBSidePanel: View {
    let photos: [PhotoItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                Text("Discard Group (没)")
                    .font(.headline)
                Spacer()
                Text("\(photos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.2), in: Capsule())
            }
            .padding()
            .background(Material.bar)
            
            Divider()
            
            // Thumbnail List
            if photos.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No discarded photos")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(photos) { photo in
                            GroupBThumbnail(photo: photo)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GroupBThumbnail: View {
    let photo: PhotoItem
    
    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: photo.url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .overlay(Image(systemName: "exclamationmark.triangle"))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.filename)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            
            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
}

#Preview {
    ContentView()
}
