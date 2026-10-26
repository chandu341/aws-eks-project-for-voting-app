import os
import time
import json
import logging
import redis
import psycopg2

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("worker")

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))

DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", 5432))
DB_USER = os.getenv("POSTGRES_USER", "postgres")
DB_PASSWORD = os.getenv("POSTGRES_PASSWORD", "postgres")
DB_NAME = os.getenv("POSTGRES_DB", "postgres")

def connect_db():
    while True:
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                port=DB_PORT,
                user=DB_USER,
                password=DB_PASSWORD,
                dbname=DB_NAME
            )
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS votes (
                        id VARCHAR(255) NOT NULL UNIQUE,
                        vote VARCHAR(255) NOT NULL
                    )
                """)
            logger.info("Connected to PostgreSQL successfully.")
            return conn
        except Exception as e:
            logger.warning(f"Waiting for PostgreSQL database at {DB_HOST}:{DB_PORT}... ({e})")
            time.sleep(2)

def connect_redis():
    while True:
        try:
            r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0)
            r.ping()
            logger.info("Connected to Redis successfully.")
            return r
        except Exception as e:
            logger.warning(f"Waiting for Redis queue at {REDIS_HOST}:{REDIS_PORT}... ({e})")
            time.sleep(2)

def main():
    logger.info("Starting Background Worker service...")
    db_conn = connect_db()
    r = connect_redis()

    while True:
        try:
            # Block until a vote is received in the Redis 'votes' list (timeout 5s)
            item = r.blpop("votes", timeout=5)
            if item:
                _, vote_raw = item
                data = json.loads(vote_raw)
                voter_id = data.get("voter_id")
                vote = data.get("vote")

                if voter_id and vote:
                    with db_conn.cursor() as cur:
                        cur.execute("""
                            INSERT INTO votes (id, vote)
                            VALUES (%s, %s)
                            ON CONFLICT (id) DO UPDATE SET vote = EXCLUDED.vote
                        """, (voter_id, vote))
                    logger.info(f"Processed vote for '{vote}' from voter '{voter_id}' into PostgreSQL.")
        except psycopg2.OperationalError:
            logger.warning("PostgreSQL connection lost. Reconnecting...")
            db_conn = connect_db()
        except redis.ConnectionError:
            logger.warning("Redis connection lost. Reconnecting...")
            r = connect_redis()
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
            time.sleep(1)

if __name__ == "__main__":
    main()
