import Foundation

class ChatService: ObservableObject {
    @Published private(set) var apiKey: String
    @Published var sessions: [ChatSession] = []
    private let sessionsKey = "chat_sessions"
    
    private var assistant: String? = nil
    
    init(apiKey: String) {
        self.apiKey = apiKey
        loadSessions()
    }
    
    func updateApiKey(_ newKey: String) {
        self.apiKey = newKey
        // Clear existing sessions when API key changes
        sessions.removeAll()
        UserDefaults.standard.removeObject(forKey: sessionsKey)
    }
    
    private func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: sessionsKey),
           let decodedSessions = try? JSONDecoder().decode([ChatSession].self, from: data) {
            self.sessions = decodedSessions
        }
    }
    
    private func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: sessionsKey)
        }
    }
    
    func createSessionForPDFs(_ pdfURLs: [URL]) async throws -> ChatSession {
        var fileIds: [String] = []
        
        // Upload all PDFs
        for pdfURL in pdfURLs {
            let fileId = try await uploadFile(pdfURL)
            fileIds.append(fileId)
        }
        
        // Create an assistant
        let assistantId = try await createAssistant(with: fileIds)
        self.assistant = assistantId
        
        // Create a thread
        let threadId = try await createThread()
        
        // Create a single session for all PDFs
        let session = ChatSession(
            name: "Combined Chat (\(pdfURLs.count) PDFs)",
            fileIds: fileIds,
            assistantId: assistantId,
            threadId: threadId
        )
        
        await MainActor.run {
            sessions.removeAll()
            sessions.append(session)
            saveSessions()
        }
        
        return session
    }
    
    private func createAssistant(with fileIds: [String]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/assistants")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let body: [String: Any] = [
            "name": "PDF Analyzer",
            "instructions": "You are analyzing multiple PDF documents. Please provide comprehensive answers that consider information from all available documents.",
            "model": "gpt-4-turbo-preview",
            "tools": [["type": "retrieval"]],
            "file_ids": fileIds
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        // Debug print the raw response
        print("=== Assistant Creation Response ===")
        if let responseString = String(data: data, encoding: .utf8) {
            print(responseString)
        }
        
        if let httpResponse = httpResponse as? HTTPURLResponse {
            print("Status Code: \(httpResponse.statusCode)")
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errorMessage = (errorJson?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw NSError(domain: "APIError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        let assistantResponse = try JSONDecoder().decode(AssistantResponse.self, from: data)
        return assistantResponse.id
    }
    
    private func createThread() async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/threads")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Debug print the raw response
        print("=== Thread Creation Response ===")
        if let responseString = String(data: data, encoding: .utf8) {
            print(responseString)
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Status Code: \(httpResponse.statusCode)")
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errorMessage = (errorJson?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw NSError(domain: "APIError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        
        let threadResponse = try JSONDecoder().decode(ThreadResponse.self, from: data)
        return threadResponse.id
    }
    
    func sendMessage(_ message: String, in session: ChatSession) async throws -> String {
        // First, add the message to the thread
        let messageId = try await addMessageToThread(message, threadId: session.threadId)
        
        // Then run the assistant
        let runId = try await runAssistant(session.assistantId, threadId: session.threadId)
        
        // Wait for completion
        try await waitForRunCompletion(runId: runId, threadId: session.threadId)
        
        // Get the assistant's response
        return try await getAssistantResponse(threadId: session.threadId)
    }
    
    private func addMessageToThread(_ message: String, threadId: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadId)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let body = ["role": "user", "content": message]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(MessageResponse.self, from: data)
        return response.id
    }
    
    private func runAssistant(_ assistantId: String, threadId: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadId)/runs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let body = ["assistant_id": assistantId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(RunResponse.self, from: data)
        return response.id
    }
    
    private func waitForRunCompletion(runId: String, threadId: String) async throws {
        while true {
            let url = URL(string: "https://api.openai.com/v1/threads/\(threadId)/runs/\(runId)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(RunResponse.self, from: data)
            
            if response.status == "completed" {
                break
            } else if response.status == "failed" {
                throw NSError(domain: "AssistantError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant run failed"])
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second
        }
    }
    
    private func getAssistantResponse(threadId: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/threads/\(threadId)/messages")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("assistants=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        // Debug print the response
        if let responseString = String(data: data, encoding: .utf8) {
            print("Messages response: \(responseString)")
        }
        
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        
        // Get the first assistant message
        if let assistantMessage = response.data.first(where: { $0.role == "assistant" }) {
            return assistantMessage.content.first?.text.value ?? "No response"
        }
        
        return "No response from assistant"
    }
    
    private func uploadFile(_ fileURL: URL) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
        data.append("assistants\r\n".data(using: .utf8)!)
        
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            data.append(fileData)
            data.append("\r\n".data(using: .utf8)!)
            data.append("--\(boundary)--\r\n".data(using: .utf8)!)
            
            request.httpBody = data
            
            let (responseData, response) = try await URLSession.shared.data(for: request)
            
            // Debug print the raw response
            print("=== File Upload Response ===")
            if let responseString = String(data: responseData, encoding: .utf8) {
                print(responseString)
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Status Code: \(httpResponse.statusCode)")
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
                    let errorMessage = (errorJson?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                    throw NSError(domain: "APIError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }
            }
            
            let uploadResponse = try JSONDecoder().decode(FileUploadResponse.self, from: responseData)
            return uploadResponse.id
        } catch {
            print("Upload error details: \(error)")
            throw error
        }
    }
}

struct FileUploadResponse: Codable {
    let id: String
    let object: String
    let bytes: Int
    let createdAt: Int
    let filename: String
    let purpose: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case bytes
        case createdAt = "created_at"
        case filename
        case purpose
    }
}

struct AssistantResponse: Codable {
    let id: String
    let object: String
    let createdAt: Int
    let name: String
    let description: String?
    let model: String
    let instructions: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case name
        case description
        case model
        case instructions
    }
}

struct ThreadResponse: Codable {
    let id: String
    let object: String
    let createdAt: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
    }
}

struct MessageResponse: Codable {
    let id: String
    let object: String
    let createdAt: Int
    let threadId: String
    let role: String
    let content: [MessageContent]
    
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case threadId = "thread_id"
        case role
        case content
    }
    
    struct MessageContent: Codable {
        let type: String
        let text: TextContent
    }
    
    struct TextContent: Codable {
        let value: String
        let annotations: [String]?
    }
}

