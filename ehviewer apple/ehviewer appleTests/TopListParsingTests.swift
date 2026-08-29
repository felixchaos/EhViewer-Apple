//
//  TopListParsingTests.swift
//  ehviewer appleTests
//
//  排行榜页 (toplist.php) 返回的就是标准的紧凑画廊列表表格 (itg gltc)，
//  字段结构与首页完全一致：glcat 分类、glthumb 封面、glname 标题、
//  gt 标签、ir 评分、页数、发布时间、上传者。
//
//  此前排行榜走的是一套单独的 parseTopList，只取出「名次 + 一行文字」，
//  于是那一页看起来和 App 里其他画廊列表完全不是一个东西。
//  这条测试守住「通用列表解析器能吃下排行榜页」——它成立，排行榜才能
//  复用 GalleryListView 和 EhGalleryRow。
//

import Testing
import Foundation
import EhParser
import EhModels

struct TopListParsingTests {

    /// 取自 e-hentai.org/toplist.php?tl=15 的真实排版（表头 + 前两条）
    private static let toplistHTML = #"""
<table class="itg gltc"><tr>
	<th colspan="2">&nbsp;</th>
	<th>Published</th>
	<th>Name</th>
	<th>Uploader</th>
</tr><tr><td><p>#1</p><p>487,634</p></td><td class="gl1c glcat"><div class="cn ct2">Doujinshi</div></td><td class="gl2c"><div class="glcut" id="ic4145131"></div><div class="glthumb" id="it4145131" style="top:-22px;height:396px"><div><img style="height:350px;width:250px;top:-5px" alt="[liyoosa] Maid-san Shirīzu‌ EP1-EP11 | 女僕小姐系列 EP1-EP11 [Chinese] [天帝哥個人漢化]" title="[liyoosa] Maid-san Shirīzu‌ EP1-EP11 | 女僕小姐系列 EP1-EP11 [Chinese] [天帝哥個人漢化]" src="https://ehgt.org/w/02/599/07355-bzzimmrs.webp" /></div><div><div><div class="cn ct2">Doujinshi</div><div onclick="popUp('https://e-hentai.org/gallerypopups.php?gid=4145131&amp;t=13df94234b&amp;act=addfav',675,415)" id="postedpop_4145131">2026-08-25 12:30</div></div><div><div class="ir" style="background-position:0px -1px;opacity:1"></div><div>170 pages</div></div></div></div><div><div onclick="popUp('https://e-hentai.org/gallerypopups.php?gid=4145131&amp;t=13df94234b&amp;act=addfav',675,415)" id="posted_4145131">2026-08-25 12:30</div><div class="ir" style="background-position:0px -1px;opacity:1"></div><div class="gldown"><a href="https://e-hentai.org/gallerytorrents.php?gid=4145131&amp;t=13df94234b" onclick="return popUp('https://e-hentai.org/gallerytorrents.php?gid=4145131&amp;t=13df94234b', 610, 590)" rel="nofollow"><img src="https://ehgt.org/g/t.png" alt="T" title="Show torrents" /></a></div></div></td><td class="gl3c glname" onmouseover="show_image_pane(4145131)" onmouseout="hide_image_pane()"><a href="https://e-hentai.org/g/4145131/13df94234b/"><div class="glink">[liyoosa] Maid-san Shirīzu‌ EP1-EP11 | 女僕小姐系列 EP1-EP11 [Chinese] [天帝哥個人漢化]</div><div><div class="gt" title="language:chinese">chinese</div><div class="gt" title="language:translated">translated</div><div class="gt" title="parody:original">original</div><div class="gt" title="artist:liyoosa">liyoosa</div><div class="gt" title="female:ahegao">f:ahegao</div><div class="gt" title="female:anal">f:anal</div><div class="gt" title="female:bdsm">f:bdsm</div><div class="gt" title="female:beauty mark">f:beauty mark</div><div class="gt" title="female:big areolae">f:big areolae</div><div class="gt" title="female:big breasts">f:big breasts</div><div class="gt" title="female:big clit">f:big clit</div><div class="gt" title="female:big nipples">f:big nipples</div></div></a></td><td class="gl4c glhide"><div><a href="https://e-hentai.org/uploader/%E5%A4%A9%E5%B8%9D%E5%93%A5">天帝哥</a></div><div>170 pages</div></td></tr><tr><td><p>#2</p><p>391,887</p></td><td class="gl1c glcat"><div class="cn ct1">Misc</div></td><td class="gl2c"><div class="glcut" id="ic4145342"></div><div class="glthumb" id="it4145342" style="top:-24px;height:187px"><div><img style="height:141px;width:250px" alt="［春天！］仙母孕胎录1-5" title="［春天！］仙母孕胎录1-5" src="https://ehgt.org/w/02/598/31292-j1bropdc.webp" /></div><div><div><div class="cn ct1">Misc</div><div onclick="popUp('https://e-hentai.org/gallerypopups.php?gid=4145342&amp;t=fa8370aaef&amp;act=addfav',675,415)" id="postedpop_4145342">2026-08-25 14:31</div></div><div><div class="ir" style="background-position:-32px -1px;opacity:1"></div><div>804 pages</div></div></div></div><div><div onclick="popUp('https://e-hentai.org/gallerypopups.php?gid=4145342&amp;t=fa8370aaef&amp;act=addfav',675,415)" id="posted_4145342">2026-08-25 14:31</div><div class="ir" style="background-position:-32px -1px;opacity:1"></div><div class="gldown"><img src="https://ehgt.org/g/td.png" alt="T" title="No torrents available" /></div></div></td><td class="gl3c glname" onmouseover="show_image_pane(4145342)" onmouseout="hide_image_pane()"><a href="https://e-hentai.org/g/4145342/fa8370aaef/"><div class="glink">［春天！］仙母孕胎录1-5</div><div><div class="gt" title="language:chinese">chinese</div><div class="gt" title="female:garter belt">f:garter belt</div><div class="gt" title="female:high heels">f:high heels</div><div class="gt" title="female:stockings">f:stockings</div><div class="gt" title="other:3d">3d</div></div></a></td><td class="gl4c glhide"><div><a href="https://e-hentai.org/uploader/%E7%94%98%E6%B2%B9%E9%85%B8%E9%85%AF">甘油酸酯</a></div><div>804 pages</div></td></tr></table>
"""#

    @Test func genericParserHandlesToplistPage() throws {
        let result = try GalleryListParser.parse(Self.toplistHTML)

        #expect(!result.galleries.isEmpty, "通用解析器吃不下排行榜页")

        let first = try #require(result.galleries.first)
        #expect(first.gid > 0)
        #expect(!first.token.isEmpty)
        #expect(!(first.title ?? "").isEmpty)
        // 分类、封面、标签这些「首页卡片有、排行榜也该有」的字段
        #expect(first.category.name != "Misc", "分类没解析出来（回落到了默认值）")
        #expect(first.thumb?.isEmpty == false)
        #expect(!(first.simpleTags ?? []).isEmpty)
    }
}
