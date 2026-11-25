import Foundation
import Testing
@testable import AetherTransferCore

private func makeDir(_ path: String) -> FileEntry {
    FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
}

private func makeFile(_ path: String, size: Int64 = 128) -> FileEntry {
    FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: false, size: size, permissions: "-rw-r--r--")
}

@Test func ancestorPathBuildingFromRootAndCustomRoot() {
    #expect(MillerColumnState.ancestorPaths(from: "/", to: "/") == ["/"])
    #expect(MillerColumnState.ancestorPaths(from: "/", to: "/Users/alice/Projects") == [
        "/",
        "/Users",
        "/Users/alice",
        "/Users/alice/Projects"
    ])
    #expect(MillerColumnState.ancestorPaths(from: "/Users/alice", to: "/Users/alice/Projects/Core/") == [
        "/Users/alice",
        "/Users/alice/Projects",
        "/Users/alice/Projects/Core"
    ])
    // Target outside custom root falls back cleanly to "/"
    #expect(MillerColumnState.ancestorPaths(from: "/Users/alice", to: "/var/log") == [
        "/",
        "/var",
        "/var/log"
    ])
}

@Test func selectingFolderOpensChildAndTruncatesDeeperBranches() {
    var state = MillerColumnState(rootPath: "/", initialPath: "/a/b/c")
    #expect(state.columns.map(\.path) == ["/", "/a", "/a/b", "/a/b/c"])
    #expect(state.activeColumnIndex == 3)
    #expect(state.activePath == "/a/b/c")
    #expect(state.columns[0].selectedEntryID == "/a")
    #expect(state.columns[1].selectedEntryID == "/a/b")
    #expect(state.columns[2].selectedEntryID == "/a/b/c")

    let branchA = makeDir("/a/b")
    let branchAlt = makeDir("/a/other")
    let readme = makeFile("/a/README.md")
    state.setEntries([branchA, branchAlt, readme], forColumnAt: "/a")
    #expect(state.columns[1].isLoading == false)
    #expect(state.columns[1].selectedEntryID == "/a/b")

    // Selecting a sibling folder in column 1 truncates /a/b and /a/b/c and opens /a/other
    let opened = state.select(entry: branchAlt, inColumnAt: 1)
    #expect(opened == "/a/other")
    #expect(state.columns.map(\.path) == ["/", "/a", "/a/other"])
    #expect(state.columns[1].selectedEntryID == "/a/other")
    #expect(state.columns[2].isLoading == true)
    #expect(state.activeColumnIndex == 1)
    #expect(state.activePath == "/a/other")
    #expect(state.previewedFile == nil)

    // Selecting a file in column 1 truncates /a/other and activates file preview
    let fileOpened = state.select(entry: readme, inColumnAt: 1)
    #expect(fileOpened == nil)
    #expect(state.columns.map(\.path) == ["/", "/a"])
    #expect(state.columns[1].selectedEntryID == "/a/README.md")
    #expect(state.activeColumnIndex == 1)
    #expect(state.activePath == "/a")
    #expect(state.previewedFile?.id == "/a/README.md")
}

@Test func syncPreservesPrefixColumnsAndNavigatesUp() {
    var state = MillerColumnState(rootPath: "/", initialPath: "/var/www/site")
    let varEntries = [makeDir("/var/www"), makeDir("/var/log")]
    state.setEntries(varEntries, forColumnAt: "/var")

    // Syncing to a sibling preserves "/" and "/var" entries without re-marking them loading
    let needed = state.sync(toPath: "/var/log/nginx")
    #expect(state.columns.map(\.path) == ["/", "/var", "/var/log", "/var/log/nginx"])
    #expect(state.columns[1].entries == varEntries)
    #expect(state.columns[1].isLoading == false)
    #expect(state.columns[1].selectedEntryID == "/var/log")
    #expect(needed == ["/", "/var/log", "/var/log/nginx"])
    #expect(state.activeColumnIndex == 3)

    // Syncing to the exact same path preserves activeColumnIndex
    _ = state.select(entry: makeDir("/var/log"), inColumnAt: 1)
    #expect(state.activeColumnIndex == 1)
    state.setEntries([makeFile("/var/log/system.log")], forColumnAt: "/var/log")
    let idempotentNeeded = state.sync(toPath: "/var/log")
    #expect(state.activeColumnIndex == 1)
    #expect(idempotentNeeded == ["/"])

    // navigateUp truncates tail column cleanly
    let upNeeded = state.navigateUp()
    #expect(state.columns.map(\.path) == ["/", "/var"])
    #expect(state.activePath == "/var")
    #expect(state.activeColumnIndex == 1)
    #expect(upNeeded == ["/"])
}

