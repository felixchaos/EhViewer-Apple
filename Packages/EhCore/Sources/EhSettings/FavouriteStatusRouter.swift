import Foundation
import EhModels

// MARK: - FavouriteStatusRouter (对应 Android FavouriteStatusRouter.java)
// 跨页面收藏状态同步: 当一个页面修改了收藏状态，其他页面也能收到通知并更新

@MainActor @Observable
public final class FavouriteStatusRouter: @unchecked Sendable {
    public static let shared = FavouriteStatusRouter()

    /// 收藏状态变更通知名
    public static let favouriteChangedNotification = Notification.Name("EhFavouriteStatusChanged")

    /// 通知 userInfo 键
    public static let gidKey = "gid"
    public static let slotKey = "slot"

    /// 保存的画廊数据映射: mapId → [gid: GalleryInfo]
    private var maps: [Int: [Int64: GalleryInfo]] = [:]
    private var nextId: Int = 0

    private init() {}

    // MARK: - 数据映射管理

    /// 保存画廊数据映射，返回 mapId (供后续 restore 使用)
    public func saveDataMap(_ map: [Int64: GalleryInfo]) -> Int {
        let id = nextId
        nextId += 1
        maps[id] = map
        return id
    }

    /// 恢复并移除数据映射
    public func restoreDataMap(_ id: Int) -> [Int64: GalleryInfo]? {
        return maps.removeValue(forKey: id)
    }

    // MARK: - 收藏状态修改

    /// 修改收藏状态并通知所有监听者
    /// - Parameters:
    ///   - gid: 画廊 ID
    ///   - slot: 收藏分类 (-1 表示未收藏，0-9 表示收藏分类)
    public func modifyFavourites(gid: Int64, slot: Int) {
        // 更新所有保存的映射
        for (mapId, _) in maps {
            maps[mapId]?[gid]?.favoriteSlot = slot
        }

        // 发送通知
        NotificationCenter.default.post(
            name: Self.favouriteChangedNotification,
            object: self,
            userInfo: [Self.gidKey: gid, Self.slotKey: slot]
        )
    }
}
