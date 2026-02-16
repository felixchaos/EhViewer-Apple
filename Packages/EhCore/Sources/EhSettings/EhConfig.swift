import Foundation
import EhModels

// MARK: - EhConfig (对应 Android EhConfig.java)
// 服务端用户配置，序列化为 uconfig cookie 值

@Observable @MainActor
public final class EhConfig: Sendable {
    public static let shared = EhConfig()

    // MARK: - Cookie Key
    public static let keyUconfig = "uconfig"

    // MARK: - 配置键
    private static let keyLoadFromHAH = "uh"
    private static let keyImageSize = "xr"
    private static let keyScaleWidth = "rx"
    private static let keyScaleHeight = "ry"
    private static let keyGalleryTitle = "tl"
    private static let keyArchiverDownload = "ar"
    private static let keyLayoutMode = "dm"
    private static let keyPopular = "prn"
    private static let keyDefaultCategories = "cats"
    private static let keyFavoritesSort = "fs"
    private static let keyExcludedNamespaces = "xns"
    private static let keyExcludedLanguages = "xl"
    private static let keyResultCount = "rc"
    private static let keyMouseOver = "ts"
    private static let keyPreviewSize = "tp"
    private static let keyPreviewRow = "tr"
    private static let keyCommentsSort = "cs"
    private static let keyCommentsVotes = "cv"
    private static let keyTagsSort = "to"
    private static let keyShowGalleryIndex = "pn"
    private static let keyHAHClientIpPort = "hp"
    private static let keyHAHClientPasskey = "hk"
    private static let keyEnableTagFlagging = "tf"
    private static let keyAlwaysOriginal = "oi"
    private static let keyMultiPage = "qb"
    private static let keyMultiPageStyle = "ms"
    private static let keyMultiPageThumb = "mt"
    private static let keyLofiResolution = "xres"
    private static let keyContentWarning = "nw"

    // MARK: - Load from H@H
    public static let loadFromHAHYes = "y"
    public static let loadFromHAHNo = "n"

    // MARK: - Image Size
    public static let imageSizeAuto = "a"
    public static let imageSize780x = "780"
    public static let imageSize980x = "980"
    public static let imageSize1280x = "1280"
    public static let imageSize1600x = "1600"
    public static let imageSize2400x = "2400"

    // MARK: - Gallery Title
    public static let galleryTitleDefault = "d"
    public static let galleryTitleJapanese = "j"

    // MARK: - Archiver Download
    public static let archiverDownloadMAMS = "0"
    public static let archiverDownloadAAMS = "1"
    public static let archiverDownloadMAAS = "2"
    public static let archiverDownloadAAAS = "3"

    // MARK: - Layout Mode
    public static let layoutModeList = "l"
    public static let layoutModeThumb = "t"

    // MARK: - Popular
    public static let popularYes = "y"
    public static let popularNo = "n"

    // MARK: - Favorites Sort
    public static let favoritesSortGalleryUpdateTime = "p"
    public static let favoritesSortFavoritedTime = "f"

    // MARK: - Result Count
    public static let resultCount25 = "25"
    public static let resultCount50 = "50"
    public static let resultCount100 = "100"
    public static let resultCount200 = "200"

    // MARK: - Mouse Over
    public static let mouseOverYes = "y"
    public static let mouseOverNo = "n"

    // MARK: - Preview Size
    public static let previewSizeNormal = "n"
    public static let previewSizeLarge = "l"

    // MARK: - Preview Row
    public static let previewRow4 = "4"
    public static let previewRow10 = "10"
    public static let previewRow20 = "20"
    public static let previewRow40 = "40"

    // MARK: - Comments Sort
    public static let commentsSortOldestFirst = "oa"
    public static let commentsSortRecentFirst = "ra"
    public static let commentsSortHighestScoreFirst = "sa"

    // MARK: - Comments Votes
    public static let commentsVotesPop = "1"
    public static let commentsVotesAlways = "2"

