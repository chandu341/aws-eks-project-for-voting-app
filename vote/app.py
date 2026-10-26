import os
import json
import uuid
import logging
from flask import Flask, render_template, request, make_response, jsonify
import redis

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Environment configuration
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
OPTION_A = os.getenv("OPTION_A", "Cats 🐱")
OPTION_B = os.getenv("OPTION_B", "Dogs 🐶")

def get_redis_connection():
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, socket_timeout=5)
        r.ping()
        return r
    except Exception as e:
        logger.warning(f"Could not connect to Redis at {REDIS_HOST}:{REDIS_PORT} - {e}")
        return None

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy", "service": "vote-frontend"}), 200

@app.route("/", methods=["GET", "POST"])
def index():
    # Identify voter via cookie or generate new unique voter ID
    voter_id = request.cookies.get("voter_id")
    if not voter_id:
        voter_id = str(uuid.uuid4())[:8]

    vote = None
    status_message = None

    if request.method == "POST":
        vote = request.form.get("vote")
        if vote in ["a", "b"]:
            r = get_redis_connection()
            if r:
                vote_data = json.dumps({"voter_id": voter_id, "vote": vote})
                r.rpush("votes", vote_data)
                status_message = f"Your vote for {'Option A' if vote == 'a' else 'Option B'} was cast successfully!"
                logger.info(f"Voter {voter_id} cast vote {vote}")
            else:
                status_message = "Redis queue is temporarily unavailable. Please try again in a few seconds."

    resp = make_response(render_template(
        "index.html",
        option_a=OPTION_A,
        option_b=OPTION_B,
        voter_id=voter_id,
        current_vote=vote,
        status_message=status_message
    ))
    resp.set_cookie("voter_id", voter_id, max_age=60*60*24*365)
    return resp

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=False)
