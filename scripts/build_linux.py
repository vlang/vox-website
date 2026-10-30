#!/usr/bin/env python3
"""Cross-compile, then link the real target libpq instead of linuxroot's stubs."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--v', default='v')
    parser.add_argument('--vflags', default='-old-compiler')
    parser.add_argument('--path', required=True)
    parser.add_argument('--libpq', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    library = args.libpq.resolve()
    if not library.is_file():
        raise SystemExit('Missing Linux libpq.so.5. Run ./deploy.sh or set LINUX_LIBPQ to the target library.')
    if library.read_bytes()[:4] != b'\x7fELF':
        raise SystemExit('LINUX_LIBPQ must be a Linux ELF shared library.')
    (root / 'build').mkdir(exist_ok=True)
    (root / 'bin').mkdir(exist_ok=True)
    binary = root / 'bin/vox-website-linux-amd64'
    command = [args.v, *shlex.split(args.vflags), '-showcc', '-keepc', '-path', args.path,
               '-os', 'linux', '-arch', 'amd64', '-prod', '-cflags',
               '-fno-lto -DMBEDTLS_NO_UDBL_DIVISION', '-o', str(binary), '.']
    compiled = subprocess.run(command, cwd=root, capture_output=True, text=True)
    output = compiled.stdout + compiled.stderr
    (root / 'build/linux-build.log').write_text(output)
    if compiled.returncode:
        raise SystemExit(output[-6000:])
    # This V cross-linker ignores -ldflags. Reuse its emitted link command,
    # substituting the system library and omitting the incomplete pgport stubs.
    linker = None
    for line in reversed(output.splitlines()):
        try:
            parts = shlex.split(line)
        except ValueError:
            continue
        if parts and Path(parts[0]).name in ('ld.lld', 'ld.lld.exe') and '-lpq' in parts:
            linker = [str(library) if part == '-lpq' else part for part in parts
                      if 'pgport_stubs.c.' not in part]
            break
    if linker is None:
        binary.unlink(missing_ok=True)
        raise SystemExit('Could not locate the V cross-link command; see build/linux-build.log.')
    linker.append('--allow-shlib-undefined')
    linked = subprocess.run(linker, cwd=root, capture_output=True, text=True)
    with (root / 'build/linux-build.log').open('a') as log:
        log.write('\nSystem libpq link:\n' + linked.stdout + linked.stderr)
    if linked.returncode:
        binary.unlink(missing_ok=True)
        raise SystemExit(linked.stdout + linked.stderr)
    report = {'compiler_command': command, 'linker_command': linker,
              'libpq_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    (root / 'build/linux-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Built Linux x86-64 release with the target server libpq.so.5.')


if __name__ == '__main__':
    main()
