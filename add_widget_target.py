#!/usr/bin/env python3
"""
Add EhDownloadWidget extension target to the Xcode project.
This script modifies the project.pbxproj to add a Widget Extension target
for Live Activity / Dynamic Island support.
"""

import re
import sys

PBXPROJ_PATH = sys.argv[1] if len(sys.argv) > 1 else "ehviewer apple.xcodeproj/project.pbxproj"

with open(PBXPROJ_PATH, 'r') as f:
    content = f.read()

# ============================================================
# New unique IDs for the widget extension target
# ============================================================
ID_TARGET      = "DC9A30012F40A10100AABB01"
ID_PRODUCT_REF = "DC9A30022F40A10100AABB02"
ID_SYNC_GROUP  = "DC9A30032F40A10100AABB03"
ID_FRAMEWORKS  = "DC9A30042F40A10100AABB04"
ID_SOURCES     = "DC9A30052F40A10100AABB05"
ID_RESOURCES   = "DC9A30062F40A10100AABB06"
ID_EMBED_PHASE = "DC9A30072F40A10100AABB07"
ID_PROXY       = "DC9A30082F40A10100AABB08"
ID_DEPENDENCY  = "DC9A30092F40A10100AABB09"
ID_CFG_DEBUG   = "DC9A300A2F40A10100AABB0A"
ID_CFG_RELEASE = "DC9A300B2F40A10100AABB0B"
ID_CFG_LIST    = "DC9A300C2F40A10100AABB0C"
ID_EMBED_FILE  = "DC9A300D2F40A10100AABB0D"

# Existing IDs
ID_PROJECT     = "DC4A07602F3DA21800717C38"
ID_APP_TARGET  = "DC4A07672F3DA21800717C38"
ID_PRODUCTS    = "DC4A07692F3DA21800717C38"
ID_MAIN_GROUP  = "DC4A075F2F3DA21800717C38"

# ============================================================
# 1. Add PBXBuildFile for embedding the extension
# ============================================================
build_file_entry = f"""\t\t{ID_EMBED_FILE} /* EhDownloadWidget.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {ID_PRODUCT_REF} /* EhDownloadWidget.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
"""
content = content.replace(
    "/* End PBXBuildFile section */",
    build_file_entry + "/* End PBXBuildFile section */"
)

# ============================================================
# 2. Add PBXContainerItemProxy
# ============================================================
proxy_entry = f"""\t\t{ID_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {ID_PROJECT} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {ID_TARGET};
\t\t\tremoteInfo = EhDownloadWidget;
\t\t}};
"""
content = content.replace(
    "/* End PBXContainerItemProxy section */",
    proxy_entry + "/* End PBXContainerItemProxy section */"
)

# ============================================================
# 3. Add PBXCopyFilesBuildPhase (embed extensions) - NEW section
# ============================================================
copy_phase = f"""/* Begin PBXCopyFilesBuildPhase section */
\t\t{ID_EMBED_PHASE} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{ID_EMBED_FILE} /* EhDownloadWidget.appex in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

"""
# Insert before PBXFileReference section
content = content.replace(
    "/* Begin PBXFileReference section */",
    copy_phase + "/* Begin PBXFileReference section */"
)

# ============================================================
# 4. Add PBXFileReference for the .appex product
# ============================================================
file_ref = f"""\t\t{ID_PRODUCT_REF} /* EhDownloadWidget.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = EhDownloadWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
"""
content = content.replace(
    "/* End PBXFileReference section */",
    file_ref + "/* End PBXFileReference section */"
)

# ============================================================
# 5. Add PBXFileSystemSynchronizedRootGroup for extension sources
# ============================================================
# Also add exception for Info.plist
sync_group = f"""\t\t{ID_SYNC_GROUP} /* EhDownloadWidget */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\texceptions = (
\t\t\t);
\t\t\tpath = EhDownloadWidget;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
content = content.replace(
    "/* End PBXFileSystemSynchronizedRootGroup section */",
    sync_group + "/* End PBXFileSystemSynchronizedRootGroup section */"
)

# ============================================================
# 6. Add PBXFrameworksBuildPhase for extension
# ============================================================
fw_phase = f"""\t\t{ID_FRAMEWORKS} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
content = content.replace(
    "/* End PBXFrameworksBuildPhase section */",
    fw_phase + "/* End PBXFrameworksBuildPhase section */"
)