struct RunResponse: Codable {
    let id: String
    let object: String
    let createdAt: Int
    let status: String
    let threadId: String
    let assistantId: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case status
        case threadId = "thread_id"
        case assistantId = "assistant_id"
    }
}

struct MessagesResponse: Codable {
    let object: String
    let data: [MessageData]
    let firstId: String
    let lastId: String
    let hasMore: Bool
    
    enum CodingKeys: String, CodingKey {
        case object
        case data
        case firstId = "first_id"
        case lastId = "last_id"
        case hasMore = "has_more"
    }
    
    struct MessageData: Codable {
        let id: String
        let object: String
        let createdAt: Int
        let threadId: String
        let role: String
        let content: [ContentItem]
        
        enum CodingKeys: String, CodingKey {
            case id
            case object
            case createdAt = "created_at"
            case threadId = "thread_id"
            case role
            case content
        }
    }
    
    struct ContentItem: Codable {
        let type: String
        let text: TextContent
    }
    
    struct TextContent: Codable {
        let value: String
        let annotations: [Annotation]?
    }
    
    struct Annotation: Codable {
        let type: String
        let text: String
        let startIndex: Int
        let endIndex: Int
        let fileCitation: FileCitation?
        
        enum CodingKeys: String, CodingKey {
            case type
            case text
            case startIndex = "start_index"
            case endIndex = "end_index"
            case fileCitation = "file_citation"
        }
    }
    
    struct FileCitation: Codable {
        let fileId: String
        let quote: String
        
        enum CodingKeys: String, CodingKey {
            case fileId = "file_id"
            case quote
        }
    }
} 