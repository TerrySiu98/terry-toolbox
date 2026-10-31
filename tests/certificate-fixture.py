#!/usr/bin/env python3
"""Create a local, self-signed time-bound certificate without new OpenSSL flags."""
import argparse
import datetime
import os
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("certificate", type=Path)
    parser.add_argument("key", type=Path)
    parser.add_argument("start", help="UTC YYYYMMDDHHMMSSZ")
    parser.add_argument("end", help="UTC YYYYMMDDHHMMSSZ")
    parser.add_argument("--hostname", default="example.com")
    args = parser.parse_args()
    before = datetime.datetime.strptime(args.start, "%Y%m%d%H%M%SZ")
    after = datetime.datetime.strptime(args.end, "%Y%m%d%H%M%SZ")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, args.hostname)])
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(before).not_valid_after(after)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(args.hostname)]), False)
            .sign(key, hashes.SHA256()))
    for path, data in ((args.key, key.private_bytes(serialization.Encoding.PEM,
                       serialization.PrivateFormat.TraditionalOpenSSL,
                       serialization.NoEncryption())),
                       (args.certificate, cert.public_bytes(serialization.Encoding.PEM))):
        with path.open("xb") as file:
            os.chmod(path, 0o600)
            file.write(data)


if __name__ == "__main__":
    main()
