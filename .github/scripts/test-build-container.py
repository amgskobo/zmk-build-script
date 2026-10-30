#!/usr/bin/env python3
"""Container-owned parser/workspace contracts; execute real build.sh at each boundary."""
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace

import yaml

BUILD = pathlib.Path('/root/zmk-config/build.sh')
SHAPES = pathlib.Path(sys.argv.pop(1))
WORKFLOW = pathlib.Path('/tmp/auto-build.yml')
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
FIELDS = ('board', 'shield', 'snippet', 'cmake-args')


def target(artifact, board='A', shield='', snippet='', cmake=''):
    return (artifact, board, shield or '<none>', snippet or '<none>', cmake or '<none>')


class ContainerContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zmk-contract-')
        self.root = pathlib.Path(self.temp.name)
        (self.root / 'config').mkdir()
        (self.root / 'config/west.yml').write_text('manifest: {projects: []}\n')
        self.modules = self.root / 'inputs'
        self.modules.mkdir()
        self.addCleanup(self.temp.cleanup)

    def run_config(self, doc, *, reset=False, snippets='', fallback='bin'):
        (self.root / 'build.yaml').write_text(yaml.safe_dump(doc, sort_keys=False), encoding='utf-8')
        env = dict(os.environ, ZMK_IN_CONTAINER='1', SOURCE_DIR=str(self.root),
                   EXTERNAL_MODULES_DIR=str(self.modules), SETTINGS_RESET=str(int(reset)),
                   ZMK_FALLBACK_BINARY=fallback)
        result = subprocess.run(['bash', str(BUILD), 'validate', snippets], env=env,
                                text=True, capture_output=True)
        output = ANSI.sub('', result.stdout + result.stderr)
        print('COMMAND: build.sh validate; reset=%s snippets=%r fallback=%r' % (reset, snippets, fallback))
        print(output, end='')
        return result.returncode, output

    def expect_targets(self, doc, expected, **kwargs):
        status, output = self.run_config(doc, **kwargs)
        self.assertEqual(status, 0, output)
        actual = [line for line in output.splitlines()
                  if line.startswith('- ') or line.startswith('  ')]
        wanted = []
        for artifact, *values in expected:
            wanted.append('- ' + artifact)
            wanted.extend('  %s: %s' % pair for pair in zip(FIELDS, values))
        if not expected:
            wanted = ['- No build targets.']
        self.assertEqual(actual, wanted)

    def expect_error(self, doc, message, **kwargs):
        status, output = self.run_config(doc, **kwargs)
        self.assertNotEqual(status, 0, output)
        self.assertIn(message, output)

    def test_empty_configuration(self):
        for document in (None, {}):
            with self.subTest(document=document):
                self.expect_targets(document, [], reset=True)

    def test_standalone_application_layout(self):
        app = self.root / 'audio app'
        app.mkdir()
        (app / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.20.0)\n')
        self.expect_targets({'application': 'audio app', 'include': [{'board': 'A'}]},
                            [target('A-zmk')])
        for invalid in ('../outside', str(self.root), 'C:/outside', 'app\\outside', '', 7):
            with self.subTest(application=invalid):
                self.expect_error({'application': invalid, 'include': [{'board': 'A'}]},
                                  'invalid application layout')
        self.expect_error({'application': 'missing', 'include': [{'board': 'A'}]},
                          'application requires CMakeLists.txt')
        (self.root / 'escape').symlink_to(self.root.parent, target_is_directory=True)
        self.expect_error({'application': 'escape', 'include': [{'board': 'A'}]},
                          'application must stay inside the target repository')

    def test_standalone_module_roots_without_registering_application(self):
        for name in ('boards', 'dts', 'snippets', 'zephyr'):
            (self.root / name).mkdir()
        for name in ('CMakeLists.txt', 'Kconfig', 'zephyr/CMakeLists.txt', 'zephyr/Kconfig'):
            (self.root / name).touch()
        metadata = self.root / 'zephyr/module.yml'
        for app in ('.', 'nested app'):
            with self.subTest(application=app):
                directory = self.root / app
                directory.mkdir(exist_ok=True)
                (directory / 'CMakeLists.txt').touch()
                if metadata.exists():
                    metadata.unlink()
                self.expect_targets({'application': app, 'board': 'A'}, [target('A-zmk')])
                actual = yaml.safe_load(metadata.read_text())
                self.assertEqual(actual['build'], {'settings': {
                    'board_root': '.', 'dts_root': '.', 'snippet_root': '.'}})

    def test_standalone_preserves_explicit_legacy_module_build_declarations(self):
        (self.root / 'CMakeLists.txt').touch()
        (self.root / 'dts').mkdir()
        declared = {'cmake': 'module', 'kconfig': 'module/Kconfig'}
        (self.root / 'module.yml').write_text(yaml.safe_dump({'build': declared}))
        self.expect_targets({'application': '.', 'board': 'A'}, [target('A-zmk')])
        actual = yaml.safe_load((self.root / 'zephyr/module.yml').read_text())
        self.assertEqual(actual['build'], dict(declared, settings={'dts_root': '.'}))

    def test_standalone_without_module_content_does_not_register_application(self):
        (self.root / 'CMakeLists.txt').touch()
        (self.root / 'Kconfig').touch()
        self.expect_targets({'application': '.', 'board': 'A'}, [target('A-zmk')])
        self.assertFalse((self.root / 'zephyr/module.yml').exists())

    def test_external_workflow_forwards_pristine_in_both_modes(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        steps = [step for step in workflow['jobs']['build-runner']['steps']
                 if step.get('name', '').startswith('Build source (')]
        self.assertCountEqual([step['name'] for step in steps],
                              ['Build source (Unix)', 'Build source (Windows)'])
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/build-external-source.sh').write_text(
            '#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$WORKFLOW_ARGV"\n')
        (self.root / '.github/scripts').mkdir(parents=True)
        shutil.copyfile('/tmp/check-build-output.sh', self.root / '.github/scripts/check-build-output.sh')
        for script in ('auto-build-external.sh', 'source-common.sh'):
            shutil.copyfile('/tmp/' + script, self.root / 'scripts' / script)
        (self.root / '.build').mkdir()
        for step in steps:
            for mode in ('build', 'validate'):
                for pristine in ('true', 'false'):
                    for kind in ('repo', 'path'):
                        with self.subTest(step=step['name'], mode=mode,
                                          pristine=pristine, kind=kind):
                            source = ('https://example.invalid/config.git' if kind == 'repo'
                                      else str(self.root / 'source with spaces'))
                            env = dict(os.environ, EXTERNAL_MODE=mode, EXTERNAL_BUILD_JOBS='2',
                                       EXTERNAL_PRISTINE=pristine, SOURCE_INDEX='0002',
                                       WORKFLOW_ARGV=str(self.root / 'workflow.argv'))
                            sources = self.root / 'sources.txt'
                            sources.write_text('repo:https://example.invalid/unselected.git\n' + kind + ':' + source + '\n')
                            (self.root / '.build/ci-source-file').write_text(str(sources))
                            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', step['run']],
                                                    cwd=self.root, env=env, capture_output=True)
                            self.assertEqual(result.returncode, 0, result.stderr.decode())
                            record = (self.root / '.build/ci-source.record').read_text().strip()
                            actual = (self.root / 'workflow.argv').read_bytes().decode().rstrip('\0').split('\0')
                            expected = ['--' + kind, source, '--source-slug',
                                        'config' if kind == 'repo' else 'source-with-spaces',
                                        '--mode', mode, '--jobs', '2']
                            if pristine == 'true':
                                expected.append('--pristine')
                            self.assertEqual(actual, expected)
                            self.assertNotIn('unselected.git', (self.root / record).read_text())
                            self.assertNotIn(source, result.stdout.decode())

    def test_workflows_publish_only_fixed_reports(self):
        root = pathlib.Path('/tmp/workflows')
        workflows = list(root.glob('*.yml'))
        self.assertEqual(len(workflows), 4)
        allowed = {'.build/public/' + name + '.txt' for name in (
            'tests-shell', 'tests-docker', 'tests-build', 'tests-all', 'build', 'validate')}
        uploads = 0
        for path in workflows:
            source = path.read_text()
            self.assertNotIn('runner.name', source)
            document = yaml.load(source, Loader=yaml.BaseLoader)
            for job in document['jobs'].values():
                self.assertNotIn('inputs.', job.get('name', ''))
                for step in job.get('steps', []):
                    if step.get('name', '').startswith('Show selected runner'):
                        self.assertNotIn('${EXTERNAL_', step['run'])
                    for raw_entry in ('scripts/test.sh', 'scripts/build-external-source.sh', 'scripts/check-runner-tools.sh', 'scripts/check-lf.sh'):
                        self.assertNotIn(raw_entry, step.get('run', ''), step)
                    if 'actions/upload-artifact@' in step.get('uses', ''):
                        uploads += 1
                        self.assertTrue(set(step['with']['path'].splitlines()) <= allowed, step)
                        self.assertNotIn('matrix.source.slug', step['with']['name'])
                        self.assertIn('publication-init', step['if'])
                        self.assertIn('publication-check', step['if'])
        self.assertEqual(uploads, 6)

    def test_external_workflow_keeps_source_values_out_of_runner_details(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        for job in workflow['jobs'].values():
            for step in job.get('steps', []):
                for value in step.get('env', {}).values():
                    self.assertNotIn('matrix.source.slug', value)
                    self.assertNotIn('matrix.source.source', value)
                    self.assertNotIn('inputs.source_file', value)
        resolver = workflow['jobs']['sources']['steps']
        self.assertTrue(any('ci-matrix' in step.get('run', '') for step in resolver))

    def test_normal_defaults_aliases_and_order(self):
        self.expect_targets({'defaults': {'cmake-args': '-DDEFAULT=1'}, 'include': [
            {'board': 'A', 'shield': 'left', 'artifact-name': 'one'},
            {'board': 'B', 'shield': 'right', 'artifact_name': 'two',
             'snippet': ['first', 'second'], 'cmake_args': ['-DNAME=two words'],
             'extra_cmake_args': ['-DEXTRA=1']}]}, [
                target('one', shield='left', snippet='cli', cmake='-DDEFAULT=1'),
                target('two', board='B', shield='right', snippet='first second cli',
                       cmake="'-DNAME=two words' -DEXTRA=1")], snippets='cli')

    def test_matrix_exclude_and_skip(self):
        self.expect_targets({'board': ['A', 'B'], 'shield': ['left', 'right'],
                             'artifact-name': '{board}-{shield}',
                             'include': [{'board': 'C', 'skip': True}],
                             'exclude': [{'board': 'B', 'shield': 'right'}]}, [
            target('A-left', shield='left'), target('A-right', shield='right'),
            target('B-left', board='B', shield='left')])

    def test_reset_added_once_per_board_and_existing_reset_preserved(self):
        self.expect_targets({'include': [
            {'board': 'A', 'shield': ['left', 'right'], 'artifact-name': '{shield}'},
            {'board': 'B', 'shield': 'settings_reset', 'artifact-name': 'existing'}]}, [
                target('left', shield='left', snippet='cli'),
                target('right', shield='right', snippet='cli'),
                target('existing', board='B', shield='settings_reset', snippet='cli'),
                target('settings_reset-A-zmk', shield='settings_reset')], reset=True, snippets='cli')

    def test_exclude_uses_yaml_snippets_before_cli_append(self):
        self.expect_targets({'include': [{'board': 'A', 'snippet': 'old',
                                          'artifact-name': 'name-{snippet}'}],
                             'exclude': [{'artifact-name': 'name-old'}]}, [], snippets='new')

    def test_current_target_shapes_fixture_exact_trace(self):
        nice = 'nice_nano/nrf52840/zmk'
        xiao = 'xiao_ble/nrf52840/zmk'
        cli = 'studio-rpc-usb-uart'
        self.expect_targets(yaml.safe_load(SHAPES.read_text()), [
            target('matrix-nice_nano_nrf52840_zmk-corne_left', nice, 'corne_left', cli, '-DDEFAULT_FLAG=1'),
            target('reset-nice_nano_nrf52840_zmk', nice, 'settings_reset', cli, '-DDEFAULT_FLAG=1'),
            target('reset-xiao_ble_nrf52840_zmk', xiao, 'settings_reset', cli, '-DDEFAULT_FLAG=1'),
            target('xiao-alias-tester_xiao-studio-rpc-usb-uart_zmk-usb-logging_studio-rpc-usb-uart',
                   xiao, 'tester_xiao', cli+' zmk-usb-logging '+cli,
                   "-DLEGACY_ALIAS=y -DEXTRA_ALIAS=1 '-DCUSTOM_LABEL=two board fixture'")],
            reset=True, snippets=cli)

    def test_invalid_schema(self):
        cases = [(value, 'must be a map') for value in ([], False, 0, '')] + [
                 ({'defaults': []}, 'defaults must be a map'),
                 ({'defaults': False}, 'defaults must be a map'),
                 ({'include': {}}, 'include must be a list'),
                 ({'exclude': {}}, 'exclude must be a list'),
                 ({'exclude': ['bad']}, 'exclude entry must be a map'),
                 ({'board': [None]}, 'board must be a scalar'),
                 ({'defaults': ['bad']}, 'defaults must be a map'),
                 ({'include': {'board': 'A'}}, 'include must be a list'),
                 ({'include': ['bad']}, 'include entry must be a map'),
                 ({'include': [{}]}, 'requires board'),
                 ({'include': [{'board': ['A', {}]}]}, 'board must be a scalar'),
                 ({'board': 'A', 'exclude': {'board': 'A'}}, 'exclude must be a list'),
                 ({'board': 'A', 'exclude': ['bad']}, 'exclude entry must be a map')]
        for doc, message in cases:
            with self.subTest(message=message): self.expect_error(doc, message)

    def test_artifact_names_and_control_separators(self):
        for name in ('CON', 'con.txt', 'Lpt1.extra', '/', '...'):
            with self.subTest(name=name):
                self.expect_error({'include': [{'board': 'A', 'artifact-name': name}]},
                                  'Windows reserved' if name[0].lower() in ('c', 'l') else 'empty or unsafe')
        self.expect_error({'include': [{'board': 'A', 'artifact-name': 'same'},
                                       {'board': 'B', 'artifact-name': 'SAME'}]}, 'duplicate artifact-name')
        self.expect_error({'board': 'A\nB'}, 'control separators or newlines')
        for name, extension in [('BuIlD', 'log'), ('build-summary', 'txt')]:
            with self.subTest(extension=extension):
                self.expect_error({'include': [{'board': 'A', 'artifact-name': name}]},
                                  'collides with build log', fallback=extension)

    def test_nul_rejected_before_shell_decoding(self):
        for key, value in [('board', 'A\0B'), ('shield', 'left\0right'),
                           ('snippet', 'first\0second'), ('cmake-args', '-DNAME=A\0B')]:
            with self.subTest(key=key):
                document = {'board': 'A'}
                document[key] = value
                self.expect_error(document, 'control separators or newlines')

    def test_cmake_quote_and_list_item_types(self):
        for value, message in [("-DNAME='unfinished", 'cmake-args'),
                               ([{'nested': 'map'}], 'scalar'), ([None], 'scalar')]:
            with self.subTest(value=value):
                self.expect_error({'board': 'A', 'cmake-args': value}, message)

    def test_module_metadata_valid_inline_and_missing_keys(self):
        module = self.modules / 'module'
        (module / 'zephyr').mkdir(parents=True)
        (module / 'boards').mkdir()
        (module / 'CMakeLists.txt').touch()
        metadata = module / 'zephyr/module.yml'
        metadata.write_text('build: {cmake: ., settings: {board_root: .}}\n')
        self.expect_targets({'board': 'A'}, [target('A-zmk')])
        for document, message in [({'build': {'settings': {'board_root': '.'}}}, 'build.cmake'),
                                  ({'build': {'cmake': '.'}}, 'build.settings.board_root'),
                                  ({'build': 'bad'}, 'build must be a map'),
                                  ([], 'must be a map'),
                                  ({'build': []}, 'build must be a map'),
                                  ({'build': {'settings': []}}, 'settings must be a map'),
                                  (['bad'], 'must be a map')]:
            with self.subTest(message=message):
                metadata.write_text(yaml.safe_dump(document))
                self.expect_error({'board': 'A'}, message)

    def test_distinct_module_names_with_spaces_validate(self):
        for name in ('alpha beta', 'beta'):
            (self.modules / name).mkdir()
        self.expect_targets({'board': 'A'}, [target('A-zmk')])

    def test_distinct_extra_module_names_reach_west(self):
        case = self.make_workspace(prior_overlay=False)
        names = ['a' + case.root.name + ' beta', 'beta']
        expected = []
        for name in names:
            source = case.inputs / name
            source.mkdir()
            (source / 'content.txt').write_text(name + '\n')
            destination = pathlib.Path('/workspaces/module-inputs') / name
            self.assertFalse(destination.exists(), str(destination))
            self.addCleanup(shutil.rmtree, destination, True)
            expected.append(str(destination))
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        for name, destination in zip(names, expected):
            self.assertEqual((pathlib.Path(destination) / 'content.txt').read_text(), name + '\n')
        calls = [json.loads(line) for line in case.commands.with_suffix('.argv.jsonl').read_text().splitlines()]
        builds = [args for args in calls if args[0] == 'build']
        self.assertEqual(len(builds), 1)
        self.assertIn('-DZMK_EXTRA_MODULES=' + ';'.join(expected), builds[0])

    def test_target_metadata_normalized_only_in_container_source(self):
        (self.root / 'boards').mkdir()
        (self.root / 'snippets').mkdir()
        (self.root / 'dts').mkdir()
        (self.root / 'Kconfig').touch()
        (self.root / 'CMakeLists.txt').touch()
        (self.root / 'module.yml').write_text('build: {cmake: .}\n')
        self.expect_targets({'board': 'A'}, [target('A-zmk')])
        actual = yaml.safe_load((self.root / 'zephyr/module.yml').read_text())
        self.assertEqual(actual['build']['cmake'], '.')
        self.assertEqual(actual['build']['kconfig'], 'Kconfig')
        self.assertEqual(actual['build']['settings'], {'board_root': '.', 'dts_root': '.', 'snippet_root': '.'})

    def make_workspace(self, project_path='modules/project', fail_copy=False, fail_remove=False,
                       *, document=None, jobs=1, prior_overlay=True, local_override=False,
                       update_actions=(), attempts=1, force_update=False):
        # Commands are controlled boundaries; production performs every restore/update decision.
        case_root = pathlib.Path(tempfile.mkdtemp(prefix='workspace-', dir=self.root))
        source = case_root / 'source'
        (source / 'config').mkdir(parents=True)
        workspace = case_root / 'workspace'
        (workspace / 'config').mkdir(parents=True)
        manifest = 'manifest: {projects: []}\n'
        (source / 'config/west.yml').write_text(manifest)
        (workspace / 'config/west.yml').write_text(manifest)
        (source / 'build.yaml').write_text(yaml.safe_dump({'board': 'A'} if document is None else document))
        (workspace / 'zmk').mkdir()
        (workspace / 'zmk/present').touch()
        project = workspace / project_path
        project.mkdir(parents=True, exist_ok=True)
        (project / 'content.txt').write_text('local override\n')
        backup = workspace / '.west/local-overlay-backups/project'
        stamp = workspace / '.west/local-overlays.tsv'
        (workspace / '.west').mkdir(exist_ok=True)
        if prior_overlay:
            backup.mkdir(parents=True)
            (backup / 'content.txt').write_text('original project\n')
            stamp.write_text('project\t' + project_path + '\n')
        manifest_stamp = workspace / '.west/manifest.sha256'
        digest = hashlib.sha256(manifest.encode()).hexdigest()
        ready = 'complete-resolved:' + digest
        manifest_stamp.write_text(('stale' if force_update else ready) + '\n')
        inputs = case_root / 'inputs'
        inputs.mkdir()
        if local_override:
            (inputs / 'project').mkdir()
            (inputs / 'project/content.txt').write_text('explicit local project\n')
        commands = case_root / 'commands.log'
        commands.touch()
        counter = case_root / 'update-count'
        control = case_root / 'control.json'
        lock = workspace / 'zmk/nested space/.git/index.lock'
        control.write_text(json.dumps({'updates': list(update_actions), 'lock': str(lock)}))
        fake_bin = case_root / 'fake-bin'
        fake_bin.mkdir()
        (fake_bin / 'west').write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
with open(os.environ['PROBE_ARGV'], 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')
with open(os.environ['PROBE_COMMANDS'], 'a') as log: log.write('west ' + ' '.join(sys.argv[1:]) + '\\n')
projects = [('zmk', 'zmk'), ('project', os.environ['PROBE_PROJECT_PATH'])]
if os.environ.get('PROBE_OMIT_PROJECT') == '1': projects = projects[:1]
if sys.argv[1] == 'list':
    wanted = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('-') else None
    fault = os.environ.get('PROBE_LIST_FAILURE')
    if fault == 'always' or (fault == 'before-update' and not pathlib.Path(os.environ['PROBE_UPDATE_COUNT']).exists()):
        sys.exit('injected unavailable west project list')
    if fault == 'formatted' and wanted is None and '-f' in sys.argv:
        print('zmk\\tzmk')
        sys.exit('injected incomplete west project list')
    for name, path in projects:
        if wanted is None or name == wanted: print(name + '\\t' + path)
elif sys.argv[1] == 'update':
    control = json.loads(pathlib.Path(os.environ['PROBE_CONTROL']).read_text())
    counter = pathlib.Path(os.environ['PROBE_UPDATE_COUNT'])
    attempt = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(attempt))
    actions = control['updates']
    if not actions: sys.exit('unexpected west update')
    lock = pathlib.Path(control['lock'])
    if lock.exists(): sys.exit('stale lock reached west update: ' + str(lock))
    action = actions[min(attempt - 1, len(actions) - 1)]
    status = action.get('exit', 0)
    print('controlled update attempt %d status=%d; lock absent' % (attempt, status))
    workspace = pathlib.Path(os.environ['WORK_DIR'])
    for name, path in projects:
        if status == 0 or (action.get('failed') is not None and name not in action['failed']):
            target = workspace / path
            target.mkdir(parents=True, exist_ok=True)
            (target / 'content.txt').write_text('resolved ' + name + '\\n')
    if status and action.get('partial'):
        target = workspace / os.environ['PROBE_PROJECT_PATH']
        (target / '.git').mkdir(parents=True, exist_ok=True)
        (target / '.git/HEAD').write_text('partial checkout\\n')
        (target / 'content.txt').write_text('partial project\\n')
    if action.get('new_lock'):
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text('stale lock from failed attempt\\n')
    if status:
        failed = action.get('failed')
        if failed:
            suffix = 's:' if len(failed) > 1 else ''
            print('ERROR: update failed for project' + suffix + ' ' + ', '.join(failed), file=sys.stderr)
        else: print('ERROR: transport failed before project identities were available', file=sys.stderr)
    sys.exit(status)
elif sys.argv[1] == 'manifest':
    if os.environ.get('PROBE_RESOLVE_REAL') == '1':
        sys.exit(subprocess.call([os.environ['PROBE_REAL_WEST']] + sys.argv[1:]))
    sys.stdout.write((pathlib.Path(os.environ['WORK_DIR']) / 'config/west.yml').read_text())
elif sys.argv[1] == 'zephyr-export': pass
elif sys.argv[1] == 'build':
    print('controlled build boundary reached')
    build = pathlib.Path(sys.argv[sys.argv.index('-d') + 1])
    (build / 'zephyr').mkdir(parents=True, exist_ok=True)
    (build / 'intermediate.o').write_text('temporary compiler output\\n')
    status = int(os.environ.get('PROBE_BUILD_EXIT', '71'))
    if status == 0 and os.environ.get('PROBE_SKIP_FIRMWARE') != '1':
        (build / 'zephyr/zephyr.uf2').write_bytes(b'controlled firmware')
    sys.exit(status)
else: sys.exit('unexpected west operation')
''')
        (fake_bin / 'rsync').write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[-2:])
if source == pathlib.Path(os.environ['EXTERNAL_MODULES_DIR']) / 'project' and os.environ.get('PROBE_FAIL_APPLY') == '1':
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'content.txt').write_text('interrupted local overlay\\n')
    print('injected module overlay apply failure', file=sys.stderr)
    sys.exit(23)
if 'local-overlay-backups' in source.parts and os.environ['PROBE_FAIL_COPY'] == '1':
    print('injected restore copy failure', file=sys.stderr)
    sys.exit(23)
shutil.copytree(source, destination, dirs_exist_ok=True)
''')
        if fail_remove:
            (fake_bin / 'rsync').unlink()
            for command in ('bash', 'python3', 'tar', 'mkdir', 'find', 'basename',
                            'dirname', 'sha256sum', 'awk', 'cat', 'ls', 'mktemp', 'tee', 'seq'):
                path = shutil.which(command)
                self.assertIsNotNone(path, command)
                (fake_bin / command).symlink_to(path)
            (fake_bin / 'rm').write_text('''#!/usr/bin/env python3
import os, sys
if any(arg.startswith(os.environ['PROBE_PROJECT_DIR'] + '/') for arg in sys.argv[1:]):
    print('injected restore removal failure', file=sys.stderr)
    sys.exit(23)
os.execv(os.environ['PROBE_REAL_RM'], ['rm'] + sys.argv[1:])
''')
        for script in fake_bin.iterdir():
            if not script.is_symlink(): script.chmod(0o755)
        env = dict(os.environ, ZMK_IN_CONTAINER='1', SOURCE_DIR=str(source),
                   WORK_DIR=str(workspace), BUILD_DIR=str(workspace / '.build'),
                   BUILD_JOBS=str(jobs), SETTINGS_RESET='0', PRISTINE='0', USER_ZMK_EXTRA_MODULES='',
                   ZMK_WEST_UPDATE_ATTEMPTS=str(attempts),
                   EXTERNAL_MODULES_DIR=str(inputs), OUTPUT_DIR=str(case_root / 'output'),
                   PATH=str(fake_bin) + ('' if fail_remove else os.pathsep + os.environ['PATH']),
                   PROBE_COMMANDS=str(commands), PROBE_ARGV=str(commands.with_suffix('.argv.jsonl')),
                   PROBE_PROJECT_PATH=project_path, PROBE_CONTROL=str(control), PROBE_UPDATE_COUNT=str(counter),
                   PROBE_FAIL_COPY=str(int(fail_copy)), PROBE_PROJECT_DIR=str(project),
                   PROBE_REAL_WEST=shutil.which('west'), PROBE_REAL_RM=shutil.which('rm'))
        return SimpleNamespace(root=case_root, source=source, workspace=workspace, project=project,
                               inputs=inputs, backup=backup, stamp=stamp, manifest_stamp=manifest_stamp,
                               digest=digest, ready=ready, commands=commands, counter=counter, control=control,
                               lock=lock, env=env)

    def run_workspace(self, case):
        result = subprocess.run(['bash', str(BUILD), 'build'], env=case.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = ANSI.sub('', result.stdout)
        print('COMMAND: build.sh build; workspace=%s jobs=%s attempts=%s'
              % (case.workspace, case.env['BUILD_JOBS'], case.env['ZMK_WEST_UPDATE_ATTEMPTS']), flush=True)
        print(output, end='', flush=True)
        return result, output

    def workspace_restore(self, project_path, fail_copy, fail_remove=False, *, document=None, jobs=1):
        case = self.make_workspace(project_path, fail_copy, fail_remove, document=document, jobs=jobs)
        result, output = self.run_workspace(case)
        return result, output, case.commands, case.backup, case.stamp, case.project

    def test_invalid_module_stops_before_workspace_mutation(self):
        for metadata in ('build: {}\n', 'build: [invalid]\n'):
            with self.subTest(metadata=metadata):
                case = self.make_workspace(local_override=True, force_update=True,
                                           update_actions=[{'exit': 0}])
                module = case.inputs / 'project'
                (module / 'CMakeLists.txt').touch()
                (module / 'zephyr').mkdir()
                (module / 'zephyr/module.yml').write_text(metadata)
                result, output = self.run_workspace(case)
                self.assertNotIn(result.returncode, (0, 71), output)
                self.assertIn('module input project:', output)
                self.assertEqual(case.commands.read_text(), '')
                self.assertEqual((case.project / 'content.txt').read_text(), 'local override\n')
                self.assertEqual((case.backup / 'content.txt').read_text(), 'original project\n')
                self.assertEqual(case.stamp.read_text(), 'project\tmodules/project\n')
                self.assertEqual(case.manifest_stamp.read_text(), 'stale\n')
                self.assertFalse(case.counter.exists())

    def test_module_metadata_without_root_content_is_still_validated(self):
        for metadata in ('build: []\n', 'build: {settings: false}\n', '[]\n'):
            with self.subTest(metadata=metadata):
                module = self.modules / 'schema-module'
                (module / 'zephyr').mkdir(parents=True, exist_ok=True)
                (module / 'zephyr/module.yml').write_text(metadata)
                status, output = self.run_config({'board': 'A'})
                self.assertNotEqual(status, 0, output)
                case = self.make_workspace(local_override=True, force_update=True,
                                           update_actions=[{'exit': 0}])
                project = case.inputs / 'project'
                (project / 'zephyr').mkdir()
                (project / 'zephyr/module.yml').write_text(metadata)
                completed, output = self.run_workspace(case)
                self.assertNotIn(completed.returncode, (0, 71), output)
                self.assertEqual(case.commands.read_text(), '')
                self.assertEqual(case.manifest_stamp.read_text(), 'stale\n')
                self.assertEqual(case.stamp.read_text(), 'project\tmodules/project\n')

    def test_create_group_signals_acquire_identity_before_cleanup(self):
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
with open(os.environ['SIGNAL_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'create':
    pathlib.Path(os.environ['SIGNAL_REACHED']).touch()
    while not pathlib.Path(os.environ['SIGNAL_RELEASE']).exists(): time.sleep(.01)
    print('a' * 64)
elif sys.argv[1] != 'rm': sys.exit(99)
''')
        docker.chmod(0o755)
        (self.root / 'build.yaml').write_text('board: A\n')
        for mode in ('build', 'validate'):
            for keep in (0, 1):
                for signum in (signal.SIGINT, signal.SIGTERM):
                    with self.subTest(mode=mode, keep=keep, signal=signum):
                        case = self.root / ('%s-%s-%s' % (mode, keep, signum))
                        case.mkdir()
                        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                   ZMK_IN_CONTAINER='0', ZMK_KEEP_CONTAINER=str(keep),
                                   SIGNAL_CALLS=str(case / 'calls'), SIGNAL_REACHED=str(case / 'reached'),
                                   SIGNAL_RELEASE=str(case / 'release'))
                        args = ['bash', str(BUILD)]
                        if mode == 'validate': args.append('validate')
                        args.append(str(self.root))
                        process = subprocess.Popen(args, env=env, start_new_session=True,
                                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                        try:
                            deadline = time.monotonic() + 5
                            while not (case / 'reached').exists() and time.monotonic() < deadline:
                                self.assertIsNone(process.poll())
                                time.sleep(.01)
                            self.assertTrue((case / 'reached').exists())
                            os.killpg(process.pid, signum)
                            time.sleep(.05)
                            (case / 'release').touch()
                            output, _ = process.communicate(timeout=5)
                            self.assertEqual(process.returncode, 128 + signum, output)
                            self.assertIn('a' * 64, output)
                            calls = [json.loads(line) for line in (case / 'calls').read_text().splitlines()]
                            self.assertFalse(any(call[0] == 'start' for call in calls), calls)
                            self.assertEqual(['rm', '-f', 'a' * 64] in calls, keep == 0, calls)
                            summaries = list((BUILD.parent / '.build').glob('*-pid-%s/build-summary.txt' % process.pid))
                            self.assertEqual(len(summaries), 1)
                            summary = summaries[0].read_text()
                            self.assertIn('Status: FAILED', summary)
                            self.assertIn('Reason: interrupted by ' + signal.Signals(signum).name, summary)
                        finally:
                            try: os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                            if process.poll() is None: process.wait(timeout=3)

    def test_restore_copy_failure_preserves_recovery_state(self):
        result, output, commands, backup, stamp, project = self.workspace_restore('modules/project', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('injected restore copy failure', output)
        self.assertIn('failed to restore module input overlay', output)
        self.assertEqual((backup / 'content.txt').read_text(), 'original project\n')
        self.assertEqual(stamp.read_text(), 'project\tmodules/project\n')
        self.assertEqual((project / 'content.txt').read_text(), 'local override\n')
        self.assertNotIn('west build ', commands.read_text())

    def test_partial_restore_retry_keeps_completed_projects(self):
        case = self.make_workspace(prior_overlay=True, fail_copy=True)
        second = case.workspace / 'modules/second'
        second.mkdir(parents=True)
        (second / 'content.txt').write_text('second overlay\n')
        backup = case.backup.parent / 'second'
        backup.mkdir()
        (backup / 'content.txt').write_text('second original\n')
        case.stamp.write_text('project\tmodules/project\nsecond\tmodules/second\n')
        fake = pathlib.Path(case.env['PATH'].split(os.pathsep)[0])
        west = fake / 'west'
        west.write_text(west.read_text().replace(
            "projects = [('zmk', 'zmk'), ('project', os.environ['PROBE_PROJECT_PATH'])]",
            "projects = [('zmk', 'zmk'), ('project', os.environ['PROBE_PROJECT_PATH']), ('second', 'modules/second')]"))
        rsync = fake / 'rsync'
        rsync.write_text(rsync.read_text().replace(
            "if 'local-overlay-backups' in source.parts and",
            "if source.name == 'second' and 'local-overlay-backups' in source.parts and"))
        for attempt in range(2):
            result, output = self.run_workspace(case)
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn('failed to restore module input overlay: second', output)
            self.assertTrue(case.project.exists(), 'restored project lost on retry %d' % attempt)
            self.assertEqual((case.project / 'content.txt').read_text(), 'original project\n')
            self.assertTrue(backup.exists())
        case.env['PROBE_FAIL_COPY'] = '0'
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertFalse(case.counter.exists(), 'completed restoration must not require an update')
        self.assertEqual((second / 'content.txt').read_text(), 'second original\n')
        self.assertFalse(case.stamp.exists())

    def test_restore_backup_cleanup_failure_keeps_completed_state(self):
        case = self.make_workspace()
        fake = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'rm'
        fake.write_text('\n'.join([
            '#!/usr/bin/env python3', 'import os, sys',
            'if os.environ.get("PROBE_BLOCK_BACKUP") == "1" and os.environ["PROBE_BACKUP"] in sys.argv[1:]:',
            '    sys.exit(23)',
            'os.execv(os.environ["PROBE_REAL_RM"], ["rm"] + sys.argv[1:])', '']))
        fake.chmod(0o755)
        case.env.update(PROBE_BLOCK_BACKUP='1', PROBE_BACKUP=str(case.backup))
        result, output = self.run_workspace(case)
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn('failed to remove restored overlay backup', output)
        self.assertTrue(case.backup.exists())
        self.assertIn('project\tmodules/project\trestored\n', case.stamp.read_text())
        case.env['PROBE_BLOCK_BACKUP'] = '0'
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual((case.project / 'content.txt').read_text(), 'original project\n')
        self.assertFalse(case.stamp.exists())

    def test_explicit_hidden_module_is_validated_and_reaches_build(self):
        module = self.modules / '.hidden-module'
        (module / 'zephyr').mkdir(parents=True)
        (module / 'CMakeLists.txt').touch()
        (module / 'zephyr/module.yml').write_text('build: []\n')
        self.expect_error({'board': 'A'}, 'build must be a map')
        for name in ('.hidden-module', '..hidden-module'):
            case = self.make_workspace(prior_overlay=False)
            source = case.inputs / name
            (source / 'zephyr').mkdir(parents=True)
            (source / 'CMakeLists.txt').touch()
            (source / 'zephyr/module.yml').write_text('build: {cmake: .}\n')
            destination = pathlib.Path('/workspaces/module-inputs') / name
            self.assertFalse(destination.exists())
            self.addCleanup(shutil.rmtree, destination, True)
            result, output = self.run_workspace(case)
            self.assertEqual(result.returncode, 71, output)
            calls = [json.loads(line) for line in case.commands.with_suffix('.argv.jsonl').read_text().splitlines()]
            builds = [args for args in calls if args[0] == 'build']
            self.assertIn('-DZMK_EXTRA_MODULES=' + str(destination), builds[0])
            self.assertTrue((destination / 'zephyr/module.yml').exists())

    def test_restore_removal_failure_preserves_recovery_state(self):
        result, output, commands, backup, stamp, project = self.workspace_restore('modules/project', False, True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('injected restore removal failure', output)
        self.assertIn('failed to restore module input overlay', output)
        self.assertEqual((backup / 'content.txt').read_text(), 'original project\n')
        self.assertEqual(stamp.read_text(), 'project\tmodules/project\n')
        self.assertEqual((project / 'content.txt').read_text(), 'local override\n')
        self.assertNotIn('west build ', commands.read_text())

    def test_restore_rejects_absolute_and_parent_paths(self):
        for path in ('../outside', 'modules/../../outside', 'modules/..',
                     str(self.root / 'absolute-project')):
            with self.subTest(path=path):
                result, output, commands, backup, stamp, project = self.workspace_restore(path, False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('invalid recorded module input overlay path', output)
                self.assertNotIn('Restoring previous module input overlay', output)
                self.assertTrue(backup.is_dir())
                self.assertTrue(stamp.is_file())
                self.assertNotIn('west build ', commands.read_text())

    def test_restore_allows_dots_inside_project_path(self):
        result, output, commands, backup, stamp, project = self.workspace_restore('modules/project..version', False)
        self.assertEqual(result.returncode, 71, output)
        self.assertIn('controlled build boundary reached', output)
        self.assertIn('west build ', commands.read_text())
        self.assertEqual((project / 'content.txt').read_text(), 'original project\n')
        self.assertFalse(backup.exists())
        self.assertFalse(stamp.exists())

    def test_cmake_argument_boundaries_reach_west(self):
        cases = [
            ({'cmake-args': "''"}, ['']),
            ({'cmake-args': "-DLEFT=1 '' -DRIGHT='two words' ''"},
             ['-DLEFT=1', '', '-DRIGHT=two words', '']),
            ({'cmake-args': ['-DNAME=two words', '-DSEMICOLON=a;b', '-DGLOB=*.conf',
                             '-DQUOTE=a"b', r'-DPATH=C:\space dir']},
             ['-DNAME=two words', '-DSEMICOLON=a;b', '-DGLOB=*.conf', '-DQUOTE=a"b',
              r'-DPATH=C:\space dir']),
            ({'cmake-args': ['  padded  ', '-DTAIL=two words  ']},
             ['  padded  ', '-DTAIL=two words  ']),
            ({'cmake-args': ['', '  padded  ', '-DTAIL=two words  ']},
             ['', '  padded  ', '-DTAIL=two words  ']),
            ({'cmake-args': ['-DBASE=1'], 'extra-cmake-args': ['', '  padded  ', '-DTAIL=two words  ']},
             ['-DBASE=1', '', '  padded  ', '-DTAIL=two words  ']),
            ({'cmake-args': ''}, []),
        ]
        for fields, expected in cases:
            with self.subTest(fields=fields):
                result, output, commands, *_ = self.workspace_restore(
                    'modules/project', False, document=dict(board='A', **fields))
                self.assertEqual(result.returncode, 71, output)
                records = [json.loads(line) for line in commands.with_suffix('.argv.jsonl').read_text().splitlines()]
                builds = [args for args in records if args[0] == 'build']
                self.assertEqual(len(builds), 1)
                args = builds[0][builds[0].index('--') + 1:]
                self.assertTrue(args[0].startswith('-DZMK_CONFIG='), args)
                self.assertEqual(args[1:], expected)

    def test_concurrent_workspace_reuse_stops_before_mutation(self):
        case = self.make_workspace(prior_overlay=False)
        reached, release = case.root / 'build-reached', case.root / 'build-release'
        west = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'west'
        text = west.read_text().replace('import json, os, pathlib, subprocess, sys',
                                        'import json, os, pathlib, subprocess, sys, time')
        text = text.replace("    status = int(os.environ.get('PROBE_BUILD_EXIT', '71'))", '''    if os.environ.get('PROBE_BLOCK_BUILD') == '1':
        pathlib.Path(os.environ['PROBE_REACHED']).touch()
        while not pathlib.Path(os.environ['PROBE_RELEASE']).exists(): time.sleep(.01)
    status = int(os.environ.get('PROBE_BUILD_EXIT', '71'))''')
        west.write_text(text)
        first_env = dict(case.env, PROBE_BUILD_EXIT='0', PROBE_BLOCK_BUILD='1',
                         PROBE_REACHED=str(reached), PROBE_RELEASE=str(release))
        first = subprocess.Popen(['bash', str(BUILD), 'build'], env=first_env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not reached.exists() and time.monotonic() < deadline:
                self.assertIsNone(first.poll())
                time.sleep(.01)
            self.assertTrue(reached.exists())
            other = case.root / 'other-source'
            shutil.copytree(case.source, other)
            (other / 'build.yaml').write_text('board: B\n')
            second_env = dict(case.env, SOURCE_DIR=str(other), OUTPUT_DIR=str(case.root / 'other-output'),
                              PROBE_BUILD_EXIT='0')
            prior_calls = case.commands.read_text()
            second = subprocess.run(['bash', str(BUILD), 'build'], env=second_env,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr +
                                '\nActive build intermediate remains: ' +
                                str((case.workspace / '.build/A-zmk/intermediate.o').exists()))
            self.assertIn('workspace is already in use', second.stdout + second.stderr)
            self.assertEqual(case.commands.read_text(), prior_calls)
            self.assertTrue((case.workspace / '.build/A-zmk/intermediate.o').exists())
            release.touch()
            output, _ = first.communicate(timeout=5)
            self.assertEqual(first.returncode, 0, output)
            # A completed process releases the lease even if its container is retained.
            again = subprocess.run(['bash', str(BUILD), 'build'], env=second_env,
                                   capture_output=True, text=True, timeout=5)
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        finally:
            release.touch()
            try: os.killpg(first.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            if first.poll() is None: first.wait(timeout=3)

    def test_parallel_failure_count_and_remaining_queue(self):
        # A partial batch, cancellation of queued work, then the first 8-bit wrap boundary.
        for total, jobs, started in ((1, 2, 1), (3, 2, 2), (256, 256, 256)):
            with self.subTest(total=total, jobs=jobs):
                document = {'include': [{'board': 'A', 'artifact-name': 'target-%03d' % i}
                                        for i in range(total)]}
                result, output, commands, *_ = self.workspace_restore(
                    'modules/project', False, document=document, jobs=jobs)
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn('%d target build(s) failed' % started, output)
                self.assertNotIn('Build complete:', output)
                records = [json.loads(line) for line in commands.with_suffix('.argv.jsonl').read_text().splitlines()]
                builds = [args for args in records if args[0] == 'build']
                names = ['target-%03d' % i for i in range(started)]
                self.assertCountEqual([pathlib.Path(args[args.index('-d') + 1]).name for args in builds], names)
                self.assertEqual(re.findall(r'ERROR: target failed: (target-\d+)', output), names)

    def test_target_cleanup_on_success_compile_and_artifact_failure(self):
        for jobs in (1, 2):
            for failure in ('none', 'compile', 'missing', 'copy'):
                with self.subTest(jobs=jobs, failure=failure):
                    document = {'include': [{'board': 'A', 'artifact-name': 'cleanup-%d' % i}
                                            for i in range(3)]}
                    case = self.make_workspace(document=document, jobs=jobs, prior_overlay=False)
                    cache = case.root / 'compiler-cache'
                    cache.mkdir()
                    (cache / 'keep').write_text('reusable compiler result\n')
                    case.env.update(CCACHE_DIR=str(cache),
                                    PROBE_BUILD_EXIT='71' if failure == 'compile' else '0')
                    if failure == 'missing':
                        case.env['PROBE_SKIP_FIRMWARE'] = '1'
                    if failure == 'copy':
                        fake_cp = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'cp'
                        fake_cp.write_text('\n'.join([
                            '#!/usr/bin/env python3', 'import os, sys',
                            'if any(arg.endswith(".uf2") for arg in sys.argv[1:]):',
                            '    print("injected firmware copy failure", file=sys.stderr)',
                            '    sys.exit(23)',
                            'os.execv(os.environ["PROBE_REAL_CP"], ["cp"] + sys.argv[1:])', '']))
                        fake_cp.chmod(0o755)
                        case.env['PROBE_REAL_CP'] = shutil.which('cp')
                    result, output = self.run_workspace(case)
                    if failure == 'none':
                        self.assertEqual(result.returncode, 0, output)
                        self.assertIn('Build complete: 3 target(s).', output)
                        self.assertEqual(len(list(pathlib.Path(case.env['OUTPUT_DIR']).glob('*.uf2'))), 3)
                    else:
                        self.assertNotEqual(result.returncode, 0, output)
                        self.assertNotIn('Build complete:', output)
                        if failure == 'compile' and jobs == 1:
                            self.assertEqual(result.returncode, 71, output)
                        if failure == 'missing':
                            self.assertIn('no firmware artifact found', output)
                        if failure == 'copy':
                            self.assertIn('injected firmware copy failure', output)
                    records = [json.loads(line) for line in case.commands.with_suffix('.argv.jsonl').read_text().splitlines()]
                    builds = [args for args in records if args[0] == 'build']
                    self.assertEqual(len(builds), 3 if failure == 'none' else jobs, output)
                    for args in builds:
                        self.assertFalse(pathlib.Path(args[args.index('-d') + 1]).exists(), output)
                    self.assertEqual((cache / 'keep').read_text(), 'reusable compiler result\n')
                    self.assertEqual((case.project / 'content.txt').read_text(), 'local override\n')

    def test_target_cleanup_failure_is_reported_without_masking_build_failure(self):
        for build_status in (0, 71):
            with self.subTest(build_status=build_status):
                case = self.make_workspace(prior_overlay=False)
                case.env['PROBE_BUILD_EXIT'] = str(build_status)
                fake_rm = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'rm'
                fake_rm.write_text('\n'.join([
                    '#!/usr/bin/env python3', 'import os, pathlib, sys',
                    'target = pathlib.Path(os.environ["PROBE_TARGET_BUILD"])',
                    'if str(target) in sys.argv[1:] and (target / "intermediate.o").exists():',
                    '    print("injected target cleanup failure", file=sys.stderr)',
                    '    sys.exit(23)',
                    'os.execv(os.environ["PROBE_REAL_RM"], ["rm"] + sys.argv[1:])', '']))
                fake_rm.chmod(0o755)
                build = case.workspace / '.build/A-zmk'
                case.env['PROBE_TARGET_BUILD'] = str(build)
                result, output = self.run_workspace(case)
                self.assertEqual(result.returncode, build_status or 1, output)
                self.assertIn('injected target cleanup failure', output)
                self.assertIn('failed to remove target build directory:', output)
                self.assertNotIn('Build complete:', output)
                self.assertTrue((build / 'intermediate.o').exists(), output)

    def test_unavailable_project_list_preserves_cache_until_update(self):
        for succeeds in (False, True):
            with self.subTest(update_succeeds=succeeds):
                case = self.make_workspace(prior_overlay=False,
                                           update_actions=[{'exit': 0 if succeeds else 23}])
                case.env['PROBE_LIST_FAILURE'] = 'before-update' if succeeds else 'always'
                cached = case.workspace / 'zmk/.git/cached-object'
                cached.parent.mkdir()
                cached.write_text('cached git object\n')
                (case.project / 'content.txt').write_text('cached project\n')
                stale = case.workspace / 'retired-cache'
                stale.mkdir()
                (stale / 'content.txt').write_text('unclassified until list resolves\n')
                result, output = self.run_workspace(case)
                self.assertTrue(cached.is_file(), output)
                self.assertEqual(cached.read_text(), 'cached git object\n')
                self.assertEqual(case.counter.read_text(), '1')
                if succeeds:
                    self.assertEqual(result.returncode, 71, output)
                    self.assertFalse(stale.exists())
                    self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
                    self.assertTrue(case.manifest_stamp.is_file())
                else:
                    self.assertNotIn(result.returncode, (0, 71), output)
                    self.assertEqual((case.project / 'content.txt').read_text(), 'cached project\n')
                    self.assertTrue(stale.is_dir())
                    self.assertFalse(case.manifest_stamp.exists())
                    self.assertNotIn('controlled build boundary reached', output)

    def test_partial_project_list_cannot_verify_failed_update(self):
        case = self.make_workspace(prior_overlay=False, local_override=True,
                                   update_actions=[{'exit': 23, 'failed': ['project']}])
        case.env['PROBE_LIST_FAILURE'] = 'formatted'
        result, output = self.run_workspace(case)
        self.assertNotIn(result.returncode, (0, 71), output)
        self.assertNotIn('controlled build boundary reached', output)
        self.assertIn('cannot verify workspace project list', output)
        self.assertEqual(case.counter.read_text(), '1')
        self.assertFalse(case.manifest_stamp.exists())
        # Recovery uses the same workspace after the list becomes complete.
        case.env.pop('PROBE_LIST_FAILURE')
        shutil.rmtree(case.inputs / 'project')
        control = json.loads(case.control.read_text())
        control['updates'] = [{'exit': 0}]
        case.control.write_text(json.dumps(control))
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')

    def test_pruning_complete_list_keeps_full_roots_and_removes_stale_once(self):
        case = self.make_workspace(project_path='module root/project', prior_overlay=False)
        stale = ['module', 'root', 'retired', '.retired']
        for name in stale:
            (case.workspace / name).mkdir()
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual((case.project / 'content.txt').read_text(), 'local override\n')
        for name in stale:
            with self.subTest(name=name):
                self.assertFalse((case.workspace / name).exists(), output)
                self.assertEqual(output.count('Removing stale workspace entry: ' + name + '\n'), 1)
        self.assertFalse(case.counter.exists())

    def test_recorded_overlay_restores_before_obsolete_root_is_pruned(self):
        case = self.make_workspace()
        case.env['PROBE_OMIT_PROJECT'] = '1'
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertFalse((case.workspace / 'modules').exists(), output)
        self.assertFalse(case.backup.exists())
        self.assertFalse(case.stamp.exists())
        self.assertFalse(case.counter.exists())
        self.assertLess(output.index('Restoring previous module input overlay'),
                        output.index('Removing stale workspace entry: modules'))

    def test_prune_removal_failure_stops_before_build(self):
        case = self.make_workspace(prior_overlay=False)
        stale = case.workspace / 'retired'
        stale.mkdir()
        fake_rm = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'rm'
        fake_rm.write_text('\n'.join([
            '#!/usr/bin/env python3', 'import os, sys',
            'if os.environ["PROBE_PRUNE_PATH"] in sys.argv[1:]:',
            '    sys.exit("injected stale-root removal failure")',
            'os.execv(os.environ["PROBE_REAL_RM"], ["rm"] + sys.argv[1:])', '']))
        fake_rm.chmod(0o755)
        case.env['PROBE_PRUNE_PATH'] = str(stale)
        result, output = self.run_workspace(case)
        self.assertNotIn(result.returncode, (0, 71), output)
        self.assertIn('injected stale-root removal failure', output)
        self.assertNotIn('controlled build boundary reached', output)
        self.assertTrue(stale.is_dir())

    def test_west_update_attempts_reaches_container(self):
        self.assertEqual(os.environ.get('ZMK_WEST_UPDATE_ATTEMPTS'), '2')

    def test_update_retry_clears_locks_and_reuses_completed_cache(self):
        case = self.make_workspace(prior_overlay=False, force_update=True, attempts=2,
                                   update_actions=[{'exit': 23, 'failed': ['project'], 'new_lock': True},
                                                   {'exit': 0}])
        case.lock.parent.mkdir(parents=True)
        case.lock.write_text('initial stale lock\n')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertIn('Retrying west update (2/2)', output)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertFalse(case.lock.exists())
        self.assertEqual(case.manifest_stamp.read_text(), case.ready + '\n')
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')

    def test_failed_update_retries_even_when_partial_checkout_is_nonempty(self):
        case = self.make_workspace(prior_overlay=False,
                                   update_actions=[{'exit': 23, 'failed': ['project'], 'partial': True}, {'exit': 0}])
        shutil.rmtree(case.project)
        result, output = self.run_workspace(case)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('controlled build boundary reached', output)
        with self.subTest(stage='failed update must invalidate marker'):
            self.assertFalse(case.manifest_stamp.exists())
        self.assertEqual((case.project / 'content.txt').read_text(), 'partial project\n')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
        self.assertEqual(case.manifest_stamp.read_text(), case.ready + '\n')

    def test_local_override_after_failed_update_requires_upstream_recovery(self):
        case = self.make_workspace(prior_overlay=False, local_override=True,
                                   update_actions=[{'exit': 23, 'failed': ['project'], 'partial': True}, {'exit': 0}])
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertIn('failed project(s) were supplied locally: project', output)
        self.assertEqual((case.project / 'content.txt').read_text(), 'explicit local project\n')
        with self.subTest(stage='override must not verify failed upstream'):
            self.assertFalse(case.manifest_stamp.exists())
        shutil.rmtree(case.inputs / 'project')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
        self.assertEqual(case.manifest_stamp.read_text(), case.ready + '\n')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')

    def test_unknown_or_uncovered_update_failure_stops_with_override(self):
        for failed, diagnostic in ((None, 'potentially stale dependencies'),
                                    (['zmk'], 'without local override: zmk'),
                                    (['project', 'zmk'], 'without local override: zmk')):
            with self.subTest(failed=failed):
                case = self.make_workspace(prior_overlay=False, local_override=True,
                                           update_actions=[{'exit': 23, 'failed': failed}])
                result, output = self.run_workspace(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, output)
                self.assertNotIn('controlled build boundary reached', output)
                self.assertFalse(case.manifest_stamp.exists())

    def test_update_failure_identity_comes_from_final_attempt(self):
        plans = [
            ([{'exit': 23, 'failed': ['project']}, {'exit': 23}], False),
            ([{'exit': 23, 'failed': ['zmk']},
              {'exit': 23, 'failed': ['project'], 'partial': True}], True),
        ]
        for actions, allowed in plans:
            with self.subTest(actions=actions):
                case = self.make_workspace(prior_overlay=False, local_override=True,
                                           update_actions=actions, attempts=2)
                result, output = self.run_workspace(case)
                self.assertEqual(case.counter.read_text(), '2')
                if allowed:
                    self.assertEqual(result.returncode, 71, output)
                    self.assertIn('failed project(s) were supplied locally: project', output)
                    self.assertEqual((case.project / 'content.txt').read_text(), 'explicit local project\n')
                    self.assertEqual((case.workspace / 'zmk/content.txt').read_text(), 'resolved zmk\n')
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('potentially stale dependencies', output)
                    self.assertNotIn('controlled build boundary reached', output)
                self.assertFalse(case.manifest_stamp.exists())

    def test_interrupted_overlay_apply_is_restored_on_next_build(self):
        case = self.make_workspace(prior_overlay=False, local_override=True, update_actions=[{'exit': 0}])
        case.env['PROBE_FAIL_APPLY'] = '1'
        result, output = self.run_workspace(case)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('injected module overlay apply failure', output)
        self.assertNotIn('controlled build boundary reached', output)
        self.assertEqual((case.backup / 'content.txt').read_text(), 'resolved project\n')
        with self.subTest(stage='recovery must be recorded before copying'):
            self.assertTrue(case.stamp.exists())
        shutil.rmtree(case.inputs / 'project')
        case.env['PROBE_FAIL_APPLY'] = '0'
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
        self.assertFalse(case.stamp.exists())
        self.assertFalse(case.backup.exists())
        self.assertEqual(case.counter.read_text(), '1')

    def test_legacy_manifest_marker_requires_reverification(self):
        for prefix in ('', 'complete:'):
            with self.subTest(prefix=prefix):
                case = self.make_workspace(prior_overlay=False, update_actions=[{'exit': 0}])
                # Both older formats hashed only the entry manifest, without resolving imports.
                case.manifest_stamp.write_text(prefix + case.digest + '\n')
                (case.project / 'content.txt').write_text('unverified legacy checkout\n')
                result, output = self.run_workspace(case)
                self.assertEqual(result.returncode, 71, output)
                self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
                self.assertEqual(case.counter.read_text(), '1')
                self.assertEqual(case.manifest_stamp.read_text(), case.ready + '\n')

    def imported_manifest_workspace(self):
        case = self.make_workspace(prior_overlay=False, update_actions=[{'exit': 0}])
        case.env['PROBE_RESOLVE_REAL'] = '1'
        # The selected image's real west resolves local imports; no network is used.
        (case.workspace / '.west/config').write_text('[manifest]\npath = config\n')
        manifest = 'manifest: {self: {path: config, import: dependencies.yml}}\n'
        imported = {'manifest': {'projects': [
            {'name': 'zmk', 'url': 'https://invalid.test/zmk', 'revision': 'v1', 'path': 'zmk'},
            {'name': 'project', 'url': 'https://invalid.test/project',
             'revision': 'v1', 'path': 'modules/project'}]}}
        for directory in (case.source, case.workspace):
            (directory / 'config/west.yml').write_text(manifest)
            (directory / 'config/dependencies.yml').write_text(yaml.safe_dump(imported))
        return case, imported

    def test_local_manifest_import_change_invalidates_cache(self):
        case, imported = self.imported_manifest_workspace()
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '1')
        original_stamp = case.manifest_stamp.read_text()
        original_manifest = (case.source / 'config/west.yml').read_bytes()
        imported['manifest']['projects'][1]['revision'] = 'v2'
        (case.source / 'config/dependencies.yml').write_text(yaml.safe_dump(imported))
        (case.project / 'content.txt').write_text('old imported dependency\n')
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual((case.source / 'config/west.yml').read_bytes(), original_manifest)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertEqual((case.project / 'content.txt').read_text(), 'resolved project\n')
        self.assertNotEqual(case.manifest_stamp.read_text(), original_stamp)
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '2')

    def test_unresolved_manifest_does_not_mark_cache_ready(self):
        case, imported = self.imported_manifest_workspace()
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        (case.source / 'config/dependencies.yml').write_text('manifest: {projects: [}\n')
        result, output = self.run_workspace(case)
        self.assertNotEqual(result.returncode, 71, output)
        self.assertNotEqual(result.returncode, 0, output)
        self.assertNotIn('controlled build boundary reached', output)
        self.assertIn('failed to resolve west manifest', output)
        self.assertEqual(case.counter.read_text(), '2')
        self.assertFalse(case.manifest_stamp.exists())
        # Repairing the import must recover without deleting the workspace.
        (case.source / 'config/dependencies.yml').write_text(yaml.safe_dump(imported))
        result, output = self.run_workspace(case)
        self.assertEqual(result.returncode, 71, output)
        self.assertEqual(case.counter.read_text(), '3')
        self.assertTrue(case.manifest_stamp.is_file())

    def test_windows_clone_pruning(self):
        root = pathlib.Path('/tmp/windows-copy')
        root.mkdir()
        keep = ['keep.txt', 'nested/valid name.txt', 'nested/COM0.txt',
                'nested/my..file.txt', 'unicode-名前.txt', 'DEL-\x7f.txt', 'COM⁴.txt']
        bad = ['tail ', 'tail.', 'CON.txt', 'lpt1.extra', 'bad:colon', 'bad?name',
               'bad*name', 'bad"quote', 'bad<name', 'bad>name', 'bad|name',
               'bad\\name', 'bad\nline', 'bad\tcontrol', 'bad\x01control',
               'bad-dir./child.txt', 'nested/NUL', 'COM¹', 'Lpt².txt', 'COM³']
        for name in keep + bad:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'clone payload\n')
        command = ['bash', '-c', 'source "$1"; prune_windows_clone_paths "$2" fixture',
                   '_', '/tmp/source-common.sh', str(root)]
        result = subprocess.run(command, capture_output=True, text=True)
        print(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()), sorted(keep))
        for name in keep:
            self.assertEqual((root / name).read_bytes(), b'clone payload\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
