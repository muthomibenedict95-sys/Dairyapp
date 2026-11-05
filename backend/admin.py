"""Admin tool, run on the laptop only:
    ./admin.sh list
    ./admin.sh reset 0712345678         (random temporary PIN, shown once)
    ./admin.sh reset 0712345678 4821    (you choose the temporary PIN)
    ./admin.sh unlock 0712345678
PINs are stored as one-way bcrypt hashes: nobody can read them, including the admin.
A reset replaces the PIN, unlocks the account and signs the farmer's phone out."""
import secrets
import sys
import time

import bcrypt
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from main import DATABASE_URL, hash_token, normalize_phone

engine = create_engine(make_url(DATABASE_URL).set(drivername="mysql+pymysql"))


def find(conn, raw_phone):
    try:
        phone = normalize_phone(raw_phone)
    except ValueError:
        sys.exit("That is not a valid phone number")
    row = conn.execute(text("SELECT id FROM farmers WHERE phone = :p"), {"p": phone}).first()
    if row is None:
        sys.exit(f"No farmer with phone {phone}")
    return phone, row[0]


def run():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    with engine.begin() as conn:
        if cmd == "list":
            now = int(time.time())
            rows = conn.execute(
                text("SELECT phone, created_at, locked_until FROM farmers ORDER BY created_at"))
            for phone, created, locked_until in rows:
                state = "LOCKED" if locked_until > now else "ok"
                print(f"{phone}  registered {created}  {state}")
        elif cmd == "reset" and len(args) >= 2:
            phone, farmer_id = find(conn, args[1])
            pin = args[2] if len(args) > 2 else f"{secrets.randbelow(10000):04d}"
            if len(pin) != 4 or not pin.isdigit():
                sys.exit("PIN must be 4 digits")
            hashed = bcrypt.hashpw(pin.encode(), bcrypt.gensalt()).decode()
            conn.execute(
                text("UPDATE farmers SET pin_hash = :h, failed_attempts = 0, locked_until = 0, "
                     "token = :t, must_change = 1, temp_expires = :exp WHERE id = :id"),
                {"h": hashed, "t": hash_token(secrets.token_hex(32)), "exp": int(time.time()) + 24 * 3600, "id": farmer_id},
            )
            print(f"New temporary PIN for {phone}: {pin}")
            print("This PIN works for 24 hours, and the farmer must choose a new PIN at first login.")
        elif cmd == "unlock" and len(args) >= 2:
            phone, farmer_id = find(conn, args[1])
            conn.execute(
                text("UPDATE farmers SET failed_attempts = 0, locked_until = 0 WHERE id = :id"),
                {"id": farmer_id},
            )
            print(f"{phone} unlocked")
        else:
            sys.exit(__doc__)


run()
