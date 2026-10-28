#!/usr/bin/env python3
"""Verify APK signatures against the CI keystore; never display keystore values."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess


def certificate_digests(text):
    """Accept known SDK 36/37 labels, never public-key or source-stamp digests."""
    counts = re.findall(r'^Number of signers:\s*([0-9]+)\s*$', text, re.M)
    if counts != ['1']:
        raise ValueError('Expected exactly one APK signer')
    prefix = r'(?:Signer #[0-9]+|V[1-4](?:\.[0-9]+)? Signer):?'
    digests = re.findall(
        r'^' + prefix + r' certificate SHA-256 digest:\s*([a-fA-F0-9]{64})\s*$',
        text, re.M)
    if not digests:
        raise ValueError('No recognized APK signing certificate digest')
    return [digest.lower() for digest in digests]


def verify(apks, keystore, apksigner):
    if not apks:
        raise ValueError('No APKs supplied for release verification')
    for name in ('STORE_PASSWORD', 'KEY_ALIAS'):
        if not os.environ.get(name):
            raise ValueError('Missing signing environment: ' + name)
    cert = subprocess.run(
        ['keytool', '-exportcert', '-keystore', str(keystore),
         '-storepass:env', 'STORE_PASSWORD', '-alias', os.environ['KEY_ALIAS']],
        check=True, capture_output=True).stdout
    expected = hashlib.sha256(cert).hexdigest()
    for apk in apks:
        result = subprocess.run(
            [str(apksigner), 'verify', '--verbose', '--print-certs', str(apk)],
            check=True, capture_output=True, text=True)
        text = result.stdout
        digests = certificate_digests(text)
        if any(digest != expected for digest in digests):
            raise ValueError('APK certificate does not match the configured release certificate: ' + str(apk))
        if re.search(r'certificate DN:.*\bCN\s*=\s*Android Debug\b', text, re.I):
            raise ValueError('Android Debug certificate is not a production release: ' + str(apk))
        print(str(apk) + ': signature verified; certificate SHA-256=' + expected)
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keystore', type=Path, default=Path('android/app/keystore.jks'))
    parser.add_argument('--apksigner', type=Path, required=True)
    parser.add_argument('apks', type=Path, nargs='+')
    args = parser.parse_args()
    try:
        verify(args.apks, args.keystore, args.apksigner)
    except subprocess.CalledProcessError:
        # Tool stderr can include command-line aliases; keep credential-related diagnostics private.
        parser.exit(1, 'Release certificate export or APK signature verification failed.\n')
    except ValueError as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
