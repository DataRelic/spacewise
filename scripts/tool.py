#!/usr/bin/env python3
"""Local development tooling. No privileges, credentials, TCC edits or content scanning."""

import argparse
import contextlib
import ctypes
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / '.spacewise'
HOME = Path.home()
APP = HOME / 'Applications/Spacewise.app'
STATE = HOME / 'Applications/.SpacewiseDevelopment'
BUNDLE = 'local.spacewise.app'
STAGED = OUT / 'Spacewise.app'
# The marketing version lives in one place, a plain-text file at the repository root. Build numbers are separate.
VERSION_FILE = ROOT / 'VERSION'
# The icon is rendered once and committed (see make-icon.swift), so a build needs no extra tool.
ICON_FILE = ROOT / 'assets/AppIcon.icns'
ICON_NAME = 'AppIcon'
PREVIOUS = STATE / 'previous.app'
JOURNAL = STATE / 'transaction.json'

COMMANDS = [
    'setup', 'doctor', 'build', 'sign', 'verify', 'install', 'relaunch', 'dev', 'rollback', 'clean', 'quit', 'status'
]
SIGNING_AUTHORITIES = ('Apple Development:', 'Developer ID Application:')
# Ask for an ad-hoc signature (`codesign --sign -`) with --adhoc, or by giving this word as the identity.
ADHOC = 'adhoc'
LOG_LIMIT_BYTES = 200000
LOG_MAX_AGE_SECONDS = 7 * 86400
QUIT_TIMEOUT_SECONDS = 15
LAUNCH_TIMEOUT_SECONDS = 8
# renameatx_np(2): both paths relative to the current directory, and swap them atomically.
AT_FDCWD = -2
RENAME_SWAP = 2

# Set by main(); the functions below read it. The installer tests set their own.
ARGS = None


class Failure(Exception):
    pass


# MARK: Running commands


def run(args, **kwargs):
    process = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if process.returncode:
        save_failure_log(process)
        if list(args[:2]) == ['swift', 'build']:
            output = (process.stdout + b'\n' + process.stderr).decode(errors='replace')
            print('\n'.join(output.strip().splitlines()[-30:]), file=sys.stderr)
        raise Failure(
            'Command failed: ' + Path(str(args[0])).name + '; inspect ignored .spacewise/last-error.log locally'
        )
    return process.stdout.decode().strip()


def save_failure_log(process):
    """Commands can print account-qualified paths and identity names, so diagnostics stay local and bounded."""
    safe_directory(OUT)
    log = OUT / 'last-error.log'
    if log.is_symlink():
        raise Failure('Refusing symlink log')
    log.write_bytes((process.stdout + process.stderr)[-LOG_LIMIT_BYTES:])


# MARK: Signing identity


def config():
    path = ROOT / '.spacewise.local.json'
    return json.loads(path.read_text()) if path.exists() else {}


def installed_identities():
    """(SHA-1, name) of every code-signing identity in the keychain."""
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    return re.findall(r'\b([A-F0-9]{40}) "([^"]+)"', listing)


def explicit_identity():
    if getattr(ARGS, 'adhoc', False):
        return ADHOC
    selected = ARGS.identity or os.environ.get('SPACEWISE_SIGNING_IDENTITY') or config().get('identity')
    if selected is not None and not isinstance(selected, str):
        raise Failure('The signing identity must be a string')
    return selected or None


def identity_choice():
    """(identity, automatic): a certificate's SHA-1, or ADHOC for an ad-hoc signature, and whether ADHOC was chosen
    only because nothing else was available.

    Ad-hoc signing is chosen explicitly with --adhoc or the word `adhoc` as the identity (flag, environment variable
    or .spacewise.local.json). It is chosen automatically only when no identity was selected at all and the keychain
    holds no suitable one. A selected certificate that is missing, or several suitable certificates with none
    selected, still fail: someone who has certificates should never get an ad-hoc build by accident.
    """
    selected = explicit_identity()
    if selected == ADHOC:
        return ADHOC, False
    found = installed_identities()
    suitable = [sha for sha, name in found if name.startswith(SIGNING_AUTHORITIES)]
    if selected:
        if selected not in [sha for sha, _ in found]:
            raise Failure(
                'Configured certificate/private key unavailable; select an existing persistent identity manually.'
            )
        return selected, False
    if not suitable:
        return ADHOC, True
    if len(suitable) != 1:
        raise Failure(
            'Select one existing certificate SHA in .spacewise.local.json; '
            'no certificates or trust will be created.'
        )
    return suitable[0], False


