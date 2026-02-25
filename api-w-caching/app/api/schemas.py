from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field


class ResponseMetadata(BaseModel):
    protocol: str
    pair: str
    generated_at: datetime
    watermark: datetime | None = None


class WidgetResponse(BaseModel):
    metadata: ResponseMetadata
    data: Any
    status: Literal["success", "error"] = "success"


class ErrorResponse(BaseModel):
    metadata: ResponseMetadata | None = None
    data: dict[str, Any] = Field(default_factory=dict)
    status: Literal["error"] = "error"
