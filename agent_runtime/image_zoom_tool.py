import math
import os
import uuid
import base64
from io import BytesIO
from pathlib import Path
from typing import List, Tuple, Union

import requests
from PIL import Image

from qwen_agent.llm.schema import ContentItem
from qwen_agent.log import logger
from qwen_agent.tools.base import BaseToolWithFileAccess, register_tool
from qwen_agent.utils.utils import extract_images_from_messages

from .image_source_map import resolve_original_image

MAX_IMAGE_PIXELS = int(os.getenv('SAFE_MAX_IMAGE_PIXELS', str(4 * 1024 * 1024)))
MAX_IMAGE_SIDE = int(os.getenv('SAFE_MAX_IMAGE_SIDE', '3072'))
MIN_IMAGE_SIDE = int(os.getenv('SAFE_MIN_IMAGE_SIDE', '28'))
MIN_BBOX_SIDE = 32
JPEG_QUALITY = int(os.getenv('SAFE_JPEG_QUALITY', '90'))
RESAMPLE_LANCZOS = getattr(getattr(Image, 'Resampling', Image), 'LANCZOS')
HTTP_TIMEOUT_SEC = 30


def _normalize_local_path(path_or_uri: str) -> str:
    raw = path_or_uri.strip()
    if raw.startswith('file://'):
        raw = raw[len('file://'):]
    return str(Path(raw).expanduser().resolve())


def _is_image_data_uri(image_ref: str) -> bool:
    return image_ref.strip().lower().startswith('data:image')


def _load_data_uri_image(image_ref: str) -> Image.Image:
    try:
        header, encoded = image_ref.split(',', 1)
    except ValueError as exc:
        raise ValueError('data URI 格式错误') from exc
    if ';base64' not in header.lower():
        raise ValueError('仅支持 base64 图片 data URI')
    decoded = base64.b64decode(encoded)
    return Image.open(BytesIO(decoded)).convert('RGB')


def _resolve_image_reference(image_ref: str) -> str:
    if _is_image_data_uri(image_ref):
        return image_ref
    if image_ref.startswith('http://') or image_ref.startswith('https://'):
        return image_ref
    return resolve_original_image(image_ref)


def _load_image(image_ref: str, work_dir: str) -> Image.Image:
    if _is_image_data_uri(image_ref):
        return _load_data_uri_image(image_ref)
    if image_ref.startswith('http://') or image_ref.startswith('https://'):
        response = requests.get(image_ref, timeout=HTTP_TIMEOUT_SEC)
        response.raise_for_status()
        return Image.open(BytesIO(response.content)).convert('RGB')

    local = _normalize_local_path(image_ref)
    if os.path.exists(local):
        return Image.open(local).convert('RGB')

    fallback = os.path.join(work_dir, image_ref)
    return Image.open(fallback).convert('RGB')


def _ensure_min_bbox(
    left: float,
    top: float,
    right: float,
    bottom: float,
    img_w: int,
    img_h: int,
) -> Tuple[int, int, int, int]:
    width = max(1.0, right - left)
    height = max(1.0, bottom - top)
    if width >= MIN_BBOX_SIDE and height >= MIN_BBOX_SIDE:
        return int(left), int(top), int(right), int(bottom)

    scale = MIN_BBOX_SIDE / min(width, height)
    half_w = width * scale * 0.5
    half_h = height * scale * 0.5
    center_x = (left + right) * 0.5
    center_y = (top + bottom) * 0.5

    new_left = max(0, int(math.floor(center_x - half_w)))
    new_top = max(0, int(math.floor(center_y - half_h)))
    new_right = min(img_w, int(math.ceil(center_x + half_w)))
    new_bottom = min(img_h, int(math.ceil(center_y + half_h)))
    return new_left, new_top, new_right, new_bottom


