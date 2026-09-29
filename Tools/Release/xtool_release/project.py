"""Import release bundles from canonical XcodeGen and Xcode project graphs."""
from __future__ import annotations

import fnmatch
import os
from pathlib import Path
import plistlib
import re
import shlex

import yaml


class ProjectError(ValueError):
    """A project cannot be represented without losing shipped functionality."""


class OpenStepParser:
    """OpenStep ASCII property lists, including comments and quoted escapes."""

    def __init__(self, text: str):
        self.text = text
        self.offset = 0

    def _space(self):
        while self.offset < len(self.text):
            if self.text[self.offset].isspace():
                self.offset += 1
            elif self.text.startswith("//", self.offset):
                end = self.text.find("\n", self.offset)
                self.offset = len(self.text) if end < 0 else end + 1
            elif self.text.startswith("/*", self.offset):
                end = self.text.find("*/", self.offset + 2)
                if end < 0:
                    raise ProjectError("Unterminated OpenStep comment")
                self.offset = end + 2
            else:
                break

    def _take(self, token):
        self._space()
        if not self.text.startswith(token, self.offset):
            raise ProjectError(f"Expected {token!r} at OpenStep offset {self.offset}")
        self.offset += len(token)

    def _peek(self):
        self._space()
        return self.text[self.offset:self.offset + 1]

    def _string(self):
        self._space()
        if self._peek() != '"':
            match = re.match(r"[A-Za-z0-9_./$:+\-]+", self.text[self.offset:])
            if not match:
                raise ProjectError(f"Invalid OpenStep atom at offset {self.offset}")
            self.offset += len(match[0])
            return match[0]
        self.offset += 1
        result = []
        while self.offset < len(self.text):
            char = self.text[self.offset]
            self.offset += 1
            if char == '"':
                # OpenStep's \U escape encodes UTF-16 code units.
                return ''.join(result).encode('utf-16', 'surrogatepass').decode('utf-16')
            if char != '\\':
                result.append(char)
                continue
            if self.offset == len(self.text):
                break
            char = self.text[self.offset]
            self.offset += 1
            if char == 'U':
                digits = self.text[self.offset:self.offset + 4]
                if not re.fullmatch(r'[0-9a-fA-F]{4}', digits):
                    raise ProjectError("Invalid OpenStep Unicode escape")
                result.append(chr(int(digits, 16)))
                self.offset += 4
            elif char in '01234567':
                digits = char
                while len(digits) < 3 and self.text[self.offset:self.offset + 1] in tuple('01234567'):
                    digits += self.text[self.offset]
                    self.offset += 1
                result.append(chr(int(digits, 8)))
            elif char == '\n':
                continue
            else:
                result.append({'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f', 'a': '\a', 'v': '\v'}.get(char, char))
        raise ProjectError("Unterminated OpenStep string")

    def _value(self):
        char = self._peek()
        if char == '{':
            self._take('{')
            result = {}
            while self._peek() != '}':
                key = self._string()
                self._take('=')
                if key in result:
                    raise ProjectError(f"Duplicate OpenStep key: {key}")
                result[key] = self._value()
                self._take(';')
            self._take('}')
            return result
        if char == '(':
            self._take('(')
            result = []
            while self._peek() != ')':
                result.append(self._value())
                if self._peek() == ')':
                    break
                self._take(',')
            self._take(')')
            return result
        if char == '<':
            self._take('<')
            end = self.text.find('>', self.offset)
            if end < 0:
                raise ProjectError("Unterminated OpenStep data")
            try:
                result = bytes.fromhex(self.text[self.offset:end])
            except ValueError as error:
                raise ProjectError("Invalid OpenStep data") from error
            self.offset = end + 1
            return result
        return self._string()

    def parse(self):
        result = self._value()
        self._space()
        if self.offset != len(self.text):
            raise ProjectError(f"Trailing OpenStep content at offset {self.offset}")
        return result


def _identifier(value):
    value = re.sub(r'[^a-zA-Z0-9_]', '_', str(value))
    return '_' + value if value[:1].isdigit() else value


_VARIABLE = re.compile(r'\$\(([^)]+)\)|\$\{([^}]+)\}')
_SIGNING_VARIABLES = {'AppIdentifierPrefix', 'TeamIdentifierPrefix'}


