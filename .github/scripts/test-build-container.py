#!/usr/bin/env python3
"""Container-owned parser/schema contracts; execute the real build.sh for every case."""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

BUILD = pathlib.Path('/root/zmk-config/build.sh')
SHAPES = pathlib.Path(sys.argv.pop(1))
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
