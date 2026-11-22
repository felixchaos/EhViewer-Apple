import GRDB

/// The persistent schema and migration history are independent of the database facade.
/// Never rewrite a shipped migration; append the next version here.
enum EhDatabaseSchema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // 下载记录表 (对应 Android DownloadsDao)
            try db.create(table: "download") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("state", .integer).notNull().defaults(to: 0)
                t.column("legacy", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
                t.column("label", .text)
            }

            // 下载标签表 (对应 Android DownloadLabelDao)
            try db.create(table: "downloadLabel") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull().unique()
                t.column("date", .integer).notNull()
            }

            // 浏览历史表 (对应 Android HistoryDao)
            try db.create(table: "history") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("mode", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 本地收藏表 (对应 Android LocalFavoritesDao)
            try db.create(table: "localFavorite") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 快速搜索表 (对应 Android QuickSearchDao)
            try db.create(table: "quickSearch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("mode", .integer).notNull()
                t.column("category", .integer).notNull()
                t.column("keyword", .text)
                t.column("advanceSearch", .integer).notNull().defaults(to: 0)
                t.column("minRating", .integer).notNull().defaults(to: 0)
                t.column("pageFrom", .integer).notNull().defaults(to: 0)
                t.column("pageTo", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 过滤器表 (对应 Android FilterDao)
            try db.create(table: "filter") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mode", .integer).notNull()
                t.column("text", .text)
                t.column("enable", .boolean).notNull().defaults(to: true)
                t.column("date", .integer).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // 黑名单表 (对应 Android BlackListDao)
            try db.create(table: "blackList") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("badgayname", .text).notNull().indexed()
                t.column("reason", .text)
                t.column("angrywith", .text)
                t.column("addTime", .text)
                t.column("mode", .integer)
            }

            // 阅读书签表 (对应 Android BookmarksBao)
            try db.create(table: "bookmark") { t in
                t.primaryKey("gid", .integer)
                t.column("token", .text).notNull()
                t.column("title", .text).notNull()
                t.column("titleJpn", .text)
                t.column("thumb", .text)
                t.column("category", .integer).notNull().defaults(to: 0)
                t.column("posted", .text)
                t.column("uploader", .text)
                t.column("rating", .real).defaults(to: 0)
                t.column("simpleLanguage", .text)
                t.column("pages", .integer).defaults(to: 0)
                t.column("page", .integer).notNull().defaults(to: 0)
                t.column("date", .integer).notNull()
            }

            // 下载目录名映射表 (对应 Android DownloadDirnameDao)
            try db.create(table: "downloadDirname") { t in
                t.primaryKey("gid", .integer)
                t.column("dirname", .text).notNull()
            }

            // 画廊标签缓存表 (对应 Android GalleryTagsDao)
            try db.create(table: "galleryTags") { t in
                t.primaryKey("gid", .integer)
                t.column("rows", .text)
                t.column("artist", .text)
                t.column("cosplayer", .text)
                t.column("character", .text)
                t.column("female", .text)
                t.column("group", .text)
                t.column("language", .text)
                t.column("male", .text)
                t.column("misc", .text)
                t.column("mixed", .text)
                t.column("other", .text)
                t.column("parody", .text)
                t.column("reclass", .text)
                t.column("createTime", .datetime)
                t.column("updateTime", .datetime)
            }
        }

        migrator.registerMigration("v3") { db in
            // 下载/历史/本地收藏三张表补 simpleTags。
            //
            // 这三处的列表行此前只能显示标题和封面：卡片组件支持标签 chip，
            // 但记录里根本没存过标签，于是同一本本子在首页信息完整、
            // 换到收藏页就只剩一个标题。列表接口本来就返回 simpleTags，
            // 存下来即可，不需要额外请求。
            for table in ["download", "history", "localFavorite"] {
                try db.alter(table: table) { t in
                    t.add(column: "simpleTags", .text)
                }
            }
        }

        return migrator
    }
}
