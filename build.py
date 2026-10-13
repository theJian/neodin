#!/usr/bin/env python3
"""Build the small MPack bridge, then the Odin application or tests."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['build', 'test', 'check'], nargs='?', default='build')
parser.add_argument('--release', action='store_true')
args = parser.parse_args()
subprocess.run(['cmake', '-S', str(root / 'native'), '-B', str(root / 'build'), '-DCMAKE_BUILD_TYPE=Release'], check=True)
subprocess.run(['cmake', '--build', str(root / 'build'), '--config', 'Release', '--parallel'], check=True)
command = ['odin', args.action, 'src', '-strict-style', '-vet', '-warnings-as-errors']
if args.action != 'check':
    command += [('-out:build/neodin-tests' if args.action == 'test' else '-out:build/neodin') + ('.exe' if os.name == 'nt' else '')]
if args.release:
    command += ['-o:speed']
if args.action != 'check' and sys.platform == 'darwin':
    prefix = subprocess.check_output(['brew', '--prefix'], text=True).strip()
    command += [f'-extra-linker-flags:-L{prefix}/lib -Wl,-rpath,{prefix}/lib']
elif args.action != 'check' and os.environ.get('SDL_LIBRARY_DIR'):
    command += [f'-extra-linker-flags:-L{os.environ["SDL_LIBRARY_DIR"]}']
subprocess.run(command, cwd=root, check=True)
