#!/usr/bin/env python3
"""Generate Pulso.xcodeproj reproducibly with Python's standard library.

Run from any directory after adding/removing Swift files. No package installation required.
Signing team is intentionally configured by the developer in Xcode.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Pulso.xcodeproj'
objects = {}
existing_teams = {}
existing_project = PROJECT / 'project.pbxproj'
if existing_project.exists():
    converted = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(existing_project)], capture_output=True, text=True)
    if converted.returncode == 0:
        for obj in json.loads(converted.stdout).get('objects', {}).values():
            if obj.get('isa') == 'XCBuildConfiguration':
                settings = obj.get('buildSettings', {})
                if settings.get('DEVELOPMENT_TEAM') and settings.get('PRODUCT_BUNDLE_IDENTIFIER'):
                    existing_teams[settings['PRODUCT_BUNDLE_IDENTIFIER']] = settings['DEVELOPMENT_TEAM']


def ident(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def add(label, isa, **fields):
    key = ident(label)
    objects[key] = dict(isa=isa, **fields)
    return key

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

def render(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(depth+1)+quote(k)+' = '+render(v, depth+1)+';\n' for k,v in value.items()) + '\t'*depth+'}'
    if isinstance(value, list):
        return '(' + ', '.join(render(v, depth) for v in value) + ')'
    return quote(value)

def plist(path, value):
    (ROOT / path).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / path).write_bytes(plistlib.dumps(value, sort_keys=False))

common_info = {'CFBundleDevelopmentRegion':'es', 'CFBundleExecutable':'$(EXECUTABLE_NAME)',
               'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion':'6.0',
               'CFBundleName':'$(PRODUCT_NAME)', 'CFBundleShortVersionString':'1.0', 'CFBundleVersion':'1'}
plist('App/Info.plist', dict(common_info, CFBundleDisplayName='Pulso', CFBundlePackageType='APPL',
    LSRequiresIPhoneOS=True, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},
    UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
    CFBundleURLTypes=[{'CFBundleURLName':'com.jesusom.pulso','CFBundleURLSchemes':['pulso']}],
    UIBackgroundModes=['fetch'], BGTaskSchedulerPermittedIdentifiers=['com.jesusom.pulso.refresh']))
plist('Widgets/Info.plist', dict(common_info, CFBundleDisplayName='Pulso', CFBundlePackageType='XPC!',
    NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}))
for target in ['App/Pulso.entitlements','Widgets/PulsoWidgets.entitlements']:
    plist(target, {'com.apple.security.application-groups':['group.com.jesusom.pulso']})

files = {}
groups = []
for folder in ['App','Core','Widgets','Tests','UITests']:
    children = []
    paths = sorted((ROOT / folder).glob('*.swift'))
    paths += sorted((ROOT / folder).glob('*.plist'))
    paths += sorted((ROOT / folder).glob('*.entitlements'))
    if folder == 'App' and (ROOT / folder / 'Assets.xcassets').exists():
        paths.append(ROOT / folder / 'Assets.xcassets')
    for path in paths:
        rel = str(path.relative_to(ROOT))
        filetype = {'.swift':'sourcecode.swift','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements','.xcassets':'folder.assetcatalog'}[path.suffix]
        files[rel] = add('file:'+rel,'PBXFileReference',lastKnownFileType=filetype,path=path.name,sourceTree='<group>')
        children.append(files[rel])
    groups.append(add('group:'+folder,'PBXGroup',children=children,path=folder,sourceTree='<group>'))

products = {}
for name, ext, filetype in [('Pulso','app','wrapper.application'),('PulsoWidgets','appex','wrapper.app-extension'),('PulsoTests','xctest','wrapper.cfbundle'),('PulsoUITests','xctest','wrapper.cfbundle')]:
    products[name] = add('product:'+name,'PBXFileReference',explicitFileType=filetype,includeInIndex='0',path=f'{name}.{ext}',sourceTree='BUILT_PRODUCTS_DIR')
products_group = add('products','PBXGroup',children=list(products.values()),name='Products',sourceTree='<group>')
main_group = add('main','PBXGroup',children=groups+[products_group],sourceTree='<group>')

base = dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='17.0', SWIFT_VERSION='5.0',
    CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', CODE_SIGN_STYLE='Automatic',
    TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO',
    ENABLE_USER_SCRIPT_SANDBOXING='YES')

def configs(label, extra):
    ids = []
    for mode in ['Debug','Release']:
        values = dict(extra)
        if mode == 'Debug':
            values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', DEBUG_INFORMATION_FORMAT='dwarf', ENABLE_TESTABILITY='YES')
        else:
            values.update(SWIFT_OPTIMIZATION_LEVEL='-O', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym', SWIFT_COMPILATION_MODE='wholemodule')
        ids.append(add(f'config:{label}:{mode}','XCBuildConfiguration',buildSettings=values,name=mode))
    return add('configs:'+label,'XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

project_configs = configs('project',base)
all_core = [p for p in files if p.startswith('Core/') and p.endswith('.swift')]
shared_core = [p for p in all_core if Path(p).stem not in ['GitHubUsageClient','TokenVault','CodexUsageParser','ClaudeUsageParser','CopilotQuotaClient']]
target_ids = {name:ident('target:'+name) for name in products}

def dependency(source, dest):
    proxy = add(f'proxy:{source}:{dest}','PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=target_ids[dest],remoteInfo=dest)
    return add(f'dependency:{source}:{dest}','PBXTargetDependency',target=target_ids[dest],targetProxy=proxy)

for name in products:
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.jesusom.pulso'+{'Pulso':'','PulsoWidgets':'.widgets','PulsoTests':'.tests','PulsoUITests':'.uitests'}[name], SWIFT_EMIT_LOC_STRINGS='YES')
    if settings['PRODUCT_BUNDLE_IDENTIFIER'] in existing_teams:
        settings['DEVELOPMENT_TEAM'] = existing_teams[settings['PRODUCT_BUNDLE_IDENTIFIER']]
    dependencies = []
    if name == 'Pulso':
        sources = [p for p in files if p.startswith('App/') and p.endswith('.swift')] + all_core
        settings.update(INFOPLIST_FILE='App/Info.plist', CODE_SIGN_ENTITLEMENTS='App/Pulso.entitlements', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
        dependencies = [dependency(name,'PulsoWidgets')]
    elif name == 'PulsoWidgets':
        sources = [p for p in files if p.startswith('Widgets/') and p.endswith('.swift')] + shared_core
        settings.update(INFOPLIST_FILE='Widgets/Info.plist', CODE_SIGN_ENTITLEMENTS='Widgets/PulsoWidgets.entitlements', APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES')
    else:
        folder = 'Tests/' if name == 'PulsoTests' else 'UITests/'
        sources = [p for p in files if p.startswith(folder) and p.endswith('.swift')]
        settings.update(GENERATE_INFOPLIST_FILE='YES')
        dependencies = [dependency(name,'Pulso')]
        if name == 'PulsoTests':
            settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/Pulso.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Pulso', BUNDLE_LOADER='$(TEST_HOST)')
        else:
            settings.update(TEST_TARGET_NAME='Pulso')
    builds = [add(f'build:{name}:{p}','PBXBuildFile',fileRef=files[p]) for p in sources]
    source_phase = add('sources:'+name,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=builds,runOnlyForDeploymentPostprocessing='0')
    framework_phase = add('frameworks:'+name,'PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[],runOnlyForDeploymentPostprocessing='0')
    resources = []
    if name == 'Pulso' and 'App/Assets.xcassets' in files:
        resources.append(add('assets-build','PBXBuildFile',fileRef=files['App/Assets.xcassets']))
    resource_phase = add('resources:'+name,'PBXResourcesBuildPhase',buildActionMask='2147483647',files=resources,runOnlyForDeploymentPostprocessing='0')
    phases = [source_phase, framework_phase, resource_phase]
    if name == 'Pulso':
        embedded = add('embed-widget-build','PBXBuildFile',fileRef=products['PulsoWidgets'],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(add('embed-widget','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[embedded],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0'))
    product_type = {'Pulso':'application','PulsoWidgets':'app-extension','PulsoTests':'bundle.unit-test','PulsoUITests':'bundle.ui-testing'}[name]
    add('target:'+name,'PBXNativeTarget',buildConfigurationList=configs(name,settings),buildPhases=phases,buildRules=[],dependencies=dependencies,name=name,productName=name,productReference=products[name],productType='com.apple.product-type.'+product_type)

add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{target_ids[n]:dict(CreatedOnToolsVersion='16.0', **({'SystemCapabilities':{'com.apple.ApplicationGroups.iOS':{'enabled':'1'}}} if n in ['Pulso','PulsoWidgets'] else {})) for n in products}}, buildConfigurationList=project_configs,compatibilityVersion='Xcode 14.0',developmentRegion='es',hasScannedForEncodings='0',knownRegions=['es','en','Base'],mainGroup=main_group,productRefGroup=products_group,projectDirPath='',projectRoot='',targets=list(target_ids.values()))
PROJECT.mkdir(exist_ok=True)
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':ident('project')})+'\n')

scheme_dir = PROJECT/'xcshareddata'/'xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
def ref(name):
    ext = 'app' if name == 'Pulso' else 'appex' if name == 'PulsoWidgets' else 'xctest'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Pulso.xcodeproj"/>'

(scheme_dir/'Pulso.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
{''.join('<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+ref(n)+'</BuildActionEntry>' for n in ['Pulso','PulsoWidgets'])}
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
{''.join('<TestableReference skipped="NO">'+ref(n)+'</TestableReference>' for n in ['PulsoTests','PulsoUITests'])}
</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('Pulso')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('Pulso')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated {PROJECT} with {len(files)} source/resource references.')
