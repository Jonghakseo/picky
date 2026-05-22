//
//  PickyDiffReviewTypes.swift
//  Picky
//
//  Codable mirrors for the diff review WebView contract.
//

import Foundation

enum ReviewScope: String, Codable, Equatable {
    case branch
    case commits
    case all
}

enum ChangeStatus: String, Codable, Equatable {
    case modified
    case added
    case deleted
    case renamed
}

enum ReviewFileKind: String, Codable, Equatable {
    case text
    case binary
    case image
}

enum ReviewCommitKind: String, Codable, Equatable {
    case commit
    case workingTree = "working-tree"
}

struct ReviewFileComparison: Codable, Equatable {
    let status: ChangeStatus
    let oldPath: String?
    let newPath: String?
    let displayPath: String
    let hasOriginal: Bool
    let hasModified: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case oldPath
        case newPath
        case displayPath
        case hasOriginal
        case hasModified
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(oldPath, forKey: .oldPath)
        try container.encode(newPath, forKey: .newPath)
        try container.encode(displayPath, forKey: .displayPath)
        try container.encode(hasOriginal, forKey: .hasOriginal)
        try container.encode(hasModified, forKey: .hasModified)
    }
}

struct ReviewFile: Codable, Equatable {
    let id: String
    let path: String
    let worktreeStatus: ChangeStatus?
    let hasWorkingTreeFile: Bool
    let inGitDiff: Bool
    let gitDiff: ReviewFileComparison?
    let kind: ReviewFileKind
    let mimeType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case worktreeStatus
        case hasWorkingTreeFile
        case inGitDiff
        case gitDiff
        case kind
        case mimeType
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(worktreeStatus, forKey: .worktreeStatus)
        try container.encode(hasWorkingTreeFile, forKey: .hasWorkingTreeFile)
        try container.encode(inGitDiff, forKey: .inGitDiff)
        try container.encode(gitDiff, forKey: .gitDiff)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
    }
}

struct ReviewCommitInfo: Codable, Equatable {
    let sha: String
    let shortSha: String
    let subject: String
    let authorName: String
    let authorDate: String
    let kind: ReviewCommitKind
}

struct ReviewFileContents: Codable, Equatable {
    let originalContent: String
    let modifiedContent: String
    let kind: ReviewFileKind
    let mimeType: String?
    let originalExists: Bool
    let modifiedExists: Bool
    let originalPreviewUrl: String?
    let modifiedPreviewUrl: String?

    enum CodingKeys: String, CodingKey {
        case originalContent
        case modifiedContent
        case kind
        case mimeType
        case originalExists
        case modifiedExists
        case originalPreviewUrl
        case modifiedPreviewUrl
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalContent, forKey: .originalContent)
        try container.encode(modifiedContent, forKey: .modifiedContent)
        try container.encode(kind, forKey: .kind)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(originalExists, forKey: .originalExists)
        try container.encode(modifiedExists, forKey: .modifiedExists)
        try container.encode(originalPreviewUrl, forKey: .originalPreviewUrl)
        try container.encode(modifiedPreviewUrl, forKey: .modifiedPreviewUrl)
    }
}

struct ReviewWindowData: Codable, Equatable {
    let repoRoot: String
    let files: [ReviewFile]
    let commits: [ReviewCommitInfo]
    let branchBaseRef: String?
    let branchMergeBaseSha: String?
    let repositoryHasHead: Bool

    enum CodingKeys: String, CodingKey {
        case repoRoot
        case files
        case commits
        case branchBaseRef
        case branchMergeBaseSha
        case repositoryHasHead
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repoRoot, forKey: .repoRoot)
        try container.encode(files, forKey: .files)
        try container.encode(commits, forKey: .commits)
        try container.encode(branchBaseRef, forKey: .branchBaseRef)
        try container.encode(branchMergeBaseSha, forKey: .branchMergeBaseSha)
        try container.encode(repositoryHasHead, forKey: .repositoryHasHead)
    }
}

extension JSONEncoder {
    static var diffReview: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }
}

extension JSONDecoder {
    static var diffReview: JSONDecoder {
        JSONDecoder()
    }
}
