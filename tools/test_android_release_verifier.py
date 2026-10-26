"""Fake certificate bytes and mocked tool output only; no private key generation."""
import importlib.util
import hashlib
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('verifier', Path(__file__).with_name('verify-android-release.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
CERT = b'FAKE-PUBLIC-CERTIFICATE'
DIGEST = hashlib.sha256(CERT).hexdigest()

class ReleaseVerifierTest(unittest.TestCase):
    def run_verifier(self, digest=DIGEST, dn='CN=AngelaBettbox', signer_count=1):
        text = f'Verifies\nNumber of signers: {signer_count}\nSigner #1 certificate DN: {dn}\nSigner #1 certificate SHA-256 digest: {digest}\n'
        if signer_count > 1:
            text += f'Signer #2 certificate SHA-256 digest: {DIGEST}\n'
        with patch.dict(os.environ, {'STORE_PASSWORD': 'FAKE-TEST-PASSWORD', 'KEY_ALIAS': 'fake-alias'}), \
             patch.object(verifier.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, CERT), subprocess.CompletedProcess([], 0, text)]) as run:
            result = verifier.verify([Path('fake.apk')], Path('fake.p12'), Path('apksigner'))
            self.assertNotIn('FAKE-TEST-PASSWORD', str(run.call_args_list))
            self.assertIn('-storepass:env', run.call_args_list[0].args[0])
            return result

    def test_matching_certificate(self): self.assertEqual(self.run_verifier(), DIGEST)
    def test_mismatching_certificate(self):
        with self.assertRaises(ValueError): self.run_verifier(digest='0' * 64)
    def test_debug_certificate_rejected_even_if_matching(self):
        with self.assertRaises(ValueError): self.run_verifier(dn='C=US, O=Android, CN=Android Debug')
    def test_multiple_signers_rejected(self):
        with self.assertRaises(ValueError): self.run_verifier(signer_count=2)
    def test_no_apks_rejected(self):
        with self.assertRaises(ValueError): verifier.verify([], Path('x'), Path('y'))
    def test_tool_failure_propagates(self):
        with patch.dict(os.environ, {'STORE_PASSWORD': 'fake', 'KEY_ALIAS': 'fake'}), \
             patch.object(verifier.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['fake'])):
            with self.assertRaises(subprocess.CalledProcessError): verifier.verify([Path('x')], Path('x'), Path('y'))
    def test_missing_environment_rejected(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError): verifier.verify([Path('x')], Path('x'), Path('y'))

    def test_sdk37_labels(self):
        text = f'Number of signers: 1\nV2 Signer: certificate SHA-256 digest: {DIGEST}\nV3.0 Signer: certificate SHA-256 digest: {DIGEST}\n'
        self.assertEqual(verifier.certificate_digests(text), [DIGEST, DIGEST])
    def test_source_stamp_and_public_key_are_not_apk_certificate(self):
        for label in ('Source Stamp Signer certificate', 'V2 Signer: public key'):
            with self.assertRaises(ValueError):
                verifier.certificate_digests(f'Number of signers: 1\n{label} SHA-256 digest: {DIGEST}\n')
    def test_sdk37_debug_rejected_even_when_digest_matches(self):
        text = f'Number of signers: 1\nV2 Signer: certificate SHA-256 digest: {DIGEST}\nV2 Signer: certificate DN: CN=Android Debug\n'
        with patch.dict(os.environ, {'STORE_PASSWORD': 'fake', 'KEY_ALIAS': 'fake'}), \
             patch.object(verifier.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, CERT), subprocess.CompletedProcess([], 0, text)]):
            with self.assertRaisesRegex(ValueError, 'Android Debug'):
                verifier.verify([Path('fake.apk')], Path('fake.p12'), Path('apksigner'))
    def test_sdk37_second_scheme_mismatch_rejected(self):
        text = f'Number of signers: 1\nV2 Signer: certificate SHA-256 digest: {DIGEST}\nV3.0 Signer: certificate SHA-256 digest: {"0"*64}\n'
        with patch.dict(os.environ, {'STORE_PASSWORD': 'fake', 'KEY_ALIAS': 'fake'}), \
             patch.object(verifier.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, CERT), subprocess.CompletedProcess([], 0, text)]):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                verifier.verify([Path('fake.apk')], Path('fake.p12'), Path('apksigner'))
    def test_missing_signer_count_rejected(self):
        with self.assertRaises(ValueError):
            verifier.certificate_digests(f'Signer #1 certificate SHA-256 digest: {DIGEST}\n')

if __name__ == '__main__': unittest.main()