# MARK: Verifying a bundle


def info(path):
    """The Info.plist of a development bundle. Refuses anything that is not a plain Spacewise bundle."""
    try:
        if path.is_symlink() or not path.is_dir():
            raise ValueError()
        value = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
        if value['CFBundleIdentifier'] != BUNDLE or value['CFBundleExecutable'] != 'Spacewise':
            raise ValueError()
        return value
    except (OSError, ValueError, KeyError):
        raise Failure('Refusing invalid, conflicting or symlink application bundle')


def requirement(path):
    result = subprocess.run(['codesign', '-d', '-r-', str(path)], capture_output=True, text=True)
    match = re.search(r'designated => (.*)', result.stdout + result.stderr)
    if result.returncode or not match:
        raise Failure('Missing designated signing requirement')
    return match[1]


def verify(path, signer=None):
    value = info(path)
    refuse_symlinks_inside(path)
    check_version_metadata(value)
    check_signature(path, signer)
    check_no_entitlements(path)
    check_architecture(path)
    check_manifest(path, value)
    check_deployment_platform(path)
    requirement(path)
    return value


def refuse_symlinks_inside(path):
    for child in path.rglob('*'):
        if child.is_symlink():
            raise Failure('Unexpected symlink in application bundle')


def check_version_metadata(value):
    if not value.get('CFBundleVersion', '').isdigit() or value.get('LSMinimumSystemVersion') != '15.0':
        raise Failure('Invalid version or deployment metadata')


def signature_mode(path):
    details = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True)
    if details.returncode:
        raise Failure('Cannot read the code signature from ' + path.name)
    lines = details.stderr.splitlines()
    # A freshly built binary carries only the linker's own ad-hoc signature, which does not seal the bundle.
    if any('linker-signed' in line for line in lines):
        raise Failure(
            path.name + ' is built but not signed yet; run ./scripts/sign.sh --adhoc, '
            'or ./scripts/sign.sh with a certificate'
        )
    has_authority = any(line.startswith('Authority=') for line in lines)
    if 'Signature=adhoc' in lines and not has_authority:
        return ADHOC
    if 'Signature=adhoc' not in lines and has_authority:
        return 'certificate'
    raise Failure('Cannot determine the code signature mode for ' + path.name)


def certificate_to_pin():
    """The certificate a certificate-signed bundle is checked against when none was selected: the one suitable
    certificate in the keychain, as for signing. Only an ad-hoc bundle is taken in its own mode without a lookup,
    because it has no signer to pin."""
    signer, _ = identity_choice()
    if signer == ADHOC:
        raise Failure(
            'This bundle is signed with a certificate, but no suitable certificate is installed to check it against; '
            'select one with --identity <SHA-1>'
        )
    return signer


def check_signature(path, signer=None):
    signer = signer or explicit_identity()
    mode = signature_mode(path)
    if signer == ADHOC and mode != ADHOC:
        raise Failure('Ad-hoc signature required; this bundle is signed with a certificate')
    if signer and signer != ADHOC and mode == ADHOC:
        raise Failure('Certificate-backed signature required; ad-hoc rejected')
    if not signer and mode != ADHOC:
        signer = certificate_to_pin()
    # The identifier requirement also applies to ad-hoc signatures. A certificate build additionally pins its leaf.
    designated = '=identifier "' + BUNDLE + '"'
    if signer and signer != ADHOC:
        if not re.fullmatch(r'[A-F0-9]{40}', signer):
            raise Failure('Select a signing certificate by its 40-character SHA-1')
        designated += ' and certificate leaf = H"' + signer + '"'
    # Verbose verification also checks the bundle against its own designated requirement.
    run(['codesign', '--verify', '--strict', '--verbose', '-R', designated, path])


