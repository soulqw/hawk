import Foundation

/// 行级 diff，用于改动预览。
///
/// 用最朴素的 LCS 动态规划：改动预览的规模（一次编辑几十到几百行）完全够用，
/// 而引入第三方 diff 库会破坏「零依赖、复制即可编译」这一点。
enum DiffEngine {
    /// 参与 LCS 计算的行数上限，超出的部分退化为「整体替换」，避免大文件把内存打满。
    private static let maxLCSLines = 800

    static func lines(before: String, after: String) -> [DiffLine] {
        let oldLines = split(before)
        let newLines = split(after)

        guard oldLines.count <= maxLCSLines, newLines.count <= maxLCSLines else {
            return fallback(oldLines: oldLines, newLines: newLines)
        }

        let n = oldLines.count
        let m = newLines.count

        // dp[i][j] = oldLines[i...] 与 newLines[j...] 的最长公共子序列长度
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let stride = m + 1

        if n > 0 && m > 0 {
            for i in Swift.stride(from: n - 1, through: 0, by: -1) {
                for j in Swift.stride(from: m - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        table[i * stride + j] = table[(i + 1) * stride + (j + 1)] + 1
                    } else {
                        table[i * stride + j] = max(table[(i + 1) * stride + j], table[i * stride + (j + 1)])
                    }
                }
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        var oldNumber = 1
        var newNumber = 1

        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                result.append(DiffLine(kind: .context, text: oldLines[i], oldNumber: oldNumber, newNumber: newNumber))
                i += 1
                j += 1
                oldNumber += 1
                newNumber += 1
            } else if table[(i + 1) * stride + j] >= table[i * stride + (j + 1)] {
                result.append(DiffLine(kind: .removed, text: oldLines[i], oldNumber: oldNumber, newNumber: nil))
                i += 1
                oldNumber += 1
            } else {
                result.append(DiffLine(kind: .inserted, text: newLines[j], oldNumber: nil, newNumber: newNumber))
                j += 1
                newNumber += 1
            }
        }

        while i < n {
            result.append(DiffLine(kind: .removed, text: oldLines[i], oldNumber: oldNumber, newNumber: nil))
            i += 1
            oldNumber += 1
        }

        while j < m {
            result.append(DiffLine(kind: .inserted, text: newLines[j], oldNumber: nil, newNumber: newNumber))
            j += 1
            newNumber += 1
        }

        return collapse(result)
    }

    private static func fallback(oldLines: [String], newLines: [String]) -> [DiffLine] {
        var result: [DiffLine] = []
        for (index, line) in oldLines.enumerated() {
            result.append(DiffLine(kind: .removed, text: line, oldNumber: index + 1, newNumber: nil))
        }
        for (index, line) in newLines.enumerated() {
            result.append(DiffLine(kind: .inserted, text: line, oldNumber: nil, newNumber: index + 1))
        }
        return collapse(result)
    }

    /// 把连续 6 行以上的未改动区域折叠成一行省略提示。
    private static func collapse(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        guard lines.count > context * 2 + 12 else { return lines }

        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard let first = changed.first, let last = changed.last else { return lines }

        let keep = Set(
            lines.indices.filter { index in
                (first...last).contains(index) && lines[index].kind != .context
            }
            .flatMap { index in
                max(0, index - context)...min(lines.count - 1, index + context)
            }
        )

        var result: [DiffLine] = []
        var inGap = false
        for index in lines.indices {
            if keep.contains(index) {
                result.append(lines[index])
                inGap = false
            } else if !inGap {
                result.append(DiffLine(kind: .context, text: "⋯⋯", oldNumber: nil, newNumber: nil))
                inGap = true
            }
        }
        return result
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // 结尾换行会产生一个多余的空元素，去掉它，diff 才不会多出一行
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
