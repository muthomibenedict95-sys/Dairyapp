"""Dairy App backend: FastAPI + async SQLAlchemy + MariaDB."""
import os
import time
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
    CREATE TABLE IF NOT EXISTS farmers (
        id CHAR(36) PRIMARY KEY,
        phone VARCHAR(20) NOT NULL UNIQUE,
        pin_hash VARCHAR(100) NOT NULL,
        token CHAR(64) NOT NULL UNIQUE,
        failed_attempts INT NOT NULL DEFAULT 0,
        locked_until BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) CHARACTER SET utf8mb4
    """,
    """
    CREATE TABLE IF NOT EXISTS cows (
        id CHAR(36) PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        tag VARCHAR(50) NOT NULL DEFAULT '',
        deleted TINYINT NOT NULL DEFAULT 0,
        removed_reason VARCHAR(100) NOT NULL DEFAULT '',
        farmer_id CHAR(36) NULL,
        server_updated_at BIGINT NOT NULL DEFAULT 0,
        updated_at BIGINT NOT NULL,
        received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_cows_farmer (farmer_id),
        INDEX idx_cows_server_updated (server_updated_at)
    ) CHARACTER SET utf8mb4
    """,
    """
    CREATE TABLE IF NOT EXISTS milk (
        id CHAR(36) PRIMARY KEY,
        cow_id CHAR(36) NOT NULL,
        litres DOUBLE NOT NULL,
        session VARCHAR(20) NOT NULL,
        date DATE NOT NULL,
        deleted TINYINT NOT NULL DEFAULT 0,
        farmer_id CHAR(36) NULL,
        server_updated_at BIGINT NOT NULL DEFAULT 0,
        updated_at BIGINT NOT NULL,
        received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_milk_cow (cow_id),
        INDEX idx_milk_date (date),
        INDEX idx_milk_farmer (farmer_id),
        INDEX idx_milk_server_updated (server_updated_at)
    ) CHARACTER SET utf8mb4
    """,
]

# Last-write-wins: a row changes only if the incoming updated_at is newer
# AND the caller owns the row (farmer_id never changes after the first insert).
# updated_at must be assigned LAST (MariaDB evaluates assignments in order).
UPSERT_COW = """
INSERT INTO cows (id, name, tag, deleted, removed_reason, farmer_id, server_updated_at, updated_at)
VALUES (:id, :name, :tag, :deleted, :removed_reason, :farmer_id, :now, :updated_at)
ON DUPLICATE KEY UPDATE
    name = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(name), name),
    tag = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(tag), tag),
    deleted = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(deleted), deleted),
    removed_reason = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(removed_reason), removed_reason),
    server_updated_at = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(server_updated_at), server_updated_at),
    updated_at = IF(farmer_id <=> VALUES(farmer_id), GREATEST(updated_at, VALUES(updated_at)), updated_at)
"""

UPSERT_MILK = """
INSERT INTO milk (id, cow_id, litres, session, date, deleted, farmer_id, server_updated_at, updated_at)
VALUES (:id, :cow_id, :litres, :session, :date, :deleted, :farmer_id, :now, :updated_at)
ON DUPLICATE KEY UPDATE
    cow_id = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(cow_id), cow_id),
    litres = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(litres), litres),
    session = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(session), session),
    date = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(date), date),
    deleted = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(deleted), deleted),
    server_updated_at = IF(VALUES(updated_at) > updated_at AND farmer_id <=> VALUES(farmer_id), VALUES(server_updated_at), server_updated_at),
    updated_at = IF(farmer_id <=> VALUES(farmer_id), GREATEST(updated_at, VALUES(updated_at)), updated_at)
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
    removed_reason: str = ""


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


class LoginIn(BaseModel):
    phone: str
    pin: str


MAX_TRIES = 5
LOCK_SECONDS = 15 * 60


