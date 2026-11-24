#!/usr/bin/env python3
"""Unit tests for the development scripts. External commands are mocked and every path is a temporary directory.

Run with: python3 scripts/test_scripts.py

Unlike test_install.py this needs no signed bundle, certificate or installed app, and touches nothing outside a
temporary directory.
"""
import argparse
import contextlib
import io
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import tool
import test_install

SCRIPTS = Path(__file__).resolve().parent
COMMANDS = tool.COMMANDS



class ControlHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='spacewise-script-test-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'SpacewiseControl').write_bytes(b'helper')
        self.out = self.root / 'out'
        self.out.mkdir()
        self.builds = []

    def tearDown(self):
        self.temp.cleanup()

    def fake_swift_build(self, *args):
        self.builds.append(args)
        return str(self.bin)

    def call_control(self):
        stderr = io.StringIO()
        with mock.patch.object(tool, 'OUT', self.out), mock.patch.object(tool, 'swift_build', self.fake_swift_build):
            with contextlib.redirect_stderr(stderr):
                helper = tool.control()
        return helper, stderr.getvalue()

    def test_first_use_builds_the_helper_once(self):
        helper, _ = self.call_control()
        self.assertEqual(self.builds, [('--product', 'SpacewiseControl'), ('--show-bin-path',)])
        self.assertEqual(helper.read_bytes(), b'helper')

    def test_existing_helper_is_used_silently(self):
        (self.out / 'SpacewiseControl').write_bytes(b'already built')
        helper, message = self.call_control()
        self.assertEqual(message, '')
        self.assertEqual(self.builds, [])
        self.assertEqual(helper.read_bytes(), b'already built')

    def test_the_notice_goes_to_stderr_so_status_keeps_clean_json_on_stdout(self):
        stdout, stderr = io.StringIO(), io.StringIO()

        def run(command, **kwargs):
            return str(self.bin) if command[0] == 'swift' else '[]'

        with mock.patch.multiple(tool, OUT=self.out, run=run):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                tool.print_status()
        self.assertEqual(stdout.getvalue(), '[]\n')
        self.assertIn('building SpacewiseControl in release mode', stderr.getvalue())



CERTIFICATE = 'A' * 40
OTHER_CERTIFICATE = 'B' * 40
KEYCHAIN = [(CERTIFICATE, 'Apple Development: Someone (ABCDE12345)')]


def arguments(**overrides):
    values = dict(identity=None, adhoc=False, command='sign')
    values.update(overrides)
    return argparse.Namespace(**values)