@Test func verticalAndHorizontalKeyboardNavigation() {
    var state = MillerColumnState(rootPath: "/", initialPath: "/workspace")
    state.setEntries([makeDir("/workspace")], forColumnAt: "/")
    let srcDir = makeDir("/workspace/src")
    let testsDir = makeDir("/workspace/tests")
    let packageFile = makeFile("/workspace/Package.swift", size: 512)
    state.setEntries([srcDir, testsDir, packageFile], forColumnAt: "/workspace")

    #expect(state.activeColumnIndex == 1)
    #expect(state.columns[1].selectedEntryID == nil)

    // Down from nil selects first item (src folder) and opens column 2
    let firstMove = state.moveSelectionVertical(delta: 1)
    #expect(firstMove?.entry == srcDir)
    #expect(firstMove?.openedDirectory == "/workspace/src")
    #expect(state.columns.map(\.path) == ["/", "/workspace", "/workspace/src"])
    #expect(state.activeColumnIndex == 1)

    // Populate child column /workspace/src
    let mainSwift = makeFile("/workspace/src/main.swift", size: 256)
    let modelsDir = makeDir("/workspace/src/Models")
    state.setEntries([modelsDir, mainSwift], forColumnAt: "/workspace/src")

    // Down again moves to testsDir
    let secondMove = state.moveSelectionVertical(delta: 1)
    #expect(secondMove?.entry == testsDir)
    #expect(state.columns.map(\.path) == ["/", "/workspace", "/workspace/tests"])

    // Down again moves to Package.swift, truncating column 2 and showing file preview
    let thirdMove = state.moveSelectionVertical(delta: 1)
    #expect(thirdMove?.entry == packageFile)
    #expect(thirdMove?.openedDirectory == nil)
    #expect(state.columns.map(\.path) == ["/", "/workspace"])
    #expect(state.previewedFile == packageFile)

    // Clamping at bottom
    let clampedBottom = state.moveSelectionVertical(delta: 1)
    #expect(clampedBottom?.entry == packageFile)

    // Move back up to srcDir
    _ = state.moveSelectionVertical(delta: -2)
    #expect(state.columns.map(\.path) == ["/", "/workspace", "/workspace/src"])
    state.setEntries([modelsDir, mainSwift], forColumnAt: "/workspace/src")

    // Right arrow steps into /workspace/src and selects its first entry (modelsDir), opening column 3
    let stepRight = state.stepIntoSelectedDirectory()
    #expect(stepRight.entry == modelsDir)
    #expect(stepRight.openedDirectory == "/workspace/src/Models")
    #expect(state.activeColumnIndex == 2)
    #expect(state.columns.map(\.path) == ["/", "/workspace", "/workspace/src", "/workspace/src/Models"])

    // Left arrow steps back to /workspace and truncates /workspace/src/Models
    #expect(state.stepOutToParentColumn() == true)
    #expect(state.activeColumnIndex == 1)
    #expect(state.columns.map(\.path) == ["/", "/workspace", "/workspace/src"])
    #expect(state.columns[2].selectedEntryID == nil)

    // Left arrow again steps to "/" and truncates /workspace/src
    #expect(state.stepOutToParentColumn() == true)
    #expect(state.activeColumnIndex == 0)
    #expect(state.columns.map(\.path) == ["/", "/workspace"])

    // At root column 0, left arrow returns false
    #expect(state.stepOutToParentColumn() == false)
    #expect(state.activeColumnIndex == 0)
}

@Test func focusColumnAndSetErrorBehavior() {
    var state = MillerColumnState(rootPath: "/", initialPath: "/a/b/c")
    state.setError("Permission denied", forColumnAt: "/a/b/c")
    #expect(state.columns[3].isLoading == false)
    #expect(state.columns[3].error == "Permission denied")

    state.setLoading(true, forColumnAt: "/a/b/c")
    #expect(state.columns[3].isLoading == true)
    #expect(state.columns[3].error == nil)

    state.focusColumn(at: 1)
    #expect(state.activeColumnIndex == 1)
    #expect(state.columns[1].selectedEntryID == nil)
    #expect(state.columns.map(\.path) == ["/", "/a"])
}

@Test func remoteClientSymlinkValidationAndProtocolGuard() async {
    let ftpProfile = ServerProfile(host: "ftp.example.com", port: 21, username: "alice", protocolKind: .ftp)
    let ftpClient = RemoteClient(profile: ftpProfile, credentials: Credentials(password: "pass"))
    await #expect(throws: TransferError.self) {
        try await ftpClient.createSymlink(target: "/var/www/live", at: "/var/www/current")
    }

    let sftpProfile = ServerProfile(host: "sftp.example.com", port: 22, username: "alice", protocolKind: .sftp)
    let sftpClient = RemoteClient(profile: sftpProfile, credentials: Credentials(password: "pass"))
    await #expect(throws: TransferError.self) {
        try await sftpClient.createSymlink(target: "/var/www/\nrm", at: "/var/www/link")
    }
}

