"""Dairy App backend: FastAPI + async SQLAlchemy + MariaDB."""
import os
import re
import asyncio
import hashlib
import secrets
import uuid
import bcrypt
from sqlalchemy.exc import IntegrityError
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "mysql+aiomysql://dairy_user:dairy_pass@localhost:3306/dairy_db",
)
API_KEY = os.getenv("API_KEY", "change-me-secret-key")

engine = create_async_engine(DATABASE_URL, pool_pre_ping=True)

SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS cows (
        id CHAR(36) PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        tag VARCHAR(50) NOT NULL DEFAULT '',
        updated_at BIGINT NOT NULL,
        received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) CHARACTER SET utf8mb4
    """,
    """
    CREATE TABLE IF NOT EXISTS milk (
        id CHAR(36) PRIMARY KEY,
        cow_id CHAR(36) NOT NULL,
        litres DOUBLE NOT NULL,
        session VARCHAR(20) NOT NULL,
        date DATE NOT NULL,
        updated_at BIGINT NOT NULL,
        received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_milk_cow (cow_id),
        INDEX idx_milk_date (date)
    ) CHARACTER SET utf8mb4
    """,
]

# Last-write-wins: a row changes only if the incoming updated_at is newer.
# updated_at must be assigned LAST (MariaDB evaluates assignments in order).
UPSERT_COW = """
INSERT INTO cows (id, name, tag, updated_at)
VALUES (:id, :name, :tag, :updated_at)
ON DUPLICATE KEY UPDATE
    name = IF(VALUES(updated_at) > updated_at, VALUES(name), name),
    tag = IF(VALUES(updated_at) > updated_at, VALUES(tag), tag),
    updated_at = GREATEST(updated_at, VALUES(updated_at))
"""

UPSERT_MILK = """
INSERT INTO milk (id, cow_id, litres, session, date, updated_at)
VALUES (:id, :cow_id, :litres, :session, :date, :updated_at)
ON DUPLICATE KEY UPDATE
    cow_id = IF(VALUES(updated_at) > updated_at, VALUES(cow_id), cow_id),
    litres = IF(VALUES(updated_at) > updated_at, VALUES(litres), litres),
    session = IF(VALUES(updated_at) > updated_at, VALUES(session), session),
    date = IF(VALUES(updated_at) > updated_at, VALUES(date), date),
    updated_at = GREATEST(updated_at, VALUES(updated_at))
"""



def normalize_phone(raw: str) -> str:
    """Turn 07xx, 01xx, 7xx or +254... into one standard form: +2547xxxxxxxx."""
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("0"):
        digits = "254" + digits[1:]
    elif len(digits) == 9:
        digits = "254" + digits
    if not re.fullmatch(r"254[17]\d{8}", digits):
        raise ValueError("Invalid phone number")
    return "+" + digits


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        for stmt in SCHEMA:
            await conn.execute(text(stmt))
    yield
    await engine.dispose()


app = FastAPI(title="Dairy App API", lifespan=lifespan)


async def verify_key(x_api_key: str = Header(default="")):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


class CowIn(BaseModel):
    id: str
    name: str
    tag: str = ""
    updated_at: int
    deleted: int = 0


class MilkIn(BaseModel):
    id: str
    cow_id: str
    litres: float
    session: str
    date: str  # YYYY-MM-DD
    updated_at: int
    deleted: int = 0


class SyncRequest(BaseModel):
    cows: list[CowIn] = []
    milk: list[MilkIn] = []


class RegisterIn(BaseModel):
    phone: str
    pin: str


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


@app.post("/api/register")
async def register(body: RegisterIn):
    try:
        phone = normalize_phone(body.phone)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid phone number")
    if not re.fullmatch(r"\d{4}", body.pin):
        raise HTTPException(status_code=400, detail="PIN must be 4 digits")
    hashed = await asyncio.to_thread(bcrypt.hashpw, body.pin.encode(), bcrypt.gensalt())
    farmer_id = str(uuid.uuid4())
    token = secrets.token_hex(32)
    try:
        async with engine.begin() as conn:
            await conn.execute(
                text("INSERT INTO farmers (id, phone, pin_hash, token) "
                     "VALUES (:id, :phone, :pin_hash, :token)"),
                {"id": farmer_id, "phone": phone,
                 "pin_hash": hashed.decode(), "token": hash_token(token)},
            )
    except IntegrityError:
        raise HTTPException(status_code=409, detail="This phone number is already registered")
    return {"farmer_id": farmer_id, "token": token}


@app.get("/api/health")
async def health():
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/api/sync", dependencies=[Depends(verify_key)])
async def sync(payload: SyncRequest):
    # One transaction: the whole batch is stored, or none of it.
    async with engine.begin() as conn:
        if payload.cows:
            await conn.execute(text(UPSERT_COW), [c.model_dump() for c in payload.cows])
        if payload.milk:
            await conn.execute(text(UPSERT_MILK), [m.model_dump() for m in payload.milk])
    return {
        "success": True,
        "cows_received": len(payload.cows),
        "milk_received": len(payload.milk),
    }


@app.get("/api/cows", dependencies=[Depends(verify_key)])
async def list_cows():
    async with engine.connect() as conn:
        rows = await conn.execute(text("SELECT id, name, tag, updated_at FROM cows ORDER BY name"))
        return [dict(r._mapping) for r in rows]


@app.get("/api/milk", dependencies=[Depends(verify_key)])
async def list_milk():
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT id, cow_id, litres, session, date, updated_at FROM milk ORDER BY date DESC LIMIT 200")
        )
        return [{**dict(r._mapping), "date": str(r._mapping["date"])} for r in rows]
