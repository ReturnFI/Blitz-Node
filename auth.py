import json
import os
import asyncio
import aiohttp
from datetime import datetime, timedelta
from aiohttp import web
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PANEL_API_URL = os.getenv("PANEL_API_URL")
PANEL_API_KEY = os.getenv("PANEL_API_KEY")
users_cache = {}

async def fetch_users_from_panel():
    global users_cache
    
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": PANEL_API_KEY, "accept": "application/json"}
            async with session.get(PANEL_API_URL, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if isinstance(data, list):
                        users_cache = {user.get("username"): user for user in data}
                    else:
                        users_cache = {u.get("username"): u for u in data.get("results", [])}
                    logger.info(f"Fetched {len(users_cache)} users from panel API")
                    return users_cache
                else:
                    logger.error(f"Panel API returned status {resp.status}")
                    return users_cache
    except asyncio.TimeoutError:
        logger.error("Panel API request timeout")
        return users_cache
    except Exception as e:
        logger.error(f"Failed to fetch users from panel: {e}")
        return users_cache

async def authenticate(request):
    try:
        data = await request.json()
        auth_str = data.get("auth")
        
        if not auth_str:
            return web.json_response({"ok": False, "msg": "Auth field missing"}, status=400)
        
        try:
            username, password = auth_str.split(":", 1)
        except ValueError:
            return web.json_response({"ok": False, "msg": "Invalid auth format"}, status=400)

        users = await fetch_users_from_panel()
        user = users.get(username)

        if not user:
            return web.json_response({"ok": False, "msg": "User not found"}, status=401)

        if user.get("blocked", False) or user.get("is_active") == False:
            return web.json_response({"ok": False, "msg": "User is blocked"}, status=401)

        if user.get("password") != password:
            return web.json_response({"ok": False, "msg": "Invalid password"}, status=401)
        
        expiration_days = user.get("expiration_days", 0)
        if expiration_days > 0:
            creation_date_str = user.get("account_creation_date")
            if creation_date_str:
                creation_date = datetime.strptime(creation_date_str, "%Y-%m-%d")
                expiration_date = creation_date + timedelta(days=expiration_days)
                if datetime.now() >= expiration_date:
                    return web.json_response({"ok": False, "msg": "Account expired"}, status=401)

        max_bytes = user.get("max_download_bytes", 0)
        if max_bytes > 0:
            current_up = user.get("upload_bytes", 0)
            current_down = user.get("download_bytes", 0)
            if (current_up + current_down) >= max_bytes:
                return web.json_response({"ok": False, "msg": "Data limit exceeded"}, status=401)

        return web.json_response({"ok": True, "id": username})

    except json.JSONDecodeError:
        return web.json_response({"ok": False, "msg": "Invalid JSON"}, status=400)
    except Exception as e:
        logger.error(f"Auth error: {e}")
        return web.json_response({"ok": False, "msg": "Internal server error"}, status=500)

async def health_check(request):
    users = await fetch_users_from_panel()
    return web.json_response({"status": "ok", "users_count": len(users)})

async def init_app():
    app = web.Application()
    app.router.add_post("/auth", authenticate)
    app.router.add_get("/health", health_check)
    return app

if __name__ == "__main__":
    app = asyncio.run(init_app())
    web.run_app(app, host="127.0.0.1", port=28262)