def check_no_entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True)
    if result.returncode:
        raise Failure('Cannot inspect application entitlements')
    if not result.stdout.strip():
        return
    try:
        entitlements = plistlib.loads(result.stdout)
    except Exception:
        raise Failure('Unreadable entitlements')
    if entitlements:
        raise Failure('Unexpected entitlements; Spacewise requires an empty entitlement set')


def check_architecture(path):
    bundle_architectures = run(['lipo', '-archs', path / 'Contents/MacOS/Spacewise'])
    if bundle_architectures != run(['uname', '-m']):
        raise Failure('Architecture mismatch')


def check_manifest(path, value):
    manifest = json.loads((path / 'Contents/Resources/build.json').read_text())
    if str(manifest['build']) != value['CFBundleVersion']:
        raise Failure('Manifest/build mismatch')


def check_deployment_platform(path):
    build_info = run(['vtool', '-show-build', path / 'Contents/MacOS/Spacewise'])
    if 'platform MACOS' not in build_info or 'minos 15.0' not in build_info:
        raise Failure('Mach-O deployment platform mismatch')


# MARK: Development state and the installation lock


def safe_directory(path):
    if path.is_symlink():
        raise Failure('Refusing symlink development directory: ' + path.name)
    path.mkdir(exist_ok=True)


def safe_state():
    safe_directory(HOME / 'Applications')
    safe_directory(STATE)
    marker = STATE / '.metadata_never_index'
    if marker.is_symlink():
        raise Failure('Refusing symlink Spotlight marker')
    if not marker.exists():
        marker.touch()


@contextlib.contextmanager
def lock(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure('Another Spacewise command holds ' + path.name)
        yield
    finally:
        os.close(fd)


def trim_logs():
    """Logs older than seven days are removed and longer ones truncated, so diagnostics stay bounded."""
    for path in OUT.glob('*.log'):
        if path.is_symlink():
            raise Failure('Refusing symlink log')
        if time.time() - path.stat().st_mtime > LOG_MAX_AGE_SECONDS:
            path.unlink()
        elif path.stat().st_size > LOG_LIMIT_BYTES:
            path.write_bytes(path.read_bytes()[-LOG_LIMIT_BYTES:])


def write_json(path, value):
    temp = path.with_suffix('.tmp')
    fd = os.open(temp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file, sort_keys=True)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp, path)


def swap(a, b):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameatx_np(AT_FDCWD, os.fsencode(a), AT_FDCWD, os.fsencode(b), RENAME_SWAP) != 0:
        raise Failure('Atomic same-filesystem replacement failed (errno %s)' % ctypes.get_errno())


# MARK: Recovering an interrupted installation


def recover(interrupted=True):
    """Finish or undo the installation recorded in the journal. A command calls it first, to settle one that was
    interrupted; `install` calls it last, to settle its own, which is not worth a message."""
    if JOURNAL.is_symlink():
        raise Failure('Refusing symlink recovery journal')
    if not JOURNAL.exists():
        return
    record = json.loads(JOURNAL.read_text())
    if (
        not isinstance(record, dict)
        or not isinstance(record.get('stage'), str)
        or not re.fullmatch(r'stage-[a-f0-9]{32}\.app', record['stage'])
        or 'old' not in record
        or (record['old'] is not None and (not isinstance(record['old'], str) or not record['old'].isdigit()))
        or not isinstance(record.get('new'), str)
        or not record['new'].isdigit()
        or not isinstance(record.get('reject', False), bool)
        or ('candidate_inode' in record and type(record['candidate_inode']) is not int)
    ):
        raise Failure('Invalid recovery journal; inspect manually')
    stage = STATE / record['stage']
    rejected = stage.with_suffix('.rejected')
    if any(path.is_symlink() for path in (APP, stage, rejected, PREVIOUS)):
        raise Failure('Unexpected symlink during recovery; all copies retained')
    quit_app()

    error = None
    if not record.get('reject'):
        try:
            finish_install(record, stage, interrupted)
        except CandidateRejected as failure:
            error = failure
            record['reject'] = True
            write_json(JOURNAL, record)
    if record.get('reject'):
        restore_and_retain(record, stage, rejected)

    JOURNAL.unlink()
    if error and not interrupted:
        raise error
    if interrupted:
        print('Recovered interrupted installation transaction')


