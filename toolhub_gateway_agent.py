import json
import os
import time
import uuid
from typing import Any, Dict, Iterable, List, Optional, Sequence, Union

import requests
from qwen_agent.agents import Assistant
from qwen_agent.llm.schema import ContentItem, Message

import agent_runtime  # noqa: F401
from agent_runtime import readonly_tools  # noqa: F401

DEFAULT_SYSTEM_PROMPT = (
    '你是 Qwen3.5，本地部署的多模态中文助手，当前启用了联网、读图和只读文件工具。\n'
    '默认中文回答。\n'
    '当用户只是打招呼或闲聊时，自然回应即可，不要主动枚举全部工具。\n'
    '你的目标是先使用可用工具获得可验证信息，再给出结论。\n'
    '规则:\n'
    '1. 对最新信息先用 web_search，再按需用 web_fetch 或 web_extractor 抓取正文。\n'
    '2. 对人名、作品名、小众概念等不确定知识先 web_search，若结果歧义则改写关键词再检索一次。\n'
    '3. 允许使用 filesystem 但仅限只读能力 list/read，禁止任何写入、删除或创建操作。\n'
    '4. 禁止执行本机命令、禁止运行代码、禁止写入记忆或任务文件。\n'
    '5. 图片问题先看整图，细节再用 image_zoom_in_tool，bbox_2d 使用 0 到 1000 相对坐标。\n'
    '6. 工具失败时必须明确说明失败原因，不得伪造结果。\n'
    '7. 联网任务要控制上下文预算，优先少量高质量来源，避免搬运大段无关正文。\n'
)

DEFAULT_FUNCTION_LIST = [
    'web_search',
    'web_fetch',
    'web_extractor',
    'image_search',
    'image_zoom_in_tool',
    'filesystem',
    'read_memory',
]
TIMINGS_EMIT_INTERVAL_SEC = 0.8
MAX_FALLBACK_PART_TEXT_CHARS = 512


def fetch_model_id(model_server: str, timeout_sec: int) -> str:
    response = requests.get(f'{model_server}/models', timeout=timeout_sec)
    response.raise_for_status()
    return response.json()['data'][0]['id']


def _extract_image_uri(part: Dict[str, Any]) -> Optional[str]:
    keys = ('image_url', 'image', 'url', 'input_image', 'image_uri')
    for key in keys:
        value = part.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        if isinstance(value, dict):
            nested = value.get('url') or value.get('image_url') or value.get('image')
            if isinstance(nested, str) and nested.strip():
                return nested.strip()
    return None


def _build_compact_part_text(part: Dict[str, Any], part_type: Any) -> str:
    part_keys = sorted(str(k) for k in part.keys())
    payload = {'type': str(part_type or 'unknown'), 'keys': part_keys[:12]}
    text = part.get('text')
    if isinstance(text, str) and text.strip():
        payload['text'] = text.strip()[:MAX_FALLBACK_PART_TEXT_CHARS]
    return json.dumps(payload, ensure_ascii=False)


def extract_generate_cfg(payload: Dict[str, Any]) -> Dict[str, Any]:
    cfg: Dict[str, Any] = {}
    keys = ('temperature', 'top_p', 'top_k', 'presence_penalty', 'frequency_penalty')
    for key in keys:
        value = payload.get(key)
        if value is not None:
            cfg[key] = value
    repeat_penalty = payload.get('repeat_penalty')
    if repeat_penalty is not None:
        cfg['repetition_penalty'] = repeat_penalty
    extra_body = payload.get('extra_body')
    if not isinstance(extra_body, dict):
        extra_body = {}
    chat_template_kwargs = extra_body.get('chat_template_kwargs')
    if not isinstance(chat_template_kwargs, dict):
        chat_template_kwargs = {}
    # 默认开启思考，若上层显式传入 false 则保持用户值。
    chat_template_kwargs.setdefault('enable_thinking', True)
    extra_body['chat_template_kwargs'] = chat_template_kwargs

    requested_reasoning_format = payload.get('reasoning_format')
    if isinstance(requested_reasoning_format, str) and requested_reasoning_format.strip():
        extra_body.setdefault('reasoning_format', requested_reasoning_format.strip())
    else:
        extra_body.setdefault('reasoning_format', 'deepseek')
    extra_body.setdefault('reasoning_budget', -1)
    cfg['extra_body'] = extra_body
    max_tokens = payload.get('max_tokens')
    if isinstance(max_tokens, int) and max_tokens > 0:
        cfg['max_tokens'] = max_tokens
    if not cfg:
        cfg = {'temperature': 0.7, 'top_p': 0.9, 'max_tokens': 512}
    return cfg