def expand(value, settings, *, signing=False, stack=()):
    if isinstance(value, dict):
        return {key: expand(item, settings, signing=signing, stack=stack) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item, settings, signing=signing, stack=stack) for item in value]
    if not isinstance(value, str):
        return value

    def replace(match):
        expression = match[1] or match[2]
        key, *modifiers = expression.split(':')
        if signing and key in _SIGNING_VARIABLES:
            return match[0]
        if key == 'inherited':
            return ''
        if key in stack or key not in settings:
            raise ProjectError(f"Unresolved or cyclic build setting: {expression}")
        replacement = expand(settings[key], settings, signing=signing, stack=(*stack, key))
        if isinstance(replacement, list):
            replacement = ' '.join(map(str, replacement))
        replacement = str(replacement)
        for modifier in modifiers:
            if modifier in ('rfc1034identifier', 'c99extidentifier'):
                replacement = _identifier(replacement) if modifier == 'c99extidentifier' else re.sub(r'[^a-zA-Z0-9.-]', '-', replacement)
            else:
                raise ProjectError(f"Unsupported build-setting modifier: {modifier}")
        return replacement

    return _VARIABLE.sub(replace, value)


def _merge(*layers):
    result = {}
    for layer in layers:
        for key, value in layer.items():
            if isinstance(value, str):
                old = result.get(key, '')
                old = ' '.join(map(str, old)) if isinstance(old, list) else str(old)
                value = value.replace('$(inherited)', old).replace('${inherited}', old)
            elif isinstance(value, list):
                old = result.get(key, [])
                old = shlex.split(old) if isinstance(old, str) else old
                value = [part for item in value for part in (old if item in ('$(inherited)', '${inherited}') else [item])]
            result[key] = value
    return result


def _xg_settings(value):
    if not value:
        return {}
    if 'groups' in value:
        raise ProjectError("XcodeGen setting groups are not supported")
    if 'base' in value or 'configs' in value:
        return _merge(value.get('base', {}), value.get('configs', {}).get('Release', {}))
    return value


def _plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)


_COMPILED_RESOURCES = {'.storyboard', '.xib', '.xcdatamodeld', '.xcdatamodel', '.xcmappingmodel', '.metal', '.intentdefinition', '.xcstrings', '.mlmodel', '.mlpackage', '.scnassets'}
_CODE = {'.c', '.m', '.mm', '.cpp', '.cc', '.cxx', '.s', '.S', '.h', '.hpp'}
_BUNDLE_RESOURCES = {'.bundle', '.lproj', '.xcassets'}


def _collect(path, sources, resources, catalogs, *, excludes=(), phase=None):
    if not path.exists():
        raise ProjectError(f"Missing project input: {path}")

    def visit(item, relative):
        if any(fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(relative, pattern.rstrip('/') + '/*') for pattern in excludes):
            return
        if item.name.startswith('.'):
            return
        suffix = item.suffix
        if suffix in _COMPILED_RESOURCES:
            raise ProjectError(f"Resource requires an unsupported compiler: {item}")
        if suffix == '.xcassets':
            catalogs.append(str(item.resolve()))
        elif item.is_dir() and suffix not in _BUNDLE_RESOURCES and phase != 'folder':
            for child in sorted(item.iterdir()):
                visit(child, f'{relative}/{child.name}' if relative else child.name)
        elif suffix == '.swift' and phase != 'resources':
            sources.append(str(item.resolve()))
        elif suffix in _CODE and phase != 'resources':
            raise ProjectError(f"Only Swift application sources are supported: {item}")
        elif suffix == '.entitlements' or item.name == 'Info.plist':
            return
        else:
            resources.append(str(item.resolve()))

    visit(path, '' if path.is_dir() else path.name)