class CandidateRejected(Failure):
    pass


def verify_build(path, expected):
    if verify(path)['CFBundleVersion'] != expected:
        raise Failure('Unexpected build during recovery; all copies retained')


def verify_candidate(path, record, interrupted):
    try:
        if not interrupted and os.environ.get('SPACEWISE_TEST_FAIL') == 'after-swap':
            raise Failure('Injected post-replacement verification failure')
        value = verify(path)
    except (Failure, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise CandidateRejected(str(error)) from error
    if value['CFBundleVersion'] != record['new']:
        raise Failure('Unexpected candidate build during recovery; all copies retained')


def candidate_at(path, record):
    if not path.exists():
        return False
    # A same-filesystem rename preserves the directory inode, even when build numbers coincide.
    if 'candidate_inode' in record:
        return path.stat().st_ino == record['candidate_inode']
    # Legacy journals recorded only build numbers. An invalid installed copy can still be
    # recovered if the stage independently verifies as the old build.
    if record['old'] == record['new']:
        raise Failure('Ambiguous legacy recovery journal; all copies retained')
    if record['old'] is None:
        return True  # Either first-install endpoint can only contain the candidate.
    try:
        if info(path)['CFBundleVersion'] == record['new']:
            return True
        verify_build(path, record['old'])
        return False
    except (Failure, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        verify_build(STATE / record['stage'], record['old'])
        return True


def finish_install(record, stage, interrupted):
    if not APP.exists() and not record['old'] and candidate_at(stage, record):
        verify_candidate(stage, record, interrupted)
        os.replace(stage, APP)
    if candidate_at(APP, record):
        verify_candidate(APP, record, interrupted)
        if record['old']:
            if stage.exists():
                verify_build(stage, record['old'])
                keep_stage_as_previous(stage)
            else:
                verify_build(PREVIOUS, record['old'])
        elif stage.exists():
            raise Failure('Unexpected first-install stage; all copies retained')
    elif record['old']:
        verify_build(APP, record['old'])
        if stage.exists():
            if 'candidate_inode' in record and not candidate_at(stage, record):
                raise Failure('Unexpected installation stage; all copies retained')
            raise CandidateRejected('Installation stopped before replacement')
        if 'candidate_inode' in record:
            raise Failure('Installation candidate is missing; all copies retained')
    else:
        raise Failure('Interrupted installation requires manual inspection; all copies retained')


def restore_and_retain(record, stage, rejected):
    if stage.exists() and rejected.exists():
        raise Failure('Rejected bundle archive already exists; all copies retained')
    if candidate_at(APP, record):
        if record['old']:
            verify_build(stage, record['old'])
            swap(APP, stage)
        else:
            if stage.exists() or rejected.exists():
                raise Failure('Unexpected first-install recovery copies; all copies retained')
            os.replace(APP, stage)
    if record['old']:
        verify_build(APP, record['old'])
    elif APP.exists():
        raise Failure('Unexpected installed bundle during recovery; all copies retained')
    retained = stage if stage.exists() else rejected
    if not retained.exists() or ('candidate_inode' in record and not candidate_at(retained, record)):
        raise Failure('Rejected bundle is missing or changed; inspect recovery state manually')
    if retained == stage:
        os.replace(stage, rejected)


def keep_stage_as_previous(stage):
    if PREVIOUS.exists():
        retire_previous()
    os.replace(stage, PREVIOUS)


def retire_previous():
    verify(PREVIOUS)
    remove_retired_copy()
    os.replace(PREVIOUS, STATE / 'retired.app')


# MARK: Building


def swift_build(*args):
    """Release `swift build`, with SwiftPM's own cache and configuration kept inside the checkout."""
    if '--product' in args:
        product = args[args.index('--product') + 1]
        print(f'Spacewise: building {product} in release mode. This may take a few minutes.',
              file=sys.stderr, flush=True)
    swiftpm = OUT / 'swiftpm'
    return run(
        ['swift', 'build', '-c', 'release', '--cache-path', swiftpm / 'cache',
         '--config-path', swiftpm / 'config', '--security-path', swiftpm / 'security',
         '--manifest-cache', 'local', *args],
        cwd=ROOT,
    )


def control():
    helper = OUT / 'SpacewiseControl'
    if not helper.exists():
        build_control_helper(helper)
    return helper


def build_control_helper(helper):
    swift_build('--product', 'SpacewiseControl')
    shutil.copy2(Path(swift_build('--show-bin-path')) / 'SpacewiseControl', helper)


def processes():
    return json.loads(run([control(), 'status']))


def quit_app():
    apps = processes()
    if any(app['exact'] != 'true' for app in apps):
        raise Failure('A different Spacewise copy is running; close it manually')
    if not apps:
        return
    run([control(), 'quit'])
    wait_until_not_running()


def wait_until_not_running():
    deadline = time.monotonic() + QUIT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if not processes():
            return
        time.sleep(.2)
    raise Failure('Spacewise is still running after 15 seconds; update aborted without force termination')


def next_build_number():
    counter = OUT / 'build-counter.json'
    if counter.is_symlink():
        raise Failure('Refusing symlink build counter')
    previous = json.loads(counter.read_text())['build'] if counter.exists() else 0
    number = max(previous + 1, int(time.time()))
    write_json(counter, {'build': number})
    return number


def build_manifest(number, revision, dirty):
    return dict(
        build=number,
        revision=revision,
        dirty=dirty,
        configuration='release',
        sdk=run(['xcrun', '--show-sdk-version']),
        timestamp=int(time.time()),
        deployment='15.0',
    )


def read_version():
    """The marketing version, from the VERSION file: digits and dots, such as 0.1 or 1.2.3."""
    try:
        version = VERSION_FILE.read_text().strip()
    except OSError as error:
        raise Failure('Cannot read the version from VERSION (%s)' % error.strerror)
    if not re.fullmatch(r'\d+(\.\d+){0,2}', version):
        raise Failure('VERSION must hold digits and dots such as 0.1 or 1.2.3, not %r' % version)
    return version


def folder_usage(folder):
    return f'Spacewise reads names, sizes and filesystem metadata in your {folder} folder to show what uses disk space during a scan.'


def info_plist(number):
    return dict(
        CFBundleIdentifier=BUNDLE,
        CFBundleExecutable='Spacewise',
        CFBundleName='Spacewise',
        CFBundleDisplayName='Spacewise',
        CFBundlePackageType='APPL',
        CFBundleShortVersionString=read_version(),
        CFBundleVersion=str(number),
        CFBundleIconFile=ICON_NAME,
        # Without this the Dock does not accept a folder dropped on the app's icon. Viewer, because Spacewise only
        # looks; Alternate, so it is offered for folders without taking Finder's place as their default.
        CFBundleDocumentTypes=[
            dict(
                CFBundleTypeName='Folder',
                CFBundleTypeRole='Viewer',
                LSItemContentTypes=['public.folder'],
                LSHandlerRank='Alternate',
            )
        ],
        LSMinimumSystemVersion='15.0',
        LSApplicationCategoryType='public.app-category.utilities',
        NSDesktopFolderUsageDescription=folder_usage('Desktop'),
        NSDocumentsFolderUsageDescription=folder_usage('Documents'),
        NSDownloadsFolderUsageDescription=folder_usage('Downloads'),
        NSHumanReadableCopyright='Copyright (c) 2026 DataRelic',
        NSHighResolutionCapable=True,
        NSPrincipalClass='NSApplication',
        NSSupportsAutomaticTermination=False,
        NSSupportsSuddenTermination=False,
    )


def git_state():
    """(revision, dirty) of this checkout. ('unknown', None) when it is not one, such as a downloaded source archive,
    including an archive unpacked inside some other repository, whose revision would be the wrong project's."""
    try:
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, cwd=ROOT)
    except OSError:
        return 'unknown', None
    if top.returncode or Path(top.stdout.strip()).resolve() != ROOT:
        return 'unknown', None
    try:
        return run(['git', 'rev-parse', 'HEAD'], cwd=ROOT), bool(run(['git', 'status', '--porcelain'], cwd=ROOT))
    except Failure:
        return 'unknown', None  # a repository with no commit yet


def build():
    safe_directory(OUT)
    if not ICON_FILE.is_file():
        raise Failure('Missing assets/AppIcon.icns; regenerate it with: swift scripts/make-icon.swift')
    revision, dirty = git_state()
    swift_build('--product', 'Spacewise')
    swift_build('--product', 'SpacewiseControl')
    app_binpath = Path(swift_build('--show-bin-path'))
    shutil.copy2(app_binpath / 'SpacewiseControl', OUT / 'SpacewiseControl')
    candidate = OUT / ('build-' + uuid.uuid4().hex + '.app')
    (candidate / 'Contents/MacOS').mkdir(parents=True)
    (candidate / 'Contents/Resources').mkdir()
    shutil.copy2(app_binpath / 'Spacewise', candidate / 'Contents/MacOS/Spacewise')
    shutil.copy2(ICON_FILE, candidate / 'Contents/Resources' / (ICON_NAME + '.icns'))
    number = next_build_number()
    write_json(candidate / 'Contents/Resources/build.json', build_manifest(number, revision, dirty))
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(info_plist(number)))
    if STAGED.exists():
        shutil.rmtree(STAGED)
    os.replace(candidate, STAGED)
    dirty_text = 'unknown' if dirty is None else dirty
    print('Built revision=%s dirty=%s build=%s' % (revision, dirty_text, number))


