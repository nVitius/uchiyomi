import copy
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'ios/scripts'))
from release_lib import inspect_payload, make_source, tag_version, validate_record, verify_ipa
from github_release import fetch_records, release_assets, verify_existing_files


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.listing = json.loads((ROOT/'ios/distribution/listing.json').read_text())
        self.info = {
            'CFBundleIdentifier': self.listing['bundleIdentifier'], 'CFBundleExecutable': 'Uchiyomi',
            'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1001', 'MinimumOSVersion': '17.0',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'WKAppBoundDomains': ['localhost'],
            'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
            'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
            'NSLocalNetworkUsageDescription': 'Connect to your server on your local network.'
        }
        self.ipa = self.root/'Uchiyomi-0.1.0-1001.ipa'
        self.write_ipa()
        self.record = {
            'artifact': self.ipa.name, 'distribution': 'altstore', 'version': '0.1.0', 'build': '1001',
            'bundleIdentifier': self.info['CFBundleIdentifier'], 'minimumIOS': '17.0',
            'releaseTag': 'ios-v0.1.0-beta.1', 'sha256': hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
            'size': self.ipa.stat().st_size, 'entitlements': {},
            'privacyPermissions': {'NSLocalNetworkUsageDescription': self.info['NSLocalNetworkUsageDescription']},
            'createdUTC': '2026-11-01T00:00:00Z', 'sourceRevision': 'a'*40, 'sourceSha256': 'b'*64,
            'sourceDirty': False, 'teamIdentifier': None, 'applicationIdentifier': None, 'provisioningExpiresUTC': None
        }

    def write_ipa(self, extra=None):
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            archive.writestr('Payload/Uchiyomi.app/Info.plist', plistlib.dumps(self.info))
            archive.writestr('Payload/Uchiyomi.app/Uchiyomi', b'fixture executable')
            for path, data in (extra or {}).items():
                archive.writestr(path, data)

    def record_for(self, version, build):
        record = copy.deepcopy(self.record)
        record.update(version=version, build=str(build), artifact=f'Uchiyomi-{version}-{build}.ipa', releaseTag=f'ios-v{version}-beta.{build}')
        return record

    def source(self, records):
        return make_source(records, self.listing, 'example/reader', 'https://example.github.io/reader')

    def test_actual_ipa_fields_and_privacy_are_verified(self):
        verify_ipa(self.ipa, self.record)
        app = self.source([self.record])['apps'][0]
        self.assertEqual(app['appPermissions']['privacy'], self.record['privacyPermissions'])
        self.assertEqual(app['versions'][0]['sha256'], self.record['sha256'])
        self.assertIn('/example/reader/releases/download/ios-v0.1.0-beta.1/', app['versions'][0]['downloadURL'])

    def test_tampered_download_and_size_are_rejected(self):
        for key, value in [('sha256', 'c'*64), ('size', self.record['size']+1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_ipa(self.ipa, dict(self.record, **{key: value}))

    def test_metadata_cannot_change_native_identity_or_permissions(self):
        for key, value in [('bundleIdentifier', 'org.other.reader'), ('privacyPermissions', {}), ('minimumIOS', '18.0')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_ipa(self.ipa, dict(self.record, **{key: value}))

    def test_personal_profile_is_rejected_even_with_matching_hash(self):
        self.write_ipa({'Payload/Uchiyomi.app/embedded.mobileprovision': b'private fixture'})
        self.record.update(sha256=hashlib.sha256(self.ipa.read_bytes()).hexdigest(), size=self.ipa.stat().st_size)
        with self.assertRaisesRegex(ValueError, 'provisioning'):
            verify_ipa(self.ipa, self.record)

    def test_simulator_ipa_is_rejected(self):
        self.info['CFBundleSupportedPlatforms'] = ['iPhoneSimulator']
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, 'physical-device'):
            inspect_payload(self.ipa)

    def test_payload_rejects_traversal_other_apps_and_bundled_web_or_tests(self):
        for path in ['../outside', 'Payload/Other.app/file', 'Payload/Uchiyomi.app/mobile-assets.json',
                     'Payload/Uchiyomi.app/PlugIns/Tests.xctest/file']:
            self.write_ipa({path: b'bad'})
            with self.subTest(path=path), self.assertRaises(ValueError):
                inspect_payload(self.ipa)

    def test_feed_uses_numeric_versions_and_builds_not_dates_or_input_order(self):
        records = [self.record_for('0.9.0', 9), self.record_for('0.10.0', 10), self.record_for('0.10.0', 2)]
        records[0]['createdUTC'] = '2030-01-01T00:00:00Z'
        versions = self.source(records)['apps'][0]['versions']
        self.assertEqual([(v['version'], v['buildVersion']) for v in versions], [('0.10.0', '10'), ('0.10.0', '2'), ('0.9.0', '9')])

    def test_source_dates_use_utc_whole_seconds(self):
        self.record['createdUTC'] = '2026-11-01T01:23:45.123456-07:00'
        date = self.source([self.record])['apps'][0]['versions'][0]['date']
        self.assertEqual(date, '2026-11-01T08:23:45Z')

    def test_retry_deduplicates_identical_records_and_rejects_changed_bytes(self):
        self.assertEqual(len(self.source([self.record, copy.deepcopy(self.record)])['apps'][0]['versions']), 1)
        other = dict(self.record, sha256='c'*64)
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            self.source([self.record, other])

    def test_history_cannot_switch_bundle_identity(self):
        with self.assertRaisesRegex(ValueError, 'bundle IDs'):
            self.source([dict(self.record, bundleIdentifier='org.other.reader')])

    def test_all_historical_permissions_remain_declared(self):
        newer = self.record_for('0.2.0', 1002)
        newer['privacyPermissions'] = {'NSCameraUsageDescription': 'Read a server QR code.'}
        permissions = self.source([newer, self.record])['apps'][0]['appPermissions']['privacy']
        self.assertEqual(set(permissions), {'NSLocalNetworkUsageDescription', 'NSCameraUsageDescription'})

    def test_release_tags_are_restricted_and_match_native_version(self):
        self.assertEqual(tag_version('ios-v0.1.0-beta.2'), '0.1.0')
        for tag in ['v0.1.0', 'ios-v01.1.0', 'ios-v0.1.0;echo bad', '../ios-v0.1.0']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                tag_version(tag)
        with self.assertRaisesRegex(ValueError, 'Tag and native'):
            validate_record(dict(self.record, releaseTag='ios-v0.2.0'))

    def test_publication_requires_clean_source_and_no_personal_signing_data(self):
        validate_record(dict(self.record, sourceDirty=True))  # Local preview only.
        for change in [{'sourceDirty': True}, {'distribution': 'development'}, {'teamIdentifier': 'PRIVATE'},
                       {'entitlements': {'get-task-allow': True}}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_record(dict(self.record, **change), publication=True)

    def test_source_rejects_insecure_urls_and_empty_history(self):
        for url in ['http://example.com', 'https://user:secret@example.com', 'https://example.com/?secret=x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                make_source([self.record], self.listing, 'example/reader', url)
        with self.assertRaises(ValueError):
            self.source([])

    def test_immutable_upload_retry_checks_existing_bytes(self):
        downloaded = self.root/'downloaded'
        downloaded.mkdir()
        (downloaded/self.ipa.name).write_bytes(self.ipa.read_bytes())
        verify_existing_files(self.root, downloaded, [self.ipa.name])
        (downloaded/self.ipa.name).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
            verify_existing_files(self.root, downloaded, [self.ipa.name])

    def test_missing_and_inconsistent_release_assets_stop_publication(self):
        release = {'assets': [{'name': 'release.json', 'size': 1}]}
        with self.assertRaisesRegex(ValueError, 'Missing'):
            release_assets(release, self.record)
        release['assets'] += [{'name': 'SHA256SUMS', 'size': 1}, {'name': self.ipa.name, 'size': 1}]
        with self.assertRaisesRegex(ValueError, 'size'):
            release_assets(release, self.record)

    def test_network_failure_does_not_turn_into_an_empty_feed(self):
        with patch('github_release.gh', side_effect=RuntimeError('network unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'network unavailable'):
                fetch_records('example/reader', self.root/'records')

    def test_generator_cli_writes_a_complete_unpublished_site(self):
        (self.root/'release.json').write_text(json.dumps(self.record))
        output = self.root/'site'
        subprocess.run([sys.executable, str(ROOT/'ios/scripts/altstore-source.py'), '--records-dir', str(self.root),
                        '--repository', 'example/reader', '--base-url', 'https://example.github.io/reader',
                        '--output', str(output)], check=True, capture_output=True)
        source = json.loads((output/'altstore.json').read_text())
        self.assertEqual(source['sourceURL'], 'https://example.github.io/reader/altstore.json')
        self.assertEqual(source['identifier'], 'io.github.example.reader.ios.beta')
        self.assertTrue((output/'icon.png').is_file())
        self.assertTrue((output/'index.html').is_file())


if __name__ == '__main__':
    unittest.main()