class SigningChoiceTests(unittest.TestCase):
    """Which signature a build gets. Ad-hoc is explicit, or automatic only when nothing else could be meant."""

    def choose(self, args=None, keychain=KEYCHAIN, environment=None, configured=None):
        listing = mock.Mock(return_value=keychain)
        with mock.patch.object(tool, 'ARGS', args or arguments()):
            with mock.patch.object(tool, 'config', lambda: configured or {}):
                with mock.patch.object(tool, 'installed_identities', listing), mock.patch.dict(os.environ):
                    os.environ.pop('SPACEWISE_SIGNING_IDENTITY', None)
                    os.environ.update(environment or {})
                    return tool.identity_choice(), listing

    def test_the_flag_asks_for_ad_hoc_without_touching_the_keychain(self):
        (choice, listing) = self.choose(arguments(adhoc=True))
        self.assertEqual(choice, (tool.ADHOC, False))
        listing.assert_not_called()

    def test_the_flag_wins_over_a_configured_certificate(self):
        (choice, _) = self.choose(arguments(adhoc=True), environment={'SPACEWISE_SIGNING_IDENTITY': CERTIFICATE})
        self.assertEqual(choice, (tool.ADHOC, False))

    def test_the_word_adhoc_is_accepted_from_each_place_an_identity_can_be_given(self):
        for case in (
            dict(args=arguments(identity='adhoc')),
            dict(environment={'SPACEWISE_SIGNING_IDENTITY': 'adhoc'}),
            dict(configured={'identity': 'adhoc'}),
        ):
            (choice, listing) = self.choose(**case)
            self.assertEqual(choice, (tool.ADHOC, False), case)
            listing.assert_not_called()

    def test_nothing_selected_and_no_suitable_certificate_falls_back_to_ad_hoc_and_says_it_was_automatic(self):
        (choice, _) = self.choose(keychain=[(CERTIFICATE, 'Some Other Authority: x')])
        self.assertEqual(choice, (tool.ADHOC, True))
        (choice, _) = self.choose(keychain=[])
        self.assertEqual(choice, (tool.ADHOC, True))

    def test_a_single_suitable_certificate_is_still_used_as_before(self):
        (choice, _) = self.choose()
        self.assertEqual(choice, (CERTIFICATE, False))

    def test_several_certificates_with_none_selected_still_fail_instead_of_going_ad_hoc(self):
        keychain = KEYCHAIN + [(OTHER_CERTIFICATE, 'Developer ID Application: Someone (ABCDE12345)')]
        with self.assertRaisesRegex(tool.Failure, 'Select one existing certificate SHA'):
            self.choose(keychain=keychain)

    def test_a_selected_certificate_that_is_missing_still_fails_instead_of_going_ad_hoc(self):
        with self.assertRaisesRegex(tool.Failure, 'unavailable'):
            self.choose(arguments(identity=OTHER_CERTIFICATE))

    def test_a_selected_installed_certificate_is_used(self):
        (choice, _) = self.choose(configured={'identity': CERTIFICATE})
        self.assertEqual(choice, (CERTIFICATE, False))

    def test_the_flag_cannot_be_combined_with_an_identity(self):
        with mock.patch('sys.argv', ['tool.py', 'sign', '--adhoc', '--identity', CERTIFICATE]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                tool.parse_arguments()

class SigningCommandTests(unittest.TestCase):
    def sign(self, args, keychain=KEYCHAIN):
        calls = []
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(tool, 'ARGS', args), mock.patch.object(tool, 'config', lambda: {}):
            with mock.patch.object(tool, 'installed_identities', lambda: keychain):
                with mock.patch.object(tool, 'info'), mock.patch.object(tool, 'verify'):
                    with mock.patch.object(tool, 'run', lambda command, **kw: calls.append([str(c) for c in command])):
                        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                            tool.sign()
        return calls, stdout.getvalue(), stderr.getvalue()

    def test_ad_hoc_signs_with_the_dash_identity_and_says_what_was_made(self):
        calls, out, err = self.sign(arguments(adhoc=True))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ['codesign', '--force', '--sign', '-'])
        self.assertIn('ad-hoc build', out)
        self.assertIn('not a certificate-backed one', err)
        self.assertNotIn('no signing certificate is selected', err)  # asked for, so no "chosen automatically" notice

    def test_the_automatic_fallback_explains_itself(self):
        calls, out, err = self.sign(arguments(), keychain=[])
        self.assertEqual(calls[0][3], '-')
        self.assertIn('no signing certificate is selected and none is installed', err)
        self.assertIn('--adhoc', err)

    def test_the_certificate_path_signs_exactly_as_before(self):
        calls, out, err = self.sign(arguments())
        self.assertEqual(calls[0][:4], ['codesign', '--force', '--sign', CERTIFICATE])
        self.assertEqual(calls[0][4:6], ['--options', 'runtime'])
        self.assertEqual(out, 'Signed and verified with persistent certificate-backed identity\n')
        self.assertEqual(err, '')


