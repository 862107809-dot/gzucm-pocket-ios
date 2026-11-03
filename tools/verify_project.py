#!/usr/bin/env python3
"""Portable source/resource checks. This does NOT compile or type-check Swift."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def pbx_objects(text):
    """Read the deterministic generator's top-level blocks without an extra dependency."""
    return dict(re.findall(r"^\t\t([0-9A-F]{24}) = \{\n(.*?)^\t\t\};", text, re.M | re.S))


def pbx_value(block, field):
    match = re.search(rf"^\t{{3}}{re.escape(field)} = ([^;\n]+);$", block, re.M)
    if not match:
        return None
    value = match.group(1)
    return json.loads(value) if value.startswith('"') else value


def pbx_refs(block, field):
    match = re.search(rf"^\t{{3}}{re.escape(field)} = \(\n(.*?)^\t{{3}}\);", block, re.M | re.S)
    return re.findall(r"\b[0-9A-F]{24}\b", match.group(1)) if match else []


def target_source_paths(objects, target):
    parents = {}
    for reference, block in objects.items():
        if pbx_value(block, "isa") == "PBXGroup":
            for child in pbx_refs(block, "children"):
                require(child not in parents, "Source/group has multiple PBX parents")
                parents[child] = reference

    def file_path(reference):
        parts = []
        visited = set()
        while reference:
            require(reference not in visited, "Cyclic PBX group hierarchy")
            visited.add(reference)
            block = objects[reference]
            path = pbx_value(block, "path")
            if path:
                parts.insert(0, path)
            reference = parents.get(reference)
        return Path(*parts).as_posix()

    paths = []
    for phase in pbx_refs(objects[target], "buildPhases"):
        if pbx_value(objects[phase], "isa") == "PBXSourcesBuildPhase":
            for build in pbx_refs(objects[phase], "files"):
                source = pbx_value(objects[build], "fileRef")
                require(source in objects, "Source build file has no file reference")
                paths.append(file_path(source))
    require(len(paths) == len(set(paths)), "Duplicate source in target")
    return set(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-syntax", action="store_true", help="Require optional tree-sitter Swift grammar (syntax only)")
    options = parser.parse_args()
    info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    require(not info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"], "Do not enable global insecure loads")
    require(not info.get("UIRequiresFullScreen", False), "Full-screen-only defeats adaptive layouts")
    privacy = plistlib.loads((ROOT / "App/Resources/PrivacyInfo.xcprivacy").read_bytes())
    require(privacy["NSPrivacyTracking"] is False, "Unexpected tracking")
    project = ROOT / "GZUCMPocket.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")
    app_swift = [p for p in (ROOT / "App").rglob("*.swift") if "Tests" not in p.parts]
    ui_swift = list((ROOT / "Tests").rglob("*.swift"))
    require(ui_swift, "UI smoke test sources are missing")
    objects = pbx_objects(text)
    targets = {pbx_value(block, "name"): reference for reference, block in objects.items() if pbx_value(block, "isa") == "PBXNativeTarget"}
    require(set(targets) == {"GZUCMPocket", "GZUCMPocketUITests"}, "Expected App and UI smoke test targets")
    app_target = targets["GZUCMPocket"]
    ui_target = targets["GZUCMPocketUITests"]
    require(pbx_value(objects[app_target], "productType") == "com.apple.product-type.application", "Invalid App target type")
    require(pbx_value(objects[ui_target], "productType") == "com.apple.product-type.bundle.ui-testing", "Invalid UI test target type")
    require(target_source_paths(objects, app_target) == {source.relative_to(ROOT).as_posix() for source in app_swift}, "App source target membership mismatch")
    require(target_source_paths(objects, ui_target) == {source.relative_to(ROOT).as_posix() for source in ui_swift}, "UI test source target membership mismatch")
    dependencies = pbx_refs(objects[ui_target], "dependencies")
    require(len(dependencies) == 1, "UI tests must depend on the App target")
    app_dependency = objects[dependencies[0]]
    require(pbx_value(app_dependency, "isa") == "PBXTargetDependency" and pbx_value(app_dependency, "target") == app_target, "UI test dependency does not point to App")
    proxy = objects[pbx_value(app_dependency, "targetProxy")]
    require(pbx_value(proxy, "isa") == "PBXContainerItemProxy" and pbx_value(proxy, "remoteGlobalIDString") == app_target, "UI test container proxy mismatch")
    test_configurations = objects[pbx_value(objects[ui_target], "buildConfigurationList")]
    for configuration in pbx_refs(test_configurations, "buildConfigurations"):
        block = objects[configuration]
        require('TEST_TARGET_NAME = "GZUCMPocket";' in block and 'GENERATE_INFOPLIST_FILE = "YES";' in block, "UI test host/generated plist settings missing")
        require('IPHONEOS_DEPLOYMENT_TARGET = "18.0";' in block and 'SWIFT_VERSION = "5.0";' in block, "UI test deployment target/language mismatch")
    for name in ["EcardBridge.js", "Assets.xcassets", "PrivacyInfo.xcprivacy", "ThirdPartyNotices.txt"]:
        require(name in text and (ROOT / "App/Resources" / name).exists(), "Missing bundled resource " + name)
    require('"18.0"' in text and '"PocketCore"' in text, "Invalid target version/package")
    require("Web/Tests" not in text, "JavaScript tests must not be app resources")
    definitions = re.findall(r"^\t\t([0-9A-F]{24}) = \{", text, re.M)
    require(len(definitions) == len(set(definitions)), "Duplicate PBX IDs")
    require(set(re.findall(r"\b[0-9A-F]{24}\b", text)) <= set(definitions), "Dangling PBX reference")
    xmls = list((ROOT / "GZUCMPocket.xcodeproj").rglob("*.xcscheme")) + list((ROOT / "GZUCMPocket.xcodeproj").rglob("*.xcworkspacedata"))
    for file in xmls:
        ET.parse(file)
    scheme = ET.parse(ROOT / "GZUCMPocket.xcodeproj/xcshareddata/xcschemes/GZUCMPocket.xcscheme")
    testables = scheme.findall("./TestAction/Testables/TestableReference")
    require(len(testables) == 1 and testables[0].get("skipped") == "NO", "Shared scheme must enable UI smoke tests")
    require(testables[0].find("BuildableReference").get("BlueprintIdentifier") == ui_target, "Scheme TestableReference target mismatch")
    entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
    require(any(entry.get("buildForTesting") == "YES" and entry.find("BuildableReference").get("BlueprintIdentifier") == ui_target for entry in entries), "UI test target missing from scheme build-for-testing")
    project_object = next(block for block in objects.values() if pbx_value(block, "isa") == "PBXProject")
    require(re.search(rf"{ui_target} = \{{[^{{}}]*TestTargetID = {app_target};", project_object), "UI test TestTargetID missing")
    for file in ROOT.rglob("*.json"):
        if not any(part.startswith(".") for part in file.relative_to(ROOT).parts):
            json.loads(file.read_text(encoding="utf-8-sig"))
    for file in (ROOT / "App/Resources/Assets.xcassets").rglob("Contents.json"):
        content = json.loads(file.read_text(encoding="utf-8"))
        for image in content.get("images", []):
            if "filename" in image:
                require((file.parent / image["filename"]).exists(), "Missing asset image")
    print(f"PASS: project resources, {len(app_swift)} app and {len(ui_swift)} UI test source memberships, App dependency, plists, JSON, scheme/workspace XML, {len(definitions)} PBX objects")
    local_tools = ROOT / ".tools/python"
    if local_tools.exists():
        sys.path.insert(0, str(local_tools))
    try:
        from openstep_parser import OpenStepDecoder
        parsed = OpenStepDecoder.ParseFromString(text)
        require(parsed["objects"][parsed["rootObject"]]["isa"] == "PBXProject", "Malformed PBX project")
        print("PASS: independent OpenStep project parser")
    except ImportError:
        print("SKIP: optional OpenStep parser; macOS plutil/xcodebuild validate the project")
    if options.swift_syntax:
        from tree_sitter import Language, Parser
        import tree_sitter_swift
        swift_parser = Parser(Language(tree_sitter_swift.language()))
        sources = app_swift + ui_swift + list((ROOT / "Packages").rglob("*.swift"))
        errors = []
        for file in sources:
            data = file.read_bytes()
            tree = swift_parser.parse(data)
            if tree.root_node.has_error:
                def collect(node):
                    if node.type == "ERROR" or node.is_missing:
                        errors.append(f"{file.relative_to(ROOT)}:{node.start_point.row + 1}: {node.type} {data[node.start_byte:node.end_byte][:100]!r}")
                    for child in node.children:
                        collect(child)
                collect(tree.root_node)
        require(not errors, "Swift syntax errors:\n" + "\n".join(errors))
        print(f"PASS: tree-sitter syntax parse of {len(sources)} Swift files (not an Apple compiler/type check)")
    print("Native build and XCTest still require tools/verify-mac.sh on macOS/Xcode 26+.")


if __name__ == "__main__":
    main()
