#!/usr/bin/env python3
"""Copy the licence files of the sources in the GStreamer source bundle into the Engine.

Usage: collect-gstreamer-licenses.py <cerbero source bundle .tar.xz> <output dir> [skipped source name...]

The bundle has sources/<name>-<version>/ with a release archive or a source tree. The licence
files of each source go into <output dir>/<name>-<version>/. A skipped source name is the
folder name without its version (for example "x264"). Prints each source without a licence file.
"""

import io
import re
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

LICENSE_FILE_NAME = re.compile(r"^(COPYING|LICEN[CS]E|NOTICE|COPYRIGHT|PATENTS|UNLICENSE|FTL\.)", re.IGNORECASE)
LICENSE_FOLDER_NAMES = {"LICENSES"}
DOCUMENTATION_FOLDER_NAMES = {"doc", "docs"}
VENDORED_CRATE_FOLDER_NAMES = {"vendor", "cargo-vendor"}
ARCHIVE_SUFFIXES = (".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".zip")
VERSIONED_SOURCE_FOLDER = re.compile(r"^(.*?)-v?\d[^-]*$")


def source_name(source_folder: str) -> str:
    versioned = VERSIONED_SOURCE_FOLDER.match(source_folder)
    return versioned.group(1) if versioned else source_folder


def is_license_path(parts: tuple[str, ...]) -> bool:
    """A licence file at the top of a source, in its LICENSES or doc folder, or in a vendored crate."""
    if ".git" in parts:
        return False
    if len(parts) == 1:
        return bool(LICENSE_FILE_NAME.match(parts[0]))
    if len(parts) == 2:
        return parts[0] in LICENSE_FOLDER_NAMES or (
            parts[0] in DOCUMENTATION_FOLDER_NAMES and bool(LICENSE_FILE_NAME.match(parts[1]))
        )
    if len(parts) == 3:
        return parts[0] in VENDORED_CRATE_FOLDER_NAMES and bool(LICENSE_FILE_NAME.match(parts[2]))
    return False


def without_top_folder(member_paths: list[str]) -> list[tuple[str, tuple[str, ...]]]:
    """Release archives put all files in one top folder. Paths are made relative to it."""
    member_parts = [(path, PurePosixPath(path).parts) for path in member_paths]
    top_folders = {parts[0] for _, parts in member_parts if parts}
    has_one_top_folder = len(top_folders) == 1 and any(len(parts) > 1 for _, parts in member_parts)
    return [(path, parts[1:] if has_one_top_folder else parts) for path, parts in member_parts]


def archive_license_files(archive_name: str, archive_data: bytes):
    """Yields (relative parts, data) for each licence file in a release archive."""
    if archive_name.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(archive_data)) as archive:
            file_paths = [info.filename for info in archive.infolist() if not info.is_dir()]
            for path, parts in without_top_folder(file_paths):
                if is_license_path(parts):
                    yield parts, archive.read(path)
        return
    with tarfile.open(fileobj=io.BytesIO(archive_data)) as archive:
        members = {member.name: member for member in archive.getmembers() if member.isfile()}
        for path, parts in without_top_folder(list(members)):
            if is_license_path(parts):
                yield parts, archive.extractfile(members[path]).read()


def write_license_file(output_dir: Path, source_folder: str, parts: tuple[str, ...], data: bytes) -> None:
    destination = output_dir.joinpath(source_folder, *parts)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    bundle_path, output_dir = Path(sys.argv[1]), Path(sys.argv[2])
    skipped_source_names = set(sys.argv[3:])
    collected_sources: set[str] = set()
    licensed_sources: set[str] = set()

    with tarfile.open(bundle_path, "r|xz") as bundle:
        for member in bundle:
            parts = PurePosixPath(member.name).parts
            if len(parts) < 4 or parts[1] != "sources" or not member.isfile():
                continue
            source_folder, source_parts = parts[2], parts[3:]
            if source_name(source_folder) in skipped_source_names:
                continue
            collected_sources.add(source_folder)
            if len(source_parts) == 1 and source_parts[0].endswith(ARCHIVE_SUFFIXES):
                archive_data = bundle.extractfile(member).read()
                for license_parts, data in archive_license_files(source_parts[0], archive_data):
                    write_license_file(output_dir, source_folder, license_parts, data)
                    licensed_sources.add(source_folder)
            elif is_license_path(source_parts):
                write_license_file(output_dir, source_folder, source_parts, bundle.extractfile(member).read())
                licensed_sources.add(source_folder)

    if not collected_sources:
        sys.exit(f"no sources found in {bundle_path}")
    for source_folder in sorted(collected_sources - licensed_sources):
        print(f"no licence file in sources/{source_folder}")


if __name__ == "__main__":
    main()