class SignatureVerificationTests(unittest.TestCase):
    PATH = Path('/nonexistent/Spacewise.app')
    ADHOC_DETAILS = 'Identifier=local.spacewise.app\nSignature=adhoc\n'
    CERTIFICATE_DETAILS = 'Identifier=local.spacewise.app\nAuthority=Apple Development: Someone\n'

    def check(self, args, details, error=None, returncode=0, environment=None, configured=None, keychain=None):
        """The codesign command check_signature ran. `keychain` is what the keychain holds; None means the check
        must not look."""
        result = subprocess.CompletedProcess([], returncode, stdout='', stderr=details)
        with contextlib.ExitStack() as stack:
            patches = dict(ARGS=args, config=lambda: configured or {})
            stack.enter_context(mock.patch.multiple(tool, **patches))
            stack.enter_context(mock.patch.dict(os.environ, environment or {}, clear=True))
            listing = stack.enter_context(mock.patch.object(tool, 'installed_identities', return_value=keychain))
            stack.enter_context(mock.patch.object(tool.subprocess, 'run', return_value=result))
            command = stack.enter_context(mock.patch.object(tool, 'run', side_effect=error))
            try:
                tool.check_signature(self.PATH)
            finally:
                if keychain is None:
                    listing.assert_not_called()
        return command.call_args.args[0]

    def test_an_ad_hoc_bundle_with_nothing_selected_is_checked_in_its_own_mode_without_the_keychain(self):
        command = self.check(arguments(), self.ADHOC_DETAILS)
        self.assertEqual(command, [
            'codesign', '--verify', '--strict', '--verbose', '-R',
            '=identifier "local.spacewise.app"', self.PATH
        ])

    def test_a_certificate_bundle_with_nothing_selected_is_pinned_to_the_one_installed_certificate(self):
        command = self.check(arguments(), self.CERTIFICATE_DETAILS, keychain=KEYCHAIN)
        self.assertIn('certificate leaf = H"' + CERTIFICATE + '"', command[command.index('-R') + 1])

    def test_a_certificate_bundle_with_nothing_selected_and_no_single_certificate_to_pin_is_refused(self):
        with self.assertRaisesRegex(tool.Failure, 'no suitable certificate is installed'):
            self.check(arguments(), self.CERTIFICATE_DETAILS, keychain=[])
        several = KEYCHAIN + [(OTHER_CERTIFICATE, 'Developer ID Application: Someone (ABCDE12345)')]
        with self.assertRaisesRegex(tool.Failure, 'Select one existing certificate SHA'):
            self.check(arguments(), self.CERTIFICATE_DETAILS, keychain=several)

    def test_a_certificate_signed_bundle_is_rejected_by_an_ad_hoc_check(self):
        with self.assertRaisesRegex(tool.Failure, 'Ad-hoc signature required'):
            self.check(arguments(adhoc=True), self.CERTIFICATE_DETAILS)

    def test_explicit_certificate_pins_the_leaf_and_rejects_ad_hoc(self):
        command = self.check(arguments(identity=CERTIFICATE), self.CERTIFICATE_DETAILS)
        self.assertIn('certificate leaf = H"' + CERTIFICATE + '"', command[command.index('-R') + 1])
        with self.assertRaisesRegex(tool.Failure, 'ad-hoc rejected'):
            self.check(arguments(identity=CERTIFICATE), self.ADHOC_DETAILS)

    def test_explicit_identity_from_the_environment_or_config_asserts_the_mode(self):
        with self.assertRaisesRegex(tool.Failure, 'Ad-hoc signature required'):
            self.check(arguments(), self.CERTIFICATE_DETAILS, environment={'SPACEWISE_SIGNING_IDENTITY': 'adhoc'})
        with self.assertRaisesRegex(tool.Failure, 'Certificate-backed signature required'):
            self.check(arguments(), self.ADHOC_DETAILS, configured={'identity': CERTIFICATE})

    def test_invalid_or_unsigned_bundle_reports_signature_failure(self):
        with self.assertRaisesRegex(tool.Failure, 'Cannot read the code signature'):
            self.check(arguments(), '', returncode=1)
        with self.assertRaisesRegex(tool.Failure, 'Cannot determine the code signature mode'):
            self.check(arguments(), '')

    def test_a_built_but_unsigned_bundle_says_to_sign_it(self):
        linker_signed = (
            'Identifier=Spacewise\n'
            'CodeDirectory v=20400 size=18978 flags=0x20002(adhoc,linker-signed) hashes=590+0 location=embedded\n'
            'Signature=adhoc\n'
        )
        with self.assertRaisesRegex(tool.Failure, r'not signed yet; run \./scripts/sign\.sh --adhoc'):
            self.check(arguments(), linker_signed)

    def test_wrong_identifier_or_tampering_fails_the_codesign_check(self):
        with self.assertRaisesRegex(tool.Failure, 'Command failed: codesign'):
            self.check(arguments(), self.ADHOC_DETAILS, error=tool.Failure('Command failed: codesign'))


