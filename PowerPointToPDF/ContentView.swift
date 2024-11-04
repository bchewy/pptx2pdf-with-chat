import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var files: [URL] = []
    @State private var isConverting = false
    @State private var showDirectoryPicker = false
    @State private var conversionProgress: Double = 0
    @State private var isSetupComplete = false
    @State private var showSetupAlert = false
    @State private var setupError: String?
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var showChatView = false
    @State private var showSettingsView = false
    @State private var convertedPDFs: [URL] = []
    @State private var showChatAfterConversion = false
    @StateObject private var settings = Settings()
    @StateObject private var chatService: ChatService
    
    init() {
        _chatService = StateObject(wrappedValue: ChatService(apiKey: ""))
    }
    
    private func updateChatService() {
        if chatService.apiKey != settings.apiKey {
            chatService.updateApiKey(settings.apiKey)
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if !isSetupComplete {
                ProgressView("Checking dependencies...")
                    .task {
                        await checkAndInstallDependencies()
                    }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                        .frame(height: 200)
                        .foregroundColor(.gray)
                    
                    if files.isEmpty {
                        VStack {
                            Image("install")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                            Text("Drop PowerPoint files here\nor click to select")
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.gray)
                        .opacity(isHovering ? 0.7 : 1.0)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(files, id: \.self) { file in
                                    Text(file.lastPathComponent)
                                        .padding(.vertical, 2)
                                }
                            }
                            .padding()
                        }
                    }
                }
                .onHover { hovering in
                    isHovering = hovering
                }
                .onDrop(of: [UTType.presentation], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }
                .onTapGesture {
                    selectFiles()
                }
                
                if !files.isEmpty {
                    if isConverting {
                        ProgressView(value: conversionProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                        Text("\(Int(conversionProgress * 100))%")
                    } else {
                        Button("Convert to PDF") {
                            convertFiles()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                Button("Select Directory") {
                    showDirectoryPicker = true
                }
                .fileImporter(
                    isPresented: $showDirectoryPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    handleDirectorySelection(result)
                }
                
                if !convertedPDFs.isEmpty {
                    Button("Chat with Converted PDFs") {
                        if !settings.isKeyValid {
                            showSettingsView = true
                        } else {
                            chatService.updateApiKey(settings.apiKey)
                            showChatView = true
                        }
                    }
                    .sheet(isPresented: $showSettingsView) {
                        SettingsView(settings: settings) {
                            chatService.updateApiKey(settings.apiKey)
                            showChatView = true
                        }
                    }
                    .sheet(isPresented: $showChatView) {
                        ChatView(chatService: chatService, pdfs: convertedPDFs)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
        .alert("Setup Error", isPresented: $showSetupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(setupError ?? "Unknown error occurred")
        }
        .onAppear {
            updateChatService()
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.presentation.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        files.append(url)
                    }
                }
            }
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.presentation]
        
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls)
        }
    }
    
    private func handleDirectorySelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let directoryURL = urls.first else { return }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            let pptFiles = contents.filter { url in
                url.pathExtension.lowercased() == "ppt" ||
                url.pathExtension.lowercased() == "pptx"
            }
            files.append(contentsOf: pptFiles)
        } catch {
            print("Error reading directory: \(error)")
        }
    }
    
    private func convertFiles() {
        guard !files.isEmpty else { return }
        isConverting = true
        convertedPDFs.removeAll()
        
        Task {
            for (index, file) in files.enumerated() {
                do {
                    try await convertToPDF(file)
                    let pdfURL = file.deletingPathExtension().appendingPathExtension("pdf")
                    
                    if FileManager.default.fileExists(atPath: pdfURL.path) {
                        await MainActor.run {
                            convertedPDFs.append(pdfURL)
                        }
                    }
                    
                    await MainActor.run {
                        conversionProgress = Double(index + 1) / Double(files.count)
                    }
                } catch {
                    print("Error converting \(file.lastPathComponent): \(error)")
                }
            }
            
            await MainActor.run {
                isConverting = false
                files.removeAll()
                conversionProgress = 0
                if !convertedPDFs.isEmpty {
                    showSettingsView = true
                }
            }
        }
    }
    
    private func convertToPDF(_ file: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        // Set up the environment with the correct PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        
        // Use unoconv with full path
        process.arguments = ["-c", "unoconv -f pdf '\(file.path)'"]
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = try pipe.fileHandleForReading.readToEnd() ?? Data()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ConversionError", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
    
    private func checkAndInstallDependencies() async {
        do {
            // Check if Homebrew is installed
            let brewInstallScript = """
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            """
            
            let brewPath = "/opt/homebrew/bin/brew"
            let brewExists = FileManager.default.fileExists(atPath: brewPath)
            
            if !brewExists {
                let installProcess = Process()
                installProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
                installProcess.arguments = ["-c", brewInstallScript]
                
                try installProcess.run()
                installProcess.waitUntilExit()
            }
            
            // Update PATH to include Homebrew
            let path = """
            eval "$(/opt/homebrew/bin/brew shellenv)" && \
            brew install libreoffice unoconv
            """
            
            let installDepsProcess = Process()
            installDepsProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            installDepsProcess.arguments = ["-c", path]
            
            let depsPipe = Pipe()
            installDepsProcess.standardOutput = depsPipe
            installDepsProcess.standardError = depsPipe
            
            try installDepsProcess.run()
            installDepsProcess.waitUntilExit()
            
            if installDepsProcess.terminationStatus == 0 {
                await MainActor.run {
                    isSetupComplete = true
                }
            } else {
                let errorData = try depsPipe.fileHandleForReading.readToEnd() ?? Data()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "InstallError", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
            
        } catch {
            await MainActor.run {
                setupError = "Failed to install dependencies: \(error.localizedDescription)"
                showSetupAlert = true
            }
        }
    }
}
