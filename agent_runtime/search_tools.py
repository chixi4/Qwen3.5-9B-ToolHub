import os
import re
from typing import List, Union

from ddgs import DDGS

from qwen_agent.llm.schema import ContentItem
from qwen_agent.tools.base import BaseTool, register_tool

DEFAULT_RESULTS = 6
DEFAULT_REGION = os.getenv('WEB_SEARCH_REGION', 'wt-wt')
DEFAULT_SAFESEARCH = os.getenv('WEB_SEARCH_SAFESEARCH', 'on')
QUERY_SUFFIX_PATTERN = re.compile(
    r'(是谁|是什么|是啥|什么意思|介绍一下|请介绍|是谁啊|是谁呀|是啥啊|是啥呀|吗|嘛|呢|么)$'
)


def _normalize_query(query: str) -> str:
    compact = query.strip()
    compact = compact.replace('？', '?').replace('！', '!').replace('。', '.')
    compact = compact.strip(' ?!.,;:，。？！；：')
    compact = compact.removeprefix('请问').strip()
    compact = QUERY_SUFFIX_PATTERN.sub('', compact).strip()
    compact = compact.strip(' ?!.,;:，。？！；：')
    return compact or query.strip()


def _clamp_results(value: int) -> int:
    if value < 1:
        return 1
    if value > 12:
        return 12
    return value


@register_tool('web_search', allow_overwrite=True)
class LocalWebSearchTool(BaseTool):
    description = '搜索互联网并返回标题、链接和摘要。'
    parameters = {
        'type': 'object',
        'properties': {
            'query': {
                'type': 'string',
                'description': '搜索关键词'
            },
            'max_results': {
                'type': 'integer',
                'description': '返回条数，建议 1 到 12',
                'default': DEFAULT_RESULTS
            }
        },
        'required': ['query'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> str:
        params = self._verify_json_format_args(params)
        query = _normalize_query(params['query'])
        if not query:
            raise ValueError('query 不能为空')
        max_results = _clamp_results(int(params.get('max_results', DEFAULT_RESULTS)))

        with DDGS() as ddgs:
            results = list(
                ddgs.text(
                    query=query,
                    max_results=max_results,
                    region=DEFAULT_REGION,
                    safesearch=DEFAULT_SAFESEARCH,
                )
            )

        if not results:
            return f'未检索到结果，query={query}'

        lines = []
        for idx, item in enumerate(results, start=1):
            title = item.get('title', '').strip()
            href = item.get('href', '').strip()
            body = item.get('body', '').strip()
            lines.append(f'[{idx}] {title}\nURL: {href}\n摘要: {body}')
        return '\n\n'.join(lines)


@register_tool('image_search', allow_overwrite=True)
class LocalImageSearchTool(BaseTool):
    description = '按关键词搜索图片并返回图文结果。'
    parameters = {
        'type': 'object',
        'properties': {
            'query': {
                'type': 'string',
                'description': '图片搜索关键词'
            },
            'max_results': {
                'type': 'integer',
                'description': '返回条数，建议 1 到 12',
                'default': DEFAULT_RESULTS
            }
        },
        'required': ['query'],
    }

    def call(self, params: Union[str, dict], **kwargs) -> List[ContentItem]:
        params = self._verify_json_format_args(params)
        query = _normalize_query(params['query'])
        if not query:
            raise ValueError('query 不能为空')
        max_results = _clamp_results(int(params.get('max_results', DEFAULT_RESULTS)))

        try:
            with DDGS() as ddgs:
                results = list(
                    ddgs.images(
                        query=query,
                        max_results=max_results,
                        region=DEFAULT_REGION,
                        safesearch=DEFAULT_SAFESEARCH,
                    )
                )
        except Exception as exc:
            return [ContentItem(text=f'图片检索失败: {exc}')]

        if not results:
            return [ContentItem(text=f'未检索到图片，query={query}')]

        content: List[ContentItem] = []
        for idx, item in enumerate(results, start=1):
            title = item.get('title', '').strip()
            image_url = item.get('image', '').strip()
            page_url = item.get('url', '').strip()
            text = f'[{idx}] {title}\n图片: {image_url}\n来源: {page_url}'
            content.append(ContentItem(text=text))
            if image_url:
                content.append(ContentItem(image=image_url))
        return content
