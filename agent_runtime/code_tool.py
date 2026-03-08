import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Union

from qwen_agent.tools.base import BaseTool, register_tool
from qwen_agent.utils.utils import extract_code

ROOT_DIR = Path(__file__).resolve().parents[1]
RUN_DIR = ROOT_DIR / '.tmp' / 'super_agent_data' / 'code_runs'
DEFAULT_TIMEOUT = 60


@register_tool('code_interpreter', allow_overwrite=True)
class LocalCodeInterpreterTool(BaseTool):
    description = '本机 Python 代码执行工具，返回 stdout 和 stderr。'
    parameters = {
        'type': 'object',
        'properties': {
            'code': {
                'type': 'string',
                'description': '要执行的 Python 代码'
            },
            'timeout_sec': {
                'type': 'integer',
                'description': '超时时间，单位秒',
                'default': DEFAULT_TIMEOUT
            }
        },
        'required': ['code'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params_dict = self._parse_code_params(params)
        code = params_dict['code']
        timeout_sec = int(params_dict.get('timeout_sec', DEFAULT_TIMEOUT))
        RUN_DIR.mkdir(parents=True, exist_ok=True)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.py', dir=RUN_DIR, delete=False, encoding='utf-8') as fp:
            fp.write(code)
            script_path = fp.name

        completed = subprocess.run(
            [sys.executable, script_path],
            text=True,
            capture_output=True,
            timeout=timeout_sec,
            check=False,
        )
        payload = {
            'script_path': script_path,
            'returncode': completed.returncode,
            'stdout': completed.stdout,
            'stderr': completed.stderr,
        }
        return json.dumps(payload, ensure_ascii=False, indent=2)

    def _parse_code_params(self, params: Union[str, dict]) -> dict:
        if isinstance(params, dict):
            if 'code' not in params:
                raise ValueError('code 字段缺失')
            return params
        try:
            parsed = json.loads(params)
            if isinstance(parsed, dict) and 'code' in parsed:
                return parsed
        except json.JSONDecodeError:
            pass
        code = extract_code(params)
        if not code.strip():
            raise ValueError('未检测到可执行代码')
        return {'code': code}