# MARK: Signing and installing


AUTOMATIC_ADHOC_NOTICE = (
    'Spacewise: no signing certificate is selected and none is installed, so this build is signed ad-hoc. '
    'To choose that deliberately, pass --adhoc; to use a certificate, pass --identity <SHA-1>. '
    'See "Signing" in docs/LOCAL-DEVELOPMENT.md.'
)
ADHOC_BUILD_NOTICE = (
    'Spacewise: this is an ad-hoc build, not a certificate-backed one. It runs on this Mac, but macOS treats '
    'every rebuild as a different app, so a permission such as Full Disk Access must be granted again after each '
    'update, and verification covers the bundle\'s integrity, not who made it.'
)


def sign():
    signer, automatic = identity_choice()
    info(STAGED)
    refuse_symlinks_inside(STAGED)
    if signer == ADHOC:
        if automatic:
            print(AUTOMATIC_ADHOC_NOTICE, file=sys.stderr)
        run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', STAGED])
        verify(STAGED, signer)
        print('Signed ad-hoc and verified (an ad-hoc build, not certificate-backed)')
        print(ADHOC_BUILD_NOTICE, file=sys.stderr)
        return
    run(['codesign', '--force', '--sign', signer, '--options', 'runtime', '--timestamp=none', STAGED])
    verify(STAGED, signer)
    print('Signed and verified with persistent certificate-backed identity')