async def current_farmer(authorization: str = Header(default=""),
                         x_api_key: str = Header(default="")):
    """Who is calling? A logged-in farmer (token), or the old shared key (temporary)."""
    if authorization.startswith("Bearer "):
        token = authorization[7:]
        async with engine.connect() as conn:
            row = (await conn.execute(
                text("SELECT id FROM farmers WHERE token = :t"),
                {"t": hash_token(token)},
            )).first()
        if row is None:
            raise HTTPException(status_code=401, detail="Please log in again")
        return row[0]
    if x_api_key == API_KEY:
        return None  # TEMPORARY: old phone app; remove once the app logs in
    raise HTTPException(status_code=401, detail="Please log in")


@app.post("/api/login")
async def login(body: LoginIn):
    try:
        phone = normalize_phone(body.phone)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid phone number")
    now = int(time.time())
    result = ("bad", None)
    # Decide inside the transaction, raise AFTER it, so the counter is saved.
    async with engine.begin() as conn:
        row = (await conn.execute(
            text("SELECT id, pin_hash, failed_attempts, locked_until FROM farmers WHERE phone = :p"),
            {"p": phone},
        )).first()
        if row is not None:
            farmer_id, pin_hash, failed, locked_until = row
            if locked_until > now:
                result = ("locked", (locked_until - now + 59) // 60)
            else:
                ok = await asyncio.to_thread(bcrypt.checkpw, body.pin.encode(), pin_hash.encode())
                if ok:
                    token = secrets.token_hex(32)
                    await conn.execute(
                        text("UPDATE farmers SET token = :t, failed_attempts = 0, locked_until = 0 WHERE id = :id"),
                        {"t": hash_token(token), "id": farmer_id},
                    )
                    result = ("ok", (farmer_id, token))
                elif failed + 1 >= MAX_TRIES:
                    await conn.execute(
                        text("UPDATE farmers SET failed_attempts = 0, locked_until = :lu WHERE id = :id"),
                        {"lu": now + LOCK_SECONDS, "id": farmer_id},
                    )
                    result = ("locked", LOCK_SECONDS // 60)
                else:
                    await conn.execute(
                        text("UPDATE farmers SET failed_attempts = :f WHERE id = :id"),
                        {"f": failed + 1, "id": farmer_id},
                    )
    kind, data = result
    if kind == "locked":
        raise HTTPException(status_code=429, detail=f"Too many wrong tries. Try again in {data} minutes")
    if kind == "bad":
        raise HTTPException(status_code=401, detail="Wrong phone number or PIN")
    return {"farmer_id": data[0], "token": data[1]}


@app.post("/api/sync")
async def sync(payload: SyncRequest, farmer_id=Depends(current_farmer)):
    # One transaction: the whole batch is stored, or none of it.
    now = int(time.time() * 1000)
    async with engine.begin() as conn:
        if payload.cows:
            await conn.execute(
                text(UPSERT_COW),
                [{**c.model_dump(), "farmer_id": farmer_id, "now": now} for c in payload.cows],
            )
        if payload.milk:
            await conn.execute(
                text(UPSERT_MILK),
                [{**m.model_dump(), "farmer_id": farmer_id, "now": now} for m in payload.milk],
            )
    return {
        "success": True,
        "cows_received": len(payload.cows),
        "milk_received": len(payload.milk),
        "server_time": now,
    }


@app.get("/api/cows")
async def list_cows(since: int = 0, offset: int = 0, farmer_id=Depends(current_farmer)):
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT id, name, tag, deleted, removed_reason, updated_at, server_updated_at "
                 "FROM cows WHERE farmer_id <=> :f AND server_updated_at >= :since "
                 "ORDER BY server_updated_at, id LIMIT 1000 OFFSET :off"),
            {"f": farmer_id, "since": since, "off": offset},
        )
        return [dict(r._mapping) for r in rows]


@app.get("/api/milk")
async def list_milk(since: int = 0, offset: int = 0, farmer_id=Depends(current_farmer)):
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT id, cow_id, litres, session, date, deleted, updated_at, server_updated_at "
                 "FROM milk WHERE farmer_id <=> :f AND server_updated_at >= :since "
                 "ORDER BY server_updated_at, id LIMIT 1000 OFFSET :off"),
            {"f": farmer_id, "since": since, "off": offset},
        )
        return [{**dict(r._mapping), "date": str(r._mapping["date"])} for r in rows]