def _normalize_target(name, raw, root, release, build_number, parent):
    settings = _merge(raw['settings'], release.get('settings', {}))
    for key in release.get('requiredEnvironment', []):
        settings[key] = os.environ[key]
    # Explicit environment overrides are restricted to declared public settings.
    for key in release.get('settings', {}):
        if key in os.environ:
            settings[key] = os.environ[key]
    settings.update(TARGET_NAME=name, SRCROOT=str(root), PROJECT_DIR=str(root), CONFIGURATION='Release', CURRENT_PROJECT_VERSION=str(build_number))
    settings.setdefault('PRODUCT_NAME', name)
    settings.setdefault('PRODUCT_MODULE_NAME', _identifier(expand(settings['PRODUCT_NAME'], settings)))
    module = expand(settings['PRODUCT_MODULE_NAME'], settings)
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', module):
        raise ProjectError(f"Invalid Swift module name: {module}")
    settings['PRODUCT_MODULE_NAME'] = module
    settings['EXECUTABLE_NAME'] = module
    platform = raw['platform']
    kind = raw['kind']
    if platform not in ('ios', 'watchos') or kind not in ('application', 'extension'):
        raise ProjectError(f"Unsupported product {name}: {platform} {kind}")
    minimum = raw.get('minimumOS') or settings.get('WATCHOS_DEPLOYMENT_TARGET' if platform == 'watchos' else 'IPHONEOS_DEPLOYMENT_TARGET')
    if not minimum:
        raise ProjectError(f"Missing deployment target for {name}")
    info = dict(raw.get('info', {}))
    for key, value in settings.items():
        if not key.startswith('INFOPLIST_KEY_'):
            continue
        key = key.removeprefix('INFOPLIST_KEY_')
        value = expand(value, settings)
        if value in ('YES', 'NO'):
            value = value == 'YES'
        if key == 'UIApplicationSceneManifest_Generation':
            if value:
                info.setdefault('UIApplicationSceneManifest', {'UIApplicationSupportsMultipleScenes': True})
        elif key == 'UILaunchScreen_Generation':
            if value:
                info.setdefault('UILaunchScreen', {})
        elif key.startswith('UISupportedInterfaceOrientations'):
            key = key.replace('_iPad', '~ipad').replace('_iPhone', '')
            info[key] = value.split() if isinstance(value, str) else value
        else:
            info[key] = value
    info = expand(info, settings)
    bundle_id = expand(settings.get('PRODUCT_BUNDLE_IDENTIFIER', ''), settings)
    if not bundle_id:
        raise ProjectError(f"Missing bundle identifier for {name}")
    info.update(CFBundleIdentifier=bundle_id, CFBundleExecutable=module, CFBundleVersion=str(build_number), CFBundlePackageType='APPL' if kind == 'application' else 'XPC!')
    info.setdefault('CFBundleName', expand(settings['PRODUCT_NAME'], settings))
    info.setdefault('CFBundleShortVersionString', str(expand(settings.get('MARKETING_VERSION', '1.0'), settings)))
    info.setdefault('CFBundleInfoDictionaryVersion', '6.0')
    info.setdefault('CFBundleDevelopmentRegion', raw.get('developmentRegion', 'en'))
    families = str(expand(settings.get('TARGETED_DEVICE_FAMILY', '4' if platform == 'watchos' else '1,2'), settings))
    info.setdefault('UIDeviceFamily', [int(item.strip()) for item in families.split(',')])
    entitlements = raw.get('entitlements', {})
    if settings.get('CODE_SIGN_ENTITLEMENTS'):
        entitlements = _plist(root / expand(settings['CODE_SIGN_ENTITLEMENTS'], settings)) | entitlements
    entitlements = expand(entitlements, settings, signing=True)
    excluded = expand(settings.get('EXCLUDED_SOURCE_FILE_NAMES', []), settings)
    excluded = shlex.split(excluded) if isinstance(excluded, str) else excluded
    included = expand(settings.get('INCLUDED_SOURCE_FILE_NAMES', []), settings)
    included = shlex.split(included) if isinstance(included, str) else included

    def retained(path):
        matches = lambda pattern: fnmatch.fnmatch(Path(path).name, pattern) or fnmatch.fnmatch(path, pattern)
        return not any(matches(pattern) for pattern in excluded) or any(matches(pattern) for pattern in included)

    sources = sorted({path for path in raw['sources'] if retained(path)})
    if not sources:
        raise ProjectError(f"No Swift sources for {name}")
    app_intents = any(re.search(r'\b(?:import\s+AppIntents|AppIntent|AppShortcutsProvider|AppEntity)\b', Path(source).read_text()) for source in sources)
    return dict(name=name, module=module, bundleID=bundle_id, platform=platform, minimumOS=str(minimum), kind=kind, parent=parent,
                sources=sources, resources=sorted({path for path in raw['resources'] if retained(path)}),
                assetCatalogs=sorted({path for path in raw['assetCatalogs'] if retained(path)}),
                info=info, entitlements=entitlements, packageDependencies=raw.get('packageDependencies', []),
                frameworks=raw.get('frameworks', []), appIntents=app_intents, settings=settings,
                appIcon=settings.get('ASSETCATALOG_COMPILER_APPICON_NAME'), postBuildScripts=raw.get('postBuildScripts', []))


