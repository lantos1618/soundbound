#!/usr/bin/env python3
"""Generate the small native iOS project without an external project generator."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
out = root / 'Apps/iOS/Soundbound.xcodeproj'
out.mkdir(exist_ok=True)
def ident(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
files = [('SoundboundApp.swift', 'SoundboundApp.swift')]
files += [(p.name, '../../' + str(p.relative_to(root))) for p in sorted((root/'Sources/SoundboundKit').glob('*.swift'))]
resources = [('SoundboundMark.png', '../../Sources/SoundboundKit/Resources/SoundboundMark.png')]
objects=[]
for name,path in files:
    objects += [f'{ident("file"+name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT; }};',
                f'{ident("build"+name)} = {{isa = PBXBuildFile; fileRef = {ident("file"+name)}; }};']
for name,path in resources:
    objects += [f'{ident("file"+name)} = {{isa = PBXFileReference; lastKnownFileType = image.png; path = "{path}"; sourceTree = SOURCE_ROOT; }};',
                f'{ident("build"+name)} = {{isa = PBXBuildFile; fileRef = {ident("file"+name)}; }};']
objects += [f'{ident("product")} = {{isa = PBXFileReference; explicitFileType = wrapper.application; path = Soundbound.app; sourceTree = BUILT_PRODUCTS_DIR; }};',
 f'{ident("group")} = {{isa = PBXGroup; children = ({",".join(ident("file"+n) for n,_ in files + resources)},{ident("product")}); sourceTree = "<group>"; }};',
 f'{ident("sources")} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ident("build"+n) for n,_ in files)}); runOnlyForDeploymentPostprocessing = 0; }};',
 f'{ident("resources")} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ident("build"+n) for n,_ in resources)}); runOnlyForDeploymentPostprocessing = 0; }};',
 f'{ident("frameworks")} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};']
for name in ['Debug','Release']:
    opt='-Onone' if name=='Debug' else '-O'
    condition = 'DEBUG' if name == 'Debug' else ''
    settings=f'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{condition}"; PRODUCT_NAME = Soundbound; PRODUCT_BUNDLE_IDENTIFIER = app.soundbound.ios; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "{opt}"; CODE_SIGN_STYLE = Automatic; INFOPLIST_FILE = Info.plist; GENERATE_INFOPLIST_FILE = NO; ENABLE_USER_SCRIPT_SANDBOXING = YES;'
    objects.append(f'{ident("config"+name)} = {{isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name}; }};')
objects += [f'{ident("configs")} = {{isa = XCConfigurationList; buildConfigurations = ({ident("configDebug")},{ident("configRelease")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};',
 f'{ident("target")} = {{isa = PBXNativeTarget; buildConfigurationList = {ident("configs")}; buildPhases = ({ident("sources")},{ident("frameworks")},{ident("resources")}); buildRules = (); dependencies = (); name = Soundbound; productName = Soundbound; productReference = {ident("product")}; productType = "com.apple.product-type.application"; }};',
 f'{ident("project")} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1600;}}; buildConfigurationList = {ident("configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {ident("group")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("target")}); }};']
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ident("project")}; }}\n')
print(out)
