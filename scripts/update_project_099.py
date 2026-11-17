#!/usr/bin/env python3
"""0.9.9: register the onboarding, call and Live Activity sources, and add the GrokBotLiveActivity
widget extension embedded in the iPhone app. Idempotent: running it twice changes nothing.
Development dependency: openstep-parser (scripts/check-requirements.txt).
"""
import hashlib
import json
from pathlib import Path
from openstep_parser import OpenStepDecoder

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'GrokBot.xcodeproj/project.pbxproj'
project = OpenStepDecoder.ParseFromFile(PROJECT.open())
objects = project['objects']
root = objects[project['rootObject']]

def uid(name): return hashlib.sha256(('099:' + name).encode()).hexdigest()[:24].upper()
def target(name): return next(key for key in root['targets'] if objects[key]['name'] == name)
def group(name): return next(key for key in objects[root['mainGroup']]['children'] if (objects[key].get('name') or objects[key].get('path')) == name)
def phase_of(target_key, isa): return next(key for key in objects[target_key]['buildPhases'] if objects[key]['isa'] == isa)
def append(owner, field, key):
    if key not in objects[owner][field]: objects[owner][field].append(key)

def reference(path, kind='sourcecode.swift'):
    existing = next((key for key, value in objects.items() if value.get('isa') == 'PBXFileReference' and value.get('path') == path), None)
    if existing: return existing
    key = uid('ref:' + path)
    objects[key] = {'isa': 'PBXFileReference', 'lastKnownFileType': kind, 'path': path, 'sourceTree': '<group>'}
    return key

def compile_in(path, target_name, group_name):
    ref = reference(path)
    sources = phase_of(target(target_name), 'PBXSourcesBuildPhase')
    if not any(objects[b].get('fileRef') == ref for b in objects[sources]['files']):
        build = uid(f'build:{target_name}:{path}')
        objects[build] = {'isa': 'PBXBuildFile', 'fileRef': ref}
        append(sources, 'files', build)
    if not any(ref in value.get('children', []) for value in objects.values() if value.get('isa') == 'PBXGroup'):
        append(group(group_name), 'children', ref)

ios, mac = target('GrokBot'), target('GrokBotMac')