def _xcodegen(path, release):
    spec = yaml.safe_load(path.read_text())
    if any(key in spec for key in ('include', 'targetTemplates', 'settingGroups')):
        raise ProjectError("XcodeGen includes/templates/setting groups require expansion before import")
    root = path.parent
    packages = {}
    for name, package in spec.get('packages', {}).items():
        package = dict(package)
        if 'path' in package:
            package['path'] = str((root / package['path']).resolve())
        packages[name] = package
    targets = {}
    for name, target in spec['targets'].items():
        if 'test' in target['type']:
            continue
        if target.get('preBuildScripts') or target.get('buildRules') or target.get('configFiles'):
            raise ProjectError(f"Unsupported pre-build rules/configuration in {name}")
        settings = _merge(_xg_settings(spec.get('settings')), _xg_settings(target.get('settings')))
        platform = target['platform'].lower()
        raw = dict(settings=settings, platform=platform, minimumOS=target.get('deploymentTarget', spec.get('options', {}).get('deploymentTarget', {}).get(target['platform'])),
                   kind={'application': 'application', 'app-extension': 'extension'}.get(target['type'], target['type']),
                   sources=[], resources=[], assetCatalogs=[], children=[], packageDependencies=[], frameworks=[], postBuildScripts=target.get('postBuildScripts', []))
        info = target.get('info', {})
        info_path = root / info.get('path', settings.get('INFOPLIST_FILE', 'Info.plist'))
        raw['info'] = (_plist(info_path) if info_path.is_file() else {}) | info.get('properties', {})
        raw['entitlements'] = target.get('entitlements', {}).get('properties', {})
        for entry in target.get('sources', []):
            entry = {'path': entry} if isinstance(entry, str) else entry
            unsupported = set(entry) - {'path', 'excludes', 'buildPhase', 'type', 'optional', 'name', 'group'}
            if unsupported or entry.get('buildPhase') not in (None, 'sources', 'resources', 'none'):
                raise ProjectError(f"Unsupported source settings for {name}: {entry}")
            if entry.get('buildPhase') == 'none':
                continue
            source_path = root / entry['path']
            if entry.get('optional') and not source_path.exists():
                continue
            _collect(source_path, raw['sources'], raw['resources'], raw['assetCatalogs'], excludes=entry.get('excludes', []), phase='folder' if entry.get('type') == 'folder' else entry.get('buildPhase'))
        for dependency in target.get('dependencies', []):
            if 'package' in dependency:
                raw['packageDependencies'].append({'package': dependency['package'], 'product': dependency.get('product', dependency['package'])})
            elif 'target' in dependency and dependency.get('embed'):
                raw['children'].append(dependency['target'])
            elif 'sdk' in dependency and dependency['sdk'].endswith('.framework'):
                raw['frameworks'].append(dependency['sdk'][:-10])
            else:
                raise ProjectError(f"Unsupported dependency in {name}: {dependency}")
        targets[name] = raw
    return spec['name'], root, targets, packages, _xg_settings(spec.get('settings'))


