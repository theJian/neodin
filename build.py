#!/usr/bin/env python3
"""Build the native dependency bridge, then the Odin application or tests."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import shutil

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['build', 'test', 'check'], nargs='?', default='build')
parser.add_argument('--release', action='store_true')
parser.add_argument('--sdl-library-dir', default=os.environ.get('SDL_LIBRARY_DIR'))
args = parser.parse_args()
subprocess.run(['cmake', '-S', str(root / 'native'), '-B', str(root / 'build'), '-DCMAKE_BUILD_TYPE=Release'], check=True)
subprocess.run(['cmake', '--build', str(root / 'build'), '--config', 'Release', '--parallel'], check=True)
local_odin = root / 'build/toolchain'
executable = 'odin.exe' if os.name == 'nt' else 'odin'
odin = next(local_odin.rglob(executable), None) if local_odin.exists() else None
command = [str(odin) if odin else 'odin', args.action, 'src', '-strict-style', '-vet', '-warnings-as-errors']
library_dir = Path(args.sdl_library_dir).resolve() if args.sdl_library_dir else root / 'build/deps/lib'
if not library_dir.exists() and sys.platform == 'darwin' and shutil.which('brew'):
    library_dir = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip()) / 'lib'
if os.name == 'nt':
    # The upstream Windows bindings use package-relative import libraries.
    # Make a local binding overlay instead of modifying the installed compiler.
    odin_root = Path(subprocess.check_output([command[0], 'root'], text=True).strip())
    overlay = root / 'build/vendor/sdl3'
    shutil.copytree(odin_root / 'vendor/sdl3', overlay, dirs_exist_ok=True)
    for name, destination in [('SDL3.lib', overlay), ('SDL3_ttf.lib', overlay / 'ttf')]:
        shutil.copy2(library_dir / name, destination / name)
    command += [f'-collection:vendor={root / "build/vendor"}']
    for dll in (library_dir.parent / 'bin').glob('*.dll'):
        shutil.copy2(dll, root / 'build' / dll.name)
if args.action == 'test':
    # Keep embedded editor integration tests deterministic and serialized.
    command += ['-define:ODIN_TEST_THREADS=1']
if args.action != 'check':
    command += [('-out:build/neodin-tests' if args.action == 'test' else '-out:build/neodin') + ('.exe' if os.name == 'nt' else '')]
if args.release:
    command += ['-o:speed']
if args.action != 'check' and library_dir.exists():
    if os.name == 'nt':
        command += [f'-extra-linker-flags:/LIBPATH:"{library_dir}"']
    else:
        command += [f'-extra-linker-flags:-L"{library_dir}" -Wl,-rpath,"{library_dir}"']
environment = os.environ.copy()
if args.action == "test":
    environment["NVIM_LOG_FILE"] = str(root / "build/test-nvim.log")
subprocess.run(command, cwd=root, env=environment, check=True)
