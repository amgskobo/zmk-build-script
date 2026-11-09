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
    def run_directory(self, output):
        paths = [line[len('Run directory: '):] for line in ANSI.sub('', output).splitlines()
                 if line.startswith('Run directory: ')]
        self.assertEqual(len(paths), 1, output)
        path = pathlib.Path(paths[0])
        self.assertRegex(path.name, r'^run-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-[a-z0-9_-]+$')
        return path

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
                    for kind in ('repo', 'pinned-repo', 'path'):
                        with self.subTest(step=step['name'], mode=mode,
                                          pristine=pristine, kind=kind):
                            source_type = 'repo' if kind == 'pinned-repo' else kind
                            revision = '1' * 40 if kind == 'pinned-repo' else ''
                            source = ('https://example.invalid/config.git' if source_type == 'repo'
                                      else str(self.root / 'source with spaces'))
                            env = dict(os.environ, EXTERNAL_MODE=mode, EXTERNAL_BUILD_JOBS='2',
                                       EXTERNAL_PRISTINE=pristine, SOURCE_INDEX='0002',
                                       WORKFLOW_ARGV=str(self.root / 'workflow.argv'))
                            sources = self.root / 'sources.txt'
                            sources.write_text('repo:https://example.invalid/unselected.git\n' + source_type + ':' + source +
                                               (' ' + revision if revision else '') + '\n')
                            (self.root / '.build/ci-source-file').write_text(str(sources))
                            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', step['run']],
                                                    cwd=self.root, env=env, capture_output=True)
                            self.assertEqual(result.returncode, 0, result.stderr.decode())
                            record = (self.root / '.build/ci-source.record').read_text().strip()
                            actual = (self.root / 'workflow.argv').read_bytes().decode().rstrip('\0').split('\0')
                            expected = ['--' + source_type, source]
                            if revision:
                                expected += ['--revision', revision]
                            expected += ['--source-slug',
                                         'config' if source_type == 'repo' else 'source-with-spaces',
                                         '--mode', mode, '--jobs', '2']
                            if pristine == 'true':
                                expected.append('--pristine')
                            self.assertEqual(actual, expected)
                            self.assertNotIn('unselected.git', (self.root / record).read_text())
                            self.assertNotIn(source, result.stdout.decode())

    def test_external_clone_pins_commit_after_default_branch_advances(self):
        # Run the production clone command with real Git. Only Docker transport is local.
        source_tree = pathlib.Path('/tmp/source')
        self.assertFalse(source_tree.exists(), 'clone transport needs an unowned path to be absent')
        self.addCleanup(lambda: shutil.rmtree(source_tree) if source_tree.exists() else None)
        repository = self.root / 'upstream'
        repository.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repository), *args], text=True).strip()
        git('init', '-q')
        marker = repository / 'marker.txt'
        revisions = []
        for value in ('original', 'advanced'):
            marker.write_text(value)
            git('add', 'marker.txt')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-qm', value)
            revisions.append(git('rev-parse', 'HEAD'))
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['CLONE_TRANSPORT'])
with (root / 'calls.jsonl').open('a') as out: out.write(json.dumps(args) + '\\n')
if args[0] == 'create':
    (root / 'command.json').write_text(json.dumps(args[args.index('/bin/bash'):]))
    print('a' * 64)
elif args[0] == 'start':
    sys.exit(subprocess.call(json.loads((root / 'command.json').read_text())))
elif args[0] == 'cp':
    shutil.copytree('/tmp/source', args[-1], dirs_exist_ok=True)
elif args[0] == 'rm':
    if pathlib.Path('/tmp/source').exists(): shutil.rmtree('/tmp/source')
