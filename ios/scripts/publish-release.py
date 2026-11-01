#!/usr/bin/env python3
"""Publish a verified tagged CI artifact, resuming identical partial uploads safely."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from github_release import gh, release_assets, verify_existing_files
from release_lib import repository_name, require, validate_record, verify_ipa

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--repository', required=True, type=repository_name)
parser.add_argument('--tag', required=True)
args = parser.parse_args()
record = validate_record(json.loads((args.directory/'release.json').read_text()), publication=True)
require(record['releaseTag'] == args.tag, 'Requested tag differs from artifact')
require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == record['sourceRevision'], 'Artifact came from a different commit')
require(subprocess.check_output(['git', 'rev-parse', args.tag+'^{commit}'], text=True).strip() == record['sourceRevision'], 'Tag came from a different commit')
verify_ipa(args.directory/record['artifact'], record)
require((args.directory/'SHA256SUMS').read_text() == f"{record['sha256']}  {record['artifact']}\n", 'Checksum file differs')
# Enumerating avoids treating an authentication/network failure as a missing release.
pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{args.repository}/releases?per_page=100'))
release = next((r for page in pages for r in page if r['tag_name'] == args.tag), None)
names = {record['artifact'], 'release.json', 'SHA256SUMS'}
if release is None:
    with tempfile.TemporaryDirectory() as scratch:
        notes = Path(scratch)/'notes.md'
        notes.write_text(f"Uchiyomi iOS beta {record['version']} ({record['build']}).\n\n"
                         'Install with AltStore Classic, which re-signs this IPA. Requires a compatible server with mobile-assets.json support.\n\n'
                         f"Source commit: {record['sourceRevision']}\n\n"
                         'Automated checks passed. Physical-device and AltStore installation/update acceptance are still pending.\n')
        gh('release', 'create', args.tag, '--repo', args.repository, '--verify-tag', '--draft', '--prerelease', '--latest=false',
           '--title', f"Uchiyomi iOS {record['version']} ({record['build']}) beta", '--notes-file', str(notes))
    release = json.loads(gh('api', f'repos/{args.repository}/releases/tags/{args.tag}'))
existing = {a['name'] for a in release['assets']} & names
with tempfile.TemporaryDirectory() as scratch:
    # Validate existing bytes before adding missing files; never use --clobber.
    for name in sorted(existing):
        gh('release', 'download', args.tag, '--repo', args.repository, '--pattern', name, '--dir', scratch)
    verify_existing_files(args.directory, Path(scratch), existing)
    for name in sorted(names-existing):
        gh('release', 'upload', args.tag, str(args.directory/name), '--repo', args.repository)
        gh('release', 'download', args.tag, '--repo', args.repository, '--pattern', name, '--dir', scratch)
    verify_existing_files(args.directory, Path(scratch), names)
release = json.loads(gh('api', f'repos/{args.repository}/releases/tags/{args.tag}'))
release_assets(release, record)
gh('release', 'edit', args.tag, '--repo', args.repository, '--draft=false', '--prerelease', '--latest=false')