    // MARK: - Tags Sort
    public static let tagsSortAlphabetical = "a"
    public static let tagsSortPower = "p"

    // MARK: - Show Gallery Index
    public static let showGalleryIndexYes = "y"
    public static let showGalleryIndexNo = "n"

    // MARK: - Enable Tag Flagging
    public static let enableTagFlaggingYes = "y"
    public static let enableTagFlaggingNo = "n"

    // MARK: - Always Original
    public static let alwaysOriginalYes = "y"
    public static let alwaysOriginalNo = "n"

    // MARK: - Multi-Page Viewer
    public static let multiPageYes = "1"
    public static let multiPageNo = "0"
    public static let multiPageStyleN = "n"
    public static let multiPageStyleC = "c"
    public static let multiPageStyleY = "y"
    public static let multiPageThumbShow = "n"
    public static let multiPageThumbHide = "y"

    // MARK: - Content Warning
    public static let contentWarningShow = "1"
    public static let contentWarningNotShow = ""

    // MARK: - Excluded Languages
    public static let japaneseOriginal = "0"
    public static let japaneseTranslated = "1024"
    public static let japaneseRewrite = "2048"
    public static let englishOriginal = "1"
    public static let englishTranslated = "1025"
    public static let englishRewrite = "2049"
    public static let chineseOriginal = "10"
    public static let chineseTranslated = "1034"
    public static let chineseRewrite = "2058"
    public static let dutchOriginal = "20"
    public static let dutchTranslated = "1044"
    public static let dutchRewrite = "2068"
    public static let frenchOriginal = "30"
    public static let frenchTranslated = "1054"
    public static let frenchRewrite = "2078"
    public static let germanOriginal = "40"
    public static let germanTranslated = "1064"
    public static let germanRewrite = "2088"
    public static let hungarianOriginal = "50"
    public static let hungarianTranslated = "1074"
    public static let hungarianRewrite = "2098"
    public static let italianOriginal = "60"
    public static let italianTranslated = "1084"
    public static let italianRewrite = "2108"
    public static let koreanOriginal = "70"
    public static let koreanTranslated = "1094"
    public static let koreanRewrite = "2118"
    public static let polishOriginal = "80"
    public static let polishTranslated = "1104"
    public static let polishRewrite = "2128"
    public static let portugueseOriginal = "90"
    public static let portugueseTranslated = "1114"
    public static let portugueseRewrite = "2138"
    public static let russianOriginal = "100"
    public static let russianTranslated = "1124"
    public static let russianRewrite = "2148"
    public static let spanishOriginal = "110"
    public static let spanishTranslated = "1134"
    public static let spanishRewrite = "2158"
    public static let thaiOriginal = "120"
    public static let thaiTranslated = "1144"
    public static let thaiRewrite = "2168"
    public static let vietnameseOriginal = "130"
    public static let vietnameseTranslated = "1154"
    public static let vietnameseRewrite = "2178"
    public static let notApplicableOriginal = "254"
    public static let notApplicableTranslated = "1278"
    public static let notApplicableRewrite = "2302"
    public static let otherOriginal = "255"
    public static let otherTranslated = "1279"
    public static let otherRewrite = "2303"

    // MARK: - Excluded Namespaces (bitmask)
    public static let namespacesReclass = 0x1
    public static let namespacesLanguage = 0x2
    public static let namespacesParody = 0x4
    public static let namespacesCharacter = 0x8
    public static let namespacesGroup = 0x10
    public static let namespacesArtist = 0x20
    public static let namespacesMale = 0x40
    public static let namespacesFemale = 0x80

    // MARK: - Favorites Order
    public static let orderByFavTime = "f"
    public static let orderByPubTime = "p"

    // MARK: - Instance Fields

