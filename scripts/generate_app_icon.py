#!/usr/bin/env python3
"""Resize the supplied artwork and write a macOS ICNS with PNG representations."""
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
representations = {
    'icp4': 16, 'icp5': 32, 'icp6': 64, 'ic07': 128,
    'ic08': 256, 'ic09': 512, 'ic10': 1024,
    'ic11': 32, 'ic12': 64, 'ic13': 256, 'ic14': 512,
}
chunks = []
with tempfile.TemporaryDirectory() as temporary:
    for tag, size in representations.items():
        output = Path(temporary) / f'{size}.png'
        if not output.exists():
            subprocess.run(['sips', '-z', str(size), str(size), str(root / 'image.png'),
                            '--out', str(output)], check=True, stdout=subprocess.DEVNULL)
        png = output.read_bytes()
        chunks.append(tag.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
body = b''.join(chunks)
(root / 'Resources').mkdir(exist_ok=True)
(root / 'Resources/Portly.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