def build_agent(
    model_server: str,
    timeout_sec: int,
    generate_cfg: Dict[str, Any],
    model_id: Optional[str] = None,
    system_prompt: str = DEFAULT_SYSTEM_PROMPT,
) -> Assistant:
    if not model_id:
        model_id = fetch_model_id(model_server, timeout_sec)
    llm_cfg = {
        'model': model_id,
        'model_server': model_server,
        'api_key': os.getenv('OPENAI_API_KEY', 'EMPTY'),
        'model_type': 'qwenvl_oai',
        'generate_cfg': generate_cfg,
    }
    return Assistant(
        name='Qwen3.5-9B-ToolHub-8080',
        description='8080 网页工具代理',
        llm=llm_cfg,
        function_list=DEFAULT_FUNCTION_LIST,
        system_message=system_prompt,
    )


def to_content_items(content: Any) -> Union[str, List[ContentItem]]:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return str(content)

    items: List[ContentItem] = []
    for part in content:
        if not isinstance(part, dict):
            items.append(ContentItem(text=str(part)))
            continue
        part_type = part.get('type')
        if part_type in (None, 'text', 'input_text'):
            text = part.get('text', '')
            if text:
                items.append(ContentItem(text=str(text)))
            continue
        image_uri = _extract_image_uri(part)
        if image_uri:
            items.append(ContentItem(image=image_uri))
            continue
        items.append(ContentItem(text=_build_compact_part_text(part, part_type)))
    return items if items else ''


def to_qwen_messages(openai_messages: Sequence[Dict[str, Any]]) -> List[Message]:
    qwen_messages: List[Message] = []
    for item in openai_messages:
        role = str(item.get('role', '')).strip()
        if role not in {'system', 'user', 'assistant'}:
            continue
        qwen_messages.append(Message(role=role, content=to_content_items(item.get('content', ''))))
    if not qwen_messages:
        raise ValueError('messages 为空或不包含可用角色')
    return qwen_messages


def content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return str(content)

    texts: List[str] = []
    for item in content:
        if isinstance(item, str):
            texts.append(item)
            continue
        if isinstance(item, dict) and item.get('text'):
            texts.append(str(item['text']))
            continue
        text = getattr(item, 'text', None)
        if text:
            texts.append(str(text))
    return '\n'.join(texts).strip()


def extract_answer_and_reasoning(messages: Sequence[Message]) -> Dict[str, str]:
    answer = ''
    reasoning_parts: List[str] = []
    for message in messages:
        if getattr(message, 'role', '') != 'assistant':
            continue
        content_text = content_to_text(message.get('content', ''))
        if content_text:
            answer = content_text
        reasoning_text = content_to_text(message.get('reasoning_content', ''))
        if reasoning_text:
            reasoning_parts.append(reasoning_text)
    return {'answer': answer, 'reasoning': '\n'.join(reasoning_parts).strip()}


def run_chat_completion(payload: Dict[str, Any], model_server: str, timeout_sec: int) -> Dict[str, str]:
    openai_messages = payload.get('messages')
    if not isinstance(openai_messages, list):
        raise ValueError('messages 必须是数组')

    model_id = fetch_model_id(model_server, timeout_sec)
    agent = build_agent(model_server, timeout_sec, extract_generate_cfg(payload), model_id=model_id)
    qwen_messages = to_qwen_messages(openai_messages)
    final_batch = None
    for batch in agent.run(qwen_messages):
        final_batch = batch
    if not final_batch:
        raise RuntimeError('未收到模型输出')

    texts = extract_answer_and_reasoning(final_batch)
    answer = texts['answer']
    reasoning = texts['reasoning']
    return {'model': model_id, 'answer': answer, 'reasoning': reasoning}


def build_sse_chunk(
    chat_id: str,
    created: int,
    model: str,
    delta: Dict[str, Any],
    finish_reason: Optional[str] = None,
    timings: Optional[Dict[str, Any]] = None,
) -> bytes:
    chunk = {
        'id': chat_id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish_reason}],
    }
    if timings:
        chunk['timings'] = timings
    return f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode('utf-8')


def text_delta(previous: str, current: str) -> str:
    if not current:
        return ''
    if current.startswith(previous):
        return current[len(previous):]
    return current


def model_base_url(model_server: str) -> str:
    if model_server.endswith('/v1'):
        return model_server[:-3]
    return model_server.rstrip('/')


def count_text_tokens(model_server: str, timeout_sec: int, text: str) -> int:
    if not text:
        return 0
    url = f'{model_base_url(model_server)}/tokenize'
    response = requests.post(url, json={'content': text}, timeout=timeout_sec)
    response.raise_for_status()
    data = response.json()
    tokens = data.get('tokens')
    if not isinstance(tokens, list):
        raise ValueError('tokenize 返回格式异常')
    return len(tokens)


