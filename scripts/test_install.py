#!/usr/bin/env python3
"""Exercise the installer with disposable copies of one signed staged bundle."""

import argparse
import contextlib
import fcntl
import io
import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import tool

SOURCE = tool.STAGED
REAL_QUIT = tool.quit_app


def require_staged_bundle():
    if SOURCE.is_symlink() or not SOURCE.is_dir():
        raise tool.Failure('Run ./scripts/build.sh && ./scripts/sign.sh --adhoc before running installer tests.')


def sign_copy(path):
    tool.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', path])


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='spacewise-install-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        home = self.root / 'home'
        out = self.root / 'out'
        state = home / 'Applications/.SpacewiseDevelopment'
        home.mkdir()
        out.mkdir()
        paths = dict(
            HOME=home,
            OUT=out,
            STATE=state,
            APP=home / 'Applications/Spacewise.app',
            PREVIOUS=state / 'previous.app',
            JOURNAL=state / 'transaction.json',
            STAGED=out / 'Spacewise.app',
        )
        patch = mock.patch.multiple(
            tool, **paths, ARGS=argparse.Namespace(identity=None), config=lambda: {}, quit_app=lambda: None
        )
        patch.start()
        self.addCleanup(patch.stop)
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop('SPACEWISE_SIGNING_IDENTITY', None)
        os.environ.pop('SPACEWISE_TEST_FAIL', None)

        tool.safe_state()
        tool.verify(SOURCE)
        shutil.copytree(SOURCE, tool.STAGED, symlinks=True)
        sign_copy(tool.STAGED)
        self.new = tool.verify(tool.STAGED)['CFBundleVersion']
        shutil.copytree(tool.STAGED, tool.APP, symlinks=True)
        build = int(self.new)
        self.old = str(build - 1 if build > 1 else build + 1)
        self.set_build(tool.APP, self.old)
        self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.old)

    def set_build(self, path, build):
        plist_path = path / 'Contents/Info.plist'
        plist = plistlib.loads(plist_path.read_bytes())
        plist['CFBundleVersion'] = build
        plist_path.write_bytes(plistlib.dumps(plist))
        manifest_path = path / 'Contents/Resources/build.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['build'] = int(build)
        tool.write_json(manifest_path, manifest)
        sign_copy(path)

    def journal_stage(self, old, legacy=False):
        stage = tool.STATE / ('stage-' + 'a' * 32 + '.app')
        shutil.copytree(tool.STAGED, stage)
        record = dict(stage=stage.name, old=old, new=self.new)
        if not legacy:
            record['candidate_inode'] = stage.stat().st_ino
        tool.write_json(tool.JOURNAL, record)
        return stage

    def assert_recovered_twice(self, installed, previous, rejected=None):
        for _ in range(2):
            tool.run_locked_command('quit')
            self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'] if tool.APP.exists() else None, installed)
            self.assertEqual(
                tool.verify(tool.PREVIOUS)['CFBundleVersion'] if tool.PREVIOUS.exists() else None, previous
            )
            self.assertFalse(tool.JOURNAL.exists())
            self.assertEqual(list(tool.STATE.glob('stage-*.app')), [])
            self.assertEqual(list(tool.STATE.glob('stage-*.rejected')), [rejected] if rejected else [])

    def interrupt_after_rename(self, method, source, destination):
        operation = getattr(tool if method == 'swap' else os, method)

        def interrupt(a, b):
            operation(a, b)
            if (a, b) == (source, destination):
                raise InterruptedError('simulated interruption after rename')

        return mock.patch.object(tool if method == 'swap' else os, method, side_effect=interrupt)

    def test_install_preserves_one_verified_previous(self):
        tool.install()
        self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.new)
        self.assertEqual(tool.verify(tool.PREVIOUS)['CFBundleVersion'], self.old)
        self.assertFalse(tool.JOURNAL.exists())

    def test_first_install_with_no_app_and_no_applications_folder(self):
        shutil.rmtree(tool.HOME / 'Applications')
        tool.safe_state()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            tool.install()
        self.assertNotIn('interrupted', out.getvalue())
        self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.new)
        self.assertFalse(tool.PREVIOUS.exists())
        self.assertFalse(tool.JOURNAL.exists())
        self.assertEqual(list(tool.STATE.glob('stage-*.app')), [])

    def test_invalid_signature_preserves_installed(self):
        bad = self.root / 'bad.app'
        shutil.copytree(tool.STAGED, bad)
        with (bad / 'Contents/MacOS/Spacewise').open('ab') as file:
            file.write(b'invalid')
        with self.assertRaises(tool.Failure):
            tool.install(bad)
        self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.old)

    def test_post_swap_failure_restores_verified_old(self):
        os.environ['SPACEWISE_TEST_FAIL'] = 'after-swap'
        with self.assertRaises(tool.Failure):
            tool.install()
        rejected, = tool.STATE.glob('stage-*.rejected')
        self.assert_recovered_twice(self.old, None, rejected)
        self.assertEqual(tool.verify(rejected)['CFBundleVersion'], self.new)

    def test_cancelled_quit_preserves_installed_and_removes_stage(self):
        with mock.patch.object(tool, 'quit_app', side_effect=tool.Failure('quit rejected')):
            with self.assertRaises(tool.Failure):
                tool.install()
        self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.old)
        self.assertEqual(list(tool.STATE.glob('stage-*.app')), [])

    def test_symlink_destination_refused(self):
        other = self.root / 'other.app'
        tool.APP.rename(other)
        tool.APP.symlink_to(other)
        with self.assertRaises(tool.Failure):
            tool.install()
        self.assertEqual(tool.verify(other)['CFBundleVersion'], self.old)

    def test_recovery_before_swap_retains_uninstalled_candidate(self):
        stage = self.journal_stage(self.old)
        rejected = stage.with_suffix('.rejected')
        self.assert_recovered_twice(self.old, None, rejected)
        self.assertEqual(tool.verify(rejected)['CFBundleVersion'], self.new)

    def test_recovery_after_swap_archives_old_build(self):
        stage = self.journal_stage(self.old)
        tool.swap(tool.APP, stage)
        self.assert_recovered_twice(self.new, self.old)

    def test_same_build_number_still_archives_exact_old_bundle(self):
        # Exercise two different bundle directories with the same build number.
        self.set_build(tool.APP, self.new)
        prior = tool.APP.stat().st_ino
        stage = self.journal_stage(self.new)
        candidate = stage.stat().st_ino
        tool.swap(tool.APP, stage)
        self.assert_recovered_twice(self.new, self.new)
        self.assertEqual(tool.APP.stat().st_ino, candidate)
        self.assertEqual(tool.PREVIOUS.stat().st_ino, prior)

    def test_legacy_corrupt_candidate_restores_old_and_keeps_previous(self):
        shutil.copytree(tool.APP, tool.PREVIOUS)
        earlier = str(int(self.new) + 2)
        self.set_build(tool.PREVIOUS, earlier)
        stage = self.journal_stage(self.old, legacy=True)
        tool.swap(tool.APP, stage)
        manifest = tool.APP / 'Contents/Resources/build.json'
        manifest.write_text('corrupt legacy candidate')
        rejected = stage.with_suffix('.rejected')
        self.assert_recovered_twice(self.old, earlier, rejected)
        self.assertEqual((rejected / 'Contents/Resources/build.json').read_text(), 'corrupt legacy candidate')

    def test_recovery_rejects_persistently_invalid_candidate(self):
        stage = self.journal_stage(self.old)
        tool.swap(tool.APP, stage)
        invalid_payload = tool.APP / 'Contents/MacOS/Spacewise'
        with invalid_payload.open('ab') as file:
            file.write(b'invalid candidate signature')
        with self.assertRaises(tool.Failure):
            tool.verify(tool.APP)
        rejected = stage.with_suffix('.rejected')
        self.assert_recovered_twice(self.old, None, rejected)
        self.assertTrue(
            (rejected / 'Contents/MacOS/Spacewise').read_bytes().endswith(b'invalid candidate signature')
        )
        with self.assertRaises(tool.Failure):
            tool.verify(rejected)

    def test_rollback_swaps_verified_temporary_bundles(self):
        tool.install()
        with mock.patch.object(tool, 'relaunch') as relaunch:
            tool.run_locked_command('rollback')
        relaunch.assert_called_once_with()
        self.assert_recovered_twice(self.old, self.new)
        self.assertEqual(list(tool.STATE.glob('rollback-*.app')), [])

    def test_retry_after_reverse_swap(self):
        stage = self.journal_stage(self.old)
        tool.swap(tool.APP, stage)
        (tool.APP / 'Contents/Info.plist').write_bytes(b'broken plist')
        with self.interrupt_after_rename('swap', tool.APP, stage), self.assertRaises(InterruptedError):
            tool.recover()
        self.assertTrue(json.loads(tool.JOURNAL.read_text())['reject'])
        rejected = stage.with_suffix('.rejected')
        self.assert_recovered_twice(self.old, None, rejected)
        self.assertEqual((rejected / 'Contents/Info.plist').read_bytes(), b'broken plist')

    def test_retry_after_reject_archive_on_first_install(self):
        shutil.rmtree(tool.APP)
        stage = self.journal_stage(None)
        tool.put_stage_in_place(stage, None)
        (tool.APP / 'Contents/Info.plist').write_bytes(b'broken first install')
        rejected = stage.with_suffix('.rejected')
        with self.interrupt_after_rename('replace', stage, rejected), self.assertRaises(InterruptedError):
            tool.recover()
        self.assertTrue(tool.JOURNAL.exists())
        self.assert_recovered_twice(None, None, rejected)
        self.assertEqual((rejected / 'Contents/Info.plist').read_bytes(), b'broken first install')

    def test_recover_valid_first_install_before_rename(self):
        shutil.rmtree(tool.APP)
        self.journal_stage(None)
        self.assert_recovered_twice(self.new, None)

    def test_retry_after_retiring_previous_and_archiving_stage(self):
        earlier = str(int(self.new) + 2)
        shutil.copytree(tool.APP, tool.PREVIOUS)
        self.set_build(tool.PREVIOUS, earlier)
        stage = self.journal_stage(self.old)
        tool.swap(tool.APP, stage)
        retired = tool.STATE / 'retired.app'
        for source, destination in ((tool.PREVIOUS, retired), (stage, tool.PREVIOUS)):
            with self.interrupt_after_rename('replace', source, destination), self.assertRaises(InterruptedError):
                tool.recover()
            self.assertTrue(tool.JOURNAL.exists())
        self.assert_recovered_twice(self.new, self.old)
        self.assertEqual(tool.verify(retired)['CFBundleVersion'], earlier)

    def test_retry_after_detaching_older_retired_bundle(self):
        shutil.copytree(tool.APP, tool.PREVIOUS)
        retired = tool.STATE / 'retired.app'
        shutil.copytree(tool.APP, retired)
        retired_inode = retired.stat().st_ino
        stage = self.journal_stage(self.old)
        tool.swap(tool.APP, stage)
        with mock.patch.object(shutil, 'rmtree', side_effect=InterruptedError), self.assertRaises(InterruptedError):
            tool.recover()
        self.assertFalse(retired.exists())
        self.assertTrue(tool.JOURNAL.exists())
        self.assert_recovered_twice(self.new, self.old)
        detached, = tool.STATE.glob('discarded-*')
        self.assertEqual(detached.stat().st_ino, retired_inode)
        self.assertEqual(tool.verify(retired)['CFBundleVersion'], self.old)

    @unittest.skipUnless(os.environ.get('SPACEWISE_TEST_LAUNCH') == '1', 'requires an interactive macOS session')
    def test_actual_rollback_and_relaunch(self):
        bundle = 'local.spacewise.installtest.' + self.root.name.rsplit('-', 1)[1]
        with mock.patch.multiple(tool, BUNDLE=bundle, quit_app=REAL_QUIT):
            for path, build in ((tool.APP, self.old), (tool.STAGED, self.new)):
                plist_path = path / 'Contents/Info.plist'
                plist = plistlib.loads(plist_path.read_bytes())
                plist.update(CFBundleIdentifier=bundle, LSUIElement=True)
                plist.pop('CFBundleDocumentTypes', None)
                plist_path.write_bytes(plistlib.dumps(plist))
                self.set_build(path, build)
            # Compile the production helper against just the disposable identity and URL.
            helper = (tool.ROOT / 'Sources/SpacewiseControl/main.swift').read_text()
            helper = helper.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Spacewise.app")',
                                    'URL(fileURLWithPath: ' + json.dumps(str(tool.APP.resolve())) + ')')
            helper = helper.replace('local.spacewise.app', bundle)
            source = self.root / 'control.swift'
            source.write_text(helper)
            tool.run(['swiftc', source, '-o', tool.OUT / 'SpacewiseControl'])
            try:
                tool.run_locked_command('install')
                tool.run_locked_command('relaunch')
                first = self.exact_running_pid()
                tool.run_locked_command('rollback')
                second = self.exact_running_pid()
                self.assertNotEqual(first, second)
                self.assertEqual(tool.verify(tool.APP)['CFBundleVersion'], self.old)
                self.assertEqual(tool.verify(tool.PREVIOUS)['CFBundleVersion'], self.new)
                tool.run_locked_command('relaunch')
                self.assertNotEqual(second, self.exact_running_pid())
                self.assertFalse(tool.JOURNAL.exists())
                self.assertEqual(list(tool.STATE.glob('stage-*.app')), [])
                self.assertFalse((tool.STATE / 'retired.app').exists())
            finally:
                tool.quit_app()

    def exact_running_pid(self):
        records = tool.processes()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['exact'], 'true')
        return records[0]['pid']

    def test_lock_excludes_second_open_description(self):
        path = tool.STATE / 'install.lock'
        with path.open('w') as file:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(tool.Failure):
                with tool.lock(path):
                    self.fail('Acquired the installation lock twice')


def main():
    try:
        require_staged_bundle()
    except tool.Failure as error:
        print(error, file=sys.stderr)
        return 1
    return 0 if unittest.main(exit=False).result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