else: sys.exit(99)
''')
        docker.chmod(0o755)
        work = self.root / 'clones'
        work.mkdir()
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   CLONE_TRANSPORT=str(self.root), ZMK_EXTERNAL_CLONE_ATTEMPTS='2')
        for requested, expected in ((revisions[0], 'original'), ('', 'advanced'), ('0' * 40, None)):
            with self.subTest(requested=requested):
                (self.root / 'calls.jsonl').write_text('')
                result = subprocess.run(['bash', '-c',
                    'source /tmp/build-external-source.sh; WORK_DIR="$1"; SOURCE_REVISION="$2"; '
                    'clone_repo_with_docker "$3" fixture "$1/checkout"',
                    '_', str(work), requested, repository.as_uri()], env=env, text=True, capture_output=True)
                output = result.stdout + result.stderr
                print(output, end='')
                calls = [json.loads(row) for row in (self.root / 'calls.jsonl').read_text().splitlines()]
                if expected is None:
                    self.assertNotEqual(result.returncode, 0, output)
                    self.assertFalse((work / 'checkout').exists())
                    self.assertEqual([args[0] for args in calls], ['create', 'start', 'rm'] * 2)
                    self.assertNotIn('Source revision:', output)
                else:
                    self.assertEqual(result.returncode, 0, output)
                    self.assertEqual((work / 'checkout/marker.txt').read_text(), expected)
                    actual = subprocess.check_output(['git', '-C', str(work / 'checkout'),
                                                       'rev-parse', 'HEAD'], text=True).strip()
                    self.assertEqual(actual, requested or revisions[1])
                    self.assertIn('Source revision: ' + actual, output)
                    self.assertEqual([args[0] for args in calls], ['create', 'start', 'cp', 'rm'])
                self.assertFalse(source_tree.exists(), 'clone cleanup left its owned tree behind')

    def test_container_build_log_capture_waits_and_requires_completion(self):
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
counter = pathlib.Path(os.environ['LOG_READ_COUNT'])
count = int(counter.read_text()) + 1
counter.write_text(str(count))
assert sys.argv[1:] == ['logs', 'a' * 64]
print('compile output', count)
if os.environ['LOG_MODE'] == 'read-failure': sys.exit(23)
if os.environ['LOG_MODE'] == 'delayed' and count >= 3: print('Build complete: 2 target(s).')
''')
        docker.chmod(0o755)
        sleep = binary / 'sleep'
        sleep.write_text('#!/bin/sh\n[ "$1" = 1 ]\n')
        sleep.chmod(0o755)
        counter = self.root / 'reads'
        output = self.root / 'stream.log'
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   LOG_READ_COUNT=str(counter), LOG_MODE='delayed')
        counter.write_text('0')
        # Named control: the old single read rejects the deliberately delayed marker.
        control = subprocess.run(['bash', '-c',
            'docker logs "$1" > "$2"; grep -F "Build complete: 2 target(s)." "$2"',
            '_', 'a' * 64, str(output)], env=env, capture_output=True)
        self.assertEqual(control.returncode, 1)
        self.assertEqual(counter.read_text(), '1')
        self.assertEqual(output.read_text(), 'compile output 1\n')
        for mode, reads, message in (
                ('delayed', '3', 'Build complete: 2 target(s).'),
                ('never', '10', 'Timed out waiting for the container build log completion marker.'),
                ('read-failure', '1', 'Failed to read the container build log.')):
            with self.subTest(mode=mode):
                counter.write_text('0')
                env['LOG_MODE'] = mode
                destination = self.root / (mode + '.log')
                result = subprocess.run(['bash', '-c',
                    'source /tmp/test-build-fixtures.sh; capture_container_build_stream "$1" "$2" "$3"',
                    '_', 'a' * 64, str(destination), 'Build complete: 2 target(s).'],
                    env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0 if mode == 'delayed' else 1, result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertEqual(counter.read_text(), reads)
                snapshots = list(self.root.glob(mode + '.log.attempt-*'))
                self.assertEqual(len(snapshots), int(reads))
                self.assertEqual(destination.read_bytes(), (self.root / (mode + '.log.attempt-' + reads)).read_bytes())

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
                steps = job.get('steps', [])
                if any('check-build-output.sh ci-' in s.get('run', '') for s in steps):
                    archives = [s for s in steps if 'check-build-output.sh ci-archive' in s.get('run', '')]
                    self.assertTrue(archives, path)
                    self.assertTrue(all('always()' in s['if'] for s in archives))
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

    def test_self_hosted_workflow_preserves_and_quotes_build_inputs(self):
        workflow = yaml.load(pathlib.Path('/tmp/workflows/self-hosted-build.yml').read_text(),
                             Loader=yaml.BaseLoader)
        inputs = workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(inputs['profile']['type'], 'boolean')
        self.assertEqual(inputs['profile']['default'], 'false')
        self.assertEqual(workflow['env']['ZMK_TEST_PROFILE'], "${{ inputs.profile && '1' || '0' }}")
        for name in ('build_image', 'docker_platform', 'target_jobs', 'compiler_jobs', 'test_jobs'):
            self.assertIn(name, inputs)
            self.assertEqual(inputs[name]['type'], 'string')
            self.assertEqual(inputs[name]['default'], '')
        self.assertEqual(workflow['env']['BUILD_IMAGE_INPUT'], '${{ inputs.build_image }}')
        self.assertEqual(workflow['env']['DOCKER_PLATFORM_INPUT'], '${{ inputs.docker_platform }}')
        self.assertEqual(workflow['env']['TARGET_JOBS_INPUT'], '${{ inputs.target_jobs }}')
        self.assertEqual(workflow['env']['COMPILER_JOBS_INPUT'], '${{ inputs.compiler_jobs }}')
        self.assertEqual(workflow['env']['TEST_JOBS_INPUT'], '${{ inputs.test_jobs }}')
        folder = self.root / '.github/scripts'
        folder.mkdir(parents=True)
        (folder / 'check-build-output.sh').write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            'printf "%s\\0" "$ZMK_BUILD_IMAGE" "$ZMK_DOCKER_PLATFORM" "$ZMK_BUILD_JOBS" '
            '"$CMAKE_BUILD_PARALLEL_LEVEL" "$ZMK_TEST_JOBS" "$@" >> "$WORKFLOW_CAPTURE"\n')
        calls = self.root / 'calls'
        marker = self.root / 'must-not-execute'
        executions = 0
        for job_id, os_label in (('macos', 'macOS'), ('windows', 'Windows'), ('linux', 'Linux')):
            job = workflow['jobs'][job_id]
            self.assertEqual(job['runs-on'], ['self-hosted', os_label, 'zmk-docker', 'zmk-docker-active'])
            shell = job['defaults']['run']['shell']
            if job_id == 'macos': self.assertTrue(shell.startswith('/bin/bash '), shell)
            if job_id == 'windows': self.assertTrue(shell.startswith('C:\\Progra~1\\Git\\bin\\bash.exe '), shell)
            step = next(s for s in job['steps'] if s.get('name') == 'Verify shell and Docker contracts')
            self.assertNotIn('${{', step['run'])
            for mode in ('validate', 'build'):
                for supplied in ('', 'synthetic.invalid/build@sha256:' + '1' * 64,
                                 'synthetic.invalid/build:tag $(touch %s)\n"literal"' % marker):
                    with self.subTest(job=job_id, mode=mode, supplied=supplied):
                        calls.write_bytes(b'')
                        platform = 'linux/amd64' if supplied else ''
                        jobs = '2' if supplied and supplied.endswith('1' * 64) else supplied
                        env = dict(os.environ, BUILD_MODE=mode, BUILD_IMAGE_INPUT=supplied,
                                   DOCKER_PLATFORM_INPUT=platform, ZMK_BUILD_IMAGE='synthetic.invalid/retained:v1',
                                   ZMK_DOCKER_PLATFORM='linux/arm64', TARGET_JOBS_INPUT=jobs,
                                   COMPILER_JOBS_INPUT=jobs, ZMK_BUILD_JOBS='3',
                                   CMAKE_BUILD_PARALLEL_LEVEL='4', TEST_JOBS_INPUT=jobs,
                                   ZMK_TEST_JOBS='5', WORKFLOW_CAPTURE=str(calls))
                        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', step['run']],
                                                cwd=self.root, env=env, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        expected = []
                        for selection in (('all',) if mode == 'build' else ('shell', 'docker')):
                            expected += [supplied or 'synthetic.invalid/retained:v1',
                                         platform or 'linux/arm64', jobs or '3', jobs or '4',
                                         jobs or '5', 'ci-tests', selection]
                        actual = calls.read_bytes().decode().split('\0')
                        self.assertEqual(actual, expected + [''])
                        self.assertFalse(marker.exists(), 'input was executed as shell code')
                        executions += 1
        self.assertEqual(executions, 18)

    def test_self_hosted_workflow_checks_docker_before_native_suite(self):
        workflow = yaml.load(pathlib.Path('/tmp/workflows/self-hosted-build.yml').read_text(),
                             Loader=yaml.BaseLoader)
        folder = self.root / '.github/scripts'
        folder.mkdir(parents=True)
        (folder / 'check-build-output.sh').write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            'printf "%s\\0" "$@" >> "$WORKFLOW_CAPTURE"\n'
            'if [ "$1" = ci-tools ]; then exit "$PREFLIGHT_STATUS"; fi\n')
        calls = self.root / 'calls'
        executions = 0
        for job_id in ('macos', 'windows', 'linux'):
            steps = workflow['jobs'][job_id]['steps']
            preflights = [s for s in steps if s.get('name') == 'Check Docker access']
            self.assertEqual(len(preflights), 1, 'native Docker preflight is missing')
            preflight = preflights[0]
            suite = next(s for s in steps if s.get('name') == 'Verify shell and Docker contracts')
            initialize = next(s for s in steps if s.get('id') == 'publication-init')
            self.assertLess(steps.index(initialize), steps.index(preflight))
            self.assertLess(steps.index(preflight), steps.index(suite))
            self.assertEqual(preflight['run'], 'bash .github/scripts/check-build-output.sh ci-tools')
            self.assertNotIn('if', preflight)
            self.assertNotIn('continue-on-error', preflight)
            for mode in ('validate', 'build'):
                for status in (0, 127):
                    with self.subTest(job=job_id, mode=mode, status=status):
                        calls.write_bytes(b'')
                        env = dict(os.environ, BUILD_MODE=mode, BUILD_IMAGE_INPUT='',
                                   DOCKER_PLATFORM_INPUT='', TARGET_JOBS_INPUT='', COMPILER_JOBS_INPUT='',
                                   TEST_JOBS_INPUT='',
                                   PREFLIGHT_STATUS=str(status),
                                   WORKFLOW_CAPTURE=str(calls))
                        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                                 preflight['run'] + '\n' + suite['run']],
                                                cwd=self.root, env=env, capture_output=True)
                        self.assertEqual(result.returncode, status, result.stderr.decode())
                        expected = ['ci-tools']
                        if status == 0:
                            for selection in (('all',) if mode == 'build' else ('shell', 'docker')):
                                expected += ['ci-tests', selection]
                        self.assertEqual(calls.read_bytes().decode().split('\0'), expected + [''])
                        executions += 1
        self.assertEqual(executions, 12)

    def make_image_selection_daemon(self):
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
calls = pathlib.Path(os.environ["IMAGE_CALLS"])
with calls.open("a") as out: out.write(json.dumps(args) + "\\n")
if args[0] == "create":
    count = sum(json.loads(row)[0] == "create" for row in calls.read_text().splitlines())
    print(chr(96 + count) * 64)
