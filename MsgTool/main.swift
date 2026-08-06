import Foundation

// Command-line access to the app's message research tools. GPT (via the
// Codex CLI) runs this binary to search the local index; it never touches
// the Messages database or the network beyond the local Ollama server.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    fail("""
    usage: msgtool <tool> [key=value ...]

    tools:
      search_messages   query= [strategy=hybrid|semantic|keyword] [from_person=] [after=YYYY-MM-DD] [before=YYYY-MM-DD] [limit=]
      grep_messages     pattern= [from_person=] [after=] [before=] [limit=]
      recent_messages   [from_person=] [after=] [before=] [limit=]
      get_conversation_context  window_id= [before=] [after=]
    """)
}

let tool = arguments.removeFirst()
var parsed: [String: JSONValue] = [:]
for argument in arguments {
    guard let equals = argument.firstIndex(of: "=") else {
        fail("bad argument (expected key=value): \(argument)")
    }
    let key = String(argument[..<equals])
    let value = String(argument[argument.index(after: equals)...])
    if let number = Double(value), !value.contains("-") {
        parsed[key] = .number(number)
    } else {
        parsed[key] = .string(value)
    }
}

let engine = SearchEngine()

// The app exports its contact map so results show names instead of numbers;
// this process has no Contacts access of its own.
if let contactsPath = ProcessInfo.processInfo.environment["MSGTOOL_CONTACTS"],
   let data = FileManager.default.contents(atPath: contactsPath),
   let names = try? JSONDecoder().decode([String: String].self, from: data) {
    await engine.setContactNames(HandleNameMap(names: names))
}

do {
    let output = try await engine.runAgentTool(name: tool, arguments: parsed)
    print(output)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
