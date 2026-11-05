#!/usr/bin/env python3
"""Regenerate the checked-in, dependency-free Xcode project deterministically."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
NAME = "GZUCMPocket"
UI_TEST_NAME = NAME + "UITests"


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


class Ref(str):
    pass


objects = {}


def obj(key, isa, **fields):
    ref = Ref(uid(key))
    objects[ref] = {"isa": isa, **fields}
    return ref


def serialize(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, Ref):
        return value
    if isinstance(value, dict):
        child_indent = "\t" * (depth + 1)
        rows = [f"{child_indent}{key} = {serialize(item, depth + 1)};" for key, item in value.items()]
        return "{\n" + "\n".join(rows) + "\n" + indent + "}"
    if isinstance(value, list):
        child_indent = "\t" * (depth + 1)
        return "(\n" + "".join(f"{child_indent}{serialize(item, depth + 1)},\n" for item in value) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def main():
    objects.clear()
    swift = sorted(p.relative_to(ROOT / "App").as_posix() for p in (ROOT / "App").rglob("*.swift") if "Tests" not in p.parts)
    source_refs = []
    builds = []
    for path in swift:
        file = obj(path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="<group>")
        source_refs.append(file)
        builds.append(obj("build:" + path, "PBXBuildFile", fileRef=file))
    resource_builds = []
    for path, kind in [("Resources/Assets.xcassets", "folder.assetcatalog"), ("Resources/EcardBridge.js", "sourcecode.javascript"), ("Resources/PrivacyInfo.xcprivacy", "text.xml"), ("Resources/ThirdPartyNotices.txt", "text")]:
        file = obj(path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")
        source_refs.append(file)
        resource_builds.append(obj("build:" + path, "PBXBuildFile", fileRef=file))
    source_refs.append(obj("info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
    app_group = obj("app-group", "PBXGroup", children=source_refs, path="App", sourceTree="<group>")
    ui_swift = sorted(p.relative_to(ROOT / "Tests").as_posix() for p in (ROOT / "Tests").rglob("*.swift"))
    ui_refs = []
    ui_builds = []
    for path in ui_swift:
        file = obj("uitest:" + path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="<group>")
        ui_refs.append(file)
        ui_builds.append(obj("uitest-build:" + path, "PBXBuildFile", fileRef=file))
    tests_group = obj("tests-group", "PBXGroup", children=ui_refs, path="Tests", sourceTree="<group>")
    product = obj("product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path=NAME + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    ui_product = obj("uitest-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path=UI_TEST_NAME + ".xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = obj("products", "PBXGroup", children=[product, ui_product], name="Products", sourceTree="<group>")
    main_group = obj("main-group", "PBXGroup", children=[app_group, tests_group, products], sourceTree="<group>")
    package = obj("package", "XCLocalSwiftPackageReference", relativePath="Packages/PocketCore")
    dependency = obj("pocket-core", "XCSwiftPackageProductDependency", package=package, productName="PocketCore")
    framework = obj("core-build", "PBXBuildFile", productRef=dependency)
    sources = obj("sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    frameworks = obj("frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[framework], runOnlyForDeploymentPostprocessing=0)
    resources = obj("resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    ui_sources = obj("uitest-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=ui_builds, runOnlyForDeploymentPostprocessing=0)
    ui_frameworks = obj("uitest-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    ui_resources = obj("uitest-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    configs = {}
    for owner in ("project", "target", "uitests"):
        config_ids = []
        for config in ("Debug", "Release"):
            settings = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17"}
            if owner == "project":
                settings.update({"DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O", "ENABLE_TESTABILITY": "YES" if config == "Debug" else "NO", "ONLY_ACTIVE_ARCH": "YES" if config == "Debug" else "NO"})
                if config == "Debug":
                    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
            elif owner == "target":
                settings.update({"PRODUCT_NAME": NAME, "PRODUCT_BUNDLE_IDENTIFIER": "com.example.gzucm.pocket", "INFOPLIST_FILE": "App/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "YES", "MACCATALYST_DEPLOYMENT_TARGET": "18.0", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0", "SWIFT_EMIT_LOC_STRINGS": "YES", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]})
            else:
                settings.update({"PRODUCT_NAME": UI_TEST_NAME, "PRODUCT_BUNDLE_IDENTIFIER": "com.example.gzucm.pocket.uitests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": NAME, "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "YES", "MACCATALYST_DEPLOYMENT_TARGET": "18.0", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO", "SKIP_INSTALL": "YES", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]})
            config_ids.append(obj(owner + config, "XCBuildConfiguration", buildSettings=settings, name=config))
        configs[owner] = obj(owner + "configs", "XCConfigurationList", buildConfigurations=config_ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = obj("target", "PBXNativeTarget", buildConfigurationList=configs["target"], buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[], name=NAME, packageProductDependencies=[dependency], productName=NAME, productReference=product, productType="com.apple.product-type.application")
    app_proxy = obj("app-proxy", "PBXContainerItemProxy", containerPortal=Ref(uid("project")), proxyType=1, remoteGlobalIDString=target, remoteInfo=NAME)
    app_dependency = obj("app-target-dependency", "PBXTargetDependency", target=target, targetProxy=app_proxy)
    ui_target = obj("uitest-target", "PBXNativeTarget", buildConfigurationList=configs["uitests"], buildPhases=[ui_sources, ui_frameworks, ui_resources], buildRules=[], dependencies=[app_dependency], name=UI_TEST_NAME, productName=UI_TEST_NAME, productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
    project = obj("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "26.0", "ProvisioningStyle": "Automatic"}, ui_target: {"CreatedOnToolsVersion": "26.0", "ProvisioningStyle": "Automatic", "TestTargetID": target}}}, buildConfigurationList=configs["project"], compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, packageReferences=[package], productRefGroup=products, projectDirPath="", projectRoot="", targets=[target, ui_target])
    project_dir = ROOT / (NAME + ".xcodeproj")
    project_dir.mkdir(exist_ok=True)
    body = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
    (project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(body) + "\n", encoding="utf-8")
    workspace = project_dir / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n', encoding="utf-8")
    schemes = project_dir / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{NAME}.app" BlueprintName="{NAME}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
    test_buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="{UI_TEST_NAME}.xctest" BlueprintName="{UI_TEST_NAME}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
    (schemes / (NAME + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_buildable}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{test_buildable}</TestableReference></Testables><MacroExpansion>{buildable}</MacroExpansion></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
    print(f"Generated {NAME}.xcodeproj: {len(swift)} app sources, {len(ui_swift)} UI test sources, local PocketCore package, 4 resources")


if __name__ == "__main__":
    main()
