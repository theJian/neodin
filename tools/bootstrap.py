#!/usr/bin/env python3
"""Fetch a pinned local Odin toolchain and SDL SDKs for development and CI."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build'
ODIN = 'dev-2026-10'
SDL = '3.4.18'
TTF = '3.2.2'
UTF8PROC = '2.11.3'
LIBUV = '1.52.1'
NVIM = 'v0.12.3'
NVIM_HASHES = {
    'nvim-linux-x86_64.tar.gz': 'c441b547142860bf01bcce39e36cbed185c41112813e15443b16e5237750724d',
    'nvim-linux-arm64.tar.gz': 'e055af73fa9c72b37456da8d204fa5c09850bc07e80e9176fe3b87d4afb7a3fc',
    'nvim-macos-arm64.tar.gz': '532da1d00e465a660fa01c3d4991333d09c52107dce7df937368545daca0a14e',
    'nvim-macos-x86_64.tar.gz': '4b40e318eb7073321fa5fc06d7f60c3c0de1d7ea50ffbaa8b04286f5484d294f',
    'nvim-win64.zip': '63daa0a0374f2255d2fb4c0867fcacc64a09c8d7ec1c349f781aff1b8350a8ad',
    'nvim-win-arm64.zip': '4e4e8fb9215af9707eaf9e8614106eaf94784bcb5fb319a96934d41918cb388c',
}
ODIN_HASHES = {
    'linux-amd64': 'c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab',
    'linux-arm64': '99c43e9670a285901d6cfee5f56197b74c7d6f7c537b35ecba0c1b44ac2e4df8',
    'macos-arm64': 'b276c6ac87c3eea17446a6ca9080089b6e9f492057fb773591775ee49d92a1cf',
    'windows-amd64': 'b6b2e426a8b6f147b74ec7e18bef8df27cf40fe16193159df7ca09a0cc0c2011',
}


def fetch(repo, tag, name, destination, digest=None, url=None):
    archive = BUILD / 'downloads' / name
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        url = url or f'https://github.com/{repo}/releases/download/{tag}/{name}'
        print(f'Downloading {url}', flush=True)
        urllib.request.urlretrieve(url, archive)
    if digest and hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'Checksum mismatch for {archive}')
    destination.mkdir(parents=True, exist_ok=True)
    if name.endswith('.zip'):
        with zipfile.ZipFile(archive) as contents:
            for entry in contents.infolist():
                if not (destination / entry.filename).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError(f'Unsafe archive path: {entry.filename}')
            contents.extractall(destination)
    else:
        with tarfile.open(archive) as contents:
            contents.extractall(destination, filter='data')
    return destination


def run(*command):
    subprocess.run(command, check=True)


def toolchain():
    system = {'Darwin': 'macos', 'Windows': 'windows', 'Linux': 'linux'}[platform.system()]
    arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'amd64'
    target = f'{system}-{arch}'
    if target not in ODIN_HASHES:
        raise RuntimeError(f'Install Odin manually for {target}')
    extension = 'zip' if system == 'windows' else 'tar.gz'
    folder = fetch('odin-lang/Odin', ODIN, f'odin-{target}-{ODIN}.{extension}', BUILD / 'toolchain', ODIN_HASHES[target])
    executable = next(folder.rglob('odin.exe' if system == 'windows' else 'odin'))
    if os.environ.get('GITHUB_PATH'):
        with open(os.environ['GITHUB_PATH'], 'a') as paths:
            paths.write(str(executable.parent) + '\n')
    print(f'Odin installed in {executable.parent}')


def sdl_dependencies():
    prefix = BUILD / 'deps'
    if os.name == 'nt':
        if platform.machine().lower() not in ('amd64', 'x86_64'):
            raise RuntimeError('The Windows SDK bootstrap currently targets x64')
        for repo, version, name in [('SDL', SDL, f'SDL3-devel-{SDL}-VC.zip'), ('SDL_ttf', TTF, f'SDL3_ttf-devel-{TTF}-VC.zip')]:
            folder = fetch(f'libsdl-org/{repo}', f'release-{version}', name, BUILD / f'sdk/{repo}')
            for file in folder.rglob('*'):
                if file.is_file() and 'x64' in file.parts and file.suffix in ('.lib', '.dll'):
                    destination = prefix / ('lib' if file.suffix == '.lib' else 'bin')
                    destination.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(file, destination / file.name)
    elif platform.system() == 'Linux':
        for repo, version, name, options in [
            ('SDL', SDL, f'SDL3-{SDL}.tar.gz', ['-DSDL_TESTS=OFF', '-DSDL_SHARED=ON', '-DSDL_STATIC=OFF']),
            ('SDL_ttf', TTF, f'SDL3_ttf-{TTF}.tar.gz', ['-DSDLTTF_VENDORED=OFF', '-DSDLTTF_PLUTOSVG=OFF', '-DSDLTTF_SAMPLES=OFF']),
        ]:
            digest = '63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d' if repo == 'SDL_ttf' else None
            folder = fetch(f'libsdl-org/{repo}', f'release-{version}', name, BUILD / 'sources', digest)
            source = folder / (f'SDL3-{version}' if repo == 'SDL' else f'SDL3_ttf-{version}')
            binary = BUILD / f'deps-build/{repo}'
            run('cmake', '-S', str(source), '-B', str(binary), '-DCMAKE_BUILD_TYPE=Release',
                f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}', '-DCMAKE_INSTALL_LIBDIR=lib', *options)
            run('cmake', '--build', str(binary), '--parallel', '4')
            run('cmake', '--install', str(binary))
    else:
        raise RuntimeError('On macOS install libraries with: brew install sdl3 sdl3_ttf utf8proc libuv')
    folder = fetch('JuliaStrings/utf8proc', f'v{UTF8PROC}', f'utf8proc-{UTF8PROC}.tar.gz', BUILD / 'sources',
                   url=f'https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v{UTF8PROC}.tar.gz')
    binary = BUILD / 'deps-build/utf8proc'
    run('cmake', '-S', str(folder / f'utf8proc-{UTF8PROC}'), '-B', str(binary),
        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
        '-DCMAKE_INSTALL_LIBDIR=lib', '-DBUILD_SHARED_LIBS=ON', '-DUTF8PROC_ENABLE_TESTING=OFF')
    run('cmake', '--build', str(binary), '--config', 'Release', '--parallel', '4')
    run('cmake', '--install', str(binary), '--config', 'Release')
    folder = fetch('libuv/libuv', f'v{LIBUV}', f'libuv-v{LIBUV}.tar.gz', BUILD / 'sources',
                   url=f'https://dist.libuv.org/dist/v{LIBUV}/libuv-v{LIBUV}.tar.gz')
    binary = BUILD / 'deps-build/libuv'
    run('cmake', '-S', str(folder / f'libuv-v{LIBUV}'), '-B', str(binary),
        '-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}',
        '-DCMAKE_INSTALL_LIBDIR=lib', '-DLIBUV_BUILD_SHARED=ON', '-DLIBUV_BUILD_TESTS=OFF')
    run('cmake', '--build', str(binary), '--config', 'Release', '--parallel', '4')
    run('cmake', '--install', str(binary), '--config', 'Release')
    print(f'SDL libraries installed in {prefix / "lib"}')


def neovim():
    system = platform.system()
    arm = platform.machine().lower() in ('arm64', 'aarch64')
    if system == 'Windows':
        name = 'nvim-win-arm64.zip' if arm else 'nvim-win64.zip'
    else:
        name = f'nvim-{"macos" if system == "Darwin" else "linux"}-{"arm64" if arm else "x86_64"}.tar.gz'
    folder = fetch('neovim/neovim', NVIM, name, BUILD / 'nvim', NVIM_HASHES[name])
    executable = next(p for p in folder.rglob('nvim.exe' if system == 'Windows' else 'nvim') if p.is_file())
    if os.environ.get('GITHUB_PATH'):
        with open(os.environ['GITHUB_PATH'], 'a') as paths:
            paths.write(str(executable.parent) + '\n')
    print(f'Neovim installed in {executable.parent}; add this directory to PATH for local use')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--odin', action='store_true')
    parser.add_argument('--sdl', action='store_true')
    parser.add_argument('--nvim', action='store_true')
    args = parser.parse_args()
    if not (args.odin or args.sdl or args.nvim):
        parser.error('Choose --odin, --sdl, and/or --nvim')
    if args.odin:
        toolchain()
    if args.sdl:
        sdl_dependencies()
    if args.nvim:
        neovim()
