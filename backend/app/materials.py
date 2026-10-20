"""资料解析不接触任意文件路径；原文保存在任务所属的数据库记录中。"""

from io import BytesIO
from pathlib import Path

from fastapi import HTTPException
from pypdf import PdfReader


def extract(name, data):
    suffix = Path(name).suffix.lower()
    try:
        if suffix == ".pdf":
            reader = PdfReader(BytesIO(data))
            if reader.is_encrypted:
                raise ValueError
            text = "\n\n".join(page.extract_text() or "" for page in reader.pages)
            kind = "pdf"
        elif suffix == ".txt":
            text, kind = data.decode("utf-8-sig"), "txt"
        else:
            raise HTTPException(422, "仅支持 UTF-8 TXT 和可提取文字的 PDF")
    except Exception as exc:
        if isinstance(exc, HTTPException):
            raise
        raise HTTPException(
            422, f"无法读取 {Path(name).name}，请检查文件格式、编码或是否加密"
        ) from None
    if not text.strip():
        raise HTTPException(
            422, f"{Path(name).name} 没有可提取文本；扫描 PDF 暂不支持 OCR"
        )
    return {"name": Path(name).name, "kind": kind, "content": text}
