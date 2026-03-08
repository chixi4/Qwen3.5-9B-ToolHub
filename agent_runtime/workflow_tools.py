import json
import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Union

from qwen_agent.tools.base import BaseTool, register_tool

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / '.tmp' / 'super_agent_data'
MEMORY_FILE = DATA_DIR / 'memory.json'
TODO_DIR = DATA_DIR / 'todos'
TASK_FILE = DATA_DIR / 'tasks.jsonl'


def _build_shell_command(command: str) -> list[str]:
    if os.name == 'nt':
        return ['powershell.exe', '-NoProfile', '-Command', command]
    return ['bash', '-lc', command]


def _ensure_data_dirs() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TODO_DIR.mkdir(parents=True, exist_ok=True)
    if not MEMORY_FILE.exists():
        MEMORY_FILE.write_text('{}', encoding='utf-8')


def _load_memory() -> Dict[str, Any]:
    _ensure_data_dirs()
    return json.loads(MEMORY_FILE.read_text(encoding='utf-8'))


def _save_memory(data: Dict[str, Any]) -> None:
    _ensure_data_dirs()
    MEMORY_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


@register_tool('save_memory', allow_overwrite=True)
class SaveMemoryTool(BaseTool):
    description = '保存一条长期记忆，按 key 覆盖写入。'
    parameters = {
        'type': 'object',
        'properties': {
            'key': {
                'type': 'string',
                'description': '记忆键名'
            },
            'value': {
                'type': 'string',
                'description': '记忆内容'
            }
        },
        'required': ['key', 'value'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        key = params['key'].strip()
        if not key:
            raise ValueError('key 不能为空')
        memory = _load_memory()
        memory[key] = params['value']
        _save_memory(memory)
        return f'已保存记忆: {key}'


@register_tool('read_memory', allow_overwrite=True)
class ReadMemoryTool(BaseTool):
    description = '读取长期记忆，支持读取单个 key 或全部。'
    parameters = {
        'type': 'object',
        'properties': {
            'key': {
                'type': 'string',
                'description': '可选，不传则返回全部记忆'
            }
        },
        'required': [],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        memory = _load_memory()
        key = params.get('key')
        if key:
            return json.dumps({key: memory.get(key)}, ensure_ascii=False, indent=2)
        return json.dumps(memory, ensure_ascii=False, indent=2)


@register_tool('todo_write', allow_overwrite=True)
class TodoWriteTool(BaseTool):
    description = '写入任务清单文件。'
    parameters = {
        'type': 'object',
        'properties': {
            'title': {
                'type': 'string',
                'description': '清单标题'
            },
            'items': {
                'type': 'array',
                'items': {
                    'type': 'string'
                },
                'description': '任务项数组'
            }
        },
        'required': ['title', 'items'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        _ensure_data_dirs()
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        safe_title = ''.join(ch if ch.isalnum() else '_' for ch in params['title'])[:40]
        todo_path = TODO_DIR / f'{ts}_{safe_title}.md'
        lines = [f'# {params["title"]}', '']
        for item in params['items']:
            lines.append(f'- [ ] {item}')
        todo_path.write_text('\n'.join(lines), encoding='utf-8')
        return f'任务清单已写入: {todo_path}'


@register_tool('task', allow_overwrite=True)
class TaskTool(BaseTool):
    description = '登记任务并可选执行命令，返回执行结果。'
    parameters = {
        'type': 'object',
        'properties': {
            'task_name': {
                'type': 'string',
                'description': '任务名称'
            },
            'notes': {
                'type': 'string',
                'description': '任务说明'
            },
            'command': {
                'type': 'string',
                'description': '可选，执行命令'
            }
        },
        'required': ['task_name'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        _ensure_data_dirs()
        event = {
            'time': datetime.now().isoformat(timespec='seconds'),
            'task_name': params['task_name'],
            'notes': params.get('notes', ''),
            'command': params.get('command', ''),
        }
        result = None
        command = params.get('command')
        if command:
            run = subprocess.run(_build_shell_command(command), text=True, capture_output=True, check=False)
            result = {
                'returncode': run.returncode,
                'stdout': run.stdout,
                'stderr': run.stderr,
            }
            event['result'] = result
        with TASK_FILE.open('a', encoding='utf-8') as fp:
            fp.write(json.dumps(event, ensure_ascii=False) + '\n')
        payload = {'saved_to': str(TASK_FILE), 'task': event, 'command_result': result}
        return json.dumps(payload, ensure_ascii=False, indent=2)
