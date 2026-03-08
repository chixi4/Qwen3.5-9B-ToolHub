import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Union

from qwen_agent.tools.base import BaseTool, register_tool

DEFAULT_TIMEOUT = 60


def _ensure_parent(path: Path) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)


def _build_shell_command(command: str) -> list[str]:
    if os.name == 'nt':
        return ['powershell.exe', '-NoProfile', '-Command', command]
    return ['bash', '-lc', command]


@register_tool('filesystem', allow_overwrite=True)
class FilesystemTool(BaseTool):
    description = '文件系统工具，支持目录列举、读写文件、创建目录和删除。'
    parameters = {
        'type': 'object',
        'properties': {
            'operation': {
                'type': 'string',
                'description': 'list|read|write|append|mkdir|remove'
            },
            'path': {
                'type': 'string',
                'description': '目标路径'
            },
            'content': {
                'type': 'string',
                'description': '写入内容，仅 write 或 append 需要'
            }
        },
        'required': ['operation', 'path'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        operation = params['operation'].strip().lower()
        target = Path(os.path.expanduser(params['path'])).resolve()
        handlers = {
            'list': self._list_path,
            'read': self._read_file,
            'write': self._write_file,
            'append': self._append_file,
            'mkdir': self._mkdir_path,
            'remove': self._remove_path,
        }
        if operation not in handlers:
            raise ValueError(f'不支持的 operation: {operation}')
        return handlers[operation](target, params)

    def _list_path(self, target: Path, params: dict) -> str:
        if not target.exists():
            raise FileNotFoundError(f'路径不存在: {target}')
        if target.is_file():
            stat = target.stat()
            return json.dumps({'type': 'file', 'path': str(target), 'size': stat.st_size}, ensure_ascii=False)

        items = []
        for child in sorted(target.iterdir()):
            item_type = 'dir' if child.is_dir() else 'file'
            size = child.stat().st_size if child.is_file() else None
            items.append({'name': child.name, 'type': item_type, 'size': size})
        return json.dumps({'type': 'dir', 'path': str(target), 'items': items}, ensure_ascii=False, indent=2)

    def _read_file(self, target: Path, params: dict) -> str:
        if not target.exists() or not target.is_file():
            raise FileNotFoundError(f'文件不存在: {target}')
        return target.read_text(encoding='utf-8')

    def _write_file(self, target: Path, params: dict) -> str:
        content = params.get('content')
        if content is None:
            raise ValueError('write 操作必须提供 content')
        _ensure_parent(target)
        target.write_text(content, encoding='utf-8')
        return f'写入成功: {target}'

    def _append_file(self, target: Path, params: dict) -> str:
        content = params.get('content')
        if content is None:
            raise ValueError('append 操作必须提供 content')
        _ensure_parent(target)
        with target.open('a', encoding='utf-8') as fp:
            fp.write(content)
        return f'追加成功: {target}'

    def _mkdir_path(self, target: Path, params: dict) -> str:
        target.mkdir(parents=True, exist_ok=True)
        return f'目录已创建: {target}'

    def _remove_path(self, target: Path, params: dict) -> str:
        if not target.exists():
            raise FileNotFoundError(f'路径不存在: {target}')
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
        return f'删除成功: {target}'


@register_tool('run_command', allow_overwrite=True)
class RunCommandTool(BaseTool):
    description = '执行本机命令并返回退出码、标准输出和标准错误。'
    parameters = {
        'type': 'object',
        'properties': {
            'command': {
                'type': 'string',
                'description': '待执行命令'
            },
            'cwd': {
                'type': 'string',
                'description': '执行目录'
            },
            'timeout_sec': {
                'type': 'integer',
                'description': '超时时间秒数',
                'default': DEFAULT_TIMEOUT
            }
        },
        'required': ['command'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        command = params['command'].strip()
        if not command:
            raise ValueError('command 不能为空')
        timeout_sec = int(params.get('timeout_sec', DEFAULT_TIMEOUT))
        cwd_raw = params.get('cwd') or os.getcwd()
        cwd = str(Path(os.path.expanduser(cwd_raw)).resolve())

        completed = subprocess.run(
            _build_shell_command(command),
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=timeout_sec,
            check=False,
        )
        payload = {
            'command': command,
            'cwd': cwd,
            'returncode': completed.returncode,
            'stdout': completed.stdout,
            'stderr': completed.stderr,
        }
        return json.dumps(payload, ensure_ascii=False, indent=2)