def build_live_timings(token_count: int, elapsed_sec: float) -> Dict[str, Any]:
    safe_elapsed = elapsed_sec if elapsed_sec > 0 else 1e-6
    return {
        'prompt_n': 0,
        'prompt_ms': 0,
        'predicted_n': token_count,
        'predicted_ms': safe_elapsed * 1000.0,
        'predicted_per_second': token_count / safe_elapsed,
        'cache_n': 0,
    }


def merge_generated_text(reasoning: str, answer: str) -> str:
    if reasoning and answer:
        return f'{reasoning}\n{answer}'
    return reasoning or answer


def stream_chat_completion(payload: Dict[str, Any], model_server: str, timeout_sec: int) -> Iterable[bytes]:
    openai_messages = payload.get('messages')
    if not isinstance(openai_messages, list):
        raise ValueError('messages 必须是数组')

    model_id = fetch_model_id(model_server, timeout_sec)
    agent = build_agent(model_server, timeout_sec, extract_generate_cfg(payload), model_id=model_id)
    qwen_messages = to_qwen_messages(openai_messages)

    now = int(time.time())
    chat_id = f'chatcmpl-{uuid.uuid4().hex}'
    yield build_sse_chunk(chat_id, now, model_id, {'role': 'assistant'})

    previous_answer = ''
    previous_reasoning = ''
    started_at = time.perf_counter()
    last_timing_at = started_at
    last_reported_tokens = -1
    last_counted_text = ''
    for batch in agent.run(qwen_messages):
        texts = extract_answer_and_reasoning(batch)
        answer = texts['answer']
        reasoning = texts['reasoning']

        reasoning_inc = text_delta(previous_reasoning, reasoning)
        if reasoning_inc:
            yield build_sse_chunk(chat_id, now, model_id, {'reasoning_content': reasoning_inc})

        answer_inc = text_delta(previous_answer, answer)
        if answer_inc:
            yield build_sse_chunk(chat_id, now, model_id, {'content': answer_inc})

        generated_text = merge_generated_text(reasoning, answer)
        current_time = time.perf_counter()
        should_emit_timing = (
            generated_text
            and generated_text != last_counted_text
            and (current_time - last_timing_at) >= TIMINGS_EMIT_INTERVAL_SEC
        )
        if should_emit_timing:
            token_count = count_text_tokens(model_server, timeout_sec, generated_text)
            if token_count != last_reported_tokens:
                timings = build_live_timings(token_count, current_time - started_at)
                yield build_sse_chunk(chat_id, now, model_id, {}, timings=timings)
                last_reported_tokens = token_count
            last_counted_text = generated_text
            last_timing_at = current_time

        previous_reasoning = reasoning
        previous_answer = answer

    final_generated_text = merge_generated_text(previous_reasoning, previous_answer)
    if final_generated_text and final_generated_text != last_counted_text:
        final_time = time.perf_counter()
        token_count = count_text_tokens(model_server, timeout_sec, final_generated_text)
        if token_count != last_reported_tokens:
            timings = build_live_timings(token_count, final_time - started_at)
            yield build_sse_chunk(chat_id, now, model_id, {}, timings=timings)

    yield build_sse_chunk(chat_id, now, model_id, {}, 'stop')
    yield b'data: [DONE]\n\n'


def build_non_stream_response(answer: str, model: str, reasoning: str = '') -> Dict[str, Any]:
    now = int(time.time())
    message = {'role': 'assistant', 'content': answer}
    if reasoning:
        message['reasoning_content'] = reasoning
    return {
        'id': f'chatcmpl-{uuid.uuid4().hex}',
        'object': 'chat.completion',
        'created': now,
        'model': model,
        'choices': [{
            'index': 0,
            'message': message,
            'finish_reason': 'stop',
        }],
        'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0},
    }


def sse_lines(answer: str, model: str, reasoning: str = '') -> Iterable[bytes]:
    now = int(time.time())
    chat_id = f'chatcmpl-{uuid.uuid4().hex}'
    chunks = [
        {
            'id': chat_id,
            'object': 'chat.completion.chunk',
            'created': now,
            'model': model,
            'choices': [{'index': 0, 'delta': {'role': 'assistant'}, 'finish_reason': None}],
        },
    ]
    if reasoning:
        chunks.append({
            'id': chat_id,
            'object': 'chat.completion.chunk',
            'created': now,
            'model': model,
            'choices': [{'index': 0, 'delta': {'reasoning_content': reasoning}, 'finish_reason': None}],
        })
    chunks.append({
        'id': chat_id,
        'object': 'chat.completion.chunk',
        'created': now,
        'model': model,
        'choices': [{'index': 0, 'delta': {'content': answer}, 'finish_reason': None}],
    })
    chunks.append({
        'id': chat_id,
        'object': 'chat.completion.chunk',
        'created': now,
        'model': model,
        'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
    })
    for chunk in chunks:
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode('utf-8')
    yield b'data: [DONE]\n\n'
