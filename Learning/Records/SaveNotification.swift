import Foundation
import SwiftData

nonisolated extension Notification {
    /// ModelContext.didSave：这次保存新增或删除了这些类型的记录。
    /// 列表、统计页不用 @Query 时用它决定要不要重新取：@Query 在每次保存（草稿自动保存、切换讲解）后都会重新取全部记录并重算，
    /// 页面即使不在屏幕上（压在导航栈下面、在别的标签页）也一样，会拖慢正在用的页面
    func insertsOrDeletes(_ types: [any PersistentModel.Type]) -> Bool {
        let names = Set(types.map { String(describing: $0) })
        let keys = [ModelContext.NotificationKey.insertedIdentifiers.rawValue,
                    ModelContext.NotificationKey.deletedIdentifiers.rawValue]
        return keys.contains { key in
            (userInfo?[key] as? [PersistentIdentifier] ?? []).contains { names.contains($0.entityName) }
        }
    }

    /// ModelContext.didSave：这次保存新增、删除或修改了这些类型的记录
    func touches(_ types: [any PersistentModel.Type]) -> Bool {
        let names = Set(types.map { String(describing: $0) })
        let keys = [ModelContext.NotificationKey.insertedIdentifiers.rawValue,
                    ModelContext.NotificationKey.deletedIdentifiers.rawValue,
                    ModelContext.NotificationKey.updatedIdentifiers.rawValue]
        return keys.contains { key in
            (userInfo?[key] as? [PersistentIdentifier] ?? []).contains { names.contains($0.entityName) }
        }
    }
}