# --- The widget extension target -------------------------------------------------------------
EXT = 'GrokBotLiveActivity'
ext_key = uid('target:' + EXT)
if ext_key not in objects:
    product = uid('product:' + EXT)
    objects[product] = {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.app-extension', 'includeInIndex': '0', 'path': EXT + '.appex', 'sourceTree': 'BUILT_PRODUCTS_DIR'}
    append(root['productRefGroup'], 'children', product)
    ext_group = uid('group:' + EXT)
    objects[ext_group] = {'isa': 'PBXGroup', 'children': [reference(EXT + '/Info.plist', 'text.plist.xml')], 'name': EXT, 'sourceTree': '<group>'}
    append(root['mainGroup'], 'children', ext_group)
    settings = {
        'PRODUCT_BUNDLE_IDENTIFIER': 'org.opengrokbot.ios.live',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'INFOPLIST_FILE': EXT + '/Info.plist',
        'GENERATE_INFOPLIST_FILE': 'NO',
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '37',
        'MARKETING_VERSION': '0.9.9',
        'TARGETED_DEVICE_FAMILY': '1',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'SUPPORTS_MACCATALYST': 'NO',
        'SKIP_INSTALL': 'YES',
        'APPLICATION_EXTENSION_API_ONLY': 'YES',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
        'SWIFT_STRICT_CONCURRENCY': 'complete',
    }
    configs = []
    for mode in ['Debug', 'Release']:
        key = uid(f'config:{EXT}:{mode}')
        objects[key] = {'isa': 'XCBuildConfiguration', 'buildSettings': dict(settings), 'name': mode}
        configs.append(key)
    config_list = uid('configs:' + EXT)
    objects[config_list] = {'isa': 'XCConfigurationList', 'buildConfigurations': configs, 'defaultConfigurationIsVisible': '0', 'defaultConfigurationName': 'Release'}
    phases = []
    for isa in ['PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXResourcesBuildPhase']:
        key = uid(f'phase:{EXT}:{isa}')
        objects[key] = {'isa': isa, 'buildActionMask': '2147483647', 'files': [], 'runOnlyForDeploymentPostprocessing': '0'}
        phases.append(key)
    objects[ext_key] = {'isa': 'PBXNativeTarget', 'buildConfigurationList': config_list, 'buildPhases': phases, 'buildRules': [], 'dependencies': [],
                        'name': EXT, 'productName': EXT, 'productReference': product, 'productType': 'com.apple.product-type.app-extension'}
    append(project['rootObject'], 'targets', ext_key)
    root.setdefault('attributes', {}).setdefault('TargetAttributes', {})[ext_key] = {'CreatedOnToolsVersion': '16.0'}
    # The iPhone app depends on and embeds the extension.
    proxy = uid('proxy:' + EXT)
    objects[proxy] = {'isa': 'PBXContainerItemProxy', 'containerPortal': project['rootObject'], 'proxyType': '1', 'remoteGlobalIDString': ext_key, 'remoteInfo': EXT}
    dependency = uid('dependency:' + EXT)
    objects[dependency] = {'isa': 'PBXTargetDependency', 'target': ext_key, 'targetProxy': proxy}
    append(ios, 'dependencies', dependency)
    embed_file = uid('embed-file:' + EXT)
    objects[embed_file] = {'isa': 'PBXBuildFile', 'fileRef': product, 'settings': {'ATTRIBUTES': ['RemoveHeadersOnCopy']}}
    embed = uid('embed-phase:' + EXT)
    objects[embed] = {'isa': 'PBXCopyFilesBuildPhase', 'buildActionMask': '2147483647', 'dstPath': '', 'dstSubfolderSpec': '13',
                      'files': [embed_file], 'name': 'Embed Foundation Extensions', 'runOnlyForDeploymentPostprocessing': '0'}
    append(ios, 'buildPhases', embed)

# --- Sources -------------------------------------------------------------------------------
shared_drawing = 'GrokBot/Design/BotGlyph.swift'
for name in ['GrokBot', 'GrokBotMac', EXT]: compile_in(shared_drawing, name, 'GrokBot')
for name in ['GrokBot', 'GrokBotMac']: compile_in('GrokBot/Design/CharacterCrowd.swift', name, 'GrokBot')
for name in ['GrokBot', EXT]: compile_in('GrokBot/Voice/CallActivity.swift', name, 'GrokBot')
compile_in('GrokBot/Features/OnboardingFlow.swift', 'GrokBot', 'GrokBot')
compile_in('GrokBot/Voice/CallCoordinator.swift', 'GrokBot', 'GrokBot')
for name in ['GrokBot', 'GrokBotMac']: compile_in('GrokBot/Core/CloudWake.swift', name, 'GrokBot')
ext_source = EXT + '/GrokBotLiveActivity.swift'
ref = reference(ext_source)
sources = phase_of(ext_key, 'PBXSourcesBuildPhase')
if not any(objects[b].get('fileRef') == ref for b in objects[sources]['files']):
    build = uid('build:' + ext_source)
    objects[build] = {'isa': 'PBXBuildFile', 'fileRef': ref}
    append(sources, 'files', build)
append(uid('group:' + EXT), 'children', ref)
for path in ['GrokBotMac/Features/MacCallPill.swift']:
    if (ROOT / path).exists(): compile_in(path, 'GrokBotMac', 'GrokBotMac')

# --- 10.0: legal files shipped inside the Mac app ---------------------------------------------
def bundle_resource(path, target_name, group_name):
    ref = reference(path, 'net.daringfireball.markdown' if path.endswith('.md') else 'text')
    phase = phase_of(target(target_name), 'PBXResourcesBuildPhase')
    if not any(objects[b].get('fileRef') == ref for b in objects[phase]['files']):
        build = uid(f'resource:{target_name}:{path}')
        objects[build] = {'isa': 'PBXBuildFile', 'fileRef': ref}
        append(phase, 'files', build)
    if not any(ref in value.get('children', []) for value in objects.values() if value.get('isa') == 'PBXGroup'):
        append(group(group_name), 'children', ref)
for legal in ['THIRD_PARTY_NOTICES.md', 'LICENSE']: bundle_resource(legal, 'GrokBotMac', 'GrokBotMac')

# --- 10.1: Skills, Routines screen, share a Bot, drag and drop ----------------------------------------------------------------
for name in ['GrokBot', 'GrokBotMac']: compile_in('GrokBot/Core/BotSkills.swift', name, 'GrokBot')
for name in ['GrokBot', 'GrokBotMac']: compile_in('GrokBot/Core/ServerAddress.swift', name, 'GrokBot')
for name in ['GrokBot', 'GrokBotMac']: compile_in('GrokBot/Core/DirectServerClient.swift', name, 'GrokBot')
compile_in('GrokBot/Remote/RemoteServersView.swift', 'GrokBot', 'GrokBot')
for path in ['GrokBotMac/Features/MacServers.swift', 'GrokBotMac/Composio/ConnectorLogos.swift', 'GrokBotMac/Composio/ConnectorIcon.swift', 'GrokBotMac/Features/MacAccountMenu.swift', 'GrokBotMac/Features/MacSkillsView.swift', 'GrokBotMac/Features/MacRoutinesView.swift', 'GrokBotMac/Features/MacDrop.swift']:
    compile_in(path, 'GrokBotMac', 'GrokBotMac')
for name in ['GrokBotTests', 'GrokBotMacTests']: compile_in('GrokBotTests/BotSkillsTests.swift', name, 'GrokBotTests')
for name in ['GrokBotTests', 'GrokBotMacTests']: compile_in('GrokBotTests/ServerAddressTests.swift', name, 'GrokBotTests')

# --- 10.1.1: background checks for Bot messages on iPhone ---------------------------------------------------------
compile_in('GrokBot/Remote/BackgroundCheck.swift', 'GrokBot', 'GrokBot')
compile_in('GrokBotTests/BackgroundCheckTests.swift', 'GrokBotTests', 'GrokBotTests')

# --- 10.1.2: chat channels on a server, managed from the Mac -----------------------------------------------------------
compile_in('GrokBotMac/Features/MacChannelsView.swift', 'GrokBotMac', 'GrokBotMac')
compile_in('GrokBotTests/MacChannelsTests.swift', 'GrokBotMacTests', 'GrokBotTests')
for path in ['GrokBotMac/Channels/MacChannels.swift', 'GrokBotMac/Channels/MacChannelAdapters.swift', 'GrokBotMac/Features/MacLocalChannelsSettings.swift']: compile_in(path, 'GrokBotMac', 'GrokBotMac')
for name in ['GrokBotTests', 'GrokBotMacTests']: compile_in('GrokBotTests/RemoteChannelsTests.swift', name, 'GrokBotTests')

# --- Version (10.1.2: updaters need three parts; the Mac updater matches it to the tag exactly) ----------------------------------------------------------------------------
for key, value in objects.items():
    if value.get('isa') == 'XCBuildConfiguration' and 'MARKETING_VERSION' in value['buildSettings']:
        value['buildSettings']['MARKETING_VERSION'] = '10.1.2'
        value['buildSettings']['CURRENT_PROJECT_VERSION'] = '41'

def encode(value, indent=0):
    if isinstance(value, dict): return '{\n' + ''.join('\t' * (indent + 1) + json.dumps(k) + ' = ' + encode(v, indent + 1) + ';\n' for k, v in value.items()) + '\t' * indent + '}'
    if isinstance(value, list): return '(\n' + ''.join('\t' * (indent + 1) + encode(v, indent + 1) + ',\n' for v in value) + '\t' * indent + ')'
    return json.dumps(str(value))
PROJECT.write_text('// !$*UTF8*$!\n' + encode(project) + '\n')
print('Project updated for 10.1.2.')