def check_replacement(source):
    info(APP)
    refuse_symlinks_inside(APP)
    old_mode = signature_mode(APP)
    if old_mode != signature_mode(source):
        raise Failure(
            'Signing mode differs from the installed app. Sign the new build in the same mode, '
            'or quit Spacewise and move the installed app to Trash before installing in the new mode.'
        )
    old = verify(APP)
    # Ad-hoc requirements contain the build's own hash, so only compare certificate-backed requirements.
    if old_mode != ADHOC and requirement(APP) != requirement(source):
        raise Failure('Designated requirement changed; use the same certificate; installed app untouched')
    return old


def install(source=None):
    source = STAGED if source is None else source
    verify(source)
    old = check_replacement(source) if APP.exists() or APP.is_symlink() else None
    stage = STATE / ('stage-' + uuid.uuid4().hex + '.app')
    shutil.copytree(source, stage, symlinks=True)
    staged = verify(stage)
    try:
        quit_app()
    except Exception:
        shutil.rmtree(stage)
        raise
    record = dict(stage=stage.name, old=old['CFBundleVersion'] if old else None,
                  new=staged['CFBundleVersion'], candidate_inode=stage.stat().st_ino)
    write_json(JOURNAL, record)
    put_stage_in_place(stage, old)
    recover(interrupted=False)
    print('Installed build=%s at ~/Applications/Spacewise.app (not launched)' % info(APP)['CFBundleVersion'])