    public var loadFromHAH: String = loadFromHAHYes
    public var imageSize: String = imageSizeAuto
    public var scaleWidth: Int = 0
    public var scaleHeight: Int = 0
    public var galleryTitle: String = galleryTitleDefault
    public var archiverDownload: String = archiverDownloadMAMS
    public var layoutMode: String = layoutModeList
    public var popular: String = popularYes
    public var defaultCategories: Int = 0
    public var favoritesSort: String = favoritesSortFavoritedTime
    public var excludedNamespaces: Int = 0
    public var excludedLanguages: String = ""
    public var resultCount: String = resultCount25
    public var mouseOver: String = mouseOverYes
    public var previewSize: String = previewSizeLarge
    public var previewRow: String = previewRow4
    public var commentSort: String = commentsSortOldestFirst
    public var commentVotes: String = commentsVotesPop
    public var tagSort: String = tagsSortAlphabetical
    public var showGalleryIndex: String = showGalleryIndexYes
    public var hahClientIp: String = ""
    public var hahClientPort: Int = -1
    public var hahClientPasskey: String = ""
    public var enableTagFlagging: String = enableTagFlaggingNo
    public var alwaysOriginal: String = alwaysOriginalNo
    public var multiPage: String = multiPageNo
    public var multiPageStyle: String = multiPageStyleN
    public var multiPageThumb: String = multiPageThumbShow
    public var lofiResolution: String = "980"
    public var contentWarning: String = contentWarningNotShow

    private var dirty = true
    private var cachedUconfig: String = ""

    public init() {}

    // MARK: - uconfig Cookie

    public func setDirty() {
        dirty = true
    }

    /// 生成 uconfig cookie 值 (对应 Android EhConfig.uconfig())
    public func uconfig() -> String {
        if dirty {
            dirty = false
            updateUconfig()
        }
        return cachedUconfig
    }

    private func updateUconfig() {
        // H@H client IP:port
        let hahIpPort: String
        if !hahClientIp.isEmpty && hahClientPort > 0 && hahClientPort <= 65535 {
            hahIpPort = "\(hahClientIp)%3A\(hahClientPort)"
        } else {
            hahIpPort = ""
        }

        cachedUconfig = [
            "\(Self.keyLoadFromHAH)_\(loadFromHAH)",
            "\(Self.keyImageSize)_\(imageSize)",
            "\(Self.keyScaleWidth)_\(scaleWidth)",
            "\(Self.keyScaleHeight)_\(scaleHeight)",
            "\(Self.keyGalleryTitle)_\(galleryTitle)",
            "\(Self.keyArchiverDownload)_\(archiverDownload)",
            "\(Self.keyLayoutMode)_\(layoutMode)",
            "\(Self.keyPopular)_\(popular)",
            "\(Self.keyDefaultCategories)_\(defaultCategories)",
            "\(Self.keyFavoritesSort)_\(favoritesSort)",
            "\(Self.keyExcludedNamespaces)_\(excludedNamespaces)",
            "\(Self.keyExcludedLanguages)_\(excludedLanguages)",
            "\(Self.keyResultCount)_\(resultCount)",
            "\(Self.keyMouseOver)_\(mouseOver)",
            "\(Self.keyPreviewSize)_\(previewSize)",
            "\(Self.keyPreviewRow)_\(previewRow)",
            "\(Self.keyCommentsSort)_\(commentSort)",
            "\(Self.keyCommentsVotes)_\(commentVotes)",
            "\(Self.keyTagsSort)_\(tagSort)",
            "\(Self.keyShowGalleryIndex)_\(showGalleryIndex)",
            "\(Self.keyHAHClientIpPort)_\(hahIpPort)",
            "\(Self.keyHAHClientPasskey)_\(hahClientPasskey)",
            "\(Self.keyEnableTagFlagging)_\(enableTagFlagging)",
            "\(Self.keyAlwaysOriginal)_\(alwaysOriginal)",
            "\(Self.keyMultiPage)_\(multiPage)",
            "\(Self.keyMultiPageStyle)_\(multiPageStyle)",
            "\(Self.keyMultiPageThumb)_\(multiPageThumb)",
        ].joined(separator: "-")
    }
}