class InstallContinuityTests(unittest.TestCase):
    def install_over_existing(self, old_mode, new_mode, requirements):
        source = Path('/nonexistent/source.app')
        installed = Path('/nonexistent/Installed.app')
        requirement = mock.Mock(side_effect=requirements)
        stop = RuntimeError('reached the copy step')
        patches = dict(
            APP=installed,
            info=mock.Mock(),
            refuse_symlinks_inside=mock.Mock(),
            verify=mock.Mock(return_value={'CFBundleVersion': '1'}),
            signature_mode=mock.Mock(side_effect=lambda path: old_mode if path == installed else new_mode),
            requirement=requirement,
            quit_app=mock.Mock(),
            write_json=mock.Mock(),
        )
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.multiple(tool, **patches))
            stack.enter_context(mock.patch.object(tool.Path, 'exists', return_value=True))
            copy = stack.enter_context(mock.patch.object(tool.shutil, 'copytree', side_effect=stop))
            with self.assertRaises((tool.Failure, RuntimeError)) as raised:
                tool.install(source)
            tool.quit_app.assert_not_called()
            tool.write_json.assert_not_called()
        return raised.exception, requirement, copy

    def test_a_changed_certificate_requirement_is_still_refused(self):
        error, _, copy = self.install_over_existing('certificate', 'certificate', ['a', 'b'])
        self.assertIsInstance(error, tool.Failure)
        self.assertIn('Designated requirement changed', str(error))
        copy.assert_not_called()

    def test_ad_hoc_builds_differ_in_every_requirement_and_are_not_refused_for_it(self):
        error, requirement, copy = self.install_over_existing(tool.ADHOC, tool.ADHOC, ['cdhash 1', 'cdhash 2'])
        self.assertIsInstance(error, RuntimeError)
        requirement.assert_not_called()
        copy.assert_called_once()

    def test_both_mixed_mode_replacements_are_refused_before_mutating(self):
        for modes in ((tool.ADHOC, 'certificate'), ('certificate', tool.ADHOC)):
            with self.subTest(modes=modes):
                error, requirement, copy = self.install_over_existing(*modes, [])
                self.assertIsInstance(error, tool.Failure)
                self.assertIn('Sign the new build in the same mode', str(error))
                requirement.assert_not_called()
                copy.assert_not_called()


class VersionAndBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='spacewise-script-test-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def read_version(self, text):
        version_file = self.root / 'VERSION'
        version_file.write_text(text)
        with mock.patch.object(tool, 'VERSION_FILE', version_file):
            return tool.read_version()

    def test_the_version_comes_from_the_version_file_and_whitespace_is_ignored(self):
        self.assertEqual(self.read_version('0.1\n'), '0.1')
        self.assertEqual(self.read_version('  12.3.4  \n'), '12.3.4')

    def test_the_version_in_the_info_plist_is_the_version_file(self):
        version_file = self.root / 'VERSION'
        version_file.write_text('3.4.5\n')
        with mock.patch.object(tool, 'VERSION_FILE', version_file):
            self.assertEqual(tool.info_plist(7)['CFBundleShortVersionString'], '3.4.5')
            self.assertEqual(tool.info_plist(7)['CFBundleVersion'], '7')

    def test_a_malformed_version_is_refused_with_the_value_shown(self):
        for text in ('', 'v1.0', '1.2.3.4', '1.x', '0.1 beta'):
            with self.assertRaisesRegex(tool.Failure, 'VERSION must hold digits and dots'):
                self.read_version(text)

    def test_a_missing_version_file_is_a_failure_not_a_traceback(self):
        with mock.patch.object(tool, 'VERSION_FILE', self.root / 'missing'):
            with self.assertRaisesRegex(tool.Failure, 'Cannot read the version'):
                tool.read_version()

    def test_the_checked_in_version_file_and_icon_exist_and_are_valid(self):
        self.assertRegex(tool.read_version(), r'^\d+(\.\d+){0,2}$')
        self.assertTrue(tool.ICON_FILE.is_file())
        self.assertEqual(tool.ICON_FILE.read_bytes()[:4], b'icns')

    def test_the_info_plist_names_the_icon_and_accepts_folders_as_a_viewer(self):
        plist = tool.info_plist(1)
        self.assertEqual(plist['CFBundleIconFile'], 'AppIcon')
        self.assertEqual(plist['CFBundleIdentifier'], 'local.spacewise.app')  # the identifier is not changed here
        (document,) = plist['CFBundleDocumentTypes']
        self.assertEqual(document['LSItemContentTypes'], ['public.folder'])
        self.assertEqual(document['CFBundleTypeRole'], 'Viewer')
        self.assertEqual(document['LSHandlerRank'], 'Alternate')
        plistlib.dumps(plist)  # and it serialises


