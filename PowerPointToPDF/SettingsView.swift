import SwiftUI
import Security

class Settings: ObservableObject {
    @Published private(set) var apiKey: String = ""
    @Published var isKeyValid: Bool = false
    
    init() {
        removeApiKey()
    }
    
    func updateApiKey(_ newKey: String) {
        apiKey = newKey
        saveApiKey(newKey)
    }
    
    func removeApiKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openai_api_key"
        ]
        
        SecItemDelete(query as CFDictionary)
        apiKey = ""
        isKeyValid = false
    }
    
    func validateApiKey(_ key: String) async -> Bool {
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    private func saveApiKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openai_api_key",
            kSecValueData as String: key.data(using: .utf8) ?? Data()
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Error saving to Keychain: \(status)")
        }
    }
    
    private func loadApiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "openai_api_key",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    var completion: (() -> Void)?
    @State private var tempApiKey: String = ""
    @State private var isValidating = false
    @State private var showError = false
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("OpenAI API Key Required")
                .font(.headline)
            
            Text("Please enter your OpenAI API key to continue")
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            SecureField("Enter API Key", text: $tempApiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            
            if isValidating {
                ProgressView("Validating...")
            } else {
                Button("Save and Continue") {
                    validateAndSaveKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(tempApiKey.isEmpty)
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
        .frame(width: 400, height: 250)
        .alert("API Key Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
    
    private func validateAndSaveKey() {
        guard !tempApiKey.isEmpty else {
            errorMessage = "API key cannot be empty"
            showError = true
            return
        }
        
        isValidating = true
        
        Task {
            let isValid = await settings.validateApiKey(tempApiKey)
            
            await MainActor.run {
                isValidating = false
                
                if isValid {
                    settings.updateApiKey(tempApiKey)
                    settings.isKeyValid = true
                    tempApiKey = ""
                    completion?()
                    dismiss()
                } else {
                    errorMessage = "Invalid API key. Please check and try again."
                    showError = true
                }
            }
        }
    }
} 