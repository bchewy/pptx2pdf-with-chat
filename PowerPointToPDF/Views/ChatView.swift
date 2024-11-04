import SwiftUI
import PDFKit

struct ChatView: View {
    @ObservedObject var chatService: ChatService
    let pdfs: [URL]
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack {
            if chatService.sessions.isEmpty {
                ProgressView("Creating chat session...")
            } else {
                VStack {
                    // Show list of included PDFs
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(pdfs, id: \.self) { pdf in
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                    Text(pdf.lastPathComponent)
                                }
                                .padding(8)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                    .frame(height: 50)
                    
                    Divider()
                    
                    // Chat messages
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(chatService.sessions[0].messages) { message in
                                MessageBubble(message: message)
                            }
                        }
                        .padding()
                    }
                    
                    Divider()
                    
                    // Message input
                    HStack {
                        TextField("Ask about any of the PDFs...", text: $messageText)
                            .textFieldStyle(.roundedBorder)
                        
                        Button(action: sendMessage) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                            }
                        }
                        .disabled(messageText.isEmpty || isLoading)
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            do {
                // Create a single session for all PDFs
                try await chatService.createSessionForPDFs(pdfs)
            } catch {
                errorMessage = error.localizedDescription
                print("Error creating session: \(error)")
            }
        }
    }
    
    private func sendMessage() {
        guard let session = chatService.sessions.first else { return }
        let userMessage = Message(content: messageText, role: .user)
        
        Task {
            isLoading = true
            do {
                await MainActor.run {
                    chatService.sessions[0].messages.append(userMessage)
                }
                
                let response = try await chatService.sendMessage(messageText, in: session)
                let assistantMessage = Message(content: response, role: .assistant)
                
                await MainActor.run {
                    chatService.sessions[0].messages.append(assistantMessage)
                    messageText = ""
                }
            } catch {
                errorMessage = error.localizedDescription
                print("Error sending message: \(error)")
            }
            isLoading = false
        }
    }
}

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == .assistant {
                Spacer()
            }
            
            Text(message.content)
                .padding()
                .background(message.role == .user ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                .cornerRadius(12)
            
            if message.role == .user {
                Spacer()
            }
        }
    }
} 