import Foundation

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    let content: String
    let role: Role
    let timestamp: Date
    
    enum Role: String, Codable, Hashable {
        case user
        case assistant
        case system
    }
    
    init(id: UUID = UUID(), content: String, role: Role, timestamp: Date = Date()) {
        self.id = id
        self.content = content
        self.role = role
        self.timestamp = timestamp
    }
}

struct ChatSession: Identifiable, Codable, Hashable {
    let id: UUID
    var messages: [Message]
    let name: String
    let fileIds: [String]
    let assistantId: String
    let threadId: String
    
    init(id: UUID = UUID(), messages: [Message] = [], name: String, fileIds: [String], assistantId: String, threadId: String) {
        self.id = id
        self.messages = messages
        self.name = name
        self.fileIds = fileIds
        self.assistantId = assistantId
        self.threadId = threadId
    }
    
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 