class GitStateTests(unittest.TestCase):
    ROOT = Path(tempfile.gettempdir()).resolve()

    def state(self, results, top=None):
        """`results` are the outputs of the two `run` calls; `top` is what `git rev-parse --show-toplevel` prints."""
        completed = subprocess.CompletedProcess([], 0 if top is not None else 128, stdout=(top or '') + '\n', stderr='')
        with mock.patch.object(tool, 'ROOT', self.ROOT):
            with mock.patch.object(tool.subprocess, 'run', return_value=completed):
                with mock.patch.object(tool, 'run', side_effect=results):
                    return tool.git_state()

    def test_a_checkout_reports_its_revision_and_whether_it_is_dirty(self):
        self.assertEqual(self.state(['abc123', ''], top=str(self.ROOT)), ('abc123', False))
        self.assertEqual(self.state(['abc123', ' M file'], top=str(self.ROOT)), ('abc123', True))

    def test_a_source_archive_with_no_git_directory_has_an_unknown_revision(self):
        self.assertEqual(self.state([], top=None), ('unknown', None))

    def test_an_archive_unpacked_inside_another_repository_does_not_report_that_repositorys_revision(self):
        self.assertEqual(self.state([], top=str(self.ROOT.parent)), ('unknown', None))

    def test_a_repository_with_no_commit_yet_is_unknown(self):
        self.assertEqual(self.state([tool.Failure('no HEAD')], top=str(self.ROOT)), ('unknown', None))

    def test_a_missing_git_executable_is_unknown_not_an_error(self):
        with mock.patch.object(tool, 'ROOT', self.ROOT):
            with mock.patch.object(tool.subprocess, 'run', side_effect=FileNotFoundError('git')):
                self.assertEqual(tool.git_state(), ('unknown', None))