elif args[0] == "exec":
    if "python3" in args:
        sys.exit(subprocess.call(args[args.index("python3"):]))
    if any("./build.sh validate" in arg for arg in args): print("build.yaml is valid.")
    else: sys.stdin.buffer.read()
elif args[0] == "rm":
    if os.environ.get("IMAGE_REMOVE_FAIL"): sys.exit(23)
    if os.environ.get("IMAGE_REMOVE_GATE"):
        pathlib.Path(os.environ["IMAGE_REMOVE_GATE"]).touch()
        while not pathlib.Path(os.environ["IMAGE_REMOVE_RELEASE"]).exists(): time.sleep(.01)
elif args[0] != "start": sys.exit(99)
''')
        docker.chmod(0o755)
        return binary

    def test_auto_image_selection_uses_west_manifest_structure(self):
        binary = self.make_image_selection_daemon()
        documents = [
            ('name-first', 'manifest:\n  projects:\n    - name: zmk\n      url: https://example.invalid/zmk\n      revision: v0.3-branch+dya\n', '3.5-branch'),
            ('name-second', 'manifest:\n  projects:\n    - url: https://example.invalid/zmk\n      name: zmk\n      revision: v0.3-branch+dya\n', '3.5-branch'),
            ('inline', 'manifest: {projects: [{url: https://example.invalid/zmk, revision: "v4.1.0-rc1", name: zmk}]}\n', '4.1-branch'),
            ('defaults', 'manifest: {defaults: {revision: v0.3.9}, projects: [{url: https://example.invalid/zmk, name: zmk}]}\n', '3.5-branch'),
            ('quoted', '"manifest": {"projects": [{"name": zmk, "url": https://example.invalid/zmk, "revision": main}]}\n', 'stable'),
            ('standalone', 'manifest: {projects: []}\n', 'stable'),
        ]
        from west.manifest import ImportFlag, Manifest
        for name, document, tag in documents:
            with self.subTest(name=name):
                # Validate the input independently of the builder's shell transport.
                Manifest.from_data(yaml.safe_load(document), import_flags=ImportFlag.IGNORE)
                case = self.root / name
                (case / 'config').mkdir(parents=True)
                (case / 'config/west.yml').write_text(document)
                (case / 'build.yaml').write_text('board: A\n')
                calls = case / 'calls'
                env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                           ZMK_IN_CONTAINER='0', ZMK_BUILD_IMAGE_TAG='auto',
                           ZMK_BUILD_IMAGE_REPOSITORY='synthetic/build', ZMK_KEEP_CONTAINER='0',
                           IMAGE_CALLS=str(calls))
                env.pop('ZMK_BUILD_IMAGE', None)
                completed = subprocess.run(['bash', str(BUILD), 'validate', str(case)], env=env,
                                           text=True, capture_output=True, timeout=15)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                commands = [json.loads(row) for row in calls.read_text().splitlines()]
                images = [row[-4] for row in commands if row[0] == 'create']
                self.assertEqual(images[-1], 'synthetic/build:' + tag)
                created = [chr(97 + i) * 64 for i in range(len(images))]
                removed = [row[-1] for row in commands if row[0] == 'rm']
                self.assertEqual(removed, created)

    def test_auto_image_selection_failure_stops_before_copy_or_replacement(self):
        binary = self.make_image_selection_daemon()
        for name, document, extra, reason in (
            ('invalid', 'manifest: {projects: false}\n', {}, 'manifest image selection failed'),
            ('cleanup', 'manifest: {projects: [{name: zmk, url: https://example.invalid/zmk, revision: v0.3}]}\n',
             {'IMAGE_REMOVE_FAIL': '1'}, 'image selection container cleanup failed'),
        ):
            with self.subTest(name=name):
                case = self.root / name
                (case / 'config').mkdir(parents=True)
                (case / 'config/west.yml').write_text(document)
                (case / 'build.yaml').write_text('board: A\n')
                calls = case / 'calls'
                env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                           ZMK_IN_CONTAINER='0', ZMK_BUILD_IMAGE_TAG='auto', IMAGE_CALLS=str(calls),
                           ZMK_KEEP_CONTAINER='1', **extra)
                env.pop('ZMK_BUILD_IMAGE', None)
                completed = subprocess.run(['bash', str(BUILD), 'validate', str(case)], env=env,
                                           text=True, capture_output=True, timeout=10)
                self.assertNotEqual(completed.returncode, 0)
                commands = [json.loads(row) for row in calls.read_text().splitlines()]
                self.assertEqual(sum(row[0] == 'create' for row in commands), 1)
                self.assertFalse(any('tar' in row or any('./build.sh validate' in arg for arg in row)
                                     for row in commands))
                summaries = [p for p in (BUILD.parent / '.build').glob('*/build-summary.txt')
                             if 'Target: ' + str(case) + '\n' in p.read_text()]
                self.assertEqual(len(summaries), 1)
                self.assertIn('Status: FAILED', summaries[0].read_text())
                self.assertIn('Reason: ' + reason, summaries[0].read_text())

    def test_auto_image_override_skips_manifest_inspection(self):
        binary = self.make_image_selection_daemon()
        (self.root / 'build.yaml').write_text('board: A\n')
        for name, override, tag, expected in (
            ('full', 'synthetic/build@sha256:' + 'd' * 64, 'auto', 'synthetic/build@sha256:' + 'd' * 64),
            ('tag', '', '3.5-branch', 'synthetic/build:3.5-branch'),
        ):
            with self.subTest(name=name):
                calls = self.root / (name + '.calls')
                env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                           ZMK_IN_CONTAINER='0', ZMK_BUILD_IMAGE=override, ZMK_BUILD_IMAGE_TAG=tag,
                           ZMK_BUILD_IMAGE_REPOSITORY='synthetic/build', ZMK_KEEP_CONTAINER='0',
                           IMAGE_CALLS=str(calls))
                completed = subprocess.run(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                           text=True, capture_output=True, timeout=10)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                commands = [json.loads(row) for row in calls.read_text().splitlines()]
                self.assertEqual([row[-4] for row in commands if row[0] == 'create'], [expected])
                self.assertFalse(any('python3' in row for row in commands))

    def test_compiler_jobs_host_validation_and_container_forwarding(self):
        binary = self.make_image_selection_daemon()
        (self.root / 'build.yaml').write_text('board: A\n')
        for index, value in enumerate((None, '', '2', '0002', '10', '0', '00', '-1', '1.5', ' 2', '2\n', 'bad')):
            with self.subTest(value=value):
                calls = self.root / ('compiler-%d.calls' % index)
                env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                           ZMK_IN_CONTAINER='0', ZMK_BUILD_IMAGE='synthetic/build:fixed',
                           ZMK_KEEP_CONTAINER='0', IMAGE_CALLS=str(calls))
                env.pop('CMAKE_BUILD_PARALLEL_LEVEL', None)
                if value is not None: env['CMAKE_BUILD_PARALLEL_LEVEL'] = value
                result = subprocess.run(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                        text=True, capture_output=True, timeout=15)
                valid = value in (None, '', '2', '0002', '10')
                self.assertEqual(result.returncode, 0 if valid else 1, result.stdout + result.stderr)
                if not valid:
                    self.assertIn('CMAKE_BUILD_PARALLEL_LEVEL must be a positive integer', result.stderr)
                    self.assertFalse(calls.exists(), 'invalid compiler count reached Docker')
                    continue
                commands = [json.loads(row) for row in calls.read_text().splitlines()]
                create = next(row for row in commands if row[0] == 'create')
                compiler_env = [arg for arg in create if arg.startswith('CMAKE_BUILD_PARALLEL_LEVEL=')]
                expected = [] if not value else ['CMAKE_BUILD_PARALLEL_LEVEL=' + value.lstrip('0')]
                self.assertEqual(compiler_env, expected, 'host override must reach Docker without replacing image defaults')
                if compiler_env: self.assertEqual(create[create.index(compiler_env[0]) - 1], '-e')

    def test_auto_image_switch_cancellation_finishes_bootstrap_cleanup(self):
        binary = self.make_image_selection_daemon()
        (self.root / 'config/west.yml').write_text(
            'manifest: {projects: [{name: zmk, url: https://example.invalid/zmk, revision: v0.3}]}\n')
        (self.root / 'build.yaml').write_text('board: A\n')
        calls, gate, release = (self.root / name for name in ('calls', 'gate', 'release'))
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   ZMK_IN_CONTAINER='0', ZMK_BUILD_IMAGE_TAG='auto', ZMK_KEEP_CONTAINER='1',
                   IMAGE_CALLS=str(calls), IMAGE_REMOVE_GATE=str(gate), IMAGE_REMOVE_RELEASE=str(release))
        env.pop('ZMK_BUILD_IMAGE', None)
        process = subprocess.Popen(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                   start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 5
            while not gate.exists() and time.monotonic() < deadline:
                self.assertIsNone(process.poll())
                time.sleep(.01)
            self.assertTrue(gate.exists())
            os.killpg(process.pid, signal.SIGTERM)
            release.touch()
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, output)
            commands = [json.loads(row) for row in calls.read_text().splitlines()]
            self.assertEqual(sum(row[0] == 'create' for row in commands), 1)
            self.assertEqual([row for row in commands if row[0] == 'rm'], [['rm', '-f', 'a' * 64]])
            summary = (self.run_directory(output) / 'build-summary.txt').read_text()
            self.assertIn('Status: FAILED', summary)
            self.assertIn('Reason: interrupted by SIGTERM', summary)
        finally:
            release.touch()
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            if process.poll() is None: process.wait(timeout=5)

    def external_cancellation_fixture(self, name):
        case = self.root / name
        (case / 'scripts').mkdir(parents=True)
        for script in ('auto-build-external.sh', 'build-external-source.sh', 'source-common.sh'):
            shutil.copyfile('/tmp/' + script, case / 'scripts' / script)
        builder = case / 'build.sh'
        builder.write_text('''#!/usr/bin/env bash
