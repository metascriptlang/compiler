import argparse
import hashlib
import json
import os
import stat
import tarfile
from pathlib import Path, PurePosixPath


def extract(archive, destination, report_path, allow_links=False):
    destination = Path(destination)
    report_path = Path(report_path)
    report = {'archive': str(archive), 'destination': str(destination),
              'filter': 'data', 'archiveMembers': {}, 'rwOnlyDifferences': {},
              'verifiedMembers': 0, 'complete': False}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    member_name = None
    try:
        if destination.exists():
            raise ValueError('destination must be fresh')
        destination.mkdir(parents=True)
        with tarfile.open(archive) as source:
            members = source.getmembers()
            for member in members:
                member_name = member.name
                name = PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or str(name) == '.':
                    raise ValueError('archive member must be a relative contained path: ' + member.name)
                key = str(name)
                if key in report['archiveMembers']:
                    raise ValueError('duplicate archive member: ' + member.name)
                if member.mode & ~0o777:
                    raise ValueError('special permission bits: ' + member.name)
                if not (member.isfile() or member.isdir() or
                        allow_links and (member.issym() or member.islnk())):
                    raise ValueError('unsupported archive member type: ' + member.name)
                row = {'mode': member.mode,
                       'type': 'file' if member.isfile() else 'directory' if member.isdir()
                       else 'symlink' if member.issym() else 'hardlink'}
                if member.isfile() or member.islnk():
                    data = source.extractfile(member).read()
                    row.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                if member.issym() or member.islnk():
                    row['target'] = member.linkname
                report['archiveMembers'][key] = row
            for member in members:
                member_name = member.name
                filtered = tarfile.data_filter(member, str(destination))
                if filtered is None or filtered.type != member.type or filtered.linkname != member.linkname:
                    raise ValueError('data filter changes member type/link target: ' + member.name)
                if filtered.mode is not None and (filtered.mode & 0o7111) != (member.mode & 0o7111):
                    raise ValueError('data filter changes executable/special bits: ' + member.name)
                source.extract(member, destination, filter='data')
            for member in members:
                member_name = member.name
                key = str(PurePosixPath(member.name))
                expected = report['archiveMembers'][key]
                path = destination / key
                actual_stat = path.lstat()
                actual_mode = stat.S_IMODE(actual_stat.st_mode)
                if actual_mode & 0o7111 != expected['mode'] & 0o7111:
                    raise ValueError('materialization changes executable/special bits: ' + member.name)
                if member.issym():
                    if not path.is_symlink() or os.readlink(path) != member.linkname:
                        raise ValueError('symlink identity changed: ' + member.name)
                elif member.isdir():
                    if not stat.S_ISDIR(actual_stat.st_mode):
                        raise ValueError('directory identity changed: ' + member.name)
                else:
                    if not stat.S_ISREG(actual_stat.st_mode):
                        raise ValueError('file identity changed: ' + member.name)
                    data = path.read_bytes()
                    if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                        raise ValueError('file bytes changed: ' + member.name)
                    if member.islnk() and not path.samefile(destination / member.linkname):
                        raise ValueError('hardlink identity changed: ' + member.name)
                if actual_mode != expected['mode']:
                    report['rwOnlyDifferences'][key] = {'archiveMode': expected['mode'], 'actualMode': actual_mode}
                report['verifiedMembers'] += 1
        report['complete'] = True
        return report
    except BaseException as error:
        report.update(failedMember=member_name, error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        report_path.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('archive')
    parser.add_argument('destination')
    parser.add_argument('report')
    parser.add_argument('--allow-links', action='store_true')
    args = parser.parse_args()
    result = extract(args.archive, args.destination, args.report, args.allow_links)
    print(json.dumps({'verifiedMembers': result['verifiedMembers'],
                      'rwOnlyDifferences': len(result['rwOnlyDifferences']), 'complete': result['complete']}))