class BuildStageTests(unittest.TestCase):
    """The whole build stage with swift, git and the filesystem outside a temporary directory mocked: what lands in
    the staged bundle for a checkout-less (source archive) build."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='spacewise-script-test-')
        self.root = Path(self.temp.name)
        (self.root / 'assets').mkdir()
        (self.root / 'assets/AppIcon.icns').write_bytes(b'icns fake icon')
        (self.root / 'VERSION').write_text('2.5\n')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'Spacewise').write_bytes(b'executable')
        (self.bin / 'SpacewiseControl').write_bytes(b'helper')
        self.out = self.root / '.spacewise'
        self.home = self.root / 'home'
        self.home.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def build(self, args, state=('unknown', None)):
        patches = [
            mock.patch.object(tool, 'ARGS', args),
            mock.patch.object(tool, 'ROOT', self.root),
            mock.patch.object(tool, 'HOME', self.home),
            mock.patch.object(tool, 'STATE', self.home / 'state'),
            mock.patch.object(tool, 'OUT', self.out),
            mock.patch.object(tool, 'STAGED', self.out / 'Spacewise.app'),
            mock.patch.object(tool, 'VERSION_FILE', self.root / 'VERSION'),
            mock.patch.object(tool, 'ICON_FILE', self.root / 'assets/AppIcon.icns'),
            mock.patch.object(tool, 'swift_build', lambda *a: str(self.bin)),
            mock.patch.object(tool, 'git_state', lambda: state),
            mock.patch.object(tool, 'run', lambda command, **kw: '26.0'),
        ]
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                tool.build()
        return self.out / 'Spacewise.app', stdout.getvalue()

    def test_a_build_without_git_succeeds_and_records_an_unknown_revision(self):
        bundle, out = self.build(arguments(command='build'))
        manifest = json.loads((bundle / 'Contents/Resources/build.json').read_text())
        self.assertEqual(manifest['revision'], 'unknown')
        self.assertIsNone(manifest['dirty'])
        self.assertIn('revision=unknown dirty=unknown', out)

    def test_the_bundle_has_the_icon_the_version_and_the_folder_document_type(self):
        bundle, _ = self.build(arguments(command='build'))
        self.assertEqual((bundle / 'Contents/Resources/AppIcon.icns').read_bytes(), b'icns fake icon')
        plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(plist['CFBundleShortVersionString'], '2.5')
        self.assertEqual(plist['LSApplicationCategoryType'], 'public.app-category.utilities')
        self.assertEqual(plist['NSHumanReadableCopyright'], 'Copyright (c) 2026 DataRelic')
        for folder in ('Desktop', 'Documents', 'Downloads'):
            self.assertEqual(
                plist[f'NS{folder}FolderUsageDescription'],
                f'Spacewise reads names, sizes and filesystem metadata in your {folder} folder to show what uses disk space during a scan.',
            )
        self.assertEqual(plist['CFBundleIconFile'], 'AppIcon')
        self.assertEqual(plist['CFBundleDocumentTypes'][0]['LSItemContentTypes'], ['public.folder'])

    def test_a_checkout_still_records_its_revision(self):
        bundle, out = self.build(arguments(command='build'), state=('abc123', True))
        manifest = json.loads((bundle / 'Contents/Resources/build.json').read_text())
        self.assertEqual((manifest['revision'], manifest['dirty']), ('abc123', True))
        self.assertIn('revision=abc123 dirty=True', out)

    def test_a_missing_icon_fails_before_building_anything_and_says_how_to_regenerate_it(self):
        (self.root / 'assets/AppIcon.icns').unlink()
        with self.assertRaisesRegex(tool.Failure, 'swift scripts/make-icon.swift'):
            self.build(arguments(command='build'))
        self.assertFalse((self.out / 'Spacewise.app').exists())


class CommandFailureTests(unittest.TestCase):
    def test_swift_failure_keeps_the_log_and_prints_only_its_tail(self):
        output = '\n'.join(f'compiler line {number}' for number in range(40)).encode()
        result = subprocess.CompletedProcess([], 1, stdout=b'', stderr=output)
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            out = Path(directory) / '.spacewise'
            stack.enter_context(mock.patch.object(tool, 'OUT', out))
            stack.enter_context(mock.patch.object(tool.subprocess, 'run', return_value=result))
            stderr = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            with self.assertRaisesRegex(tool.Failure, 'Command failed: swift'):
                tool.run(['swift', 'build'])
            self.assertEqual(stderr.getvalue().splitlines(), output.decode().splitlines()[-30:])
            self.assertEqual((out / 'last-error.log').read_bytes(), output)

    def test_long_build_reports_progress_before_starting_and_uses_local_swiftpm_paths(self):
        stderr = io.StringIO()

        def run(command, **kwargs):
            self.assertIn('building Spacewise in release mode', stderr.getvalue())
            for option in ('--cache-path', '--config-path', '--security-path'):
                self.assertEqual(command[command.index(option) + 1].parent, tool.OUT / 'swiftpm')
            self.assertEqual(command[command.index('--manifest-cache') + 1], 'local')

        with mock.patch.object(tool, 'run', side_effect=run), contextlib.redirect_stderr(stderr):
            tool.swift_build(False, '--product', 'Spacewise')
        self.assertEqual(len(stderr.getvalue().splitlines()), 1)

    def test_installer_cli_reports_a_missing_staged_bundle_in_one_line(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(test_install, 'SOURCE', Path(directory) / 'missing.app'):
                with mock.patch.object(test_install.unittest, 'main') as run_tests:
                    with contextlib.redirect_stderr(io.StringIO()) as stderr:
                        self.assertEqual(test_install.main(), 1)
                run_tests.assert_not_called()
                self.assertEqual(len(stderr.getvalue().splitlines()), 1)
                self.assertIn('./scripts/build.sh && ./scripts/sign.sh --adhoc', stderr.getvalue())


class DoctorTests(unittest.TestCase):
    def doctor(self, macos='15.0', swift='6.2', developer_dir='/Library/Developer/CommandLineTools', status=0):
        results = {
            ('sw_vers', '-productVersion'): macos,
            ('swift', '--version'): f'Apple Swift version {swift} (swiftlang)\nTarget: arm64-apple-macosx15.0',
            ('uname', '-m'): 'arm64',
            ('xcrun', '--show-sdk-version'): '15.0',
            ('xcode-select', '-p'): developer_dir,
        }
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(tool, 'ARGS', arguments(command='doctor')))
            stack.enter_context(mock.patch.object(tool, 'config', return_value={}))
            stack.enter_context(mock.patch.dict(os.environ, {}, clear=True))
            stack.enter_context(mock.patch.object(tool, 'run', side_effect=lambda args: results[tuple(args)]))
            readiness = stack.enter_context(mock.patch.object(tool.subprocess, 'run', return_value=mock.Mock(
                returncode=status
            )))
            stdout = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stderr = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            stack.enter_context(mock.patch.object(tool, 'parse_arguments', return_value=arguments(
                command='doctor', dry_run=False
            )))
            stack.enter_context(mock.patch.object(tool, 'run_locked_command', side_effect=lambda _: tool.doctor()))
            try:
                tool.main()
            except SystemExit as error:
                return error.code, stdout.getvalue(), stderr.getvalue(), readiness
            return 0, stdout.getvalue(), stderr.getvalue(), readiness

    def test_macos_below_15_fails_with_found_and_required_versions(self):
        code, _, err, readiness = self.doctor(macos='14.7')
        self.assertEqual(code, 1)
        self.assertIn('macOS 15 or later is required. Found 14.7', err)
        readiness.assert_not_called()

    def test_swift_below_6_2_fails_with_found_and_required_versions(self):
        code, _, err, readiness = self.doctor(swift='6.1.2')
        self.assertEqual(code, 1)
        self.assertIn('Swift 6.2 or later is required. Found Apple Swift version 6.1.2', err)
        readiness.assert_not_called()

    def test_command_line_tools_skip_the_xcode_first_launch_check(self):
        code, out, err, readiness = self.doctor()
        self.assertEqual(code, 0)
        self.assertIn('Command Line Tools selected', out)
        self.assertIn('Apple Swift version 6.2', out)
        self.assertEqual(err, '')
        readiness.assert_not_called()

    def test_xcode_first_launch_failure_is_reported_without_claiming_tools_are_unusable(self):
        code, _, err, readiness = self.doctor(developer_dir='/Applications/Xcode.app/Contents/Developer', status=69)
        self.assertEqual(code, 0)
        self.assertIn('first-launch check returned 69', err)
        readiness.assert_called_once_with(['xcodebuild', '-checkFirstLaunchStatus'], capture_output=True)


class StateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.home = root / 'home'
        self.home.mkdir()
        self.state = self.home / 'Applications/.SpacewiseDevelopment'
        self.out = root / '.spacewise'
        patch = mock.patch.multiple(tool, HOME=self.home, STATE=self.state, OUT=self.out)
        patch.start()
        self.addCleanup(patch.stop)

    def test_repository_commands_neither_create_home_state_nor_recover(self):
        actions = dict(zip(tool.REPO_COMMANDS, ('doctor', 'build', 'sign', 'print_verification', 'clean')))
        with mock.patch.multiple(tool, recover=mock.DEFAULT, **dict.fromkeys(actions.values(), mock.DEFAULT)):
            for command, action in actions.items():
                tool.run_locked_command(command)
                getattr(tool, action).assert_called_once()
            tool.recover.assert_not_called()
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertTrue((self.out / 'workspace.lock').is_file())

    def test_status_takes_both_locks_without_running_recovery(self):
        with mock.patch.multiple(tool, print_status=mock.DEFAULT, recover=mock.DEFAULT):
            tool.run_locked_command('status')
            tool.print_status.assert_called_once()
            tool.recover.assert_not_called()
        self.assertTrue((self.state / 'install.lock').is_file())

    def test_dev_holds_both_locks_through_every_step(self):
        calls = []

        def record(action):
            def check():
                for path in (self.out / 'workspace.lock', self.state / 'install.lock'):
                    with self.assertRaisesRegex(tool.Failure, 'holds ' + path.name):
                        with tool.lock(path):
                            self.fail('Dev released a lock early')
                calls.append(action)
            return check

        steps = ['recover', 'build', 'sign', 'install', 'relaunch']
        with mock.patch.multiple(tool, **{step: record(step) for step in steps}):
            tool.run_locked_command('dev')
        self.assertEqual(calls, steps)

    def test_build_counter_stays_in_workspace_and_increases_when_clock_goes_back(self):
        self.out.mkdir()
        with mock.patch.object(tool.time, 'time', side_effect=[100, 99, 200]):
            self.assertEqual([tool.next_build_number() for _ in range(3)], [100, 101, 200])
        self.assertEqual(json.loads((self.out / 'build-counter.json').read_text()), {'build': 200})
        self.assertEqual(list(self.home.iterdir()), [])


class DryRunSigningTests(unittest.TestCase):
    def plan(self, args, environment=None, configuration=None):
        patches = dict(ARGS=args, config=lambda: configuration or {}, installed_identities=mock.DEFAULT)
        with mock.patch.multiple(tool, **patches):
            with mock.patch.dict(os.environ, environment or {}, clear=True):
                description = tool.describe_plan()
                tool.installed_identities.assert_not_called()
        return description

    def test_dry_signing_describes_the_keychain_cases_when_there_is_no_selection(self):
        self.assertIn('ad-hoc with no suitable certificate, certificate with one', self.plan(arguments()))

    def test_dry_signing_respects_flag_environment_and_configuration(self):
        self.assertIn('ad-hoc signature', self.plan(arguments(adhoc=True)))
        self.assertIn('ad-hoc signature', self.plan(arguments(), {'SPACEWISE_SIGNING_IDENTITY': 'adhoc'}))
        self.assertIn('certificate signature', self.plan(arguments(), configuration={'identity': CERTIFICATE}))

    def test_dry_verification_defaults_to_the_bundles_mode_and_dry_build_has_no_signing_step(self):
        self.assertIn('verify each bundle in its own signing mode', self.plan(arguments(command='verify')))
        self.assertIn('require an ad-hoc signature', self.plan(arguments(command='verify', adhoc=True)))
        self.assertNotIn('signature', self.plan(arguments(command='build')))


class SetupTests(unittest.TestCase):
    """setup is the newcomer's one command: check the Mac, then build, sign, install and open."""

    def run_setup(self, args, environment=None, configured=None):
        steps = []
        names = ('doctor', 'build', 'sign', 'install', 'relaunch')
        patches = {name: (lambda name=name: steps.append(name)) for name in names}
        with mock.patch.multiple(tool, ARGS=args, config=lambda: configured or {}, **patches):
            with mock.patch.dict(os.environ, environment or {}, clear=True):
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    tool.setup()
        return steps, args, out.getvalue()

    def test_it_checks_the_mac_first_then_builds_signs_installs_and_opens(self):
        steps, _, out = self.run_setup(arguments(command='setup'))
        self.assertEqual(steps, ['doctor', 'build', 'sign', 'install', 'relaunch'])
        self.assertIn('installed at ~/Applications/Spacewise.app', out)
        self.assertIn('move it to the Trash', out)

    def test_it_signs_ad_hoc_when_nothing_is_selected_whatever_the_keychain_holds(self):
        _, args, _ = self.run_setup(arguments(command='setup'))
        self.assertTrue(args.adhoc)

    def test_an_explicitly_selected_identity_is_respected(self):
        for case in (
            dict(args=arguments(command='setup', identity=CERTIFICATE)),
            dict(args=arguments(command='setup'), environment={'SPACEWISE_SIGNING_IDENTITY': CERTIFICATE}),
            dict(args=arguments(command='setup'), configured={'identity': CERTIFICATE}),
        ):
            _, args, _ = self.run_setup(**case)
            self.assertFalse(args.adhoc, case)

    def test_a_failed_check_stops_before_anything_is_built(self):
        build = mock.Mock()
        failing = mock.Mock(side_effect=tool.Failure('Swift 6.2 or later is required. Found Swift 5.10.'))
        with mock.patch.multiple(tool, ARGS=arguments(command='setup'), config=lambda: {}, doctor=failing, build=build):
            with mock.patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(tool.Failure, 'Swift 6.2'):
                tool.setup()
        build.assert_not_called()

    def test_the_dry_run_names_every_step(self):
        with mock.patch.multiple(tool, ARGS=arguments(command='setup'), config=lambda: {}):
            with mock.patch.dict(os.environ, {}, clear=True):
                plan = tool.describe_plan()
        for step in ('check macOS and Swift', 'native build', 'ad-hoc signature', 'install and open'):
            self.assertIn(step, plan)