def put_stage_in_place(stage, old):
    if old:
        swap(APP, stage)
    else:
        os.replace(stage, APP)


# MARK: Launching


def relaunch():
    value = verify(APP)
    quit_app()
    # Launched exactly as Finder launches it. Anything the app writes to stderr is kept for diagnosis.
    run(['open', '--stderr', OUT / 'launch-error.log', APP])
    wait_for_launch()
    time.sleep(1)
    current = processes()
    if len(current) != 1 or current[0]['exact'] != 'true':
        raise Failure('Exact installed process not alive after startup interval')
    remove_retired_copy()
    print('Launched ~/Applications/Spacewise.app; build=%s pid=%s' % (value['CFBundleVersion'], current[0]['pid']))


def wait_for_launch():
    deadline = time.monotonic() + LAUNCH_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if any(app['exact'] == 'true' for app in processes()):
            return
        time.sleep(.2)
    raise Failure('Installed process did not start; inspect .spacewise/launch-error.log; rollback available')


def remove_retired_copy():
    retired = STATE / 'retired.app'
    if retired.is_symlink():
        raise Failure('Refusing symlink retired bundle')
    if retired.exists():
        verify(retired)
        # Detach before recursive removal so an interruption cannot leave a partial
        # bundle at a path the next installation or launch needs to verify.
        discarded = STATE / ('discarded-' + uuid.uuid4().hex)
        os.replace(retired, discarded)
        shutil.rmtree(discarded)


# MARK: The other commands


def require_version(found, pattern, name, minimum):
    match = re.search(pattern, found)
    if not match or tuple(map(int, match.groups())) < minimum:
        needed = '.'.join(map(str, minimum))
        version = found.splitlines()[0] if found else "no version"
        raise Failure(f'{name} {needed} or later is required. Found {version}.')


def doctor():
    system = run(['sw_vers', '-productVersion'])
    require_version(system, r'^(\d+)', 'macOS', (15,))
    swift = run(['swift', '--version'])
    require_version(swift, r'\bSwift version (\d+)\.(\d+)', 'Swift', (6, 2))
    architecture = run(['uname', '-m'])
    sdk = run(['xcrun', '--show-sdk-version'])
    print('macOS=' + system + ' arch=' + architecture + ' SDK=' + sdk)
    print(swift)
    developer_dir = os.environ.get('DEVELOPER_DIR') or run(['xcode-select', '-p'])
    if Path(developer_dir).resolve().name == 'CommandLineTools':
        print('Command Line Tools selected. Xcode first-launch setup is unnecessary.')
    else:
        first_launch = subprocess.run(['xcodebuild', '-checkFirstLaunchStatus'], capture_output=True)
        if first_launch.returncode:
            print(
                f'Xcode first-launch check returned {first_launch.returncode}. '
                'If the build fails, open Xcode to check for pending setup.',
                file=sys.stderr,
            )
        else:
            print('Xcode first-launch readiness=ready')
    print('Signing: ' + describe_signing())
    print('Canonical target writable=' + str(os.access(APP.parent if APP.parent.exists() else HOME, os.W_OK)))
    print('Conflicting system copy=' + str(Path('/Applications/Spacewise.app').exists()))


def rollback():
    verify(PREVIOUS)
    saved = STATE / ('rollback-' + uuid.uuid4().hex + '.app')
    shutil.copytree(PREVIOUS, saved, symlinks=True)
    try:
        install(saved)
        relaunch()
    finally:
        shutil.rmtree(saved)


