import json
import os
from pathlib import Path
from typing import Iterable, Union

from qwen_agent.tools.base import BaseTool, register_tool

DEFAULT_MAX_READ_BYTES = 512 * 1024


def _project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _split_root_items(raw: str) -> list[str]:
    if not raw.strip():
        return []
    return [item.strip() for item in raw.split(os.pathsep) if item.strip()]


def _resolve_roots() -> tuple[Path, ...]:
    roots_value = os.getenv('READONLY_FS_ROOTS', '')
    root_items = _split_root_items(roots_value)
    if not root_items:
        legacy_root = os.getenv('READONLY_FS_ROOT', '')
        if legacy_root.strip():
            root_items = [legacy_root.strip()]
    if not root_items:
        root_items = [str(_project_root())]
    return tuple(Path(os.path.expanduser(item)).resolve() for item in root_items)


def _resolve_target(raw_path: str) -> Path:
    return Path(os.path.expanduser(raw_path)).resolve()


def _is_within_root(target: Path, root: Path) -> bool:
    try:
        target.relative_to(root)
        return True
    except ValueError:
        return False


def _ensure_within_roots(target: Path, roots: Iterable[Path]) -> None:
    allowed_roots = tuple(roots)
    if any(_is_within_root(target, root) for root in allowed_roots):
        return
    allowed_text = ', '.join(str(root) for root in allowed_roots)
    raise PermissionError(f'只允许访问这些根目录内的路径: {allowed_text}；拒绝: {target}')


@register_tool('filesystem', allow_overwrite=True)
class ReadOnlyFilesystemTool(BaseTool):
    description = '只读文件系统工具，支持 list 和 read 两种操作。'
    parameters = {
        'type': 'object',
        'properties': {
            'operation': {
                'type': 'string',
                'description': '仅支持 list|read'
            },
            'path': {
                'type': 'string',
                'description': '目标路径'
            },
        },
        'required': ['operation', 'path'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        operation = str(params['operation']).strip().lower()
        if operation not in {'list', 'read'}:
            raise PermissionError(f'只读策略已启用，禁止 operation={operation}')

        roots = _resolve_roots()
        target = _resolve_target(str(params['path']))
        _ensure_within_roots(target, roots)
        if operation == 'list':
            return self._list_path(target)
        return self._read_file(target)

    def _list_path(self, target: Path) -> str:
        if not target.exists():
            raise FileNotFoundError(f'路径不存在: {target}')
        if target.is_file():
            stat = target.stat()
            payload = {'type': 'file', 'path': str(target), 'size': stat.st_size}
            return json.dumps(payload, ensure_ascii=False)

        items = []
        for child in sorted(target.iterdir()):
            item_type = 'dir' if child.is_dir() else 'file'
            size = child.stat().st_size if child.is_file() else None
            items.append({'name': child.name, 'type': item_type, 'size': size})
        payload = {'type': 'dir', 'path': str(target), 'items': items}
        return json.dumps(payload, ensure_ascii=False, indent=2)

    def _read_file(self, target: Path) -> str:
        if not target.exists() or not target.is_file():
            raise FileNotFoundError(f'文件不存在: {target}')
        limit = int(os.getenv('READONLY_FS_MAX_READ_BYTES', str(DEFAULT_MAX_READ_BYTES)))
        size = target.stat().st_size
        if size > limit:
            raise ValueError(f'文件过大: {size} bytes，超过读取上限 {limit} bytes')
        return target.read_text(encoding='utf-8')
