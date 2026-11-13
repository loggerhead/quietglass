#!/usr/bin/env python3
"""Create an Xcode UI-test project from the current SwiftPM debug objects.

No application runs here. All generated files live outside tracked sources.
Xcode/XCTest supplies the accessibility automation runner at execution time.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def prepare(output: Path, scratch: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.pop("QUIETGLASS_DESKTOP_TESTS", None)
    subprocess.run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch)],
                   cwd=ROOT, env=env, check=True)
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"],
        cwd=ROOT, env=env, text=True).strip())
    object_list = binary_dir / "QuietGlass.product/Objects.LinkFileList"
    objects = [p for p in object_list.read_text().splitlines() if not p.endswith("QuietGlassApp.swift.o")]
    assert objects and len(objects) < len(object_list.read_text().splitlines()), "Cannot exclude production app entry point"
    links = output / "UITestObjects.LinkFileList"
    links.write_text("\n".join(objects) + "\n")
    project = output / "QuietGlassUITests.xcodeproj"
    project.mkdir(exist_ok=True)
    all_objects = {}

    def ident(name):
        return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

    def add(key, isa, **fields):
        uid = ident(key)
        all_objects[uid] = dict(isa=isa, **fields)
        return uid

    def configurations(name, settings):
        debug = add(name + " Debug", "XCBuildConfiguration", name="Debug", buildSettings=settings)
        return add(name + " Configurations", "XCConfigurationList", buildConfigurations=[debug],
                   defaultConfigurationName="Debug", defaultConfigurationIsVisible=0)

    def file(name, path, kind):
        return add(name, "PBXFileReference", path=str(path), sourceTree="<absolute>", lastKnownFileType=kind)

    def build_file(name, reference):
        return add(name, "PBXBuildFile", fileRef=reference)

    def phase(name, kind, files):
        return add(name, kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

    host_file = file("Host source", ROOT / "Tests/QuietGlassUITests/TestHost.swift", "sourcecode.swift")
    test_file = file("UI source", ROOT / "Tests/QuietGlassUITests/InteractionTests.swift", "sourcecode.swift")
    host_product = add("Host product", "PBXFileReference", path="QuietGlassUITestHost.app",
                       sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.application")
    test_product = add("UI product", "PBXFileReference", path="QuietGlassUITests.xctest",
                       sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.cfbundle")
    resources = []
    for path in [ROOT / "Resources/zh-Hans.lproj", ROOT / "Resources/Preview/BlurPreview.png",
                 ROOT / "Resources/Preview/BlurPreview.mp4"]:
        ref = file(str(path), path, "folder" if path.is_dir() else "file")
        resources.append(build_file(str(path) + " Build", ref))
    common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "5.0",
              "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": "",
              "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
              "ENABLE_TESTABILITY": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
              "ARCHS": os.uname().machine, "ONLY_ACTIVE_ARCH": "YES",
              "ENABLE_DEBUG_DYLIB": "NO", "ALWAYS_SEARCH_USER_PATHS": "NO"}
    host_settings = dict(common, PRODUCT_NAME="$(TARGET_NAME)",
                         PRODUCT_BUNDLE_IDENTIFIER="local.quietglass.tests.host",
                         SWIFT_INCLUDE_PATHS=[str(binary_dir / "Modules")],
                         OTHER_LDFLAGS=["$(inherited)", "-Xlinker", "-filelist", "-Xlinker", str(links)],
                         INFOPLIST_KEY_NSPrincipalClass="NSApplication",
                         INFOPLIST_KEY_LSApplicationCategoryType="public.app-category.developer-tools")
    host_target = add("Host target", "PBXNativeTarget", name="QuietGlassUITestHost", productName="QuietGlassUITestHost",
                      productType="com.apple.product-type.application", productReference=host_product,
                      buildConfigurationList=configurations("Host", host_settings),
                      buildPhases=[phase("Host sources", "PBXSourcesBuildPhase", [build_file("Build host", host_file)]),
                                   phase("Host resources", "PBXResourcesBuildPhase", resources)], buildRules=[], dependencies=[])
    project_id = ident("Project")
    proxy = add("Host proxy", "PBXContainerItemProxy", containerPortal=project_id,
                proxyType=1, remoteGlobalIDString=host_target, remoteInfo="QuietGlassUITestHost")
    dependency = add("Host dependency", "PBXTargetDependency", target=host_target, targetProxy=proxy)
    test_settings = dict(common, PRODUCT_NAME="$(TARGET_NAME)",
                         PRODUCT_BUNDLE_IDENTIFIER="local.quietglass.tests.ui",
                         TEST_TARGET_NAME="QuietGlassUITestHost")
    test_target = add("UI target", "PBXNativeTarget", name="QuietGlassUITests", productName="QuietGlassUITests",
                      productType="com.apple.product-type.bundle.ui-testing", productReference=test_product,
                      buildConfigurationList=configurations("UI", test_settings),
                      buildPhases=[phase("UI sources", "PBXSourcesBuildPhase", [build_file("Build UI", test_file)])],
                      buildRules=[], dependencies=[dependency])
    products = add("Products", "PBXGroup", name="Products", sourceTree="<group>", children=[host_product, test_product])
    group = add("Main group", "PBXGroup", sourceTree="<group>", children=[host_file, test_file, products])
    add("Project", "PBXProject", buildConfigurationList=configurations("Project", common), compatibilityVersion="Xcode 14.0",
        attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {test_target: {"TestTargetID": host_target}}},
        developmentRegion="en", knownRegions=["en", "zh-Hans"], mainGroup=group, productRefGroup=products,
        projectDirPath="", projectRoot="", targets=[host_target, test_target])
    (project / "project.pbxproj").write_bytes(plistlib.dumps(
        {"archiveVersion": "1", "objectVersion": "56", "classes": {}, "objects": all_objects, "rootObject": project_id}))
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="QuietGlassUITests.xctest" BlueprintName="QuietGlassUITests" ReferencedContainer="container:QuietGlassUITests.xcodeproj"/>'
    desktop_mode = os.environ.get("QUIETGLASS_TEST_DESKTOP", "")
    assert desktop_mode in ("", "interactive", "isolated")
    (schemes / "QuietGlassUITests.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO">
    <EnvironmentVariables><EnvironmentVariable key="QUIETGLASS_TEST_DESKTOP" value="{desktop_mode}" isEnabled="YES"/></EnvironmentVariables>
    <Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables>
  </TestAction>
</Scheme>
''')
    (output / "project.json").write_text(json.dumps({"project": str(project), "binary_dir": str(binary_dir)}))
    return project


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    args = parser.parse_args()
    print(prepare(args.output.resolve(), args.scratch_path.resolve()))