def dev():
    build()
    sign()
    install()
    relaunch()


SETUP_DONE_NOTICE = (
    'Spacewise is installed at ~/Applications/Spacewise.app and running. Run this command again to update it. '
    'To remove it, quit it and move it to the Trash.'
)


def setup():
    """The one command for someone who only wants the app: check the Mac, then build, sign, install and open it.
    It signs ad-hoc unless an identity was selected explicitly, so it behaves the same whether the keychain holds no
    certificate, one or several."""
    if explicit_identity() is None:
        ARGS.adhoc = True
    doctor()
    dev()
    print(SETUP_DONE_NOTICE)


def clean():
    for path in [ROOT / '.build', STAGED]:
        if path.exists() and not path.is_symlink():
            shutil.rmtree(path)
    for path in OUT.glob('build-*.app'):
        if not path.is_symlink():
            shutil.rmtree(path)
    if ARGS.logs:
        for path in OUT.glob('*.log'):
            path.unlink()
    print('Removed scoped build artifacts; installed app, rollback, preferences and scanned files preserved')


def print_verification():
    staged = verify(STAGED)
    print(json.dumps({'verified': True, 'build': staged['CFBundleVersion']}))


def print_status():
    print(json.dumps(processes()))


# MARK: Command line


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=COMMANDS)
    parser.add_argument('--identity')
    parser.add_argument(
        '--adhoc',
        action='store_true',
        help='choose ad-hoc signing or require an ad-hoc signature when verifying',
    )
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--logs', action='store_true')
    arguments = parser.parse_args()
    if arguments.adhoc and arguments.identity:
        parser.error('--adhoc and --identity cannot be combined')
    return arguments


def describe_signing():
    signer = explicit_identity()
    if signer == ADHOC:
        return 'ad-hoc signature'
    if signer:
        return 'certificate signature if the selected identity is available'
    return 'ad-hoc with no suitable certificate, certificate with one, selection required with several'


def describe_plan():
    command = ARGS.command
    plan = [command]
    if command == 'setup':
        plan.append('check macOS and Swift')
    if command in ('build', 'dev', 'setup'):
        plan.append('release macOS 15.0 native build')
    if command == 'setup':
        plan.append(describe_signing() if explicit_identity() else 'ad-hoc signature')
    if command in ('sign', 'dev', 'doctor'):
        plan.append(describe_signing())
    if command in ('verify', 'install', 'relaunch', 'rollback'):
        signer = explicit_identity()
        plan.append({
            ADHOC: 'require an ad-hoc signature',
            None: 'verify each bundle in its own signing mode',
        }.get(signer, 'require the selected certificate signature'))
    if command not in REPO_COMMANDS:
        plan.append('~/Applications/Spacewise.app')
    if command in ('relaunch', 'dev', 'rollback'):
        plan.append('launch')
    if command == 'setup':
        plan.append('install and open')
    return 'Plan: ' + '; '.join(plan) + '; no changes'


REPO_COMMANDS = ('doctor', 'build', 'sign', 'verify', 'clean')


def run_locked_command(command):
    safe_directory(OUT)
    with contextlib.ExitStack() as locks:
        locks.enter_context(lock(OUT / 'workspace.lock'))
        if command not in REPO_COMMANDS:
            safe_state()
            locks.enter_context(lock(STATE / 'install.lock'))
        trim_logs()
        if command in ('setup', 'install', 'relaunch', 'dev', 'rollback', 'quit'):
            recover()
        actions = dict(setup=setup, doctor=doctor, build=build, sign=sign, verify=print_verification,
                       install=install, relaunch=relaunch, dev=dev, rollback=rollback, clean=clean, quit=quit_app,
                       status=print_status)
        actions[command]()


def main():
    global ARGS
    ARGS = parse_arguments()
    try:
        if ARGS.dry_run:
            print(describe_plan())
        else:
            run_locked_command(ARGS.command)
    except (Failure, OSError, ValueError, KeyError) as error:
        print('Spacewise: ' + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
