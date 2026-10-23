import Foundation

struct SafetyError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// 安全层：路径沙箱 + 命令白名单。
///
/// 这是本地 agent 能不能「放心用」的分水岭。模型再强也会犯错，
/// 所以边界必须由代码强制，而不是靠提示词约束。
struct SafetyGuard: Sendable {
    /// 命中即拒绝的危险模式（正则）。
    static let defaultDangerousPatterns = [
        "\\brm\\s+-\\w*r\\w*f",        // rm -rf / rm -fr
        "\\bsudo\\b",
        "\\bmkfs(\\.[a-z0-9]+)?\\b",
        "\\bdd\\s+if=",
        ":\\(\\)\\s*\\{",              // fork bomb
        "\\bgit\\s+push\\b",
        "\\bgit\\s+reset\\s+--hard\\b",
        "\\bgit\\s+clean\\s+-\\w*f",
        "\\b(shutdown|reboot|halt)\\b",
        "\\b(curl|wget|nc|ncat)\\b",
        "\\bchmod\\s+777\\b",
        ">\\s*/dev/(sd|disk)",
        "\\bdiskutil\\b",
    ]

    /// 允许自动执行的命令前缀（按 argv 前缀匹配，不经过 shell）。
    static let defaultAllowedPrefixes = [
        "ls", "cat", "head", "tail", "wc", "pwd", "find", "grep", "rg",
        "diff", "sort", "uniq", "echo", "touch", "mkdir",
        "python", "python3", "pytest", "node", "npm", "npx", "make",
        "swift", "xcodebuild", "git status", "git diff", "git log",
        "git show", "git branch", "git add",
    ]

    let root: String
    let allowWrite: Bool
    let allowedPrefixes: [String]
    let dangerousPatterns: [String]
    let authorizedPaths: [String]

    init(
        rootPath: String,
        allowWrite: Bool,
        extraAllowed: [String] = [],
        extraDangerous: [String] = [],
        authorizedPaths: [String] = []
    ) {
        self.root = SafetyGuard.normalize(rootPath)
        self.allowWrite = allowWrite
        // 追加而非替换，避免用户配置覆盖掉默认保护
        self.allowedPrefixes = SafetyGuard.defaultAllowedPrefixes + extraAllowed
        self.dangerousPatterns = SafetyGuard.defaultDangerousPatterns + extraDangerous
        self.authorizedPaths = Array(Set(authorizedPaths.map(SafetyGuard.normalize))).sorted()
    }

    // MARK: - 路径

    /// 把路径解析成绝对路径，并确保它位于 workspace 或用户临时授权的附件路径内。
    func resolvePath(_ path: String, forWrite: Bool = false) throws -> String {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw SafetyError(message: "路径不能为空") }

        let candidate = SafetyGuard.normalize(raw.hasPrefix("/") ? raw : root + "/" + raw)

        guard isAuthorized(candidate) else {
            let extra = authorizedPaths.isEmpty ? "" : "；附加授权：\(authorizedPaths.joined(separator: "、"))"
            throw SafetyError(message: "路径越界，拒绝访问：\(path)（允许范围：\(root)\(extra)）")
        }

        if forWrite && !allowWrite {
            throw SafetyError(message: "当前是只读模式，写入被拒绝")
        }

        return candidate
    }

    func relativePath(_ absolute: String) -> String {
        if absolute == root { return "." }
        if absolute.hasPrefix(root + "/") {
            return String(absolute.dropFirst(root.count + 1))
        }
        return absolute
    }

    private func isAuthorized(_ candidate: String) -> Bool {
        if candidate == root || candidate.hasPrefix(root + "/") {
            return true
        }

        for item in authorizedPaths {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: item, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                if candidate == item || candidate.hasPrefix(item + "/") {
                    return true
                }
            } else if candidate == item {
                return true
            }
        }
        return false
    }

    /// Python `os.path.abspath` + `normpath` 的等价物：只做词法归一，不解析符号链接。
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [String] = []

        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append("..")
                }
            default:
                components.append(String(part))
            }
        }

        let joined = components.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    // MARK: - 命令

    func checkCommand(_ command: String) -> (allowed: Bool, reason: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (false, "空命令") }

        for pattern in dangerousPatterns {
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return (false, "命中危险命令规则 /\(pattern)/")
            }
        }

        // 不经过 shell，因此直接拒绝管道、重定向与命令拼接
        for token in ["|", ";", "&&", "||", ">", "<", "`", "$("] where text.contains(token) {
            return (false, "为安全起见，暂不允许管道、重定向与命令拼接")
        }

        guard let argv = SafetyGuard.shellSplit(text), let executable = argv.first else {
            return (false, "命令无法解析")
        }

        let joined = argv.joined(separator: " ")
        for prefix in allowedPrefixes where joined == prefix || joined.hasPrefix(prefix + " ") {
            return (true, "ok")
        }

        return (false, "命令不在白名单内：\(executable)（可在设置里追加放行）")
    }

    /// 极简的 `shlex.split`：只处理空白、单引号、双引号与反斜杠转义。
    static func shellSplit(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false

        for char in text {
            if escaped {
                current.append(char)
                hasToken = true
                escaped = false
                continue
            }

            if let active = quote {
                if char == active {
                    quote = nil
                } else if char == "\\" && active == "\"" {
                    escaped = true
                } else {
                    current.append(char)
                }
                hasToken = true
                continue
            }

            switch char {
            case "\\":
                hasToken = true
                escaped = true
            case "\"", "'":
                hasToken = true
                quote = char
            case " ", "\t", "\n":
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(char)
                hasToken = true
            }
        }

        guard quote == nil else { return nil }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
