import json
import os
import asyncio
import aiohttp
from datetime import datetime
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

CONFIG_FILE = '/etc/hysteria/config.json'
PANEL_API_URL = os.getenv("PANEL_API_URL")
PANEL_TRAFFIC_URL = os.getenv("PANEL_TRAFFIC_URL")
PANEL_API_KEY = os.getenv("PANEL_API_KEY")
HYSTERIA_API_BASE = "http://127.0.0.1:25413"
SYNC_INTERVAL = int(os.getenv("SYNC_INTERVAL"))

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def get_secret():
    config = load_config()
    return config.get('trafficStats', {}).get('secret')

async def fetch_users_from_panel():
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": PANEL_API_KEY, "accept": "application/json"}
            async with session.get(PANEL_API_URL, headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if isinstance(data, list):
                        return {user.get("username"): user for user in data}
                    else:
                        return {u.get("username"): u for u in data.get("results", [])}
                else:
                    logger.error(f"Panel API returned status {resp.status}")
                    return {}
    except Exception as e:
        logger.error(f"Failed to fetch users from panel: {e}")
        return {}

async def collect_traffic_from_hysteria(secret):
    try:
        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": secret}
            async with session.get(f"{HYSTERIA_API_BASE}/traffic?clear=1", headers=headers, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    traffic_dict = {}
                    for username, stats in data.items():
                        traffic_dict[username] = {
                            "upload_bytes": stats.get("tx", 0),
                            "download_bytes": stats.get("rx", 0)
                        }
                    logger.info(f"Successfully collected traffic for {len(traffic_dict)} users from Hysteria2")
                    return traffic_dict
                else:
                    logger.error(f"Hysteria2 API returned status {resp.status}")
                    return {}
    except Exception as e:
        logger.error(f"Failed to collect traffic from Hysteria2: {e}")
        return {}

async def send_traffic_to_panel(users_traffic):
    if not users_traffic:
        logger.debug("No traffic data to send")
        return True
    
    try:
        async with aiohttp.ClientSession() as session:
            headers = {
                "Authorization": PANEL_API_KEY,
                "accept": "application/json",
                "Content-Type": "application/json"
            }
            payload = {
                "timestamp": datetime.now().isoformat(),
                "users": users_traffic
            }
            async with session.post(PANEL_TRAFFIC_URL, headers=headers, json=payload, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                if resp.status in [200, 201]:
                    logger.info(f"Successfully sent traffic data for {len(users_traffic)} users")
                    return True
                else:
                    error_msg = await resp.text()
                    logger.error(f"Panel API returned status {resp.status}: {error_msg}")
                    return False
    except Exception as e:
        logger.error(f"Failed to send traffic to panel: {e}")
        return False

async def sync_traffic():
    try:
        if not PANEL_API_URL or not PANEL_API_KEY:
            logger.error("Missing PANEL_API_URL or PANEL_API_KEY in environment")
            return
        
        logger.info("Starting traffic sync...")
        
        secret = get_secret()
        if not secret:
            logger.error("Secret not found in config.json")
            return
        
        users_from_panel = await fetch_users_from_panel()
        if not users_from_panel:
            logger.warning("No users fetched from panel")
            return
        
        traffic_stats = await collect_traffic_from_hysteria(secret)
        
        users_traffic = []
        for username, traffic_data in traffic_stats.items():
            if username not in users_from_panel:
                logger.debug(f"Skipping user {username} - not found on panel")
                continue
            
            user_data = users_from_panel[username]
            upload_delta = traffic_data.get("upload_bytes", 0)
            download_delta = traffic_data.get("download_bytes", 0)
            
            if upload_delta == 0 and download_delta == 0 and user_data.get("status") != "On-hold":
                logger.debug(f"Skipping user {username} - no traffic")
                continue
            
            traffic_entry = {
                "username": username,
                "upload_bytes": upload_delta,
                "download_bytes": download_delta,
                "status": "Online" if (upload_delta > 0 or download_delta > 0) else user_data.get("status", "Offline")
            }
            
            if upload_delta > 0 or download_delta > 0:
                if user_data.get("account_creation_date") is None:
                    traffic_entry["account_creation_date"] = datetime.now().strftime("%Y-%m-%d")
                else:
                    traffic_entry["account_creation_date"] = user_data.get("account_creation_date")
            
            users_traffic.append(traffic_entry)
        
        await send_traffic_to_panel(users_traffic)
        logger.info("Traffic sync completed")
    
    except Exception as e:
        logger.error(f"Error during traffic sync: {e}")

async def main():
    logger.info(f"Traffic collector started - sync interval: {SYNC_INTERVAL}s")
    while True:
        await sync_traffic()
        await asyncio.sleep(SYNC_INTERVAL)

if __name__ == "__main__":
    asyncio.run(main())