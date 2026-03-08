from typing import Tuple, Union

import requests
from requests import Response
from requests.exceptions import SSLError
from bs4 import BeautifulSoup

from qwen_agent.tools.base import BaseTool, register_tool

DEFAULT_MAX_CHARS = 8000


def _normalize_text(text: str) -> str:
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line]
    return '\n'.join(lines)


def _fetch_page(url: str, timeout: int = 20) -> Tuple[Response, bool]:
    try:
        response = requests.get(url, timeout=timeout)
        response.raise_for_status()
        return response, False
    except SSLError:
        response = requests.get(url, timeout=timeout, verify=False)
        response.raise_for_status()
        return response, True


def _extract_page_text(html: str, max_chars: int) -> Tuple[str, str]:
    soup = BeautifulSoup(html, 'html.parser')
    for tag in soup(['script', 'style', 'noscript']):
        tag.decompose()
    title = soup.title.string.strip() if soup.title and soup.title.string else ''
    body_text = _normalize_text(soup.get_text(separator='\n'))
    return title, body_text[:max_chars]


@register_tool('web_fetch', allow_overwrite=True)
class WebFetchTool(BaseTool):
    description = '抓取网页正文并返回可读文本。'
    parameters = {
        'type': 'object',
        'properties': {
            'url': {
                'type': 'string',
                'description': '网页链接'
            },
            'max_chars': {
                'type': 'integer',
                'description': '返回最大字符数',
                'default': DEFAULT_MAX_CHARS
            }
        },
        'required': ['url'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        url = params['url'].strip()
        if not url:
            raise ValueError('url 不能为空')
        max_chars = int(params.get('max_chars', DEFAULT_MAX_CHARS))
        if max_chars < 200:
            max_chars = 200

        response, insecure = _fetch_page(url)
        title, body_text = _extract_page_text(response.text, max_chars)
        insecure_note = '说明: 本次请求因证书校验失败使用了 verify=False。\n' if insecure else ''
        return f'标题: {title}\n链接: {url}\n{insecure_note}\n{body_text}'


@register_tool('web_extractor', allow_overwrite=True)
class WebExtractorTool(BaseTool):
    description = '提取单个网页正文。'
    parameters = {
        'type': 'object',
        'properties': {
            'url': {
                'type': 'string',
                'description': '网页链接'
            },
            'max_chars': {
                'type': 'integer',
                'description': '返回最大字符数',
                'default': DEFAULT_MAX_CHARS
            }
        },
        'required': ['url'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        url = params['url'].strip()
        if not url:
            raise ValueError('url 不能为空')
        max_chars = int(params.get('max_chars', DEFAULT_MAX_CHARS))
        response, insecure = _fetch_page(url)
        title, body_text = _extract_page_text(response.text, max_chars)
        insecure_note = '说明: 本次请求因证书校验失败使用了 verify=False。\n' if insecure else ''
        return f'标题: {title}\n链接: {url}\n{insecure_note}\n{body_text}'