def _relative_bbox_to_absolute(bbox_2d: list, img_w: int, img_h: int) -> Tuple[int, int, int, int]:
    rel_x1, rel_y1, rel_x2, rel_y2 = [float(v) for v in bbox_2d]
    abs_x1 = max(0.0, min(img_w, rel_x1 / 1000.0 * img_w))
    abs_y1 = max(0.0, min(img_h, rel_y1 / 1000.0 * img_h))
    abs_x2 = max(0.0, min(img_w, rel_x2 / 1000.0 * img_w))
    abs_y2 = max(0.0, min(img_h, rel_y2 / 1000.0 * img_h))
    left = min(abs_x1, abs_x2)
    top = min(abs_y1, abs_y2)
    right = max(abs_x1, abs_x2)
    bottom = max(abs_y1, abs_y2)
    return _ensure_min_bbox(left, top, right, bottom, img_w, img_h)


def _scale_size(width: int, height: int) -> Tuple[int, int]:
    pixel_count = width * height
    if pixel_count <= 0:
        raise ValueError(f'无效图片尺寸: {width}x{height}')
    scale_by_pixels = math.sqrt(MAX_IMAGE_PIXELS / pixel_count) if pixel_count > MAX_IMAGE_PIXELS else 1.0
    longest_side = max(width, height)
    scale_by_side = MAX_IMAGE_SIDE / longest_side if longest_side > MAX_IMAGE_SIDE else 1.0
    scale = min(1.0, scale_by_pixels, scale_by_side)
    return (
        max(MIN_IMAGE_SIDE, int(width * scale)),
        max(MIN_IMAGE_SIDE, int(height * scale)),
    )


def _resize_crop_if_needed(image: Image.Image) -> Image.Image:
    width, height = image.size
    new_w, new_h = _scale_size(width, height)
    if (new_w, new_h) == (width, height):
        return image
    return image.resize((new_w, new_h), RESAMPLE_LANCZOS)


@register_tool('image_zoom_in_tool', allow_overwrite=True)
class OriginalImageZoomTool(BaseToolWithFileAccess):
    description = '基于原图裁切指定区域，并在裁切后按安全阈值缩放输出。'
    parameters = {
        'type': 'object',
        'properties': {
            'bbox_2d': {
                'type': 'array',
                'items': {
                    'type': 'number'
                },
                'minItems': 4,
                'maxItems': 4,
                'description': '裁切框，格式 [x1,y1,x2,y2]，坐标范围 0 到 1000'
            },
            'label': {
                'type': 'string',
                'description': '目标对象标签'
            },
            'img_idx': {
                'type': 'number',
                'description': '图片索引，从 0 开始'
            }
        },
        'required': ['bbox_2d', 'label', 'img_idx']
    }

    def call(self, params: Union[str, dict], **kwargs) -> List[ContentItem]:
        params = self._verify_json_format_args(params)
        images = extract_images_from_messages(kwargs.get('messages', []))
        if not images:
            return [ContentItem(text='Error: 未找到输入图片')]

        img_idx = int(params['img_idx'])
        if img_idx < 0 or img_idx >= len(images):
            return [ContentItem(text=f'Error: img_idx 越界，当前图片数量 {len(images)}')]

        os.makedirs(self.work_dir, exist_ok=True)
        try:
            image_ref = images[img_idx]
            source_ref = _resolve_image_reference(image_ref)
            image = _load_image(source_ref, self.work_dir)
            bbox = _relative_bbox_to_absolute(params['bbox_2d'], *image.size)
            cropped = image.crop(bbox)
            resized = _resize_crop_if_needed(cropped)
            output_path = os.path.abspath(os.path.join(self.work_dir, f'{uuid.uuid4()}.jpg'))
            resized.save(output_path, format='JPEG', quality=JPEG_QUALITY, optimize=True)
            return [ContentItem(image=output_path)]
        except Exception as exc:
            logger.warning(str(exc))
            return [ContentItem(text=f'Tool Execution Error {exc}')]
