#!/usr/bin/env python3
"""Generate native iOS and macOS projects with automatic Apple provisioning."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent

version, build = (root / "VERSION").read_text().split()

def ident(s):
    return hashlib.sha256(s.encode()).hexdigest()[:24].upper()

def generate(platform):
    mobile = platform == 'iOS'
    app = root / 'Apps' / platform
    out = app / 'Soundbound.xcodeproj'
    out.mkdir(parents=True, exist_ok=True)
    files = [('SoundboundApp.swift', 'SoundboundApp.swift')] if mobile else [
        (p.name, '../../' + str(p.relative_to(root))) for p in sorted((root/'Sources/Soundbound').glob('*.swift'))]
    if mobile:
        files += [(p.name, '../../' + str(p.relative_to(root))) for p in sorted((root/'Sources/SoundboundKit').glob('*.swift'))]
    resources = [('SoundboundMark.png', '../../Sources/SoundboundKit/Resources/SoundboundMark.png'), ('Assets.xcassets', 'Assets.xcassets')]
    objects=[]
    package_ref = ''
    package_products = ''
    framework_files = ''
    if not mobile:
        objects += [f'{ident("localpackage")} = {{isa = XCLocalSwiftPackageReference; relativePath = "../.."; }};',
                    f'{ident("kitproduct")} = {{isa = XCSwiftPackageProductDependency; package = {ident("localpackage")}; productName = SoundboundKit; }};',
                    f'{ident("kitbuild")} = {{isa = PBXBuildFile; productRef = {ident("kitproduct")}; }};']
        package_ref = f'packageReferences = ({ident("localpackage")});'
        package_products = f'packageProductDependencies = ({ident("kitproduct")});'
        framework_files = ident("kitbuild")
    for name,path in files:
        objects += [f'{ident("file"+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT; }};',
                    f'{ident("build"+name)} = {{isa = PBXBuildFile; fileRef = {ident("file"+name)}; }};']
    for name,path in resources:
        resource_type = 'folder.assetcatalog' if name.endswith('.xcassets') else 'image.png'
        objects += [f'{ident("file"+name)} = {{isa = PBXFileReference; lastKnownFileType = {resource_type}; path = "{path}"; sourceTree = SOURCE_ROOT; }};',
                    f'{ident("build"+name)} = {{isa = PBXBuildFile; fileRef = {ident("file"+name)}; }};']
    objects += [f'{ident("product")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = Soundbound.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
        f'{ident("group")} = {{isa = PBXGroup; children = ({",".join(ident("file"+n) for n,_ in files + resources)},{ident("product")}); sourceTree = "<group>"; }};',
        f'{ident("sources")} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ident("build"+n) for n,_ in files)}); runOnlyForDeploymentPostprocessing = 0; }};',
        f'{ident("resources")} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ident("build"+n) for n,_ in resources)}); runOnlyForDeploymentPostprocessing = 0; }};',
        f'{ident("frameworks")} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework_files}); runOnlyForDeploymentPostprocessing = 0; }};']
    for name in ['Debug','Release']:
        opt='-Onone' if name=='Debug' else '-O'
        condition = 'DEBUG' if name == 'Debug' else ''
        platform_settings = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; TARGETED_DEVICE_FAMILY = "1,2";' if mobile else 'SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 13.0; ENABLE_HARDENED_RUNTIME = YES;'
        bundle = 'app.soundbound.ios' if mobile else 'app.soundbound.mac'
        settings=f'MARKETING_VERSION = {version}; CURRENT_PROJECT_VERSION = {build}; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{condition}"; PRODUCT_NAME = Soundbound; PRODUCT_BUNDLE_IDENTIFIER = {bundle}; {platform_settings} SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "{opt}"; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "Apple Development"; CODE_SIGN_ENTITLEMENTS = Soundbound.entitlements; INFOPLIST_FILE = Info.plist; GENERATE_INFOPLIST_FILE = NO; ENABLE_USER_SCRIPT_SANDBOXING = YES;'
        objects.append(f'{ident("config"+name)} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};')
    objects += [f'{ident("configs")} = {{isa = XCConfigurationList; buildConfigurations = ({ident("configDebug")},{ident("configRelease")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};',
        f'{ident("target")} = {{isa = PBXNativeTarget; buildConfigurationList = {ident("configs")}; buildPhases = ({ident("sources")},{ident("frameworks")},{ident("resources")}); buildRules = (); dependencies = (); name = Soundbound; productName = Soundbound; productReference = {ident("product")}; productType = "com.apple.product-type.application"; {package_products} }};',
        f'{ident("project")} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{{ident("target")} = {{SystemCapabilities = {{com.apple.SignInWithApple = {{enabled = 1;}};}};}};}};}}; buildConfigurationList = {ident("configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {ident("group")}; projectDirPath = ""; projectRoot = ""; {package_ref} targets = ({ident("target")}); }};']
    (out/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ident("project")}; }}\n')
    schemes = out / 'xcshareddata' / 'xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / 'SoundboundApp.xcscheme').write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="Soundbound.app" BlueprintName="Soundbound" ReferencedContainer="container:Soundbound.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target')}" BuildableName="Soundbound.app" BlueprintName="Soundbound" ReferencedContainer="container:Soundbound.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
    print(out)

for platform in ['iOS', 'macOS']:
    generate(platform)