# ============================================================
# 7. Add product to Products group + source dir to root group
# ============================================================
# Add to Products group
old_products = f"""\t\t{ID_PRODUCTS} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tDC4A07682F3DA21800717C38 /* ehviewer apple.app */,
\t\t\t\tDC4A07792F3DA21800717C38 /* ehviewer appleTests.xctest */,
\t\t\t\tDC4A07832F3DA21800717C38 /* ehviewer appleUITests.xctest */,
\t\t\t);"""
new_products = f"""\t\t{ID_PRODUCTS} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tDC4A07682F3DA21800717C38 /* ehviewer apple.app */,
\t\t\t\tDC4A07792F3DA21800717C38 /* ehviewer appleTests.xctest */,
\t\t\t\tDC4A07832F3DA21800717C38 /* ehviewer appleUITests.xctest */,
\t\t\t\t{ID_PRODUCT_REF} /* EhDownloadWidget.appex */,
\t\t\t);"""
content = content.replace(old_products, new_products)

# Add source dir to root group
old_root = f"""\t\t{ID_MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tDC4A076A2F3DA21800717C38 /* ehviewer apple */,
\t\t\t\tDC4A07862F3DA21800717C38 /* ehviewer appleUITests */,
\t\t\t\t{ID_PRODUCTS} /* Products */,
\t\t\t);"""
new_root = f"""\t\t{ID_MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tDC4A076A2F3DA21800717C38 /* ehviewer apple */,
\t\t\t\t{ID_SYNC_GROUP} /* EhDownloadWidget */,
\t\t\t\tDC4A07862F3DA21800717C38 /* ehviewer appleUITests */,
\t\t\t\t{ID_PRODUCTS} /* Products */,
\t\t\t);"""
content = content.replace(old_root, new_root)

# ============================================================
# 8. Add PBXNativeTarget for widget extension
# ============================================================
native_target = f"""\t\t{ID_TARGET} /* EhDownloadWidget */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ID_CFG_LIST} /* Build configuration list for PBXNativeTarget "EhDownloadWidget" */;
\t\t\tbuildPhases = (
\t\t\t\t{ID_SOURCES} /* Sources */,
\t\t\t\t{ID_FRAMEWORKS} /* Frameworks */,
\t\t\t\t{ID_RESOURCES} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{ID_SYNC_GROUP} /* EhDownloadWidget */,
\t\t\t);
\t\t\tname = EhDownloadWidget;
\t\t\tpackageProductDependencies = (
\t\t\t);
\t\t\tproductName = EhDownloadWidget;
\t\t\tproductReference = {ID_PRODUCT_REF} /* EhDownloadWidget.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};
"""
content = content.replace(
    "/* End PBXNativeTarget section */",
    native_target + "/* End PBXNativeTarget section */"
)

# ============================================================
# 9. Update PBXProject: add target, embed phase to app, dependency
# ============================================================

# Add target to project targets list
content = content.replace(
    f"""\t\t\ttargets = (
\t\t\t\t{ID_APP_TARGET} /* ehviewer apple */,
\t\t\t\tDC4A07782F3DA21800717C38 /* ehviewer appleTests */,
\t\t\t\tDC4A07822F3DA21800717C38 /* ehviewer appleUITests */,
\t\t\t);""",
    f"""\t\t\ttargets = (
\t\t\t\t{ID_APP_TARGET} /* ehviewer apple */,
\t\t\t\tDC4A07782F3DA21800717C38 /* ehviewer appleTests */,
\t\t\t\tDC4A07822F3DA21800717C38 /* ehviewer appleUITests */,
\t\t\t\t{ID_TARGET} /* EhDownloadWidget */,
\t\t\t);"""
)

