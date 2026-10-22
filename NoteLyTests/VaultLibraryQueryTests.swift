import XCTest
@testable import NoteLy

final class VaultLibraryQueryTests: XCTestCase {
    func testFiltersByTypeAndKeepsFolder() {
        let folder = UUID()
        let photo = item(name: "a.jpg", type: .photo, folder: folder)
        let video = item(name: "b.mov", type: .video, folder: folder)
        let pdf = item(name: "c.pdf", type: .pdf, folder: folder)
        let otherFolder = item(name: "d.jpg", type: .photo, folder: UUID())
        let items = [photo, video, pdf, otherFolder]
        let photos = VaultLibraryQuery.apply(items: items, trash: [], folderID: folder, filter: .photos, favoritesOnly: false, sort: .name, ascending: true, query: "")
        XCTAssertEqual(photos.map(\.originalName), ["a.jpg"])
        let files = VaultLibraryQuery.apply(items: items, trash: [], folderID: folder, filter: .files, favoritesOnly: false, sort: .name, ascending: true, query: "")
        XCTAssertEqual(files.map(\.originalName), ["c.pdf"])
        let videos = VaultLibraryQuery.apply(items: items, trash: [], folderID: folder, filter: .videos, favoritesOnly: false, sort: .name, ascending: true, query: "")
        XCTAssertEqual(videos.map(\.id), [video.id])
    }

    func testSortDirectionAndFavorites() {
        let older = item(name: "B", type: .photo, imported: Date(timeIntervalSince1970: 10), favorite: false)
        let newer = item(name: "A", type: .photo, imported: Date(timeIntervalSince1970: 20), favorite: true)
        let items = [older, newer]
        let descending = VaultLibraryQuery.apply(items: items, trash: [], folderID: nil, filter: .all, favoritesOnly: false, sort: .imported, ascending: false, query: "")
        XCTAssertEqual(descending.map(\.originalName), ["A", "B"])
        let ascending = VaultLibraryQuery.apply(items: items, trash: [], folderID: nil, filter: .all, favoritesOnly: false, sort: .imported, ascending: true, query: "")
        XCTAssertEqual(ascending.map(\.originalName), ["B", "A"])
        let favorites = VaultLibraryQuery.apply(items: items, trash: [], folderID: nil, filter: .all, favoritesOnly: true, sort: .name, ascending: true, query: "")
        XCTAssertEqual(favorites.map(\.originalName), ["A"])
    }

    func testTrashIsHiddenAndCounts() {
        let photo = item(name: "p", type: .photo)
        let video = item(name: "v", type: .video)
        let counts = VaultLibraryQuery.counts(items: [photo, video], trash: [photo.id], folderID: nil)
        XCTAssertEqual(counts[.all], 1)
        XCTAssertEqual(counts[.photos], 0)
        XCTAssertEqual(counts[.videos], 1)
    }

    private func item(name: String, type: VaultMediaType, folder: UUID? = nil, imported: Date = .now, favorite: Bool = false) -> VaultItem {
        VaultItem(originalName: name, type: type, utType: type.rawValue, size: 10, importedAt: imported, folderID: folder, isFavorite: favorite, plaintextSHA256: name)
    }
}