def _xcode(path, release):
    if path.suffix == '.xcodeproj':
        path = path / 'project.pbxproj'
    root = path.parent.parent
    data = OpenStepParser(path.read_text()).parse()
    objects = data['objects']
    project = objects[data['rootObject']]
    if project.get('projectReferences'):
        raise ProjectError('Cross-project Xcode references are not supported')
    paths = {}

    def group(ref, base):
        obj = objects[ref]
        tree = obj.get('sourceTree', '<group>')
        if tree == '<group>':
            result = base / obj.get('path', '')
        elif tree == 'SOURCE_ROOT':
            result = root / obj.get('path', '')
        elif tree == '<absolute>':
            result = Path(obj['path'])
        else:
            return
        paths[ref] = result.resolve()
        for child in obj.get('children', []):
            group(child, result)

    group(project['mainGroup'], root)

    def settings_for(obj):
        configurations = objects[obj['buildConfigurationList']]['buildConfigurations']
        selected = [objects[ref] for ref in configurations if objects[ref]['name'] == 'Release']
        if len(selected) != 1:
            raise ProjectError('Expected one Release build configuration')
        config = selected[0]
        if config.get('baseConfigurationReference'):
            raise ProjectError('xcconfig references are not supported; expand them before import')
        return config.get('buildSettings', {})

    common = settings_for(project)
    packages = {}
    package_refs = {}
    for ref in project.get('packageReferences', []):
        package = objects[ref]
        if package['isa'] == 'XCLocalSwiftPackageReference':
            local = (root / package['relativePath']).resolve()
            name = local.name
            packages[name] = {'path': str(local)}
        elif package['isa'] == 'XCRemoteSwiftPackageReference':
            url = package['repositoryURL']
            name = url.rstrip('/').removesuffix('.git').rsplit('/', 1)[-1]
            requirement = package['requirement']
            kind = requirement['kind']
            mapping = {'upToNextMajorVersion': ('from', 'minimumVersion'), 'upToNextMinorVersion': ('minorVersion', 'minimumVersion'),
                       'exactVersion': ('exactVersion', 'version'), 'branch': ('branch', 'branch'), 'revision': ('revision', 'revision')}
            if kind not in mapping:
                raise ProjectError(f'Unsupported package requirement: {requirement}')
            key, value_key = mapping[kind]
            packages[name] = {'url': url, key: requirement[value_key]}
        else:
            raise ProjectError(f'Unsupported package reference: {package}')
        package_refs[ref] = name
    native = {ref: objects[ref] for ref in project['targets'] if objects[ref]['isa'] == 'PBXNativeTarget'}
    product_refs = {obj['productReference']: ref for ref, obj in native.items()}
    targets = {}
    for ref, target in native.items():
        if 'test' in target['productType']:
            continue
        name = target['name']
        if target.get('buildRules'):
            raise ProjectError(f'Custom Xcode build rules are not supported: {name}')
        settings = _merge(common, settings_for(target))
        platform = {'iphoneos': 'ios', 'watchos': 'watchos'}.get(settings.get('SDKROOT'), settings.get('SDKROOT'))
        raw = dict(settings=settings, platform=platform,
                   kind={'com.apple.product-type.application': 'application', 'com.apple.product-type.app-extension': 'extension'}.get(target['productType'], target['productType']),
                   sources=[], resources=[], assetCatalogs=[], children=[], packageDependencies=[], frameworks=[], postBuildScripts=[], developmentRegion=project.get('developmentRegion', 'en'))
        info_file = settings.get('INFOPLIST_FILE')
        raw['info'] = _plist(root / expand(info_file, settings | {'SRCROOT': str(root)})) if info_file else {}
        for package_ref in target.get('packageProductDependencies', []):
            dependency = objects[package_ref]
            raw['packageDependencies'].append({'package': package_refs[dependency['package']], 'product': dependency['productName']})
        for group_ref in target.get('fileSystemSynchronizedGroups', []):
            obj = objects[group_ref]
            if obj.get('explicitFileTypes') or obj.get('explicitFolders'):
                raise ProjectError(f'Explicit synchronized file types/folders are not supported in {name}')
            excluded = []
            for exception_ref in obj.get('exceptions', []):
                exception = objects[exception_ref]
                if exception.get('target') != ref:
                    continue
                if set(exception) - {'isa', 'target', 'membershipExceptions'}:
                    raise ProjectError(f'Unsupported synchronized exception: {exception}')
                excluded.extend(exception.get('membershipExceptions', []))
            _collect(paths[group_ref], raw['sources'], raw['resources'], raw['assetCatalogs'], excludes=excluded)
        embedded = set()
        for phase_ref in target.get('buildPhases', []):
            phase = objects[phase_ref]
            kind = phase['isa']
            if kind == 'PBXShellScriptBuildPhase':
                script_name = phase.get('name', phase_ref)
                skipped = release.get('skippedBuildScripts', {})
                if script_name in skipped and skipped[script_name]:
                    continue
                if phase.get('inputFileListPaths') or phase.get('outputFileListPaths'):
                    raise ProjectError(f'Script file lists are not supported: {script_name}')
                if not phase.get('outputPaths'):
                    raise ProjectError(f'Shell phase {script_name!r} has no declared resource outputs; explicitly configure skippedBuildScripts for validation-only phases')
                raw['postBuildScripts'].append({'name': script_name, 'script': phase['shellScript'], 'shell': phase.get('shellPath', '/bin/sh'), 'outputFiles': phase['outputPaths']})
                continue
            if kind not in ('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXCopyFilesBuildPhase'):
                raise ProjectError(f'Unsupported build phase {kind} in {name}')
            for file_ref in phase.get('files', []):
                build_file = objects[file_ref]
                if build_file.get('platformFilter') or build_file.get('platformFilters'):
                    raise ProjectError(f'Platform-filtered build file not supported: {build_file}')
                if 'productRef' in build_file:
                    if kind != 'PBXFrameworksBuildPhase':
                        raise ProjectError('Package products outside framework phases are not supported')
                    continue
                item_ref = build_file['fileRef']
                item = objects[item_ref]
                if kind == 'PBXCopyFilesBuildPhase':
                    if item_ref not in product_refs or str(phase.get('dstSubfolderSpec')) not in ('13', '16'):
                        raise ProjectError(f'Unsupported copied product in {name}: {item}')
                    child_ref = product_refs[item_ref]
                    raw['children'].append(native[child_ref]['name'])
                    embedded.add(child_ref)
                elif kind == 'PBXFrameworksBuildPhase':
                    framework = Path(item.get('path', '')).name
                    if not framework.endswith('.framework') or item.get('sourceTree') not in ('SDKROOT', 'DEVELOPER_DIR'):
                        raise ProjectError(f'Non-system framework is not supported: {item}')
                    raw['frameworks'].append(framework[:-10])
                else:
                    if build_file.get('settings'):
                        raise ProjectError(f'Per-file compiler settings are not supported: {build_file}')
                    if item['isa'] == 'PBXVariantGroup':
                        for child in item['children']:
                            _collect(paths[child].parent, raw['sources'], raw['resources'], raw['assetCatalogs'], phase='resources')
                    else:
                        _collect(paths[item_ref], raw['sources'], raw['resources'], raw['assetCatalogs'], phase='resources' if kind == 'PBXResourcesBuildPhase' else 'sources')
        for dependency_ref in target.get('dependencies', []):
            dependency = objects[dependency_ref]
            if dependency.get('target') not in embedded:
                raise ProjectError(f'Non-embedded target dependency is not supported in {name}: {dependency}')
        targets[name] = raw
    return path.parent.stem, root, targets, packages, common