# Add TargetAttributes for widget extension
content = content.replace(
    f"""\t\t\t\t\t{ID_APP_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.2;
\t\t\t\t\t}};""",
    f"""\t\t\t\t\t{ID_APP_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.2;
\t\t\t\t\t}};
\t\t\t\t\t{ID_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.2;
\t\t\t\t\t}};"""
)

# Add embed phase + dependency to app target build phases
old_app_phases = f"""\t\t{ID_APP_TARGET} /* ehviewer apple */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = DC4A078C2F3DA21800717C38 /* Build configuration list for PBXNativeTarget "ehviewer apple" */;
\t\t\tbuildPhases = (
\t\t\t\tDC4A07642F3DA21800717C38 /* Sources */,
\t\t\t\tDC4A07652F3DA21800717C38 /* Frameworks */,
\t\t\t\tDC4A07662F3DA21800717C38 /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);"""
new_app_phases = f"""\t\t{ID_APP_TARGET} /* ehviewer apple */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = DC4A078C2F3DA21800717C38 /* Build configuration list for PBXNativeTarget "ehviewer apple" */;
\t\t\tbuildPhases = (
\t\t\t\tDC4A07642F3DA21800717C38 /* Sources */,
\t\t\t\tDC4A07652F3DA21800717C38 /* Frameworks */,
\t\t\t\tDC4A07662F3DA21800717C38 /* Resources */,
\t\t\t\t{ID_EMBED_PHASE} /* Embed Foundation Extensions */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{ID_DEPENDENCY} /* PBXTargetDependency */,
\t\t\t);"""
content = content.replace(old_app_phases, new_app_phases)

# ============================================================
# 10. Add PBXResourcesBuildPhase for extension
# ============================================================
res_phase = f"""\t\t{ID_RESOURCES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
content = content.replace(
    "/* End PBXResourcesBuildPhase section */",
    res_phase + "/* End PBXResourcesBuildPhase section */"
)

# ============================================================
# 11. Add PBXSourcesBuildPhase for extension
# ============================================================
src_phase = f"""\t\t{ID_SOURCES} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
content = content.replace(
    "/* End PBXSourcesBuildPhase section */",
    src_phase + "/* End PBXSourcesBuildPhase section */"
)

# ============================================================
# 12. Add PBXTargetDependency
# ============================================================
dep_entry = f"""\t\t{ID_DEPENDENCY} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {ID_TARGET} /* EhDownloadWidget */;
\t\t\ttargetProxy = {ID_PROXY} /* PBXContainerItemProxy */;
\t\t}};
"""
content = content.replace(
    "/* End PBXTargetDependency section */",
    dep_entry + "/* End PBXTargetDependency section */"
)

# ============================================================
# 13. Add XCBuildConfiguration Debug + Release for extension
# ============================================================
cfg_debug = f"""\t\t{ID_CFG_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSTCALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = HWZEUNLCY6;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_FILE = EhDownloadWidget/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = EhDownloadWidget;
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.2.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "Stellatrix.ehviewer-apple.EhDownloadWidget";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSTRING_CATALOG_GENERATE_SYMBOLS = YES;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
"""

cfg_release = f"""\t\t{ID_CFG_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSTCALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = HWZEUNLCY6;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_FILE = EhDownloadWidget/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = EhDownloadWidget;
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.2.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "Stellatrix.ehviewer-apple.EhDownloadWidget";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSTRING_CATALOG_GENERATE_SYMBOLS = YES;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""
# Insert before the first XCConfigurationList
content = content.replace(
    "/* End XCBuildConfiguration section */",
    cfg_debug + cfg_release + "/* End XCBuildConfiguration section */"
)

# ============================================================
# 14. Add XCConfigurationList for extension
# ============================================================
cfg_list = f"""\t\t{ID_CFG_LIST} /* Build configuration list for PBXNativeTarget "EhDownloadWidget" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ID_CFG_DEBUG} /* Debug */,
\t\t\t\t{ID_CFG_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""
content = content.replace(
    "/* End XCConfigurationList section */",
    cfg_list + "/* End XCConfigurationList section */"
)

with open(PBXPROJ_PATH, 'w') as f:
    f.write(content)

print("✅ Successfully added EhDownloadWidget extension target to project.pbxproj")