set -eu
target="$1"
child=""
finish() {
    trap '' INT TERM
    [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
    [ -z "$child" ] || wait "$child" 2>/dev/null || true
    : > "$target/cleanup-complete"
    exit 143
}
trap finish TERM
printf '%s\\n' "$$" > "$target/builder.pid"
sleep 30 &
child=$!
: > "$target/started"
wait "$child"
''')
        builder.chmod(0o755)
        for number in range(3):
            (case / str(number)).mkdir()
        return case

    def test_external_queue_cancellation_stops_active_workers_before_return(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                case = self.external_cancellation_fixture('queue-' + str(signum))
                args = ['bash', str(case / 'scripts/auto-build-external.sh'), '--source-jobs', '2']
                for number in range(3): args.extend(['--path', str(case / str(number))])
                with (case / 'console').open('w') as output:
                    process = subprocess.Popen(args, start_new_session=True, stdout=output, stderr=output)
                    try:
                        deadline = time.monotonic() + 5
                        while not all((case / str(i) / 'started').exists() for i in range(2)) and time.monotonic() < deadline:
                            self.assertIsNone(process.poll())
                            time.sleep(.01)
                        self.assertTrue(all((case / str(i) / 'started').exists() for i in range(2)))
                        process.send_signal(signum)
                        self.assertEqual(process.wait(timeout=5), 128 + signum, (case / 'console').read_text())
                        for number in range(2):
                            self.assertTrue((case / str(number) / 'cleanup-complete').exists(), (case / 'console').read_text())
                        self.assertFalse((case / '2/started').exists())
                    finally:
                        for pid in case.glob('*/builder.pid'):
                            try: os.kill(int(pid.read_text()), signal.SIGTERM)
                            except ProcessLookupError: pass
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        if process.poll() is None: process.wait(timeout=5)

    def test_external_source_cancellation_waits_for_builder_cleanup(self):
        case = self.external_cancellation_fixture('single-source')
        with (case / 'console').open('w') as output:
            process = subprocess.Popen(['bash', str(case / 'scripts/build-external-source.sh'),
                                        '--path', str(case / '0')], start_new_session=True,
                                       stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 5
                while not (case / '0/started').exists() and time.monotonic() < deadline:
                    self.assertIsNone(process.poll())
                    time.sleep(.01)
                self.assertTrue((case / '0/started').exists())
                process.terminate()
                self.assertEqual(process.wait(timeout=5), 143, (case / 'console').read_text())
                self.assertTrue((case / '0/cleanup-complete').exists())
                self.assertTrue((case / '0').is_dir())
            finally:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                if process.poll() is None: process.wait(timeout=5)

    def test_external_clone_cancellation_acquires_and_removes_created_identity(self):
        case = self.external_cancellation_fixture('clone-cancel')
        binary = case / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ["CLONE_CANCEL_CASE"])
with (root / "calls").open("a") as out: out.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "create":
    # Keep creation pending, but expose the actual cancellation delivery.
    signal.signal(signal.SIGTERM, lambda *_: (root / "signal-received").touch())
    (root / "group").write_text(str(os.getpgrp()))
    (root / "reached").touch()
    while not (root / "release").exists(): time.sleep(.01)
    print("c" * 64)
elif sys.argv[1] not in ("info", "rm"): sys.exit(99)
''')
        docker.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   CLONE_CANCEL_CASE=str(case))
        with (case / 'console').open('w') as output:
            process = subprocess.Popen(['bash', str(case / 'scripts/auto-build-external.sh'),
                                        '--repo', 'https://example.invalid/config.git'],
                                       env=env, start_new_session=True, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 5
                while not (case / 'reached').exists() and time.monotonic() < deadline:
                    self.assertIsNone(process.poll())
                    time.sleep(.01)
                self.assertTrue((case / 'reached').exists())
                process.terminate()
                deadline = time.monotonic() + 5
                while not (case / 'signal-received').exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue((case / 'signal-received').exists(), (case / 'console').read_text())
                (case / 'release').touch()
                self.assertEqual(process.wait(timeout=5), 143, (case / 'console').read_text())
                calls = [json.loads(row) for row in (case / 'calls').read_text().splitlines()]
                self.assertEqual(sum(row[0] == 'create' for row in calls), 1, calls)
                self.assertEqual([row for row in calls if row[0] == 'rm'], [['rm', '-f', 'c' * 64]])
                self.assertFalse(any(row[0] in ('start', 'cp') for row in calls))
                self.assertFalse(any((case / '.build/external').iterdir()))
            finally:
                (case / 'release').touch()
                group = case / 'group'
                if group.exists():
                    try: os.killpg(int(group.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                if process.poll() is None: process.wait(timeout=5)

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

    def test_external_json_round_trips_all_shell_representable_control_bytes(self):
        for number in range(1, 32):
            with self.subTest(number=number):
                value = '/synthetic/control' + chr(number) + 'path'
                result = subprocess.run(['bash', '/tmp/auto-build-external.sh', '--list-json', '--path', value],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['include'][0]['source'], value)

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

    def test_module_build_paths_require_strings_before_workspace_changes(self):
        for key in ('cmake', 'kconfig'):
            for value in (True, 17, ['.'], {'path': '.'}):
                with self.subTest(key=key, value=value):
                    case = self.make_workspace(prior_overlay=False)
                    module = case.inputs / 'typed-module'
                    (module / 'zephyr').mkdir(parents=True)
                    (module / 'CMakeLists.txt').touch()
                    (module / 'Kconfig').touch()
                    declaration = {'cmake': '.', 'kconfig': 'Kconfig'}
                    declaration[key] = value
                    (module / 'zephyr/module.yml').write_text(yaml.safe_dump({'build': declaration}))
                    result = subprocess.run(['bash', str(BUILD), 'validate'], env=case.env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('build.' + key + ' must be a string', result.stderr)
                    result, output = self.run_workspace(case)
                    self.assertNotEqual(result.returncode, 0, output)
                    self.assertEqual(case.commands.read_text(), '', output)
                    self.assertFalse((case.source / 'zephyr').exists())

    def test_target_build_paths_are_not_replaced_when_their_type_is_invalid(self):
        (self.root / 'CMakeLists.txt').touch()
        for value in (False, 0, ['.'], {'path': '.'}):
            with self.subTest(value=value):
                (self.root / 'module.yml').write_text(yaml.safe_dump({'build': {'cmake': value}}))
                metadata = self.root / 'zephyr/module.yml'
                if metadata.exists(): metadata.unlink()
                self.expect_error({'board': 'A'}, 'build.cmake must be a string')

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
    with open(os.environ['PROBE_BUILD_ENV'], 'a') as log:
        log.write(json.dumps({'compiler_jobs': os.environ.get('CMAKE_BUILD_PARALLEL_LEVEL')}) + '\\n')
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
                   PROBE_BUILD_ENV=str(case_root / 'build-env.jsonl'),
                   PROBE_PROJECT_PATH=project_path, PROBE_CONTROL=str(control), PROBE_UPDATE_COUNT=str(counter),
                   PROBE_FAIL_COPY=str(int(fail_copy)), PROBE_PROJECT_DIR=str(project),
                   PROBE_REAL_WEST=shutil.which('west'), PROBE_REAL_RM=shutil.which('rm'))
        return SimpleNamespace(root=case_root, source=source, workspace=workspace, project=project,
                               inputs=inputs, backup=backup, stamp=stamp, manifest_stamp=manifest_stamp,
                               digest=digest, ready=ready, commands=commands, counter=counter, control=control,
                               lock=lock, env=env)

    def test_compiler_jobs_container_validation_before_workspace_mutation(self):
        for value in (None, '', '2', '0002', '0', '00', '-1', '1.5', ' 2', '2\n', 'bad'):
            with self.subTest(value=value):
                case = self.make_workspace()
                case.env.pop('CMAKE_BUILD_PARALLEL_LEVEL', None)
                case.env['PROBE_BUILD_EXIT'] = '0'
                if value is not None: case.env['CMAKE_BUILD_PARALLEL_LEVEL'] = value
                original_stamp = case.stamp.read_bytes()
                result, output = self.run_workspace(case)
                valid = value in (None, '', '2', '0002')
                self.assertEqual(result.returncode, 0 if valid else 1, output)
                if valid:
                    captured = [json.loads(row) for row in pathlib.Path(case.env['PROBE_BUILD_ENV']).read_text().splitlines()]
                    self.assertEqual(captured, [{'compiler_jobs': value.lstrip('0') if value else value}])
                else:
                    self.assertIn('CMAKE_BUILD_PARALLEL_LEVEL must be a positive integer', output)
                    self.assertEqual(case.commands.read_bytes(), b'')
                    self.assertEqual(case.stamp.read_bytes(), original_stamp)
                    self.assertEqual((case.project / 'content.txt').read_text(), 'local override\n')
                    self.assertFalse(pathlib.Path(case.env['PROBE_BUILD_ENV']).exists())

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

    def test_run_reservation_signals_retain_evidence_before_docker(self):
        binary = self.root / 'bin'
        binary.mkdir()
        (self.root / 'build.yaml').write_text('board: A\n')
        (binary / 'mkdir').write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
status = subprocess.call([os.environ['RESERVE_REAL_MKDIR']] + sys.argv[1:])
destination = pathlib.Path(sys.argv[-1])
if status == 0 and destination.name.startswith('run-'):
    pathlib.Path(os.environ['RESERVE_REACHED']).write_text(str(destination))
    while not pathlib.Path(os.environ['RESERVE_RELEASE']).exists(): time.sleep(.01)
sys.exit(status)
''')
        (binary / 'docker').write_text('''#!/usr/bin/env python3
import os, pathlib, sys
pathlib.Path(os.environ['RESERVE_DOCKER_CALLED']).write_text(repr(sys.argv[1:]))
sys.exit(99)
''')
        for script in binary.iterdir(): script.chmod(0o755)
        for group in (False, True):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(group=group, signal=signum):
                    case = self.root / ('reserve-%s-%s' % (group, signum))
                    case.mkdir()
                    env = dict(os.environ, ZMK_IN_CONTAINER='0',
                               PATH=str(binary) + os.pathsep + os.environ['PATH'],
                               RESERVE_REAL_MKDIR=shutil.which('mkdir'),
                               RESERVE_REACHED=str(case / 'reached'), RESERVE_RELEASE=str(case / 'release'),
                               RESERVE_DOCKER_CALLED=str(case / 'docker-called'))
                    process = subprocess.Popen(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                               start_new_session=True, stdout=subprocess.PIPE,
                                               stderr=subprocess.STDOUT, text=True)
                    try:
                        deadline = time.monotonic() + 5
                        while not (case / 'reached').exists() and time.monotonic() < deadline:
                            self.assertIsNone(process.poll())
                            time.sleep(.01)
                        self.assertTrue((case / 'reached').exists())
                        if group: os.killpg(process.pid, signum)
                        else: os.kill(process.pid, signum)
                        time.sleep(.05)
                        try:
                            if group: os.killpg(process.pid, signum)
                            else: os.kill(process.pid, signum)
                        except ProcessLookupError:
                            pass
                        (case / 'release').touch()
                        output, _ = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 128 + signum, output)
                        run = pathlib.Path((case / 'reached').read_text())
                        self.assertTrue(run.is_dir())
                        print('RESERVATION: signal=%s group=%s files=%r' %
                              (signal.Signals(signum).name, group, sorted(p.name for p in run.iterdir())))
                        self.assertTrue((run / 'build.log').is_file(), output)
                        self.assertTrue((run / 'build-summary.txt').is_file(), output)
                        summary = (run / 'build-summary.txt').read_text()
                        self.assertIn('Status: FAILED', summary)
                        self.assertIn('Reason: interrupted by ' + signal.Signals(signum).name, summary)
                        self.assertRegex(summary, r'(?m)^Run sequence: [1-9][0-9]*$')
                        self.assertEqual(self.run_directory(output), run)
                        self.assertFalse((case / 'docker-called').exists(), output)
                    finally:
                        (case / 'release').touch()
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        if process.poll() is None: process.wait(timeout=3)

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
                            os.killpg(process.pid, signum)
                            (case / 'release').touch()
                            output, _ = process.communicate(timeout=5)
                            self.assertEqual(process.returncode, 128 + signum, output)
                            self.assertIn('a' * 64, output)
                            calls = [json.loads(line) for line in (case / 'calls').read_text().splitlines()]
                            self.assertFalse(any(call[0] == 'start' for call in calls), calls)
                            self.assertEqual(['rm', '-f', 'a' * 64] in calls, keep == 0, calls)
                            summary = (self.run_directory(output) / 'build-summary.txt').read_text()
                            self.assertIn('Status: FAILED', summary)
                            self.assertIn('Reason: interrupted by ' + signal.Signals(signum).name, summary)
                        finally:
                            try: os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                            if process.poll() is None: process.wait(timeout=3)

    def test_finalization_group_signals_complete_cleanup_and_publish_final_status(self):
        binary = self.root / 'bin'
        binary.mkdir()
        docker = binary / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import os, pathlib, sys, time
if sys.argv[1] == 'create': print('a' * 64)
elif sys.argv[1] == 'start': sys.exit(int(os.environ['FINAL_INITIAL_STATUS']))
elif sys.argv[1] == 'exec':
    if 'mkdir -p /root/zmk-config' in ' '.join(sys.argv): pass
    elif './build.sh validate' in ' '.join(sys.argv): print('build.yaml is valid.')
    else: sys.stdin.buffer.read()
elif sys.argv[1] == 'rm':
    pathlib.Path(os.environ['FINAL_REACHED']).touch()
    while not pathlib.Path(os.environ['FINAL_RELEASE']).exists(): time.sleep(.01)
    pathlib.Path(os.environ['FINAL_COMPLETE']).touch()
else: sys.exit(99)
''')
        docker.chmod(0o755)
        (self.root / 'build.yaml').write_text('board: A\n')
        for initial in (0, 23):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(initial=initial, signal=signum):
                    folder = self.root / ('finish-%s-%s' % (initial, signum))
                    folder.mkdir()
                    env = dict(os.environ, ZMK_IN_CONTAINER='0', ZMK_KEEP_CONTAINER='0',
                               PATH=str(binary) + os.pathsep + os.environ['PATH'],
                               FINAL_INITIAL_STATUS=str(initial), FINAL_REACHED=str(folder / 'reached'),
                               FINAL_RELEASE=str(folder / 'release'), FINAL_COMPLETE=str(folder / 'complete'))
                    process = subprocess.Popen(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                               start_new_session=True, stdout=subprocess.PIPE,
                                               stderr=subprocess.STDOUT, text=True)
                    try:
                        deadline = time.monotonic() + 5
                        while not (folder / 'reached').exists() and time.monotonic() < deadline:
                            self.assertIsNone(process.poll())
                            time.sleep(.01)
                        self.assertTrue((folder / 'reached').exists())
                        os.killpg(process.pid, signum)
                        time.sleep(.05)
                        (folder / 'release').touch()
                        output, _ = process.communicate(timeout=5)
                        self.assertTrue((folder / 'complete').exists(), output)
                        self.assertEqual(process.returncode, initial or 128 + signum, output)
                        summary = (self.run_directory(output) / 'build-summary.txt').read_text()
                        self.assertIn('Status: FAILED', summary)
                        reason = 'container start failed' if initial else 'interrupted by ' + signal.Signals(signum).name
                        self.assertIn('Reason: ' + reason, summary)
                    finally:
                        (folder / 'release').touch()
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        if process.poll() is None: process.wait(timeout=3)

    def test_finalization_entry_signals_preserve_cleanup_and_the_original_failure(self):
        binary = self.root / 'bin'
        binary.mkdir()
        (self.root / 'build.yaml').write_text('board: A\n')
        (binary / 'docker').write_text('''#!/usr/bin/env bash
case "$1" in
  create) printf '%064d\\n' 0 ;;
  start) exit "${ENTRY_INITIAL_STATUS}" ;;
  exec)
    case "$*" in
      *'mkdir -p /root/zmk-config'*) ;;
      *'./build.sh validate'*) echo 'build.yaml is valid.' ;;
      *) cat >/dev/null ;;
    esac ;;
  rm) : > "${ENTRY_CLEANED}" ;;
  *) exit 99 ;;
esac
''')
        (binary / 'docker').chmod(0o755)
        hook = self.root / 'entry-hook.sh'
        hook.write_text('''set -T
trap 'if [ "${FUNCNAME[0]:-}" = finish_run ]; then trap - DEBUG; : > "$ENTRY_REACHED"; kill -s "$ENTRY_SIGNAL" "$$"; fi' DEBUG
''')
        for initial in (0, 23):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(initial=initial, signal=signum):
                    folder = self.root / ('entry-%s-%s' % (initial, signum))
                    folder.mkdir()
                    env = dict(os.environ, ZMK_IN_CONTAINER='0', ZMK_KEEP_CONTAINER='0',
                               PATH=str(binary) + os.pathsep + os.environ['PATH'], BASH_ENV=str(hook),
                               ENTRY_INITIAL_STATUS=str(initial), ENTRY_SIGNAL=str(int(signum)),
                               ENTRY_REACHED=str(folder / 'reached'), ENTRY_CLEANED=str(folder / 'cleaned'))
                    process = subprocess.Popen(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    output, _ = process.communicate(timeout=10)
                    self.assertTrue((folder / 'reached').exists(), output)
                    self.assertTrue((folder / 'cleaned').exists(), output)
                    self.assertEqual(process.returncode, initial or 128 + signum, output)
                    summary = (self.run_directory(output) / 'build-summary.txt').read_text()
                    self.assertIn('Status: FAILED', summary)
                    reason = 'container start failed' if initial else 'interrupted by ' + signal.Signals(signum).name
                    self.assertIn('Reason: ' + reason, summary)

    def test_summary_publication_is_atomic_and_commits_the_outcome(self):
        binary = self.root / 'bin'
        binary.mkdir()
        (self.root / 'build.yaml').write_text('board: A\n')
        (binary / 'docker').write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if sys.argv[1] == 'create': print('a' * 64)
elif sys.argv[1] == 'start': pass
elif sys.argv[1] == 'exec':
    if 'mkdir -p /root/zmk-config' in ' '.join(sys.argv): pass
    elif './build.sh validate' in ' '.join(sys.argv): print('build.yaml is valid.')
    else: sys.stdin.buffer.read()
elif sys.argv[1] == 'rm': pathlib.Path(os.environ['PUBLISH_CLEANED']).touch()
else: sys.exit(99)
''')
        (binary / 'mv').write_text('''#!/usr/bin/env python3
import os, pathlib, signal, subprocess, sys
if sys.argv[-1].endswith('/build-summary.txt'):
    pathlib.Path(os.environ['PUBLISH_REACHED']).touch()
    assert pathlib.Path(os.environ['PUBLISH_CLEANED']).exists(), 'summary preceded cleanup'
    if os.environ['PUBLISH_CASE'] == 'io-failure': sys.exit(23)
    status = subprocess.call([os.environ['PUBLISH_REAL_MV']] + sys.argv[1:])
    os.kill(int(pathlib.Path(os.environ['PUBLISH_PID']).read_text()), signal.SIGTERM)
    sys.exit(status)
os.execv(os.environ['PUBLISH_REAL_MV'], ['mv'] + sys.argv[1:])
''')
        for file in binary.iterdir(): file.chmod(0o755)
        for name in ('late-signal', 'io-failure'):
            with self.subTest(name=name):
                folder = self.root / name
                folder.mkdir()
                env = dict(os.environ, ZMK_IN_CONTAINER='0', ZMK_KEEP_CONTAINER='0',
                           PATH=str(binary) + os.pathsep + os.environ['PATH'], PUBLISH_CASE=name,
                           PUBLISH_CLEANED=str(folder / 'cleaned'), PUBLISH_REACHED=str(folder / 'reached'),
                           PUBLISH_PID=str(folder / 'pid'), PUBLISH_REAL_MV=shutil.which('mv'))
                process = subprocess.Popen(['bash', str(BUILD), 'validate', str(self.root)], env=env,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                (folder / 'pid').write_text(str(process.pid))
                output, _ = process.communicate(timeout=10)
                self.assertTrue((folder / 'reached').exists(), output)
                self.assertTrue((folder / 'cleaned').exists(), output)
                run = self.run_directory(output)
                summary = run / 'build-summary.txt'
                if name == 'late-signal':
                    self.assertEqual(process.returncode, 0, output)
                    self.assertIn('Status: SUCCESS', summary.read_text())
                else:
                    self.assertNotEqual(process.returncode, 0, output)
                    self.assertFalse(summary.exists(), output)
                self.assertFalse(list(run.glob('summary-tmp-*')))

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

    def test_pruning_normalizes_in_workspace_parent_components(self):
        for path in ('project', './project', 'modules/../project', 'case..name/project'):
            with self.subTest(path=path):
                case = self.make_workspace(project_path=path, prior_overlay=False)
                result, output = self.run_workspace(case)
                self.assertEqual(result.returncode, 71, output)
                self.assertTrue(case.project.resolve().is_dir(), output)
                self.assertFalse(case.counter.exists(), output)

    def test_standalone_resolves_zephyr_once_for_all_targets(self):
        for jobs in (1, 2):
            with self.subTest(jobs=jobs):
                case = self.make_workspace(prior_overlay=False, jobs=jobs, document={
                    'application': '.', 'include': [
                        {'board': 'A', 'artifact-name': 'app-' + str(i)} for i in range(3)]})
                (case.source / 'CMakeLists.txt').touch()
                zephyr = case.workspace / 'zephyr'
                package = zephyr / 'share/zephyr-package/cmake'
                package.mkdir(parents=True)
                (package / 'ZephyrConfig.cmake').touch()
                west = pathlib.Path(case.env['PATH'].split(os.pathsep)[0]) / 'west'
                text = west.read_text().replace("projects = [('zmk', 'zmk'),", "projects = [('zephyr', 'zephyr'), ('zmk', 'zmk'),")
                text = text.replace("    fault = os.environ.get('PROBE_LIST_FAILURE')", "    if wanted == 'zephyr':\n        print(str(pathlib.Path(os.environ['WORK_DIR']) / 'zephyr'))\n        sys.exit(0)\n    fault = os.environ.get('PROBE_LIST_FAILURE')")
                west.write_text(text)
                case.env['PROBE_BUILD_EXIT'] = '0'
                result, output = self.run_workspace(case)
                self.assertEqual(result.returncode, 0, output)
                calls = [json.loads(line) for line in case.commands.with_suffix('.argv.jsonl').read_text().splitlines()]
                self.assertEqual(sum(args[:2] == ['list', 'zephyr'] for args in calls), 1)
                self.assertEqual(sum(args[0] == 'build' for args in calls), 3)

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
                'nested/my..file.txt', 'unicode-名前.txt', 'DEL-\x7f.txt', 'COM⁴.txt',
                '-C', '--exclude=src', 'literal [ab] $value; & (test).txt', 'unicode-名前-📦.txt']
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