class DispatcherTests(unittest.TestCase):
    def dry_run(self, script, *args):
        return subprocess.run(
            [str(SCRIPTS / script), '--dry-run', *args], capture_output=True, text=True, cwd='/'
        )

    def test_every_command_name_is_a_link_to_the_one_dispatcher(self):
        dispatcher = SCRIPTS / 'spacewise.sh'
        for command in COMMANDS:
            link = SCRIPTS / (command + '.sh')
            self.assertTrue(link.is_symlink(), command + '.sh should be a symlink')
            self.assertEqual(link.resolve(), dispatcher.resolve())

    def test_each_name_runs_its_own_command(self):
        for command in COMMANDS:
            process = self.dry_run(command + '.sh')
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(process.stdout.startswith('Plan: ' + command + ';'), process.stdout)

    def test_arguments_are_forwarded(self):
        process = self.dry_run('sign.sh', '--adhoc')
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn('ad-hoc signature', process.stdout)

    def test_the_command_can_also_be_named_as_an_argument(self):
        process = self.dry_run('spacewise.sh', 'status')
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(process.stdout.startswith('Plan: status;'))

    def test_without_a_command_it_prints_usage_and_fails(self):
        process = subprocess.run([str(SCRIPTS / 'spacewise.sh')], capture_output=True, text=True, cwd='/')
        self.assertEqual(process.returncode, 64)
        self.assertIn('usage: spacewise.sh <command>', process.stderr)


if __name__ == '__main__':
    unittest.main()