def load_project(config: Path, build_number: str) -> dict:
    """Normalize a manifest and its reachable release product graph, without signing."""
    config = Path(config).resolve()
    release = yaml.safe_load(config.read_text())
    if not isinstance(release, dict) or release.get('version') != 1:
        raise ProjectError('Expected an xtool-release manifest with version: 1')
    for key in release.get('requiredEnvironment', []):
        if not os.environ.get(key):
            raise ProjectError(f'Required environment variable is missing: {key}')
    path = (config.parent / release['project']).resolve()
    loader = _xcode if path.suffix in ('.xcodeproj', '.pbxproj') else _xcodegen
    name, root, raw_targets, packages, settings = loader(path, release)
    targets = []
    seen = set()

    def visit(target_name, parent):
        if target_name in seen:
            raise ProjectError(f'Product is embedded multiple times or cyclic: {target_name}')
        if target_name not in raw_targets:
            raise ProjectError(f'Unknown release target: {target_name}')
        seen.add(target_name)
        raw = raw_targets[target_name]
        targets.append(_normalize_target(target_name, raw, root, release, build_number, parent))
        for child in raw['children']:
            visit(child, target_name)

    visit(release['target'], None)
    if targets[0]['kind'] != 'application' or targets[0]['platform'] != 'ios':
        raise ProjectError('The release root must be an iOS application')
    if len({target['module'] for target in targets}) != len(targets):
        raise ProjectError('Release product module names collide')
    return dict(name=name, rootTarget=release['target'], root=str(root.resolve()), targets=targets, packages=packages,
                settings=settings, release=release, buildNumber=str(build_number))
